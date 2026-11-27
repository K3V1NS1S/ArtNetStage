import SceneKit
import AppKit
import simd

// MARK: - Utilità

fileprivate func colorKey(_ c: SIMD3<Float>) -> UInt32 {
    func q(_ v: Float) -> UInt32 { UInt32(max(0, min(255, v * 255))) }
    return (q(c.x) << 16) | (q(c.y) << 8) | q(c.z)
}

fileprivate func nsColor(_ c: SIMD3<Float>, scale: Float = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat(min(max(c.x * scale, 0), 1)),
        green: CGFloat(min(max(c.y * scale, 0), 1)),
        blue: CGFloat(min(max(c.z * scale, 0), 1)),
        alpha: 1
    )
}

// MARK: - Mappa canali

/// Indici (0-based) dei canali per ruolo, calcolati una sola volta per profilo.
struct ChannelMap {
    var dimmer: Int?
    var red: Int?
    var green: Int?
    var blue: Int?
    var white: Int?
    var wheel: Int?
    var pan: Int?
    var panFine: Int?
    var tilt: Int?
    var tiltFine: Int?
    var speed: Int?
    var strobe: Int?
    var gobo: Int?
    var prism: Int?
    var prismRotation: Int?
    var smoke: Int?
    /// LED di una barra, nell'ordine in cui compaiono i canali (v3.1): il pixel i-esimo usa l'i-esimo canale di ogni ruolo.
    var pixels: [FixtureProfile.PixelChannels] = []
    var colorMode: ColorMode = .rgb
    /// Slot della ruota ordinati per valore DMX crescente = ordine fisico lungo la ruota.
    var wheelSlots: [(from: Int, to: Int, rgb: SIMD3<Float>)] = []
    var goboSlots: [(from: Int, to: Int, mask: GoboMask?)] = []

    var hasRGB: Bool { red != nil || green != nil || blue != nil }
    var hasRGBW: Bool { hasRGB || white != nil }

    init(profile: FixtureProfile) {
        func first(_ role: ChannelRole) -> Int? {
            profile.channels.firstIndex(where: { $0.role == role })
        }
        dimmer = first(.dimmer)
        red = first(.red)
        green = first(.green)
        blue = first(.blue)
        white = first(.white)
        wheel = first(.colorWheel)
        pan = first(.pan)
        panFine = first(.panFine)
        tilt = first(.tilt)
        tiltFine = first(.tiltFine)
        speed = first(.panTiltSpeed)
        strobe = first(.strobe)
        gobo = first(.gobo)
        prism = first(.prism)
        prismRotation = first(.prismRotation)
        smoke = first(.smoke)
        pixels = profile.pixelLayout
        colorMode = profile.colorMode
        if let w = wheel {
            wheelSlots = profile.channels[w].wheelSlots
                .sorted { $0.from < $1.from }
                .map { (from: $0.from, to: $0.to, rgb: parseHex($0.colorHex)) }
        }
        if gobo != nil {
            goboSlots = profile.gobos.map {
                (from: $0.from, to: $0.to, mask: GoboMaskCache.mask(for: $0))
            }
        }
    }

    /// Indice (nell'ordine della ruota) dello slot che contiene il valore DMX; nil se il valore cade fuori da ogni slot.
    func wheelSlotIndex(for value: Int) -> Int? {
        wheelSlots.firstIndex { value >= $0.from && value <= $0.to }
    }

    /// Maschera attiva al valore DMX del canale Gobo; nil = gobo aperto (nessuna sagomatura).
    func goboMask(for value: Int) -> GoboMask? {
        for s in goboSlots where value >= s.from && value <= s.to { return s.mask }
        return nil
    }
}

// MARK: - Cono di luce volumetrico

/// Cono additivo con dissolvenza lungo l'asse (colori per vertice). Asse +Y, apice in origine.
final class BeamVisual {
    let node = SCNNode()
    private let outer: SCNNode
    private let inner: SCNNode?
    private let outerMat: SCNMaterial
    private let innerMat: SCNMaterial?
    private var lastKey: UInt32 = .max
    private var lastAngle = -1.0
    private var lastLength = -1.0

    // Modalità gobo: al posto del cono pieno, un fascio di raggi sagomato dalla maschera.
    private var rayNode: SCNNode?
    private var rayMat: SCNMaterial?
    private var shaped = false

    private static let baseCone: SCNGeometry = makeCone()

    init(core: Bool) {
        let om = BeamVisual.makeMaterial()
        let og = BeamVisual.baseCone.copy() as! SCNGeometry
        og.materials = [om]
        let on = SCNNode(geometry: og)
        on.renderingOrder = 100
        outerMat = om
        outer = on

        if core {
            let im = BeamVisual.makeMaterial()
            let ig = BeamVisual.baseCone.copy() as! SCNGeometry
            ig.materials = [im]
            let inn = SCNNode(geometry: ig)
            inn.renderingOrder = 101
            innerMat = im
            inner = inn
        } else {
            innerMat = nil
            inner = nil
        }

        node.name = SceneHelpers.ignoreName
        node.addChildNode(on)
        if let inner { node.addChildNode(inner) }
        node.isHidden = true
    }

    /// Attiva o disattiva la sagomatura gobo.
    /// - `shaped == false`: cono pieno normale.
    /// - `shaped == true` con `source`: il cono pieno sparisce e compare il fascio di raggi della maschera.
    /// - `shaped == true` senza `source`: maschera completamente nera, il fascio non si vede.
    func setRays(_ source: SCNGeometry?, shaped: Bool) {
        rayNode?.removeFromParentNode()
        rayNode = nil
        rayMat = nil
        self.shaped = shaped

        if shaped, let source, let copy = source.copy() as? SCNGeometry {
            let m = BeamVisual.makeMaterial()
            copy.materials = [m]
            let n = SCNNode(geometry: copy)
            n.renderingOrder = 102
            n.castsShadow = false
            node.addChildNode(n)
            rayNode = n
            rayMat = m
        }
        // Forza il riapplicare di scala e colore al prossimo update.
        lastKey = .max
        lastAngle = -1
        lastLength = -1
    }

    func update(color: SIMD3<Float>, intensity: Float, halfAngleDeg: Double, length: Double) {
        let c = color * intensity
        if max(c.x, max(c.y, c.z)) < 0.004 {
            node.isHidden = true
            return
        }
        node.isHidden = false
        outer.isHidden = shaped
        inner?.isHidden = shaped
        rayNode?.isHidden = !shaped

        if abs(halfAngleDeg - lastAngle) > 0.01 || abs(length - lastLength) > 0.01 {
            lastAngle = halfAngleDeg
            lastLength = length
            let r = Float(length * tan(halfAngleDeg * Double.pi / 180))
            outer.simdScale = SIMD3<Float>(r, Float(length), r)
            inner?.simdScale = SIMD3<Float>(r * 0.4, Float(length), r * 0.4)
            rayNode?.simdScale = SIMD3<Float>(r, Float(length), r)
        }

        let key = colorKey(c)
        if key != lastKey {
            lastKey = key
            outerMat.multiply.contents = nsColor(c, scale: 0.32)
            innerMat?.multiply.contents = nsColor(c, scale: 0.6)
            rayMat?.multiply.contents = nsColor(c, scale: 0.85)
        }
    }

    func hide() { node.isHidden = true }

