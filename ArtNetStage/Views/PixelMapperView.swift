import SwiftUI

/// Pixel mapper grafico: mostra la barra come una fila di LED numerati con i canali DMX assegnati in sequenza
/// (LED 1 → primi canali, LED 2 → i successivi, …). Il click seleziona un LED; se `values` è presente i LED
/// si colorano con i valori DMX reali dei canali, quindi coincidono con l'accensione indipendente nel 3D.
struct PixelMapperView: View {
    @Environment(\.sectionTheme) private var theme
    let profile: FixtureProfile
    /// Indirizzo DMX di partenza della fixture (se patchata): abilita gli indirizzi assoluti.
    var startAddress: Int? = nil
    /// Valori DMX (0–255) dei canali della fixture, nell'ordine del profilo. Nil = anteprima della sola mappatura.
    var values: [UInt8]? = nil
    @Binding var selected: Int?
    var onTap: ((Int) -> Void)? = nil

    private var layout: [FixtureProfile.PixelChannels] { profile.pixelLayout }

    /// Canali (numerati da 1 nella fixture) del LED `p`, in ordine crescente.
    private func channelNumbers(_ p: Int) -> [Int] {
        guard p >= 0, p < layout.count else { return [] }
        return layout[p].indices.sorted().map { $0 + 1 }
    }

    private func label(_ p: Int) -> String {
        let n = channelNumbers(p)
        guard let f = n.first, let l = n.last else { return "–" }
        if n.count == 1 { return "\(f)" }
        return n == Array(f...l) ? "\(f)–\(l)" : n.map(String.init).joined(separator: ",")
    }

    private func color(for p: Int) -> Color {
        guard let values, p < layout.count else { return Color.gray.opacity(0.28) }
        func v(_ i: Int?) -> Double {
            guard let i, i < values.count else { return 0 }
            return Double(values[i]) / 255
        }
        let px = layout[p]
        let w = v(px.w)
        return Color(.sRGB, red: min(v(px.r) + w, 1), green: min(v(px.g) + w, 1), blue: min(v(px.b) + w, 1), opacity: 1)
    }

    var body: some View {
        if !layout.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54, maximum: 84), spacing: 6)], spacing: 6) {
                    ForEach(0..<layout.count, id: \.self) { p in
                        cell(p)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                detail
            }
        } else {
            Text("Assegna canali Pixel Rosso/Verde/Blu ai canali della barra per vedere la mappa dei LED.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Parti

    private var header: some View {
        let comps = layout.contains { $0.w != nil } ? "RGBW" : "RGB"
        let total = layout.reduce(0) { $0 + $1.indices.count }
        return HStack(spacing: 10) {
            Text("\(layout.count) LED · \(comps) · \(total) canali")
                .font(.caption.bold())
            if profile.barMotorized {
                if let t = profile.channels.firstIndex(where: { $0.role == .tilt }) {
                    Label("Tilt: CH \(t + 1)", systemImage: "arrow.up.and.down.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Label("Tilt non assegnato", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    private func cell(_ p: Int) -> some View {
        let nums = channelNumbers(p)
        let overflow = (nums.last ?? 0) > profile.channelCount
        let isSelected = selected == p
        let text = label(p)
        return VStack(spacing: 2) {
            Text("\(p + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
            RoundedRectangle(cornerRadius: 4)
                .fill(color(for: p))
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.35), lineWidth: 0.5))
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(overflow ? Color.red : Color.secondary)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? theme.accent.opacity(0.28) : Color.secondary.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(isSelected ? theme.accent : (overflow ? Color.red : Color.clear), lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            selected = p
            onTap?(p)
        }
        .help("LED \(p + 1): canali \(text) della fixture")
    }

    @ViewBuilder
    private var detail: some View {
        if let p = selected, p >= 0, p < layout.count {
            let px = layout[p]
            let comps: [(String, Int?)] = [("R", px.r), ("G", px.g), ("B", px.b), ("W", px.w)]
            VStack(alignment: .leading, spacing: 2) {
                Text("LED \(p + 1)")
                    .font(.caption.bold())
                ForEach(comps.filter { $0.1 != nil }, id: \.0) { name, idx in
                    let ch = (idx ?? 0) + 1
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(.caption, design: .monospaced).bold())
                            .frame(width: 16)
                        Text("CH \(ch)")
                            .font(.system(.caption, design: .monospaced))
                        if let start = startAddress {
                            Text("→ DMX \(start + ch - 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let values, ch - 1 < values.count {
                            Text("= \(values[ch - 1])")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Text("Clicca un LED per vedere i suoi canali DMX.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Prova live dei LED (vista Patch)

/// Mappa dei LED sulla luce patchata, con i valori DMX reali. Il click su un LED lo accende/spegne con il
/// colore di prova scelto, scrivendo nel buffer DMX locale: l'effetto compare subito, LED per LED, nella vista 3D
/// (finché non arrivano pacchetti Art-Net reali sullo stesso universo).
struct PixelTestBox: View {
    @EnvironmentObject var vm: AppViewModel
    let fixture: PatchedFixture

    @State private var selected: Int?
    @State private var color: TestColor = .red

    enum TestColor: String, CaseIterable, Identifiable {
        case red = "Rosso", green = "Verde", blue = "Blu", white = "Bianco"
        var id: String { rawValue }
        var rgbw: (UInt8, UInt8, UInt8, UInt8) {
            switch self {
            case .red: return (255, 0, 0, 0)
            case .green: return (0, 255, 0, 0)
            case .blue: return (0, 0, 255, 0)
            case .white: return (0, 0, 0, 255)
            }
        }
    }

    var body: some View {
        GroupBox(label: Label("Pixel mapper (live)", systemImage: "rectangle.split.3x1")) {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    PixelMapperView(
                        profile: fixture.profile,
                        startAddress: fixture.startAddress,
                        values: vm.channelValues(of: fixture),
                        selected: $selected,
                        onTap: { p in vm.togglePixel(of: fixture, pixel: p, color: color.rgbw) }
                    )
                }
                HStack {
                    Picker("Colore di prova", selection: $color) {
                        ForEach(TestColor.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                    Spacer()
                }
                HStack {
                    Button("Accendi tutti") { vm.setAllPixels(of: fixture, color: color.rgbw) }
                    Button("Spegni tutti") { vm.setAllPixels(of: fixture, color: (0, 0, 0, 0)) }
                    Spacer()
                }
                .controlSize(.small)
                Text("Click su un LED: lo accende o lo spegne nel 3D con il colore scelto. Il bianco usa il canale W nelle barre RGBW e R+G+B in quelle RGB.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}
