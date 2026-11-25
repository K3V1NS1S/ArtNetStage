import Foundation
import UniformTypeIdentifiers

// MARK: - Versione

enum AppInfo {
    /// Versione mostrata nell'interfaccia (deve coincidere con CFBundleShortVersionString / MARKETING_VERSION).
    static let version = "1.3"
    static let build = "4"
    static let name = "ArtNet Stage"
}

// MARK: - Tipo di file

/// Estensione e tipo di documento delle scene salvate su disco.
enum ProjectFileType {
    static let fileExtension = "artnetstage"
    static let identifier = "local.artnetstage.project"

    /// Il tipo dichiarato in Info.plist; se l'app gira senza (per esempio da Xcode senza la dichiarazione)
    /// si ricade su un tipo dinamico legato all'estensione, che i pannelli di macOS gestiscono comunque.
    static var utType: UTType {
        UTType(identifier)
            ?? UTType(filenameExtension: fileExtension, conformingTo: .json)
            ?? .json
    }
}

// MARK: - Contenuto del file

enum ProjectFileError: LocalizedError {
    case newerFormat(Int)

    var errorDescription: String? {
        switch self {
        case .newerFormat(let v):
            return "Il file è stato creato da una versione più recente di ArtNet Stage (formato \(v)). Aggiorna l'app per aprirlo."
        }
    }
}

/// Stato completo del progetto, salvato come JSON in un file `.artnetstage`:
/// palco e americane (dimensioni e colore), fixture patchate con indirizzi e canali DMX (profilo incluso:
/// modalità colore, strobo in Hz, prisma e **maschere gobo incorporate come PNG in base64**),
/// libreria fixture, oggetti 3D, parametri del nodo Art-Net e inquadratura della camera.
///
/// Formato 1 = ArtNet Stage 1.1 (si apre ancora: i campi nuovi hanno valori predefiniti).
/// Formato 2 = ArtNet Stage 1.2 (gobo e prisma; la 1.1 lo rifiuta con un messaggio chiaro).
/// Formato 3 = ArtNet Stage 1.3 (dimensioni fixture, forma PAR, barre multi-pixel motorizzate, stativi,
/// macchina del fumo, posizioni/rotazioni dal Gumball, luminosità di scena e luci). Le versioni precedenti
/// non aprono i file di formato 3; la 1.3 apre ancora i formati 1 e 2.
struct ProjectFile: Codable {
    static let currentFormat = 3

    var format: Int
    var appVersion: String
    var savedAt: Date
    var nodeName: String?
    var net: Int
    var subNet: Int
    var stage: StageConfig
    var fixtures: [PatchedFixture]
    var library: [FixtureProfile]?
    var objects: [StageObject]
    var camera: CameraSnapshot?
    /// Luminosità elementi di scena (0...1) e master luci (0...2). Nil nei file delle versioni precedenti.
    var ambientLevel: Double?
    var beamMaster: Double?

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    static func decode(from data: Data) throws -> ProjectFile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(ProjectFile.self, from: data)
        if file.format > currentFormat { throw ProjectFileError.newerFormat(file.format) }
        return file
    }
}