    private static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white      // modulato dai colori per vertice
        m.multiply.contents = NSColor.black     // tinta + intensità, aggiornata solo se cambia
        m.blendMode = .add                      // blending additivo
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }

    /// Cono unitario: anello 0 (y=0, raggio piccolo, luminoso) → anello 5 (y=1, raggio 1, nero).
    private static func makeCone() -> SCNGeometry {
        let segments = 32
        let rings = 6
        var vertices: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []

        for r in 0..<rings {
            let t = Float(r) / Float(rings - 1)
            let radius = 0.03 + 0.97 * t
            let b = powf(1 - t, 1.4)
            for s in 0..<segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                vertices.append(SCNVector3(CGFloat(cosf(a) * radius), CGFloat(t), CGFloat(sinf(a) * radius)))
                colors.append(SIMD4<Float>(b, b, b, 1))
            }
        }

        var indices: [Int32] = []
        for r in 0..<(rings - 1) {
            for s in 0..<segments {
                let s2 = (s + 1) % segments
                let a = Int32(r * segments + s)
                let b = Int32(r * segments + s2)
                let c = Int32((r + 1) * segments + s)
                let d = Int32((r + 1) * segments + s2)
                indices += [a, b, c, b, d, c]
            }
        }

        let vSrc = SCNGeometrySource(vertices: vertices)
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
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vSrc, cSrc], elements: [element])
    }
}

// MARK: - Macchia di luce sul pavimento

final class SpotVisual {
    let node = SCNNode()
    private let mat: SCNMaterial
    private let planeNode: SCNNode
    private var lastKey: UInt32 = .max
    private var lastRoll: Float = .nan
    private var maskImage: NSImage?

    private static let radialImage: NSImage = {
        let w = 128
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [
            CGColor(gray: 1.0, alpha: 1),
            CGColor(gray: 0.55, alpha: 1),
            CGColor(gray: 0.15, alpha: 1),
            CGColor(gray: 0.0, alpha: 1)
        ] as CFArray
        let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.3, 0.7, 1])!
        let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(w) / 2)
        ctx.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0,
            endCenter: center, endRadius: CGFloat(w) / 2,
            options: [.drawsAfterEndLocation]
        )
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: w))
    }()

    init() {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = SpotVisual.radialImage
        material.multiply.contents = NSColor.black
        material.blendMode = .add
        material.isDoubleSided = true
        material.writesToDepthBuffer = false

        let plane = SCNPlane(width: 1, height: 1)
        plane.materials = [material]
        let pn = SCNNode(geometry: plane)
        pn.simdEulerAngles = SIMD3<Float>(-Float.pi / 2, 0, 0)   // sdraiato sul pavimento
        pn.renderingOrder = 90
        pn.castsShadow = false
        mat = material
        planeNode = pn
        node.name = SceneHelpers.ignoreName
        node.addChildNode(pn)
        node.isHidden = true
    }

    /// Sagoma la macchia con una maschera gobo (nil = alone radiale normale).
    func setMask(_ image: NSImage?) {
        maskImage = image
        mat.diffuse.contents = image ?? SpotVisual.radialImage
        lastRoll = .nan
        if image == nil { planeNode.simdOrientation = simd_quatf(angle: -Float.pi / 2, axis: [1, 0, 0]) }
    }

    /// `roll` ruota l'immagine attorno alla normale della macchia (rotazione del gobo rispetto al fascio).
    func update(position: SIMD3<Float>, yaw: Float, diameter: Float, stretch: Float, color: SIMD3<Float>, roll: Float = 0) {
        if max(color.x, max(color.y, color.z)) < 0.004 {
            node.isHidden = true
            return
        }
        node.isHidden = false
        node.simdPosition = position
        node.simdEulerAngles = SIMD3<Float>(0, yaw, 0)
        node.simdScale = SIMD3<Float>(diameter, 1, diameter * stretch)
        if maskImage != nil, !(abs(roll - lastRoll) < 0.002) {
            lastRoll = roll
            // Prima ruota l'immagine attorno alla propria normale, poi la sdraia sul pavimento.
            planeNode.simdOrientation = simd_quatf(angle: -Float.pi / 2, axis: [1, 0, 0])
                * simd_quatf(angle: roll, axis: [0, 0, 1])
        }
        let key = colorKey(color)
        if key != lastKey {
            lastKey = key
            mat.multiply.contents = nsColor(color, scale: 0.8)
        }
    }

    /// Macchia su una superficie qualsiasi (oggetto, stativo, manichino): il disco si orienta secondo la normale
    /// e si allunga lungo la proiezione del fascio sulla superficie.
    func updateSurface(point: SIMD3<Float>, normal: SIMD3<Float>, dir: SIMD3<Float>,
                       diameter: Float, stretch: Float, color: SIMD3<Float>) {
        if max(color.x, max(color.y, color.z)) < 0.004 {
            node.isHidden = true
            return
        }
        var n = simd_normalize(normal)
        if simd_dot(n, dir) > 0 { n = -n }
        node.isHidden = false
        node.simdPosition = point + n * 0.012

        var q = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: n)
        let proj = dir - n * simd_dot(dir, n)
        if simd_length(proj) > 1e-4 {
            let p = simd_normalize(proj)
            let z = q.act(SIMD3<Float>(0, 0, 1))
            let angle = atan2f(simd_dot(simd_cross(z, p), n), simd_dot(z, p))
            q = simd_quatf(angle: angle, axis: n) * q
        }
        node.simdOrientation = q
        node.simdScale = SIMD3<Float>(diameter, 1, diameter * stretch)

        if maskImage != nil, !lastRoll.isNaN {
            lastRoll = .nan
            planeNode.simdOrientation = simd_quatf(angle: -Float.pi / 2, axis: [1, 0, 0])
        }
        let key = colorKey(color)
        if key != lastKey {
            lastKey = key
            mat.multiply.contents = nsColor(color, scale: 0.8)
        }
    }

    func hide() { node.isHidden = true }
}

// MARK: - Fixture

/// Punto in cui un fascio incontra il palco o un oggetto.
struct BeamHit {
    var t: Float
    var point: SIMD3<Float>
    var normal: SIMD3<Float>
    var onFloor: Bool
    var floorY: Float
}

/// Raycast verso gli oggetti di scena (manichini, parallelepipedi, stativi): distanza dall'origine del segmento
/// e normale della superficie colpita, oppure nil se il segmento non incontra nulla.
/// Parametri di una fixture durante il «Test Luci» (v2.5).
struct LightTestParams {
    /// Tonalità 0…1: le fixture ricevono tonalità ben distribuite (rapporto aureo) con un offset casuale a ogni attivazione.
    var hue: Double
    var phase: Double
    /// Moltiplicatore di velocità del movimento (circa 0,6…1,4).
    var speed: Double
    /// Ampiezze massime del movimento in gradi (limitate a una frazione della corsa del motore).
    var panDegrees: Double
    var tiltDegrees: Double

    static func random(hue: Double) -> LightTestParams {
        LightTestParams(
            hue: hue - hue.rounded(.down),
            phase: Double.random(in: 0..<(2 * Double.pi)),
            speed: Double.random(in: 0.6...1.4),
            panDegrees: Double.random(in: 30...55),
            tiltDegrees: Double.random(in: 20...35)
        )
    }

    func panAmplitude(range: Double) -> Double { min(panDegrees, range * 0.35) }
    func tiltAmplitude(range: Double) -> Double { min(tiltDegrees, range * 0.30) }

    /// Spostamento normalizzato -1…1 di pan e tilt: tre sinusoidi incommensurabili, quindi fluido e senza ripetizioni evidenti.
    func motion(time: Double) -> (pan: Double, tilt: Double) {
        let t = time * speed
        let pan = 0.50 * sin(t * 0.37 + phase) + 0.32 * sin(t * 0.83 + 1.7 * phase) + 0.18 * sin(t * 1.51 + 0.6 * phase)
        let tilt = 0.50 * sin(t * 0.43 + 2.1 * phase) + 0.30 * sin(t * 0.97 + 0.9 * phase) + 0.20 * sin(t * 1.69 + 1.3 * phase)
        return (pan, tilt)
    }

    /// Colore vivace e saturo (HSB con S = 1, B = 1).
    static func color(hue: Double) -> SIMD3<Float> {
        let h = (hue - hue.rounded(.down)) * 6
        let f = Float(h - h.rounded(.down))
        let q = 1 - f
        switch Int(h) % 6 {
        case 0: return SIMD3<Float>(1, f, 0)
        case 1: return SIMD3<Float>(q, 1, 0)
        case 2: return SIMD3<Float>(0, 1, f)
        case 3: return SIMD3<Float>(0, q, 1)
        case 4: return SIMD3<Float>(f, 0, 1)
        default: return SIMD3<Float>(1, 0, q)
        }
    }
}

