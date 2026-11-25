import SceneKit
import AppKit
import simd

// MARK: - Maschera gobo pronta per il rendering

/// Maschera gobo decodificata dal PNG incorporato nel profilo della fixture.
/// Bianco = la luce passa, nero = la luce è bloccata. Usata solo dal render thread.
///
/// Da una singola maschera si ricavano tre rappresentazioni:
/// - `image`: l'immagine proiettata da `SCNLight.gobo` (illumina davvero oggetti e palco);
/// - `spotImage`: maschera × alone radiale, per la macchia di luce additiva sul pavimento;
/// - `rays(grid:)`: un fascio di raggi (linee additive) che parte dall'apice e passa solo dove la maschera è
///   chiara, così anche il cono visibile in aria risulta sagomato dal gobo.
final class GoboMask {
    /// Lato (in pixel) delle maschere memorizzate: gli import vengono ridotti/ritagliati a questa misura.
    static let size = 256

    let revision: UUID
    let image: NSImage
    let spotImage: NSImage

    private let gray: [UInt8]               // luminanza, riga 0 = bordo superiore
    private var rayCache: [Int: SCNGeometry] = [:]

    init?(data: Data, revision: UUID) {
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        let s = GoboMask.size

        // Qualsiasi immagine (grigi, colore, con trasparenza) → luminanza 8 bit su fondo nero.
        var buf = [UInt8](repeating: 0, count: s * s)
        let drawn: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: s, height: s))
            return true
        }
        guard drawn,
              let plain = GoboMask.rgbImage(gray: buf, radial: false),
              let spot = GoboMask.rgbImage(gray: buf, radial: true)
        else { return nil }

        self.revision = revision
        self.gray = buf
        self.image = plain
        self.spotImage = spot
    }

    // MARK: Immagini

    /// Profilo dell'alone della macchia a terra (stessi nodi del gradiente radiale di `SpotVisual`).
    private static func falloff(_ r: Float) -> Float {
        if r >= 1 { return 0 }
        if r < 0.3 { return 1 - (r / 0.3) * 0.45 }
        if r < 0.7 { return 0.55 - ((r - 0.3) / 0.4) * 0.40 }
        return 0.15 - ((r - 0.7) / 0.3) * 0.15
    }

    private static func rgbImage(gray: [UInt8], radial: Bool) -> NSImage? {
        let s = size
        guard let ctx = CGContext(
            data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let base = ctx.data else { return nil }

        let rowBytes = ctx.bytesPerRow
        let p = base.assumingMemoryBound(to: UInt8.self)
        let c = Float(s - 1) / 2
        for y in 0..<s {
            for x in 0..<s {
                var v = Float(gray[y * s + x]) / 255
                if radial {
                    let dx = (Float(x) - c) / c
                    let dy = (Float(y) - c) / c
                    v *= falloff(sqrtf(dx * dx + dy * dy))
                }
                let b = UInt8(max(0, min(255, v * 255 + 0.5)))
                let i = y * rowBytes + x * 4
                p[i] = b
                p[i + 1] = b
                p[i + 2] = b
                p[i + 3] = 255
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: s, height: s))
    }

    // MARK: Fascio di raggi

    /// Geometria unitaria (apice in origine, asse +Y, raggio 1 a Y = 1) fatta di linee che attraversano solo
    /// le zone chiare della maschera. Si scala come il cono: (r, lunghezza, r). Nil se la maschera è tutta nera.
    /// Asse X = destra dell'immagine, asse Z = alto dell'immagine (come l'orientamento di `SCNLight.gobo`
    /// sul nodo luce della fixture).
    func rays(grid: Int) -> SCNGeometry? {
        if let g = rayCache[grid] { return g }

        let s = GoboMask.size
        let cell = max(1, s / grid)
        let ts: [Float] = [0.03, 0.28, 0.58, 1.0]
        var verts: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []
        var idx: [Int32] = []

        for gy in 0..<grid {
            for gx in 0..<grid {
                let u = (Float(gx) + 0.5) / Float(grid) * 2 - 1
                let v = 1 - (Float(gy) + 0.5) / Float(grid) * 2          // verso l'alto
                guard u * u + v * v <= 1 else { continue }              // solo dentro il cerchio del cono

                // Media della maschera sulla cella.
                let cx = Int((Float(gx) + 0.5) / Float(grid) * Float(s))
                let cy = Int((Float(gy) + 0.5) / Float(grid) * Float(s))
                var sum = 0
                var count = 0
                for yy in max(0, cy - cell / 2)..<min(s, cy + cell / 2 + 1) {
                    for xx in max(0, cx - cell / 2)..<min(s, cx + cell / 2 + 1) {
                        sum += Int(gray[yy * s + xx])
                        count += 1
                    }
                }
                let g = Float(sum) / Float(max(count, 1)) / 255
                guard g >= 0.12 else { continue }

                let first = Int32(verts.count)
                for (k, t) in ts.enumerated() {
                    verts.append(SCNVector3(CGFloat(u * t), CGFloat(t), CGFloat(v * t)))
                    let b = g * powf(1 - t, 1.4)
                    colors.append(SIMD4<Float>(b, b, b, 1))
                    if k > 0 {
                        idx.append(first + Int32(k - 1))
                        idx.append(first + Int32(k))
                    }
                }
            }
        }
        guard !idx.isEmpty else { return nil }

        let vSrc = SCNGeometrySource(vertices: verts)
        let cData = Data(bytes: colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let cSrc = SCNGeometrySource(
            data: cData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let element = SCNGeometryElement(indices: idx, primitiveType: .line)
        let geometry = SCNGeometry(sources: [vSrc, cSrc], elements: [element])
        rayCache[grid] = geometry
        return geometry
    }
}

// MARK: - Cache delle maschere

/// Evita di ridecodificare lo stesso PNG per ogni fixture: la chiave è la `revision` dello slot.
enum GoboMaskCache {
    private static let lock = NSLock()
    private static var items: [UUID: GoboMask] = [:]

    static func mask(for slot: GoboSlot) -> GoboMask? {
        guard let data = slot.imageData else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let m = items[slot.revision] { return m }
        guard let m = GoboMask(data: data, revision: slot.revision) else { return nil }
        if items.count > 64 { items.removeAll() }
        items[slot.revision] = m
        return m
    }
}

// MARK: - Importazione delle immagini

/// Prepara un file JPG/PNG scelto dall'utente per essere salvato nel profilo e nei file scena.
enum GoboImageImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Il file non è un'immagine leggibile (usa JPG o PNG)."
            case .encodeFailed: return "Impossibile preparare la maschera."
            }
        }
    }

    /// Ritaglia al centro un quadrato, riduce a `GoboMask.size`, converte in scala di grigi e restituisce un PNG.
    /// Le zone trasparenti contano come nere (bloccano la luce).
    static func normalizedPNG(from url: URL) throws -> Data {
        guard let source = NSImage(contentsOf: url),
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw ImportError.unreadable }

        let side = min(cg.width, cg.height)
        guard side > 0,
              let square = cg.cropping(to: CGRect(
                x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side))
        else { throw ImportError.unreadable }

        let s = GoboMask.size
        guard let ctx = CGContext(
            data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw ImportError.encodeFailed }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.draw(square, in: CGRect(x: 0, y: 0, width: s, height: s))

        guard let out = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
        else { throw ImportError.encodeFailed }
        return png
    }
}
