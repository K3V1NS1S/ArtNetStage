import Foundation
import SwiftUI
import AppKit

// MARK: - Tipologie e ruoli

enum FixtureType: String, Codable, CaseIterable, Identifiable {
    case movingHeadBeam = "Moving Head Beam"
    case movingHeadSpot = "Moving Head Spot"
    case parLED = "PAR LED"
    case ledBar = "Barra LED Multi-Pixel"

    var id: String { rawValue }

    var isMover: Bool { self == .movingHeadBeam || self == .movingHeadSpot }

    var icon: String {
        switch self {
        case .movingHeadBeam, .movingHeadSpot: return "scope"
        case .parLED: return "circle.circle"
        case .ledBar: return "rectangle.split.3x1"
        }
    }
}

enum ChannelRole: String, Codable, CaseIterable, Identifiable {
    case dimmer
    case red, green, blue, white
    case colorWheel
    case pan, panFine, tilt, tiltFine
    case panTiltSpeed
    case strobe
    case pixel
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
        case .pixel: return "Multi-Pixel RGB/RGBW"
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

    var channelCount: Int { channels.count }

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

    var endAddress: Int { startAddress + profile.channelCount - 1 }
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
