import Foundation

// MARK: - Palco

/// Dimensioni del palco e delle americane (metri). Modificabili in tempo reale dal pannello "Palco".
struct StageConfig: Codable, Hashable {
    /// Alluminio: colore predefinito delle americane.
    static let defaultTrussColorHex = "#A8ACB1"

    var width: Double = 12
    var depth: Double = 8
    /// Altezza del piano del palco dal suolo (0 = palco a terra).
    var baseHeight: Double = 0
    /// Altezza delle americane (asse centrale) sopra il piano del palco.
    var trussHeight: Double = 5
    var showTruss: Bool = true
    /// Colore della struttura delle americane (#RRGGBB).
    var trussColorHex: String = StageConfig.defaultTrussColorHex
    /// Ombre proiettate dai fasci sugli oggetti (disattivale se la scena rallenta).
    var beamShadows: Bool = true

    /// Posizione Z della prima americana (al centro del palco).
    var frontTrussZ: Double { 0 }
    /// Posizione Z della seconda americana (verso il fondale).
    var backTrussZ: Double { -(depth / 2 - 0.5) }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case width, depth, baseHeight, trussHeight, showTruss, trussColorHex, beamShadows
    }

    /// Decodifica tollerante: i file e i salvataggi creati prima dell'aggiunta di un campo
    /// (per esempio il colore delle americane) restano leggibili e usano il valore predefinito.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 12
        depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? 8
        baseHeight = try c.decodeIfPresent(Double.self, forKey: .baseHeight) ?? 0
        trussHeight = try c.decodeIfPresent(Double.self, forKey: .trussHeight) ?? 5
        showTruss = try c.decodeIfPresent(Bool.self, forKey: .showTruss) ?? true
        trussColorHex = try c.decodeIfPresent(String.self, forKey: .trussColorHex) ?? StageConfig.defaultTrussColorHex
        beamShadows = try c.decodeIfPresent(Bool.self, forKey: .beamShadows) ?? true
    }

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

// MARK: - Camera

/// Inquadratura della camera (pitch = elevazione in gradi sopra l'orizzonte).
struct CameraSnapshot: Codable, Hashable {
    var yaw: Double
    var pitch: Double
    var dist: Double
    var tx: Double
    var tz: Double
}
