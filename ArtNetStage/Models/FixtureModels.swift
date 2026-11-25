import Foundation
import SwiftUI
import AppKit

// MARK: - Tipologie e ruoli

enum FixtureType: String, Codable, CaseIterable, Identifiable {
    case movingHeadBeam = "Moving Head Beam"
    case movingHeadSpot = "Moving Head Spot"
    case parLED = "PAR LED"
    case ledBar = "Barra LED Multi-Pixel"
    case wallWash = "Wall Wash"
    case smokeMachine = "Macchina del Fumo"

    var id: String { rawValue }

    var isMover: Bool { self == .movingHeadBeam || self == .movingHeadSpot }

    /// PAR e Wall Wash condividono il corpo a cassa/cilindro con staffa a «U».
    var isWash: Bool { self == .parLED || self == .wallWash }

    /// Emette luce (fascio, luce SCNLight, macchia a terra). La macchina del fumo no.
    var emitsLight: Bool { self != .smokeMachine }

    var icon: String {
        switch self {
        case .movingHeadBeam, .movingHeadSpot: return "scope"
        case .parLED: return "circle.circle"
        case .ledBar: return "rectangle.split.3x1"
        case .wallWash: return "rectangle.portrait.and.arrow.right"
        case .smokeMachine: return "cloud.fill"
        }
    }
}

/// Forma del corpo di PAR e Wall Wash.
enum BodyShape: String, Codable, CaseIterable, Identifiable {
    case round = "Tondo"
    case rect = "Rettangolare"

    var id: String { rawValue }
}

/// Ingombro fisico di una fixture in metri: larghezza (asse X; lunghezza per la barra), altezza (Y), profondità (Z).
struct FixtureDims: Hashable {
    var w: Double
    var h: Double
    var d: Double
}

enum ChannelRole: String, Codable, CaseIterable, Identifiable {
    case dimmer
    case red, green, blue, white
    case colorWheel
    case pan, panFine, tilt, tiltFine
    case panTiltSpeed
    case strobe
    case gobo
    case prism
    case pixel
    case smoke
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dimmer: return "Dimmer (intensità master)"
        case .red: return "Rosso"
        case .green: return "Verde"
        case .blue: return "Blu"
        case .white: return "Bianco"
        case .colorWheel: return "Color Wheel"
        case .pan: return "Pan (8-bit / coarse)"
        case .panFine: return "Pan Fine (16-bit)"
        case .tilt: return "Tilt (8-bit / coarse)"
        case .tiltFine: return "Tilt Fine (16-bit)"
        case .panTiltSpeed: return "Pan/Tilt Speed"
        case .strobe: return "Strobe / Shutter"
        case .gobo: return "Gobo (maschere personalizzate)"
        case .prism: return "Prisma radiale"
        case .pixel: return "Multi-Pixel RGB/RGBW"
        case .smoke: return "Fumo (attivazione / intensità)"
        case .custom: return "Custom / Non usato"
        }
    }
}

// MARK: - Canali

struct ColorWheelSlot: Codable, Identifiable, Hashable {
    var id = UUID()
    var from: Int
    var to: Int
    var name: String
    var colorHex: String
}

struct ChannelDefinition: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var role: ChannelRole
    var wheelSlots: [ColorWheelSlot] = []
}

// MARK: - Colore, gobo, prisma (v1.2)

/// Come la fixture compone il colore del fascio.
enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case wheel = "Ruota Colori"
    case rgb = "RGB"
    case rgbw = "RGBW"

    var id: String { rawValue }
}

/// Un intervallo DMX del canale Gobo con la sua maschera. Senza immagine il gobo è «aperto» (nessuna sagomatura).
/// L'immagine è un PNG quadrato in scala di grigi (bianco = passa la luce, nero = blocca), incorporato
/// nel profilo: viene quindi salvato dentro i file `.artnetstage`, senza dipendere dal file originale.
struct GoboSlot: Codable, Identifiable, Hashable {
    var id = UUID()
    var from: Int
    var to: Int
    var name: String
    var imageData: Data? = nil
    /// Cambia a ogni sostituzione dell'immagine: identifica la maschera nella cache del renderer.
    var revision = UUID()
    /// Nome del file di origine, solo informativo.
    var sourceName: String? = nil

    var hasImage: Bool { imageData != nil }

    /// L'hash non legge i byte dell'immagine (la `revision` basta): le firme delle fixture restano economiche.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(from)
        hasher.combine(to)
        hasher.combine(name)
        hasher.combine(revision)
    }
}

// MARK: - Pixel

