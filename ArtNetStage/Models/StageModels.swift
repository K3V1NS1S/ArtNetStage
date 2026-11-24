import Foundation

// MARK: - Palco

/// Dimensioni del palco e delle americane (metri). Modificabili in tempo reale dal pannello "Palco".
struct StageConfig: Codable, Hashable {
    var width: Double = 12
    var depth: Double = 8
    /// Altezza del piano del palco dal suolo (0 = palco a terra).
    var baseHeight: Double = 0
    /// Altezza delle americane (asse centrale) sopra il piano del palco.
    var trussHeight: Double = 5
    var showTruss: Bool = true
    /// Ombre proiettate dai fasci sugli oggetti (disattivale se la scena rallenta).
    var beamShadows: Bool = true

    /// Posizione Z della prima americana (al centro del palco).
    var frontTrussZ: Double { 0 }
    /// Posizione Z della seconda americana (verso il fondale).
    var backTrussZ: Double { -(depth / 2 - 0.5) }

    func clamped() -> StageConfig {
        var c = self
        c.width = min(max(c.width, 2), 60)
        c.depth = min(max(c.depth, 2), 40)
        c.baseHeight = min(max(c.baseHeight, 0), 4)
        c.trussHeight = min(max(c.trussHeight, 1.5), 20)
        return c
    }
}

// MARK: - Oggetti 3D

enum StageObjectKind: String, Codable, CaseIterable, Identifiable {
    case box = "Parallelepipedo"
    case mannequin = "Manichino"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .box: return "cube"
        case .mannequin: return "person.fill"
        }
    }
}

struct StageObject: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: StageObjectKind
    var x: Double = 0
    /// Altezza della base dell'oggetto rispetto al piano del palco.
    var y: Double = 0
    var z: Double = 0
    var width: Double = 1
    var height: Double = 1
    var depth: Double = 1
    var yaw: Double = 0
    var colorHex: String = "#9A9A9A"
}

// MARK: - Scene salvate

/// Inquadratura della camera (pitch = elevazione in gradi sopra l'orizzonte).
struct CameraSnapshot: Codable, Hashable {
    var yaw: Double
    var pitch: Double
    var dist: Double
    var tx: Double
    var tz: Double
}

struct ScenePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date = Date()
    var fixtures: [PatchedFixture]
    var stage: StageConfig
    var objects: [StageObject]
    var net: Int
    var subNet: Int
    var camera: CameraSnapshot?
}
