import SwiftUI
import AppKit

struct NetworkPanelView: View {
    @Environment(\.sectionTheme) private var theme
    @EnvironmentObject var server: ArtNetServer

    @State private var aliasIP = "2.0.0.2"
    @State private var aliasMask = "255.0.0.0"
    @State private var aliasMessage: String?
    @State private var aliasIsError = false
    @State private var aliasBusy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusBox
                interfacesBox
                artNetBox
                aliasBox
            }
            .padding(12)
        }
    }

    // MARK: - Stato

    private var statusBox: some View {
        GroupBox(label: Label("Stato del nodo", systemImage: "antenna.radiowaves.left.and.right")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(server.isRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(server.isRunning ? "In ascolto su UDP 6454" : "Nodo fermo")
                        .font(.headline)
                    Spacer()
                    Button(server.isRunning ? "Ferma" : "Avvia") {
                        if server.isRunning { server.stop() } else { server.start() }
                    }
                }
                if let e = server.lastError {
                    Text(e)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if server.isRunning {
                    Text(server.listenOnAllInterfaces
                         ? "Ascolto su 0.0.0.0 (unicast e broadcast su tutte le interfacce). Identità Art-Net: \(server.selectedIP)."
                         : "Ascolto solo su \(server.selectedIP) (e relativo broadcast).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    // MARK: - Interfacce

    private var interfacesBox: some View {
        GroupBox(label: Label("Interfaccia e IP di ascolto", systemImage: "network")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(server.interfaces) { itf in
                    interfaceRow(itf)
                }

                if let itf = server.selectedInterface {
                    if itf.ipv4.isEmpty {
                        Text("Nessun indirizzo IPv4 su \(itf.name): aggiungi un alias qui sotto.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Picker("IP di ascolto", selection: $server.selectedIP) {
                            ForEach(itf.ipv4, id: \.ip) { a in
                                Text("\(a.ip)  /  \(a.netmask)").tag(a.ip)
                            }
                        }
                        if let b = server.selectedAddress?.broadcast {
                            Text("Broadcast: \(b)  ·  MAC: \(itf.macString)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle("Ascolta su tutte le interfacce (0.0.0.0) — consigliato", isOn: $server.listenOnAllInterfaces)
                    .font(.callout)

                HStack {
                    Button("127.0.0.1 (Loopback)") {
                        server.select(interface: "lo0", ip: "127.0.0.1")
                    }
                    Button("Aggiorna elenco") { server.refreshInterfaces() }
                }
                .controlSize(.small)
            }
            .padding(6)
        }
    }

    private func interfaceRow(_ itf: NetInterface) -> some View {
        let selected = itf.name == server.selectedInterfaceName
        let ips = itf.ipv4.isEmpty ? "nessun IPv4" : itf.ipv4.map { $0.ip }.joined(separator: ", ")
        let linkColor: Color = (itf.isLoopback || itf.hasLink) ? .green : .orange
        return Button {
            server.select(interface: itf.name)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(itf.name) — \(itf.displayName)")
                        .font(.system(.body, design: .default).weight(.semibold))
                    HStack(spacing: 6) {
                        Circle().fill(linkColor).frame(width: 7, height: 7)
                        Text("\(itf.kind) · \(itf.linkText)")
                    }
                    .font(.caption)
                    Text("IP: \(ips)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Art-Net

    private var artNetBox: some View {
        GroupBox(label: Label("Nodo Art-Net", systemImage: "square.stack.3d.up")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Nome nodo")
                    TextField("Nome", text: $server.shortName)
                        .textFieldStyle(.glass)
                }
                HStack(spacing: 16) {
                    Stepper(value: $server.net, in: 0...127) {
                        Text("Net \(server.net)").monospacedDigit()
                    }
                    Stepper(value: $server.subNet, in: 0...15) {
                        Text("SubNet \(server.subNet)").monospacedDigit()
                    }
                }
                Text("Gli universi 0–15 della catena vengono letti come Net:SubNet:Universe (Port-Address a 15 bit). Il nodo dichiara in ArtPollReply gli universi usati dalla catena.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    // MARK: - Alias IP

    private var aliasBox: some View {
        GroupBox(label: Label("Alias IP rapido", systemImage: "plus.rectangle.on.rectangle")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Aggiunge un IP (es. 2.0.0.2) all'interfaccia selezionata (\(server.selectedInterfaceName)) anche senza cavo collegato a uno switch. L'alias sparisce al riavvio del Mac. Per un risultato indipendente dal cavo, scegli lo0 (Loopback).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    TextField("IP alias", text: $aliasIP).textFieldStyle(.glass)
                    TextField("Netmask", text: $aliasMask).textFieldStyle(.glass)
                }

                Text(IPAliasTool.command(add: true, interface: server.selectedInterfaceName, ip: aliasIP, mask: aliasMask))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack {
                    Button("Aggiungi alias…") { runAlias(add: true) }
                        .disabled(aliasBusy)
                    Button("Rimuovi alias…") { runAlias(add: false) }
                        .disabled(aliasBusy)
                    Button("Copia comando") {
                        let cmd = IPAliasTool.command(add: true, interface: server.selectedInterfaceName, ip: aliasIP, mask: aliasMask)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                    }
                    if aliasBusy { ProgressView().controlSize(.small) }
                }

                if let m = aliasMessage {
                    Text(m)
                        .font(.caption)
                        .foregroundStyle(aliasIsError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
    }

    private func runAlias(add: Bool) {
        aliasBusy = true
        aliasMessage = nil
        let iface = server.selectedInterfaceName
        let ip = aliasIP
        IPAliasTool.run(add: add, interface: iface, ip: ip, mask: aliasMask) { result in
            aliasBusy = false
            switch result {
            case .success:
                aliasIsError = false
                aliasMessage = add ? "Alias \(ip) aggiunto su \(iface)." : "Alias \(ip) rimosso da \(iface)."
                server.refreshInterfaces()
                if add { server.select(interface: iface, ip: ip) }
            case .failure(let error):
                aliasIsError = true
                aliasMessage = error.localizedDescription
            }
        }
    }
}