enum PixelComponent: String, Codable, CaseIterable {
    case r = "R", g = "G", b = "B", w = "W"
}

struct PixelConfig: Codable, Hashable {
    var count: Int = 10
    var components: [PixelComponent] = [.r, .g, .b]
    /// Indice (0-based) del primo canale dei pixel all'interno della fixture.
    var firstChannel: Int = 0

    var stride: Int { components.count }
    var channelSpan: Int { count * stride }

    static let orderPresets: [[PixelComponent]] = [
        [.r, .g, .b], [.g, .r, .b], [.b, .g, .r],
        [.r, .g, .b, .w], [.w, .r, .g, .b], [.g, .r, .b, .w]
    ]

    static func orderLabel(_ c: [PixelComponent]) -> String {
        c.map { $0.rawValue }.joined()
    }
}

// MARK: - Profilo fixture

struct FixtureProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var modelName: String
    var type: FixtureType
    var channels: [ChannelDefinition]
    var panRange: Double = 540
    var tiltRange: Double = 270
    /// Apertura totale del cono in gradi.
    var beamAngle: Double = 25
    var pixelConfig: PixelConfig? = nil

    // v1.2 — colore, strobo, gobo, prisma
    /// Ruota colori (con transito), RGB oppure RGBW.
    var colorMode: ColorMode = .rgb
    /// Frequenza dello strobo in Hz al valore DMX 255 (il valore 10 corrisponde a 1 Hz).
    var strobeMaxHz: Double = 16
    /// Intervalli DMX del canale Gobo e relative maschere.
    var gobos: [GoboSlot] = []
    /// Numero di sotto-fasci (facce) del prisma radiale.
    var prismFacets: Int = 6
    /// Valore DMX da cui il prisma è inserito (0 = sempre inserito).
    var prismInFrom: Int = 1
    /// Soglia DMX: fino a questo valore il prisma resta fermo, oltre ruota con velocità crescente.
    var prismRotateThreshold: Int = 128
    /// Velocità di rotazione del prisma al valore DMX 255, in giri al minuto.
    var prismMaxRPM: Double = 60

    // v1.3 — forma del corpo, barra motorizzata
    /// Forma del corpo di PAR LED e Wall Wash.
    var bodyShape: BodyShape = .round
    /// Barra LED motorizzata: il canale Tilt inclina l'intera barra.
    var barMotorized: Bool = false

    var channelCount: Int { channels.count }

    /// Pan/Tilt attivi: teste mobili e barre motorizzate (solo tilt).
    var hasTilt: Bool { type.isMover || (type == .ledBar && barMotorized) }

    /// Ingombro predefinito (metri) per tipo di fixture; le dimensioni modificate stanno in `PatchedFixture`.
    var defaultDims: FixtureDims {
        switch type {
        case .movingHeadBeam, .movingHeadSpot: return FixtureDims(w: 0.42, h: 0.62, d: 0.36)
        case .parLED: return FixtureDims(w: 0.30, h: 0.36, d: 0.26)
        case .wallWash: return FixtureDims(w: 0.46, h: 0.34, d: 0.26)
        case .ledBar:
            let n = max(1, pixelConfig?.count ?? 1)
            return FixtureDims(w: 0.1 * Double(n) + 0.04, h: 0.06, d: 0.08)
        case .smokeMachine: return FixtureDims(w: 0.45, h: 0.22, d: 0.28)
        }
    }

    /// Attiva o disattiva la motorizzazione della barra: aggiunge/toglie il canale Tilt in testa
    /// e sposta di conseguenza il primo canale dei pixel.
    mutating func setBarMotorized(_ on: Bool) {
        guard type == .ledBar else { return }
        barMotorized = on
        if on {
            if !hasChannel(.tilt) {
                channels.insert(ChannelDefinition(name: "Tilt", role: .tilt), at: 0)
                if var pc = pixelConfig { pc.firstChannel += 1; pixelConfig = pc }
            }
            if tiltRange < 45 || tiltRange > 360 { tiltRange = 180 }
            if tiltRange == 270 { tiltRange = 180 }
        } else {
            var removedBeforePixels = 0
            let first = pixelConfig?.firstChannel ?? 0
            var i = channels.count - 1
            while i >= 0 {
                if channels[i].role == .tilt || channels[i].role == .tiltFine {
                    if i < first { removedBeforePixels += 1 }
                    channels.remove(at: i)
                }
                i -= 1
            }
            if var pc = pixelConfig { pc.firstChannel = max(0, pc.firstChannel - removedBeforePixels); pixelConfig = pc }
        }
        regeneratePixelChannels()
    }

    /// Passa le barre LED da RGB a RGBW e viceversa (anche i PAR/Wall Wash usano `colorMode`).
    mutating func setPixelWhite(_ on: Bool) {
        guard var pc = pixelConfig else { return }
        pc.components = on ? [.r, .g, .b, .w] : [.r, .g, .b]
        pixelConfig = pc
        colorMode = on ? .rgbw : .rgb
        regeneratePixelChannels()
    }

    /// Conta dei pixel con ridimensionamento dei canali (mantiene l'ordine dei componenti).
    mutating func setPixelCount(_ n: Int) {
        guard var pc = pixelConfig else { return }
        pc.count = min(max(n, 1), 170)
        pixelConfig = pc
        regeneratePixelChannels()
        trimTrailingPixelChannels()
    }

    /// Dopo una riduzione dei pixel toglie i canali «vuoti» in coda, riportando i ruoli a Custom.
    mutating func trimTrailingPixelChannels() {
        guard let pc = pixelConfig else { return }
        let needed = pc.firstChannel + pc.channelSpan
        while channels.count > needed, let last = channels.last, last.role == .custom, last.name.hasPrefix("CH ") {
            channels.removeLast()
        }
    }

    func hasChannel(_ role: ChannelRole) -> Bool { channels.contains { $0.role == role } }

    mutating func setChannelCount(_ newCount: Int) {
        let n = min(max(newCount, 1), 512)
        if n > channels.count {
            for i in channels.count..<n {
                channels.append(ChannelDefinition(name: "CH \(i + 1)", role: .custom))
            }
        } else if n < channels.count {
            channels.removeLast(channels.count - n)
        }
    }

    /// Assegna il ruolo `.pixel` ai canali occupati dai pixel e li rinomina.
    mutating func regeneratePixelChannels() {
        guard let pc = pixelConfig else { return }
        let needed = pc.firstChannel + pc.channelSpan
        if needed > channels.count { setChannelCount(needed) }
        for i in channels.indices where channels[i].role == .pixel {
            channels[i].role = .custom
            channels[i].name = "CH \(i + 1)"
        }
        for p in 0..<pc.count {
            for (k, comp) in pc.components.enumerated() {
                let idx = pc.firstChannel + p * pc.stride + k
                guard idx < channels.count else { continue }
                channels[idx].role = .pixel
                channels[idx].name = "Pixel \(p + 1) \(comp.rawValue)"
            }
        }
    }
}

