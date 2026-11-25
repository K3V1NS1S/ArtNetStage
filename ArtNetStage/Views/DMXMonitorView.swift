import SwiftUI

struct DMXMonitorView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var server: ArtNetServer

    @State private var selectedPort: UInt16 = 0

    private var options: [UInt16] {
        var list = server.activeUniverses
        if !list.contains(selectedPort) { list.append(selectedPort) }
        return list.sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statsBox
                universeBox
                testBox
            }
            .padding(12)
        }
        .onChange(of: server.activeUniverses) { newValue in
            // Se l'universo mostrato non riceve nulla, passa al primo universo attivo.
            if !newValue.isEmpty && !newValue.contains(selectedPort) {
                selectedPort = newValue[0]
            }
        }
    }

    private func label(_ port: UInt16) -> String {
        "Net \(port >> 8) · Sub \((port >> 4) & 0xF) · Uni \(port & 0xF)   (Port-Address \(port))"
    }

    private var statsBox: some View {
        GroupBox(label: Label("Sniffer Art-Net", systemImage: "waveform.path.ecg")) {
            VStack(alignment: .leading, spacing: 6) {
                row("ArtDmx ricevuti (totale)", String(format: "%.1f Hz", server.totalHz))
                row("Universo selezionato", String(format: "%.1f Hz", server.universeHz[selectedPort] ?? 0))
                row("Universi attivi", server.activeUniverses.isEmpty
                    ? "—" : server.activeUniverses.map { String($0) }.joined(separator: ", "))
                row("Ultimo mittente", server.lastSender)
                row("Pacchetti ArtDmx totali", "\(server.totalPackets)")
                row("ArtPoll ricevuti", "\(server.pollCount)")
            }
            .padding(6)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
        .font(.callout)
    }

    private var universeBox: some View {
        GroupBox(label: Label("Valori DMX in ingresso (1–512)", systemImage: "square.grid.4x3.fill")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Universo", selection: $selectedPort) {
                    ForEach(options, id: \.self) { p in
                        Text(label(p)).tag(p)
                    }
                }
                DMXGridView(dmx: vm.dmx, port: selectedPort)
                    .frame(height: CGFloat(512 / DMXGridView.columns) * DMXGridView.cellHeight)
            }
            .padding(6)
        }
    }

    private var testBox: some View {
        GroupBox(label: Label("Test locale", systemImage: "wand.and.stars")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scrive valori direttamente nel buffer locale per verificare la scena senza software esterno. I pacchetti Art-Net reali sullo stesso universo li sovrascrivono.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Accendi tutto") { vm.testAllOn() }
                    Button("Blackout") { vm.blackout() }
                }
            }
            .padding(6)
        }
    }
}

/// Griglia 16 × 32 disegnata con Canvas e aggiornata a 15 Hz leggendo direttamente il DMXStore.
struct DMXGridView: View {
    static let columns = 16
    static let cellHeight: CGFloat = 20

    let dmx: DMXStore
    let port: UInt16

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { _ in
            Canvas { ctx, size in
                let data = dmx.universe(port)
                let cols = DMXGridView.columns
                let gutter: CGFloat = 32
                let cw = (size.width - gutter) / CGFloat(cols)
                let ch = DMXGridView.cellHeight
                let font = Font.system(size: 9, design: .monospaced)

                for row in 0..<(512 / cols) {
                    let y = CGFloat(row) * ch
                    ctx.draw(
                        Text("\(row * cols + 1)").font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary),
                        at: CGPoint(x: gutter - 5, y: y + ch / 2),
                        anchor: .trailing
                    )
                    for col in 0..<cols {
                        let v = Int(data[row * cols + col])
                        let rect = CGRect(x: gutter + CGFloat(col) * cw + 0.5, y: y + 0.5, width: cw - 1, height: ch - 1)
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: 2),
                            with: .color(Color.accentColor.opacity(0.08 + 0.85 * Double(v) / 255))
                        )
                        ctx.draw(
                            Text("\(v)").font(font).foregroundColor(v == 0 ? .secondary : .white),
                            at: CGPoint(x: rect.midX, y: rect.midY),
                            anchor: .center
                        )
                    }
                }
            }
        }
    }
}
