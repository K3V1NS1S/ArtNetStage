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

    // Bridge virtuale feth → bridge1 (v2.4)
    @State private var bridgeBusy = false
    @State private var bridgeMessage: String?
    @State private var bridgeIsError = false
    @State private var feth0Present = BridgeTool.isFeth0Present
    @State private var bridge1Present = BridgeTool.isBridge1Present

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                bridgeBox
                statusBox
                interfacesBox
                artNetBox
                aliasBox
            }
            .padding(12)
        }
        .onAppear { refreshBridgeState() }
        .onReceive(server.$interfaces) { _ in refreshBridgeState() }
    }

    // MARK: - Bridge virtuale

    private var bridgeBox: some View {
        GroupBox(label: Label("Bridge Virtuale Art-Net (bridge1)", systemImage: "point.3.connected.trianglepath.dotted")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(feth0Present ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(feth0Present ? "Attivo: feth0 presente nel sistema" : "Non attivo: feth0 non trovato")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                }
                Text(bridge1Present
                     ? "bridge1 esiste: puoi collegargli la coppia feth0/feth1."
                     : "bridge1 non esiste ancora: crealo nelle Impostazioni di Sistema prima di attivare il collegamento.")
                    .font(.caption)
                    .foregroundStyle(bridge1Present ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        activateBridge()
                    } label: {
                        Label("Attiva collegamento feth su bridge1", systemImage: "link")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(GlassButtonStyle(prominent: true))
                    .disabled(bridgeBusy)
                    if bridgeBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if let m = bridgeMessage {
                    Text(m)
                        .font(.caption)
                        .foregroundStyle(bridgeIsError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text("macOS chiederà la password amministratore. Il collegamento sparisce al riavvio del Mac.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private func refreshBridgeState() {
        feth0Present = BridgeTool.isFeth0Present
        bridge1Present = BridgeTool.isBridge1Present
    }

    private func activateBridge() {
        bridgeBusy = true
        bridgeMessage = nil
        // Un istante per mostrare lo stato «in corso» prima che compaia la finestra della password.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            BridgeTool.activate { outcome in
                bridgeBusy = false
                server.refreshInterfaces()
                refreshBridgeState()
                switch outcome {
                case .success:
                    bridgeIsError = false
                    bridgeMessage = "Collegamento attivato: feth0 e feth1 create e collegate, feth0 aggiunta a bridge1. Elenco interfacce aggiornato."
                case .failure(let text):
                    bridgeIsError = true
                    bridgeMessage = text
                }
            }
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