typealias BeamOccluder = (_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> (t: Float, normal: SIMD3<Float>)?

final class FixtureRenderer {
    private(set) var fixture: PatchedFixture
    private var stage: StageConfig
    let signature: Int

    /// Nodo con posizione/yaw della luce nel mondo. Il nome è l'UUID della fixture (usato dal hitTest).
    let node = SCNNode()
    /// La macchia sul pavimento vive in coordinate mondo, quindi in un nodo separato.
    let spotNode = SCNNode()
    var nodes: [SCNNode] { [node, spotNode] }

    /// Fornito dal controller: serve a troncare i coni sugli oggetti di scena.
    var occluder: BeamOccluder?

    private let mountNode = SCNNode()
    private let panNode = SCNNode()
    private let tiltNode = SCNNode()
    private let map: ChannelMap

    private var beams: [BeamVisual] = []
    private var pixelMats: [SCNMaterial] = []
    private var pixelKeys: [UInt32] = []
    private var pixelOffsets: [Float] = []
    private var lensMat: SCNMaterial?
    private var lastLensKey: UInt32 = .max
    private var spot: SpotVisual?
    private var selectionBox: SCNNode?
    private var smoke: SmokeVisual?

    /// Quota (rispetto alla base della fixture, con segno se appesa) del centro del corpo: posizione del Gumball.
    private(set) var gizmoOffset: Float = 0.2

    // Luce reale (SCNLight spot): illumina oggetti e manichini.
    private var lightNode: SCNNode?
    private var lastLightKey: UInt32 = .max
    private var lastLightIntensity: Float = -1
    private var lightGain: Float = 1400

    /// Se la zona illuminata non coincide con il cono visibile, regola questo fattore.
    private static let lightConeScale = 1.0

    private var curPan = 0.0
    private var curTilt = 0.0
    private var primed = false

    // Ruota colori: posizione continua in "unità di slot" (0 = primo slot) e slot di destinazione.
    private var wheelPos = 0.0
    private var wheelTarget = 0
    private var wheelPrimed = false
    /// Velocità della ruota in slot al secondo, e durata massima del transito completo.
    private static let wheelSlotsPerSecond = 14.0
    private static let wheelMaxTransit = 0.7

    // Strobo: fase in periodi (0..<1), apertura per il 30% del periodo.
    private var strobePhase = 0.0
    private static let strobeDuty = 0.3

    // Gobo e prisma
    private var curMask: GoboMask?
    private var lightMask: GoboMask?
    private var prismAngle = 0.0                 // gradi
    private var prismNode: SCNNode?
    private var subBeams: [BeamVisual] = []
    private var subSpots: [SpotVisual] = []
    private var baseLightOuter: CGFloat = 25
    private var lastLightOuter: CGFloat = -1
    private var lightGainScale: Float = 1
    private static let mainRayGrid = 28
    private static let subRayGrid = 12

    private var pivotHeight: Float = 0.3
    private var lensDistance: Float = 0.27
    private var maxBeamLength = 14.0

    /// Cambia se cambiano profilo, tipo di montaggio o dimensioni (richiede ricostruzione della geometria).
    static func signature(for f: PatchedFixture) -> Int {
        var h = Hasher()
        h.combine(f.profile)
        h.combine(f.mount)
        h.combine(f.dims)
        return h.finalize()
    }

    init(fixture: PatchedFixture, stage: StageConfig) {
        self.fixture = fixture
        self.stage = stage
        self.signature = FixtureRenderer.signature(for: fixture)
        self.map = ChannelMap(profile: fixture.profile)
        build()
    }

    /// Vero se profilo, montaggio e dimensioni sono quelli con cui è stato costruito il modello 3D: in tal caso basta
    /// aggiornare la posizione. Il confronto per uguaglianza è molto più leggero dell'hash dell'intero profilo,
    /// quindi il trascinamento di una luce non appesantisce il thread di rendering.
    func hasSameStructure(as f: PatchedFixture) -> Bool {
        fixture.profile == f.profile && fixture.mount == f.mount && fixture.dims == f.dims
    }

    func updateFixture(_ f: PatchedFixture) {
        fixture = f
        applyPlacement()
    }

    func setStage(_ s: StageConfig) {
        stage = s
        applyPlacement()
        lightNode?.light?.castsShadow = s.beamShadows
    }

    func setSelected(_ selected: Bool) {
        selectionBox?.isHidden = !selected
    }

    /// Centro del corpo nel mondo (dove compare il Gumball).
    var worldCenter: SIMD3<Float> {
        worldBase + SIMD3<Float>(0, gizmoOffset, 0)
    }

    // MARK: Costruzione

    private func build() {
        let body = Self.flatMaterial(white: 0.09)
        let trim = Self.flatMaterial(white: 0.22)

        let profile = fixture.profile
        let dims = fixture.dims
        let def = profile.defaultDims
        let sx = Float(dims.w / def.w)
        let sy = Float(dims.h / def.h)
        let sz = Float(dims.d / def.d)
        let scale = SIMD3<Float>(sx, sy, sz)
        let sr = CGFloat((sx + sz) / 2)

        node.name = fixture.id.uuidString
        node.addChildNode(mountNode)
        mountNode.addChildNode(panNode)
        panNode.addChildNode(tiltNode)

        /// Gruppo con la scala delle dimensioni: la geometria di riferimento resta alle misure predefinite.
        func group(in parent: SCNNode) -> SCNNode {
            let g = SCNNode()
            g.simdScale = scale
            parent.addChildNode(g)
            return g
        }

        var selSize = SIMD3<Float>(Float(dims.w), Float(dims.h), Float(dims.d))
        var selCenter = SIMD3<Float>(0, Float(dims.h) * 0.5, 0)

        switch profile.type {
        case .movingHeadBeam, .movingHeadSpot:
            pivotHeight = 0.30 * sy
            lensDistance = 0.27 * sy
            maxBeamLength = 18
            group(in: mountNode).addChildNode(shape(SCNCylinder(radius: 0.14, height: 0.10), body, at: [0, 0.05, 0]))
            let yoke = group(in: panNode)
            for side: Float in [-1, 1] {
                yoke.addChildNode(shape(
                    SCNBox(width: 0.04, height: 0.30, length: 0.09, chamferRadius: 0.01), trim, at: [side * 0.14, 0.25, 0]))
            }
            tiltNode.simdPosition = [0, pivotHeight, 0]
            group(in: tiltNode).addChildNode(shape(SCNCylinder(radius: 0.11, height: 0.30), body, at: [0, 0.10, 0]))
            addLens(round: 0.085 * sr, at: lensDistance)
            addBeam(core: true, at: [0, lensDistance + 0.005, 0])
            addLight(outerAngle: profile.beamAngle, at: [0, lensDistance + 0.02, 0], range: maxBeamLength)
            let s = SpotVisual()
            spot = s
            spotNode.addChildNode(s.node)
            if map.prism != nil { buildPrism() }
            selCenter = [0, Float(dims.h) * 0.48, 0]

        case .parLED, .wallWash:
            let wash = profile.type == .wallWash
            let rect = profile.bodyShape == .rect
            pivotHeight = 0.12 * sy
            lensDistance = 0.175 * sy
            maxBeamLength = 12

            // Misure di riferimento del corpo (m) alle dimensioni predefinite.
            let yokeHalf: CGFloat = wash ? (rect ? 0.20 : 0.15) : (rect ? 0.115 : 0.11)
            let headR: CGFloat = wash ? 0.11 : 0.085
            let headW: CGFloat = wash ? 0.34 : 0.17
            let headD: CGFloat = 0.17

            group(in: mountNode).addChildNode(shape(
                SCNBox(width: yokeHalf * 2, height: 0.02, length: 0.14, chamferRadius: 0), trim, at: [0, 0.01, 0]))
            let yoke = group(in: panNode)
            for side: Float in [-1, 1] {
                yoke.addChildNode(shape(
                    SCNBox(width: 0.02, height: 0.20, length: 0.06, chamferRadius: 0), trim, at: [side * Float(yokeHalf), 0.11, 0]))
            }
            tiltNode.simdPosition = [0, pivotHeight, 0]
            let head = group(in: tiltNode)
            if rect {
                head.addChildNode(shape(SCNBox(width: headW, height: 0.20, length: headD, chamferRadius: 0.008), body, at: [0, 0.07, 0]))
                addLens(
                    rectWidth: (headW - 0.03) * CGFloat(sx),
                    rectDepth: (headD - 0.03) * CGFloat(sz), at: lensDistance)
            } else {
                head.addChildNode(shape(SCNCylinder(radius: headR, height: 0.20), body, at: [0, 0.07, 0]))
                addLens(round: (headR - 0.015) * sr, at: lensDistance)
            }
            addBeam(core: true, at: [0, lensDistance + 0.005, 0])
            addLight(outerAngle: profile.beamAngle, at: [0, lensDistance + 0.02, 0], range: maxBeamLength)
            let s = SpotVisual()
            spot = s
            spotNode.addChildNode(s.node)
            if map.prism != nil || map.prismRotation != nil { buildPrism() }
            selCenter = [0, Float(dims.h) * 0.39, 0]

        case .ledBar:
            let n = max(1, map.pixels.count)
            let length = Float(dims.w)
            let height = Float(dims.h)
            let thick = Float(dims.d)
            let pitch = max((length - 0.04) / Float(n), 0.005)
            let motor = profile.barMotorized
            pivotHeight = motor ? 0.06 + hypotf(height, thick) / 2 : height / 2 + 0.02
            lensDistance = height / 2 + 0.005
            maxBeamLength = 5
            tiltNode.simdPosition = [0, pivotHeight, 0]
            tiltNode.addChildNode(shape(
                SCNBox(width: CGFloat(length), height: CGFloat(height), length: CGFloat(thick), chamferRadius: 0.005),
                body, at: [0, 0, 0]))
            for i in 0..<n {
                let x = (Float(i) - Float(n - 1) / 2) * pitch
                let g = SCNBox(width: CGFloat(pitch) * 0.8, height: 0.006, length: CGFloat(thick) * 0.625, chamferRadius: 0)
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = NSColor(white: 0.1, alpha: 1)
                g.materials = [m]
                let ln = SCNNode(geometry: g)
                ln.simdPosition = [x, height / 2 + 0.001, 0]
                tiltNode.addChildNode(ln)
                pixelMats.append(m)
                pixelOffsets.append(x)
                addBeam(core: false, at: [x, lensDistance, 0])
            }
            pixelKeys = Array(repeating: UInt32.max, count: n)
            if motor {
                // Base e staffe laterali: la barra ruota attorno al proprio asse longitudinale (Tilt).
                mountNode.addChildNode(shape(
                    SCNBox(width: CGFloat(length) + 0.12, height: 0.03, length: CGFloat(max(thick * 1.6, 0.12)), chamferRadius: 0.004),
                    trim, at: [0, 0.015, 0]))
                let armH = pivotHeight + 0.02
                for side: Float in [-1, 1] {
                    panNode.addChildNode(shape(
                        SCNBox(width: 0.025, height: CGFloat(armH), length: 0.06, chamferRadius: 0),
                        trim, at: [side * (length / 2 + 0.03), armH / 2, 0]))
                }
            }
            // Una sola luce per tutta la barra, con il colore medio dei pixel.
            addLight(outerAngle: profile.beamAngle + 20, at: [0, height / 2 + 0.04, 0], range: maxBeamLength)
            if motor {
                let h = pivotHeight + hypotf(height, thick) / 2 + 0.05
                selSize = [length + 0.16, h, max(thick * 1.6, 0.12) + 0.04]
                selCenter = [0, h / 2, 0]
            } else {
                selSize = [length + 0.08, max(0.16, height + 0.1), thick + 0.06]
                selCenter = [0, pivotHeight, 0]
            }

        case .smokeMachine:
            pivotHeight = 0.1
            lensDistance = 0.2
            let g = group(in: mountNode)
            g.addChildNode(shape(SCNBox(width: 0.45, height: 0.22, length: 0.28, chamferRadius: 0.02), body, at: [0, 0.11, 0]))
            let nozzle = shape(SCNCylinder(radius: 0.035, height: 0.09), trim, at: [0, 0.22, 0.12])
            nozzle.simdEulerAngles = SIMD3<Float>(Float.pi / 5, 0, 0)
            g.addChildNode(nozzle)
            let led = SCNBox(width: 0.03, height: 0.012, length: 0.01, chamferRadius: 0)
            let lm = SCNMaterial()
            lm.lightingModel = .constant
            lm.diffuse.contents = NSColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 1)
            led.materials = [lm]
            let ledNode = SCNNode(geometry: led)
            ledNode.simdPosition = [-0.15, 0.17, 0.141]
            g.addChildNode(ledNode)

            let s = SmokeVisual()
            s.node.simdPosition = [0, 0.26 * sy, 0.16 * sz]
            mountNode.addChildNode(s.node)
            smoke = s
        }

        gizmoOffset = selCenter.y * (fixture.mount == .truss ? -1 : (fixture.mount == .vertical ? 0 : 1))

        // I corpi delle fixture NON proiettano ombra: la luce nasce dentro di loro e si auto-oscurerebbe.
        node.enumerateHierarchy { n, _ in n.castsShadow = false }

        let box = SceneHelpers.wireBox(size: selSize, center: selCenter)
        mountNode.addChildNode(box)
        selectionBox = box

        applyPlacement()
    }

    private func shape(_ g: SCNGeometry, _ m: SCNMaterial, at p: SIMD3<Float>) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = p
        return n
    }

    private static func lensMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 0.1, alpha: 1)
        return m
    }

    private func addLens(round radius: CGFloat, at y: Float) {
        let cyl = SCNCylinder(radius: radius, height: 0.01)
        let m = Self.lensMaterial()
        cyl.materials = [m]
        let n = SCNNode(geometry: cyl)
        n.simdPosition = [0, y, 0]
        tiltNode.addChildNode(n)
        lensMat = m
    }

    /// Lente rettangolare (PAR / Wall Wash a corpo rettangolare), già scalata sulle dimensioni.
    private func addLens(rectWidth: CGFloat, rectDepth: CGFloat, at y: Float) {
        let box = SCNBox(width: rectWidth, height: 0.01, length: rectDepth, chamferRadius: 0)
        let m = Self.lensMaterial()
        box.materials = [m]
        let n = SCNNode(geometry: box)
        n.simdPosition = [0, y, 0]
        tiltNode.addChildNode(n)
        lensMat = m
    }

    private func addBeam(core: Bool, at p: SIMD3<Float>) {
        let b = BeamVisual(core: core)
        b.node.simdPosition = p
        tiltNode.addChildNode(b.node)
        beams.append(b)
    }

    /// Prisma radiale: un gruppo di sotto-fasci (cono + macchia a terra) attorno all'asse ottico.
    /// Restano nascosti finché il canale Prisma non è attivo.
    private func buildPrism() {
        let n = min(max(fixture.profile.prismFacets, 2), 24)
        let group = SCNNode()
        group.name = SceneHelpers.ignoreName
        group.simdPosition = [0, lensDistance + 0.005, 0]
        tiltNode.addChildNode(group)
        prismNode = group

        for _ in 0..<n {
            let b = BeamVisual(core: false)
            group.addChildNode(b.node)
            subBeams.append(b)

            let s = SpotVisual()
            spotNode.addChildNode(s.node)
            subSpots.append(s)
        }
    }

    /// SCNLight di tipo spot lungo l'asse del fascio (+Y locale). La luce spot punta verso -Z,
    /// quindi il nodo viene ruotato di +90° attorno a X.
    private func addLight(outerAngle: Double, at position: SIMD3<Float>, range: Double) {
        let light = SCNLight()
        light.type = .spot
        light.color = NSColor.white
        light.intensity = 0
        let outer = CGFloat(min(max(outerAngle * Self.lightConeScale, 4), 120))
        baseLightOuter = outer
        lastLightOuter = outer
        light.spotOuterAngle = outer
        light.spotInnerAngle = outer * 0.6
        light.attenuationStartDistance = 1
        light.attenuationEndDistance = CGFloat(range * 1.3)
        light.attenuationFalloffExponent = 1
        // Ombre reali (v3.0): lo spot proietta ombre su palco, pareti e oggetti. Intensità, colore, dimmer e strobo della luce
        // sono già legati ai valori effettivi della fixture (`updateLight`), compresa la modalità «Test Luci».
        light.zNear = 0.3                                       // oltre l'ottica: niente ombre dal corpo della fixture
        light.zFar = CGFloat(range * 1.3)
        light.castsShadow = stage.beamShadows
        light.shadowMode = .forward
        light.shadowRadius = 4                                  // bordi morbidi
        light.shadowSampleCount = 8
        light.shadowBias = 1.5                                  // evita il «shadow acne» su palco e pareti
        light.shadowColor = NSColor(white: 0, alpha: 0.65)
        light.shadowMapSize = CGSize(width: 1024, height: 1024)

        let n = SCNNode()
        n.light = light
        n.simdPosition = position
        n.simdEulerAngles = SIMD3<Float>(Float.pi / 2, 0, 0)
        tiltNode.addChildNode(n)
        lightNode = n

        // I fasci stretti concentrano più luce: guadagno maggiore con angoli piccoli.
        lightGain = 1400 * Float(min(4, max(1, 28 / max(fixture.profile.beamAngle, 1))))
    }

    private static func flatMaterial(white: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(white: white, alpha: 1)
        m.specular.contents = NSColor(white: 0.35, alpha: 1)
        return m
    }

    // MARK: Posizionamento

    private static func rad(_ deg: Double) -> Float { Float(deg * Double.pi / 180) }

    private static func mountQuat(_ m: MountOrientation) -> simd_quatf {
        switch m {
        case .floor: return simd_quatf(angle: 0, axis: [1, 0, 0])
        case .truss: return simd_quatf(angle: Float.pi, axis: [1, 0, 0])          // appesa: +Y locale → verso il basso
        case .vertical: return simd_quatf(angle: Float.pi / 2, axis: [1, 0, 0])   // laterale: +Y locale → verso il pubblico (+Z)
        }
    }

    /// `y` della fixture è l'altezza sopra il piano del palco: l'altezza della base si somma qui.
    private var worldBase: SIMD3<Float> {
        SIMD3<Float>(Float(fixture.x), Float(stage.baseHeight + fixture.y), Float(fixture.z))
    }

    private func applyPlacement() {
        node.simdPosition = worldBase
        node.simdEulerAngles = SIMD3<Float>(0, Self.rad(fixture.yaw), 0)
        mountNode.simdOrientation = Self.mountQuat(fixture.mount)
    }

    // MARK: Aggiornamento per frame

    private func slew(_ cur: Double, _ target: Double, speed: Double, dt: Double) -> Double {
        let delta = target - cur
        let eased = delta * min(1, 14 * dt)        // smorzamento esponenziale
        let maxStep = speed * dt                   // limite di velocità dei motori
        return cur + max(-maxStep, min(maxStep, eased))
    }

    /// Punto in cui il fascio incontra il piano del palco (se dentro la pedana) oppure il suolo.
    private func floorHit(origin: SIMD3<Float>, dir: SIMD3<Float>) -> (t: Float, y: Float)? {
        guard dir.y < -0.01 else { return nil }
        let deckY = Float(stage.baseHeight)
        let hw = Float(stage.width) / 2
        let hd = Float(stage.depth) / 2
        if origin.y > deckY {
            let t = (origin.y - deckY) / -dir.y
            let p = origin + dir * t
            if abs(p.x) <= hw && abs(p.z) <= hd { return (t, deckY) }
        }
        if origin.y > 0.001 {
            return (origin.y / -dir.y, 0)
        }
        return nil
    }

    /// Pareti (fondo, sinistra, destra) e soffitto dell'ambiente chiuso (v2.4): intersezione esatta raggio/piano, limitata ai
    /// bordi reali della sala. Il lato frontale (+Z, pubblico) è aperto. Vale solo per i raggi che partono dentro la sala,
    /// così un fascio non può mai uscirne attraversando una superficie.
    private func roomHit(origin: SIMD3<Float>, dir: SIMD3<Float>) -> (t: Float, normal: SIMD3<Float>)? {
        guard stage.environment == .closed else { return nil }
        let hw = Float(stage.roomWidth) / 2
        let hd = Float(stage.roomDepth) / 2
        let top = Float(stage.baseHeight + stage.ceilingHeight)
        let eps: Float = 0.05
        guard abs(origin.x) <= hw + eps, origin.z >= -hd - eps, origin.z <= hd + eps, origin.y <= top + eps else { return nil }

        var best: (t: Float, normal: SIMD3<Float>)? = nil
        func consider(_ t: Float, _ n: SIMD3<Float>, _ inside: (SIMD3<Float>) -> Bool) {
            guard t >= 0 else { return }
            if let b = best, b.t <= t { return }
            if inside(origin + dir * t) { best = (t, n) }
        }
        let tol: Float = 0.001
        // Parete di fondo (z = -hd), normale verso l'interno (+Z).
        if dir.z < -1e-6 {
            consider((-hd - origin.z) / dir.z, SIMD3<Float>(0, 0, 1)) { abs($0.x) <= hw + tol && $0.y <= top + tol }
        }
        // Parete sinistra (x = -hw) e destra (x = +hw).
        if dir.x < -1e-6 {
            consider((-hw - origin.x) / dir.x, SIMD3<Float>(1, 0, 0)) { abs($0.z) <= hd + tol && $0.y <= top + tol }
        }
        if dir.x > 1e-6 {
            consider((hw - origin.x) / dir.x, SIMD3<Float>(-1, 0, 0)) { abs($0.z) <= hd + tol && $0.y <= top + tol }
        }
        // Soffitto (y = top), normale verso il basso.
        if dir.y > 1e-6 {
            consider((top - origin.y) / dir.y, SIMD3<Float>(0, -1, 0)) { abs($0.x) <= hw + tol && abs($0.z) <= hd + tol }
        }
        return best
    }

    /// Raggio lungo l'asse del fascio: restituisce il primo impatto con il palco/suolo o con un oggetto di scena.
    /// Il cono viene poi troncato alla distanza dell'impatto, quindi la luce non attraversa le superfici.
    private func trace(origin: SIMD3<Float>, dir: SIMD3<Float>) -> BeamHit? {
        let maxT = Float(maxBeamLength)
        var best: BeamHit? = nil
        if let h = floorHit(origin: origin, dir: dir), h.t > 0.05, h.t < maxT {
            best = BeamHit(t: h.t, point: origin + dir * h.t, normal: SIMD3<Float>(0, 1, 0), onFloor: true, floorY: h.y)
        }
        // Pareti e soffitto della sala: stesso raycast dei fasci, quindi il cono si ferma al contatto.
        if let r = roomHit(origin: origin, dir: dir), r.t > 0.02, r.t < (best?.t ?? maxT) {
            best = BeamHit(t: r.t, point: origin + dir * r.t, normal: r.normal, onFloor: false, floorY: 0)
        }
        if let occ = occluder {
            let limit = best?.t ?? maxT
            if let o = occ(origin, origin + dir * limit), o.t > 0.05, o.t < limit {
                best = BeamHit(t: o.t, point: origin + dir * o.t, normal: o.normal, onFloor: false, floorY: 0)
            }
        }
        return best
    }

    /// `master` = «Luminosità Generale Luci»: moltiplicatore su luce reale (SCNLight), coni e macchie.
    /// Parametri del «Test Luci» (v2.5): colore, fase e velocità del movimento di questa fixture. Nil = funzionamento normale.
    var lightTest: LightTestParams?

    /// Fine del test: pan/tilt e ruota colori tornano subito ai valori reali del DMX (nessun transito).
    func endLightTest() {
        lightTest = nil
        primed = false
        wheelPrimed = false
        strobePhase = 0
    }

    func update(data: [UInt8]?, dt: Double, time: Double, master: Float) {
        // Test Luci: i canali DMX ricevuti vengono ignorati e sostituiti da valori sintetici (mai scritti nel buffer DMX
        // né nel modello, quindi nessun effetto su Annulla/Ripristina e sullo stato «Modificato»).
        var d = data ?? []
        if let test = lightTest, fixture.profile.type != .smokeMachine {
            d = testData(test, time: time)
        }
        let start = fixture.startAddress - 1
        let count = fixture.profile.channelCount

        func ch(_ i: Int?) -> Int? {
            guard let i else { return nil }
            guard i >= 0, i < count else { return 0 }
            let a = start + i
            return (a >= 0 && a < d.count) ? Int(d[a]) : 0
        }

        // Macchina del fumo: nessun fascio, solo emissione di particelle.
        if fixture.profile.type == .smokeMachine {
            smoke?.update(level: Float(ch(map.smoke) ?? 0) / 255)
            return
        }

        // Intensità master (lineare) + strobo (valori 0-9 = shutter aperto)
        var intensity: Float = 1
        if let v = ch(map.dimmer) { intensity = Float(v) / 255 }
        intensity *= strobeLevel(ch(map.strobe), dt: dt)

        // Colore: ruota (con transito fisico) oppure RGB / RGBW (cambio diretto)
        let color = beamColor(ch: ch, dt: dt)

        // Pan / Tilt (8 o 16 bit) con velocità motori. Le barre motorizzate usano solo il tilt.
        if fixture.profile.hasTilt {
            var targetPan = 0.0
            var targetTilt = 0.0
            if let c = ch(map.pan) {
                let norm: Double
                if let f = ch(map.panFine) { norm = Double(c * 256 + f) / 65535 } else { norm = Double(c) / 255 }
                targetPan = (norm - 0.5) * fixture.profile.panRange
            }
            if let c = ch(map.tilt) {
                let norm: Double
                if let f = ch(map.tiltFine) { norm = Double(c * 256 + f) / 65535 } else { norm = Double(c) / 255 }
                targetTilt = (norm - 0.5) * fixture.profile.tiltRange
            }
            if fixture.invertPan { targetPan = -targetPan }
            if fixture.invertTilt { targetTilt = -targetTilt }

            var speed = 300.0
            if let s = ch(map.speed) {
                let n = Double(s) / 255
                speed = 6 + 394 * (1 - n) * (1 - n)     // 0 = veloce, 255 = lentissimo
            }
            if !primed {
                curPan = targetPan
                curTilt = targetTilt
                primed = true
            } else {
                curPan = slew(curPan, targetPan, speed: speed, dt: dt)
                curTilt = slew(curTilt, targetTilt, speed: speed, dt: dt)
            }
        }

        let panDeg = fixture.staticPan + curPan
        let tiltDeg = fixture.staticTilt + curTilt
        panNode.simdEulerAngles = SIMD3<Float>(0, Self.rad(panDeg), 0)
        tiltNode.simdEulerAngles = SIMD3<Float>(Self.rad(tiltDeg), 0, 0)

        // Geometria del fascio nel mondo (per lunghezza del cono e macchia sul pavimento)
        let yawQ = simd_quatf(angle: Self.rad(fixture.yaw), axis: [0, 1, 0])
        let placeQ = yawQ * Self.mountQuat(fixture.mount)
        let headQ = placeQ
            * simd_quatf(angle: Self.rad(panDeg), axis: [0, 1, 0])
            * simd_quatf(angle: Self.rad(tiltDeg), axis: [1, 0, 0])
        let dir = headQ.act(SIMD3<Float>(0, 1, 0))
        let origin = worldBase + placeQ.act(SIMD3<Float>(0, pivotHeight, 0)) + dir * lensDistance

        let half = fixture.profile.beamAngle / 2

        if fixture.profile.type == .ledBar {
            updatePixels(ch: ch, intensity: intensity, half: half, headQ: headQ, placeQ: placeQ, master: master)
            return
        }

        // Occlusione: il cono finisce sul primo palco/oggetto incontrato lungo l'asse del fascio.
        var length = maxBeamLength
        let hit = trace(origin: origin, dir: dir)
        if let h = hit { length = Double(h.t) }

        // Gobo e prisma
        let mask = ch(map.gobo).flatMap { map.goboMask(for: $0) }
        let prismOn = updatePrism(value: ch(map.prism), rotation: ch(map.prismRotation), dt: dt)
        applyMask(mask)
        refreshLight(prismOn: prismOn, half: half)

        let shown = intensity * master

        if prismOn {
            beams.first?.hide()
            spot?.hide()
            updateSubBeams(
                color: color, intensity: shown, half: half,
                headQ: headQ, origin: origin
            )
            updateLight(color: color, level: shown)
        } else {
            for b in subBeams { b.hide() }
            for s in subSpots { s.hide() }

            beams.first?.update(color: color, intensity: shown, halfAngleDeg: half, length: length)
            updateLight(color: color, level: shown)

            if let spot {
                if let h = hit {
                    updateSpot(
                        spot, hit: h, dir: dir, half: half,
                        color: color * shown, right: headQ.act(SIMD3<Float>(1, 0, 0))
                    )
                } else {
                    spot.hide()
                }
            }
        }

        if let lm = lensMat {
            let lv = SIMD3<Float>(repeating: 0.1) + color * intensity * 0.9
            let key = colorKey(lv)
            if key != lastLensKey {
                lastLensKey = key
                lm.diffuse.contents = nsColor(lv)
            }
        }
    }

    // MARK: Test Luci

    /// Buffer DMX sintetico per questa fixture: dimmer e shutter aperti, colore vivace, gobo/prisma spenti e, per le teste
    /// mobili, pan/tilt che oscillano in modo fluido (somma di tre sinusoidi con fasi e velocità diverse).
    private func testData(_ t: LightTestParams, time: Double) -> [UInt8] {
        let p = fixture.profile
        let start = max(fixture.startAddress - 1, 0)
        let count = p.channelCount
        var d = [UInt8](repeating: 0, count: start + count)

        func put(_ i: Int?, _ v: Int) {
            guard let i, i >= 0, i < count else { return }
            d[start + i] = UInt8(min(max(v, 0), 255))
        }
        func put16(_ coarse: Int?, _ fine: Int?, norm: Double) {
            let v = Int((min(max(norm, 0), 1) * 65535).rounded())
            if fine != nil {
                put(coarse, v >> 8)
                put(fine, v & 0xFF)
            } else {
                put(coarse, Int((min(max(norm, 0), 1) * 255).rounded()))
            }
        }
        func rgb(_ hue: Double) -> (Int, Int, Int) {
            let c = LightTestParams.color(hue: hue)
            return (Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
        }

        put(map.dimmer, 255)
        put(map.strobe, p.strobeOffFrom)                                  // shutter aperto
        put(map.prism, p.prismOffFrom)                                    // prisma spento
        put(map.gobo, map.goboSlots.first(where: { $0.mask == nil })?.from ?? 0)
        put(map.speed, 0)                                                 // motori alla massima velocità: il movimento è già dolce

        let (r, g, b) = rgb(t.hue)
        put(map.red, r)
        put(map.green, g)
        put(map.blue, b)
        put(map.white, 0)
        if !map.wheelSlots.isEmpty {
            let k = min(Int(t.hue * Double(map.wheelSlots.count)), map.wheelSlots.count - 1)
            put(map.wheel, map.wheelSlots[k].from)
        }

        // Barre LED multi-pixel: un colore diverso per ogni pixel.
        let layout = map.pixels
        for (i, px) in layout.enumerated() {
            let (pr, pg, pb) = rgb(t.hue + 0.55 * Double(i) / Double(max(layout.count, 1)))
            put(px.r, pr)
            put(px.g, pg)
            put(px.b, pb)
            put(px.w, 0)
        }

        // Movimento fluido attorno alla posizione di puntamento (centro corsa + angoli statici della fixture).
        if p.hasTilt {
            let s = t.motion(time: time)
            if p.panRange > 0 {
                put16(map.pan, map.panFine, norm: 0.5 + s.pan * t.panAmplitude(range: p.panRange) / p.panRange)
            }
            if p.tiltRange > 0 {
                put16(map.tilt, map.tiltFine, norm: 0.5 + s.tilt * t.tiltAmplitude(range: p.tiltRange) / p.tiltRange)
            }
        }
        return d
    }

    // MARK: Colore, strobo

    /// Colore del fascio secondo la modalità del profilo.
    /// - RGB / RGBW: valori dei canali applicati direttamente, senza transizioni.
    /// - Ruota Colori: la ruota si muove fisicamente verso lo slot richiesto e, se non è adiacente,
    ///   attraversa gli slot intermedi mostrandone brevemente i colori.
    private func beamColor(ch: (Int?) -> Int?, dt: Double) -> SIMD3<Float> {
        let white = SIMD3<Float>(1, 1, 1)
        switch map.colorMode {
        case .rgb:
            guard map.hasRGB else { return white }
            return SIMD3<Float>(
                Float(ch(map.red) ?? 0) / 255,
                Float(ch(map.green) ?? 0) / 255,
                Float(ch(map.blue) ?? 0) / 255
            )
        case .rgbw:
            guard map.hasRGBW else { return white }
            let r = Float(ch(map.red) ?? 0) / 255
            let g = Float(ch(map.green) ?? 0) / 255
            let b = Float(ch(map.blue) ?? 0) / 255
            let w = Float(ch(map.white) ?? 0) / 255
            return simd_min(SIMD3<Float>(r + w, g + w, b + w), SIMD3<Float>(repeating: 1))
        case .wheel:
            return wheelColor(value: ch(map.wheel), dt: dt)
        }
    }

    private func wheelColor(value: Int?, dt: Double) -> SIMD3<Float> {
        let slots = map.wheelSlots
        guard !slots.isEmpty else { return SIMD3<Float>(1, 1, 1) }

        // Un valore fuori da ogni slot non sposta la ruota: resta dov'è.
        if let v = value, let idx = map.wheelSlotIndex(for: v) { wheelTarget = idx }
        wheelTarget = min(max(wheelTarget, 0), slots.count - 1)
        let target = Double(wheelTarget)

        if !wheelPrimed {
            wheelPos = target                // all'avvio la ruota è già in posizione, senza transito
            wheelPrimed = true
        } else if wheelPos != target {
            let distance = abs(target - wheelPos)
            // Velocità costante, ma il transito più lungo dura al massimo `wheelMaxTransit` secondi.
            let speed = max(Self.wheelSlotsPerSecond, distance / Self.wheelMaxTransit)
            let step = speed * dt
            if distance <= step {
                wheelPos = target
            } else {
                wheelPos += target > wheelPos ? step : -step
            }
        }

        // Tra due slot la finestra della ruota li mostra entrambi: miscela proporzionale alla posizione.
        let lo = min(max(Int(wheelPos.rounded(.down)), 0), slots.count - 1)
        let hi = min(lo + 1, slots.count - 1)
        let f = Float(wheelPos - Double(lo))
        let a = slots[lo].rgb
        let b = slots[hi].rgb
        return a + (b - a) * f
    }

    /// Fattore 0...1 di apertura dello shutter per il frame corrente.
    /// Due intervalli DMX configurabili: «Spento» (shutter aperto, fascio continuo) e «Attivo», dove la frequenza
    /// cresce in modo lineare da 1 Hz (inizio intervallo) a `strobeMaxHz` (fine intervallo). Il lampeggio è integrato sull'intervallo del
    /// frame, così a frequenze alte il visualizzatore mostra l'ampiezza reale invece di perdere i flash per aliasing.
    private func strobeLevel(_ value: Int?, dt: Double) -> Float {
        let p = fixture.profile
        guard let s = value,
              !(s >= p.strobeOffFrom && s <= p.strobeOffTo),          // Spento ha la precedenza
              s >= p.strobeActiveFrom && s <= p.strobeActiveTo else {
            strobePhase = 0
            return 1
        }
        let maxHz = max(p.strobeMaxHz, 0.5)
        let minHz = min(FixtureProfile.strobeMinHz, maxHz)
        let span = Double(max(p.strobeActiveTo - p.strobeActiveFrom, 1))
        let freq = minHz + Double(s - p.strobeActiveFrom) / span * (maxHz - minHz)

        func openTime(_ u: Double) -> Double {      // tempo di apertura cumulato, in periodi
            let whole = u.rounded(.down)
            return whole * Self.strobeDuty + min(u - whole, Self.strobeDuty)
        }
        let u0 = strobePhase
        let u1 = u0 + freq * max(dt, 1e-6)
        let open = (openTime(u1) - openTime(u0)) / (u1 - u0)
        strobePhase = u1 - u1.rounded(.down)
        return Float(min(max(open, 0), 1))
    }

    // MARK: Gobo, prisma

    /// Applica (o toglie) la maschera gobo al cono visibile, alla macchia a terra e ai sotto-fasci del prisma.
    private func applyMask(_ mask: GoboMask?) {
        guard curMask !== mask else { return }
        curMask = mask
        let shaped = mask != nil
        beams.first?.setRays(mask?.rays(grid: Self.mainRayGrid), shaped: shaped)
        spot?.setMask(mask?.spotImage)
        for b in subBeams { b.setRays(mask?.rays(grid: Self.subRayGrid), shaped: shaped) }
        for s in subSpots { s.setMask(mask?.spotImage) }
    }

    /// Aggiorna la rotazione del prisma. Restituisce true se il prisma è attivo.
    /// Tre intervalli DMX: Spento (fascio singolo), Fisso (sotto-fasci fermi) e Rotazione, dove la velocità
    /// cresce linearmente da `prismMinRPM` (inizio intervallo) a `prismMaxRPM` (fine intervallo).
    /// Se gli intervalli si sovrappongono vale il primo: Spento, poi Rotazione, poi Fisso.
    private func updatePrism(value: Int?, rotation: Int?, dt: Double) -> Bool {
        guard !subBeams.isEmpty else { return false }
        let p = fixture.profile
        // Canale dedicato alla rotazione (v3.1): 0 = ferma, 1…255 = da velocità minima a massima.
        func spin(_ r: Int?) {
            guard let r, r > 0 else { return }
            let rpm = p.prismMinRPM + (p.prismMaxRPM - p.prismMinRPM) * Double(r - 1) / 254
            prismAngle = (prismAngle + rpm * 6.0 * dt).truncatingRemainder(dividingBy: 360)
        }
        guard let v = value else {
            // Nessun canale Prisma: con la sola rotazione il prisma è sempre inserito.
            guard rotation != nil else { return false }
            spin(rotation)
            return true
        }
        if v >= p.prismOffFrom && v <= p.prismOffTo { return false }
        if v >= p.prismRotFrom && v <= p.prismRotTo {
            let span = Double(max(p.prismRotTo - p.prismRotFrom, 1))
            let n = Double(v - p.prismRotFrom) / span
            let rpm = p.prismMinRPM + (p.prismMaxRPM - p.prismMinRPM) * n
            prismAngle += rpm * 6.0 * dt                      // 1 giro/min = 6 gradi/s
            prismAngle = prismAngle.truncatingRemainder(dividingBy: 360)
            return true
        }
        let on = v >= p.prismStaticFrom && v <= p.prismStaticTo
        if on { spin(rotation) }
        return on
    }

    /// Scostamento angolare (gradi) dell'asse di ogni sotto-fascio rispetto all'asse ottico.
    private func prismRadius(half: Double) -> Double {
        min(30, max(2.5, half * 1.6))
    }

    /// Un SCNLight solo: con il prisma si allarga per coprire la corona di sotto-fasci
    /// (il gobo resta sui coni e sulle macchie, non sulla luce, perché verrebbe stirato).
    private func refreshLight(prismOn: Bool, half: Double) {
        guard let light = lightNode?.light else { return }

        let wanted: GoboMask? = prismOn ? nil : curMask
        if lightMask !== wanted {
            lightMask = wanted
            light.gobo?.contents = wanted?.image
        }

        var outer = baseLightOuter
        lightGainScale = 1
        if prismOn {
            outer = CGFloat(min(120, 2 * (prismRadius(half: half) + half)))
            outer = max(outer, baseLightOuter)
            lightGainScale = Float(min(3, outer / max(baseLightOuter, 1)))
        }
        if abs(outer - lastLightOuter) > 0.01 {
            lastLightOuter = outer
            light.spotOuterAngle = outer
            light.spotInnerAngle = outer * 0.6
        }
    }

    private func updateSubBeams(
        color: SIMD3<Float>, intensity: Float, half: Double,
        headQ: simd_quatf, origin: SIMD3<Float>
    ) {
        let n = subBeams.count
        let delta = Self.rad(prismRadius(half: half))
        let base = Float(prismAngle * Double.pi / 180)

        for k in 0..<n {
            let phi = base + Float(k) / Float(n) * 2 * Float.pi
            // Prima inclina il sotto-fascio di `delta` verso +Z, poi lo fa ruotare attorno all'asse ottico.
            let subQ = simd_quatf(angle: phi, axis: [0, 1, 0]) * simd_quatf(angle: delta, axis: [1, 0, 0])
            subBeams[k].node.simdOrientation = subQ

            let dir = headQ.act(subQ.act(SIMD3<Float>(0, 1, 0)))
            var length = maxBeamLength
            let hit = trace(origin: origin, dir: dir)
            if let h = hit { length = Double(h.t) }
            subBeams[k].update(color: color, intensity: intensity, halfAngleDeg: half, length: length)

            if let h = hit {
                updateSpot(
                    subSpots[k], hit: h, dir: dir, half: half,
                    color: color * intensity, right: headQ.act(subQ.act(SIMD3<Float>(1, 0, 0)))
                )
            } else {
                subSpots[k].hide()
            }
        }
    }

    /// Macchia di un fascio sul pavimento o su un oggetto. `right` è l'asse destro dell'immagine del gobo nel mondo.
    private func updateSpot(
        _ spot: SpotVisual, hit h: BeamHit, dir: SIMD3<Float>,
        half: Double, color: SIMD3<Float>, right: SIMD3<Float>
    ) {
        let diameter = Float(2 * Double(h.t) * tan(half * Double.pi / 180)) + 0.12
        let falloff = 1 / (1 + 0.05 * h.t)
        if h.onFloor {
            let p = h.point
            let stretch = min(1 / max(abs(dir.y), 0.12), 8)
            let yaw = atan2f(dir.x, dir.z)
            spot.update(
                position: SIMD3<Float>(p.x, h.floorY + 0.012, p.z),
                yaw: yaw,
                diameter: diameter,
                stretch: stretch,
                color: color * falloff,
                roll: curMask == nil ? 0 : goboRoll(dir: dir, right: right, yaw: yaw)
            )
        } else {
            let stretch = min(1 / max(abs(simd_dot(dir, h.normal)), 0.12), 8)
            spot.updateSurface(
                point: h.point, normal: h.normal, dir: dir,
                diameter: diameter, stretch: stretch, color: color * falloff
            )
        }
    }

    /// Angolo di rotazione dell'immagine del gobo nella macchia a terra, nel riferimento della macchia
    /// (asse X = orizzontale perpendicolare al fascio, asse Y = verso la fixture lungo la proiezione).
    private func goboRoll(dir: SIMD3<Float>, right: SIMD3<Float>, yaw: Float) -> Float {
        let planeX = SIMD3<Float>(cosf(yaw), 0, -sinf(yaw))
        var along = simd_cross(dir, planeX)
        let len = simd_length(along)
        guard len > 1e-4 else { return 0 }
        along /= len
        let a = simd_dot(right, planeX)
        let b = simd_dot(right, along)
        return atan2f(-b, a)
    }

    private func updateLight(color: SIMD3<Float>, level: Float) {
        guard let light = lightNode?.light else { return }
        let target = level * lightGain * lightGainScale
        let key = colorKey(color)
        if key != lastLightKey {
            lastLightKey = key
            light.color = nsColor(color)
        }
        if abs(target - lastLightIntensity) > 2 || ((target == 0) != (lastLightIntensity == 0)) {
            lastLightIntensity = target
            light.intensity = CGFloat(target)
        }
    }

    /// Barra multi-pixel: ogni LED ha i propri canali (R, G, B, eventualmente W) e il proprio cono, troncato
    /// sull'eventuale oggetto che incontra. Con la barra motorizzata il tilt inclina tutti i fasci insieme.
    private func updatePixels(
        ch: (Int?) -> Int?, intensity: Float, half: Double,
        headQ: simd_quatf, placeQ: simd_quatf, master: Float
    ) {
        let layout = map.pixels
        let dir = headQ.act(SIMD3<Float>(0, 1, 0))
        let base = worldBase + placeQ.act(SIMD3<Float>(0, pivotHeight, 0))
        var acc = SIMD3<Float>(repeating: 0)
        for i in 0..<beams.count {
            var r: Float = 0, g: Float = 0, b: Float = 0, w: Float = 0
            if i < layout.count {
                let px = layout[i]
                r = Float(ch(px.r) ?? 0) / 255
                g = Float(ch(px.g) ?? 0) / 255
                b = Float(ch(px.b) ?? 0) / 255
                w = Float(ch(px.w) ?? 0) / 255
            } else {
                r = Float(ch(map.red) ?? 0) / 255
                g = Float(ch(map.green) ?? 0) / 255
                b = Float(ch(map.blue) ?? 0) / 255
                w = Float(ch(map.white) ?? 0) / 255
            }
            let c = simd_min(SIMD3<Float>(r + w, g + w, b + w), SIMD3<Float>(repeating: 1)) * intensity
            acc += c

            let shown = c * master
            var length = maxBeamLength
            if max(shown.x, max(shown.y, shown.z)) > 0.004 {
                let off = i < pixelOffsets.count ? pixelOffsets[i] : 0
                let o = base + headQ.act(SIMD3<Float>(off, lensDistance, 0))
                if let h = trace(origin: o, dir: dir) { length = Double(h.t) }
            }
            beams[i].update(color: shown, intensity: 1, halfAngleDeg: half, length: length)

            if i < pixelMats.count {
                let lv = SIMD3<Float>(repeating: 0.1) + c * 0.9
                let key = colorKey(lv)
                if key != pixelKeys[i] {
                    pixelKeys[i] = key
                    pixelMats[i].diffuse.contents = nsColor(lv)
                }
            }
        }

        let avg = acc / Float(max(beams.count, 1))
        let level = max(avg.x, max(avg.y, avg.z))
        let lightColor = level > 0.001 ? avg / level : SIMD3<Float>(1, 1, 1)
        updateLight(color: lightColor, level: level * master)
    }
}