// Codable tollerante: i profili salvati con la 1.1 (senza i campi nuovi) si leggono ancora.
// Sta in un'estensione per non perdere l'inizializzatore membro a membro usato dai preset.
extension FixtureProfile {
    enum CodingKeys: String, CodingKey {
        case id, modelName, type, channels, panRange, tiltRange, beamAngle, pixelConfig
        case colorMode, strobeMaxHz, gobos, prismFacets, prismInFrom, prismRotateThreshold, prismMaxRPM
        case bodyShape, barMotorized
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        modelName = try c.decode(String.self, forKey: .modelName)
        type = try c.decode(FixtureType.self, forKey: .type)
        channels = try c.decode([ChannelDefinition].self, forKey: .channels)
        panRange = try c.decodeIfPresent(Double.self, forKey: .panRange) ?? 540
        tiltRange = try c.decodeIfPresent(Double.self, forKey: .tiltRange) ?? 270
        beamAngle = try c.decodeIfPresent(Double.self, forKey: .beamAngle) ?? 25
        pixelConfig = try c.decodeIfPresent(PixelConfig.self, forKey: .pixelConfig)

        if let mode = try c.decodeIfPresent(ColorMode.self, forKey: .colorMode) {
            colorMode = mode
        } else {
            // File della 1.1: la modalità si deduce dai canali presenti.
            let roles = Set(channels.map { $0.role })
            if roles.contains(.red) || roles.contains(.green) || roles.contains(.blue) {
                colorMode = roles.contains(.white) ? .rgbw : .rgb
            } else if roles.contains(.colorWheel) {
                colorMode = .wheel
            } else {
                colorMode = .rgb
            }
        }
        strobeMaxHz = try c.decodeIfPresent(Double.self, forKey: .strobeMaxHz) ?? 16
        gobos = try c.decodeIfPresent([GoboSlot].self, forKey: .gobos) ?? []
        prismFacets = try c.decodeIfPresent(Int.self, forKey: .prismFacets) ?? 6
        prismInFrom = try c.decodeIfPresent(Int.self, forKey: .prismInFrom) ?? 1
        prismRotateThreshold = try c.decodeIfPresent(Int.self, forKey: .prismRotateThreshold) ?? 128
        prismMaxRPM = try c.decodeIfPresent(Double.self, forKey: .prismMaxRPM) ?? 60
        bodyShape = try c.decodeIfPresent(BodyShape.self, forKey: .bodyShape) ?? .round
        barMotorized = try c.decodeIfPresent(Bool.self, forKey: .barMotorized) ?? false
        sanitizeOptics()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(type, forKey: .type)
        try c.encode(channels, forKey: .channels)
        try c.encode(panRange, forKey: .panRange)
        try c.encode(tiltRange, forKey: .tiltRange)
        try c.encode(beamAngle, forKey: .beamAngle)
        try c.encodeIfPresent(pixelConfig, forKey: .pixelConfig)
        try c.encode(colorMode, forKey: .colorMode)
        try c.encode(strobeMaxHz, forKey: .strobeMaxHz)
        try c.encode(gobos, forKey: .gobos)
        try c.encode(prismFacets, forKey: .prismFacets)
        try c.encode(prismInFrom, forKey: .prismInFrom)
        try c.encode(prismRotateThreshold, forKey: .prismRotateThreshold)
        try c.encode(prismMaxRPM, forKey: .prismMaxRPM)
        try c.encode(bodyShape, forKey: .bodyShape)
        try c.encode(barMotorized, forKey: .barMotorized)
    }

