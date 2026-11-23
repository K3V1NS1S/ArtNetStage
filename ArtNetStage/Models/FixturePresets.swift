import Foundation

enum FixturePresets {

    private static func ch(_ name: String, _ role: ChannelRole, wheel: [ColorWheelSlot] = []) -> ChannelDefinition {
        ChannelDefinition(name: name, role: role, wheelSlots: wheel)
    }

    /// Ruota colori standard a range da 10 valori DMX.
    static func standardWheel() -> [ColorWheelSlot] {
        let items: [(Int, Int, String, String)] = [
            (0, 9, "Bianco", "#FFFFFF"),
            (10, 19, "Rosso", "#FF0000"),
            (20, 29, "Arancione", "#FF7A00"),
            (30, 39, "Giallo", "#FFE600"),
            (40, 49, "Verde", "#00D84A"),
            (50, 59, "Azzurro", "#00B7FF"),
            (60, 69, "Blu", "#0030FF"),
            (70, 79, "Viola", "#8A2BE2"),
            (80, 89, "Magenta", "#FF00B4"),
            (90, 99, "Rosa", "#FF8FC7")
        ]
        return items.map { ColorWheelSlot(from: $0.0, to: $0.1, name: $0.2, colorHex: $0.3) }
    }

    // UUID fissi: permettono di ripristinare i preset senza duplicarli.

    /// PAR LED RGBW a 8 canali.
    static let par = FixtureProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
        modelName: "PAR LED RGBW 8ch",
        type: .parLED,
        channels: [
            ch("Dimmer", .dimmer),
            ch("Rosso", .red),
            ch("Verde", .green),
            ch("Blu", .blue),
            ch("Bianco", .white),
            ch("Strobe", .strobe),
            ch("Macro colore", .custom),
            ch("Velocità auto", .custom)
        ],
        panRange: 0,
        tiltRange: 0,
        beamAngle: 35
    )

    /// Testa mobile Beam a 12 canali, pan/tilt 16-bit e ruota colori.
    static let mover = FixtureProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!,
        modelName: "Moving Head Beam 12ch",
        type: .movingHeadBeam,
        channels: [
            ch("Pan", .pan),
            ch("Pan Fine", .panFine),
            ch("Tilt", .tilt),
            ch("Tilt Fine", .tiltFine),
            ch("Pan/Tilt Speed", .panTiltSpeed),
            ch("Dimmer", .dimmer),
            ch("Strobe / Shutter", .strobe),
            ch("Color Wheel", .colorWheel, wheel: standardWheel()),
            ch("Gobo", .custom),
            ch("Prisma", .custom),
            ch("Focus", .custom),
            ch("Controllo", .custom)
        ],
        panRange: 540,
        tiltRange: 270,
        beamAngle: 5
    )

    /// Barra LED con 10 pixel RGB indipendenti (30 canali, senza dimmer master).
    static let bar: FixtureProfile = {
        var p = FixtureProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!,
            modelName: "Barra LED 10 pixel RGB",
            type: .ledBar,
            channels: [],
            panRange: 0,
            tiltRange: 0,
            beamAngle: 40,
            pixelConfig: PixelConfig(count: 10, components: [.r, .g, .b], firstChannel: 0)
        )
        p.setChannelCount(30)
        p.regeneratePixelChannels()
        return p
    }()

    static var all: [FixtureProfile] { [par, mover, bar] }
}
