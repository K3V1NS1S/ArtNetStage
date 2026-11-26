import Foundation

// MARK: - Palco

/// Tipologia di ambiente (v2.4): palco aperto oppure sala chiusa con pareti (fondo, sinistra, destra) e soffitto.
enum StageEnvironment: String, Codable, CaseIterable, Identifiable {
    case open = "open"
    case closed = "closed"

    var id: String { rawValue }
    var title: String { self == .open ? "Palco Aperto" : "Ambiente Chiuso / Sala" }
}

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
    /// Colore del piano del palco (#RRGGBB) — v1.4.
    var deckColorHex: String = StageConfig.defaultDeckColorHex
    /// Luminosità del piano del palco (0…1.5), indipendente dal livello «Elementi scena» — v1.4.
    var deckBrightness: Double = StageConfig.defaultDeckBrightness

    static let defaultDeckColorHex = "#333333"
    static let defaultDeckBrightness = 0.35

    // MARK: Ambiente chiuso / sala (v2.4)

    /// `.open` = palco aperto (come nelle versioni precedenti); `.closed` = sala con 3 pareti e soffitto (fronte pubblico aperto).
    var environment: StageEnvironment = .open
    /// Larghezza (asse X) e profondità (asse Z) della sala, centrate sull'origine del palco. Il lato +Z (pubblico) resta aperto.
    var roomWidth: Double = 14
    var roomDepth: Double = 10
    /// Altezza del soffitto sopra il piano del palco.
    var ceilingHeight: Double = 6
    /// Colore delle superfici interne (#RRGGBB) e relativa luminosità / riflettività (0…1.5).
    var roomColorHex: String = StageConfig.defaultRoomColorHex
    var roomBrightness: Double = StageConfig.defaultRoomBrightness

    static let defaultRoomColorHex = "#4A4A52"
    static let defaultRoomBrightness = 0.6

    var isClosedRoom: Bool { environment == .closed }

    /// Posizione Z della prima americana (al centro del palco).
    var frontTrussZ: Double { 0 }
    /// Posizione Z della seconda americana (verso il fondale).
    var backTrussZ: Double { -(depth / 2 - 0.5) }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case width, depth, baseHeight, trussHeight, showTruss, trussColorHex, beamShadows, deckColorHex, deckBrightness
        case environment, roomWidth, roomDepth, ceilingHeight, roomColorHex, roomBrightness
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
        deckColorHex = try c.decodeIfPresent(String.self, forKey: .deckColorHex) ?? StageConfig.defaultDeckColorHex
        deckBrightness = try c.decodeIfPresent(Double.self, forKey: .deckBrightness) ?? StageConfig.defaultDeckBrightness
        // v2.4: i file delle versioni precedenti non hanno questi campi e si aprono come palco aperto.
        environment = try c.decodeIfPresent(StageEnvironment.self, forKey: .environment) ?? .open
        roomWidth = try c.decodeIfPresent(Double.self, forKey: .roomWidth) ?? 14
        roomDepth = try c.decodeIfPresent(Double.self, forKey: .roomDepth) ?? 10
        ceilingHeight = try c.decodeIfPresent(Double.self, forKey: .ceilingHeight) ?? 6
        roomColorHex = try c.decodeIfPresent(String.self, forKey: .roomColorHex) ?? StageConfig.defaultRoomColorHex
        roomBrightness = try c.decodeIfPresent(Double.self, forKey: .roomBrightness) ?? StageConfig.defaultRoomBrightness
        // Nota: i file salvati con la 2.1 contengono anche «showCrowd» (folla, rimossa nella 2.2): la chiave viene ignorata.
    }

    func clamped() -> StageConfig {
        var c = self
        c.width = min(max(c.width, 2), 60)
        c.depth = min(max(c.depth, 2), 40)
        c.baseHeight = min(max(c.baseHeight, 0), 4)
        c.trussHeight = min(max(c.trussHeight, 1.5), 20)
        if !c.deckBrightness.isFinite { c.deckBrightness = StageConfig.defaultDeckBrightness }
        c.deckBrightness = min(max(c.deckBrightness, 0), 1.5)
        c.roomWidth = min(max(c.roomWidth, 4), 80)
        c.roomDepth = min(max(c.roomDepth, 4), 60)
        c.ceilingHeight = min(max(c.ceilingHeight, 2), 30)
        if !c.roomBrightness.isFinite { c.roomBrightness = StageConfig.defaultRoomBrightness }
        c.roomBrightness = min(max(c.roomBrightness, 0), 1.5)
        return c
    }
}

// MARK: - Oggetti 3D

enum StageObjectKind: String, Codable, CaseIterable, Identifiable {
    case box = "Parallelepipedo"
    case mannequin = "Manichino"
    case standSingle = "Stativo singolo"
    case standDouble = "Stativo T-Bar 2 posti"
    case standQuad = "Stativo T-Bar 4 posti"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .box: return "cube"
        case .mannequin: return "person.fill"
        case .standSingle: return "line.diagonal"
        case .standDouble, .standQuad: return "t.square"
        }
    }

    var isStand: Bool { self == .standSingle || self == .standDouble || self == .standQuad }

    /// Numero di attacchi per le fixture (0 per gli oggetti che non ne hanno).
    var mountCount: Int {
        switch self {
        case .standSingle: return 1
        case .standDouble: return 2
        case .standQuad: return 4
        default: return 0
        }
    }

    /// Voci del menu «Aggiungi» raggruppate: oggetti normali e stativi.
    static let plainKinds: [StageObjectKind] = [.box, .mannequin]
    static let standKinds: [StageObjectKind] = [.standSingle, .standDouble, .standQuad]
}

struct StageObject: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: StageObjectKind
    var x: Double = 0
    /// Altezza della base dell'oggetto rispetto al piano del palco.
    var y: Double = 0
    var z: Double = 0
    /// Per gli stativi: `width` = larghezza della barra superiore, `height` = altezza totale (estensione dell'asta),
    /// `depth` = ingombro (diametro) della base a treppiede.
    var width: Double = 1
    var height: Double = 1
    var depth: Double = 1
    var yaw: Double = 0
    var colorHex: String = "#9A9A9A"
    /// Inclinazione attorno a X e rollio attorno a Z (gradi), modificabili con gli archi del Gumball. Nil = 0.
    var pitch: Double? = nil
    var roll: Double? = nil

    var pitchDeg: Double { pitch ?? 0 }
    var rollDeg: Double { roll ?? 0 }

    /// Spessore della barra superiore dello stativo.
    static let barThickness = 0.035

    /// Posizioni X (nel riferimento dello stativo) dei punti di montaggio lungo la barra superiore.
    func mountLocalX() -> [Double] {
        let n = kind.mountCount
        switch n {
        case 0: return []
        case 1: return [0]
        case 2: return [-0.5 * width, 0.5 * width]
        default: return (0..<n).map { (-0.5 + Double($0) / Double(n - 1)) * width }
        }
    }

    /// Punti di montaggio degli stativi in coordinate mondo, relativi al piano del palco
    /// (la quota Y è sopra il piano del palco, come `PatchedFixture.y`).
    func mountPoints() -> [SIMD3<Double>] {
        let n = kind.mountCount
        guard n > 0 else { return [] }
        let top = y + height + (n > 1 ? Self.barThickness : 0.012)
        let a = yaw * Double.pi / 180
        let c = cos(a), s = sin(a)
        // Rotazione attorno a Y: x' = x·cos, z' = -x·sin (convenzione SceneKit per eulerAngles.y)
        return mountLocalX().map { lx in SIMD3<Double>(x + lx * c, top, z - lx * s) }
    }
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