    /// Riporta i parametri ottici in intervalli sensati (file modificati a mano, valori fuori scala).
    mutating func sanitizeOptics() {
        if !strobeMaxHz.isFinite { strobeMaxHz = 16 }
        strobeMaxHz = min(max(strobeMaxHz, 0.5), 60)
        prismFacets = min(max(prismFacets, 2), 24)
        prismInFrom = min(max(prismInFrom, 0), 255)
        prismRotateThreshold = min(max(prismRotateThreshold, 0), 255)
        if !prismMaxRPM.isFinite { prismMaxRPM = 60 }
        prismMaxRPM = min(max(prismMaxRPM, 1), 600)
        for i in gobos.indices {
            gobos[i].from = min(max(gobos[i].from, 0), 255)
            gobos[i].to = min(max(gobos[i].to, gobos[i].from), 255)
        }
    }
}

// MARK: - Luce patchata

enum MountOrientation: String, Codable, CaseIterable, Identifiable {
    case floor = "A terra"
    case truss = "Su americana / truss"
    case vertical = "Verticale (laterale)"

    var id: String { rawValue }
}

struct PatchedFixture: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var profile: FixtureProfile
    /// Universo Art-Net 0-15 (combinato con Net/SubNet impostati nel pannello Rete).
    var universe: Int = 0
    /// Indirizzo DMX di partenza 1-512.
    var startAddress: Int = 1
    /// X = sinistra/destra, Y = altezza, Z = profondità (positivo verso il pubblico), in metri.
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var mount: MountOrientation = .floor
    var yaw: Double = 0
    var staticPan: Double = 0
    var staticTilt: Double = 0
    var invertPan: Bool = false
    var invertTilt: Bool = false

    // v1.3 — dimensioni personalizzate (nil = predefinite del profilo) e aggancio a uno stativo
    var sizeW: Double? = nil
    var sizeH: Double? = nil
    var sizeD: Double? = nil
    /// Stativo (`StageObject.id`) a cui la luce è agganciata e indice del suo punto di montaggio.
    var mountedOn: UUID? = nil
    var mountSlot: Int? = nil

    var endAddress: Int { startAddress + profile.channelCount - 1 }

    /// Ingombro effettivo, limitato a valori sensati.
    var dims: FixtureDims {
        let d = profile.defaultDims
        func clamp(_ v: Double?, _ def: Double) -> Double {
            guard let v, v.isFinite else { return def }
            return min(max(v, 0.03), 5)
        }
        return FixtureDims(w: clamp(sizeW, d.w), h: clamp(sizeH, d.h), d: clamp(sizeD, d.d))
    }

    var hasCustomSize: Bool { sizeW != nil || sizeH != nil || sizeD != nil }
}

// MARK: - Colori

func parseHex(_ hex: String) -> SIMD3<Float> {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return SIMD3<Float>(1, 1, 1) }
    return SIMD3<Float>(
        Float((v >> 16) & 255) / 255,
        Float((v >> 8) & 255) / 255,
        Float(v & 255) / 255
    )
}

extension Color {
    init(hex: String) {
        let c = parseHex(hex)
        self.init(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: 1)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return String(
            format: "#%02X%02X%02X",
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded())
        )
    }
}
