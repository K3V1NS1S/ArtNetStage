import Foundation
import Darwin
import Combine

enum ArtNetError: LocalizedError {
    case socketFailed(String)
    case bindFailed(Int32)
    case invalidIP(String)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let m):
            return "Impossibile creare il socket UDP: \(m)"
        case .bindFailed(let e) where e == EADDRINUSE:
            return "La porta UDP 6454 è occupata da un programma che non ammette la condivisione (SO_REUSEPORT). Chiudi l'altro software in ascolto Art-Net, oppure avvia questa app prima di lui."
        case .bindFailed(let e):
            return "bind() sulla porta 6454 non riuscito: \(String(cString: strerror(e)))"
        case .invalidIP(let s):
            return "Indirizzo IP non valido: \(s)"
        }
    }
}

/// Nodo Art-Net simulato: riceve ArtDmx, risponde ad ArtPoll, espone stato e impostazioni di rete.
final class ArtNetServer: ObservableObject {

    // MARK: Stato pubblicato (aggiornato sul main thread)

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var totalHz: Double = 0
    @Published private(set) var universeHz: [UInt16: Double] = [:]
    @Published private(set) var totalPackets = 0
    @Published private(set) var pollCount = 0
    @Published private(set) var lastSender = "—"
    @Published private(set) var activeUniverses: [UInt16] = []
    @Published private(set) var interfaces: [NetInterface] = []

    // MARK: Impostazioni (persistite in UserDefaults)

    @Published var selectedInterfaceName: String {
        didSet { UserDefaults.standard.set(selectedInterfaceName, forKey: "net.interface"); settingsChanged() }
    }
    @Published var selectedIP: String {
        didSet { UserDefaults.standard.set(selectedIP, forKey: "net.ip"); settingsChanged() }
    }
    @Published var listenOnAllInterfaces: Bool {
        didSet {
            UserDefaults.standard.set(listenOnAllInterfaces, forKey: "net.all")
            settingsChanged(forceRestart: true)
        }
    }
    @Published var net: Int {
        didSet {
            // Assegnare dentro didSet non rilancia l'observer: basta correggere il valore e proseguire.
            if net < 0 || net > 127 { net = min(max(net, 0), 127) }
            UserDefaults.standard.set(net, forKey: "art.net")
            rebuildConfig()
        }
    }
    @Published var subNet: Int {
        didSet {
            if subNet < 0 || subNet > 15 { subNet = min(max(subNet, 0), 15) }
            UserDefaults.standard.set(subNet, forKey: "art.sub")
            rebuildConfig()
        }
    }
    @Published var shortName: String {
        didSet { UserDefaults.standard.set(shortName, forKey: "art.name"); rebuildConfig() }
    }

    let dmx: DMXStore

    // MARK: Interni

    private let queue = DispatchQueue(label: "artnet.udp.rx", qos: .userInteractive)
    private let stateLock = NSLock()
    private var sources: [DispatchSourceRead] = []
    private var sendFD: Int32 = -1
    private var rxBuffer = [UInt8](repeating: 0, count: 2048)   // usato solo da `queue`
    private var nodeConfig = NodeConfig()
    private var patchedUniverses: [Int] = [0]
    private var statTotal = 0
    private var statPolls = 0
    private var statSender = "—"
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var tickCount = 0
    private var timer: Timer?

    init(dmx: DMXStore) {
        self.dmx = dmx
        let d = UserDefaults.standard
        selectedInterfaceName = d.string(forKey: "net.interface") ?? "lo0"
        selectedIP = d.string(forKey: "net.ip") ?? "127.0.0.1"
        listenOnAllInterfaces = (d.object(forKey: "net.all") as? Bool) ?? true
        net = d.integer(forKey: "art.net")
        subNet = d.integer(forKey: "art.sub")
        shortName = d.string(forKey: "art.name") ?? "ArtNet Stage"

        refreshInterfaces()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Interfacce

    var selectedInterface: NetInterface? {
        interfaces.first { $0.name == selectedInterfaceName }
    }

    var selectedAddress: InterfaceAddress? {
        selectedInterface?.ipv4.first { $0.ip == selectedIP }
    }

    func refreshInterfaces() {
        let list = NetInterfaceScanner.scan()
        if list != interfaces { interfaces = list }

        if !list.contains(where: { $0.name == selectedInterfaceName }) {
            selectedInterfaceName = list.first(where: { $0.isLoopback })?.name ?? list.first?.name ?? "lo0"
        }
        if let itf = selectedInterface, !itf.ipv4.contains(where: { $0.ip == selectedIP }),
           let firstIP = itf.ipv4.first?.ip {
            selectedIP = firstIP
        }
        rebuildConfig()
    }

    func select(interface name: String, ip: String? = nil) {
        selectedInterfaceName = name
        if let ip {
            selectedIP = ip
        } else if let itf = interfaces.first(where: { $0.name == name }),
                  !itf.ipv4.contains(where: { $0.ip == selectedIP }) {
            selectedIP = itf.ipv4.first?.ip ?? ""
        }
    }

    private func settingsChanged(forceRestart: Bool = false) {
        rebuildConfig()
        if isRunning && (forceRestart || !listenOnAllInterfaces) { start() }
    }

    func setPatchedUniverses(_ universes: [Int]) {
        stateLock.lock()
        patchedUniverses = universes
        stateLock.unlock()
        rebuildConfig()
    }

    private func rebuildConfig() {
        var c = NodeConfig()
        c.shortName = shortName.isEmpty ? "ArtNet Stage" : shortName
        c.longName = "\(c.shortName) - Visualizzatore macOS"
        c.ip = selectedIP.isEmpty ? "0.0.0.0" : selectedIP
        c.broadcast = selectedAddress?.broadcast
        c.mac = selectedInterface?.mac ?? [0x02, 0x00, 0x00, 0x41, 0x4E, 0x53]
        c.net = net & 0x7F
        c.subNet = subNet & 0x0F
        stateLock.lock()
        c.universes = patchedUniverses.isEmpty ? [0] : patchedUniverses
        nodeConfig = c
        stateLock.unlock()
    }

    // MARK: - Avvio / arresto

    func start() {
        stop()
        lastError = nil
        rebuildConfig()

        var fds: [Int32] = []
        do {
            if listenOnAllInterfaces {
                // 0.0.0.0: necessario per ricevere anche i pacchetti broadcast.
                fds.append(try Self.openSocket(bindTo: 0))
            } else {
                guard let ip = ipv4InAddr(selectedIP) else { throw ArtNetError.invalidIP(selectedIP) }
                fds.append(try Self.openSocket(bindTo: ip))
                // Secondo socket sull'indirizzo di broadcast dell'interfaccia scelta.
                if let b = selectedAddress?.broadcast, let ba = ipv4InAddr(b), ba != ip,
                   let fd2 = try? Self.openSocket(bindTo: ba) {
                    fds.append(fd2)
                }
            }
        } catch {
            fds.forEach { close($0) }
            lastError = error.localizedDescription
            isRunning = false
            return
        }

        stateLock.lock()
        sendFD = fds[0]
        stateLock.unlock()

        for fd in fds {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.drain(fd: fd) }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
        isRunning = true
    }

    func stop() {
        for s in sources { s.cancel() }
        sources.removeAll()
        stateLock.lock()
        sendFD = -1
        stateLock.unlock()
        isRunning = false
    }

    // MARK: - Socket BSD

    private static func openSocket(bindTo address: in_addr_t) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ArtNetError.socketFailed(String(cString: strerror(errno))) }

        var yes: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        // Condivisione della porta 6454 con altri software sullo stesso Mac (QLab, QLC+, ...).
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, size)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, size)
        var rcvBuf: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, size)

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ArtNet.port.bigEndian
        addr.sin_addr = in_addr(s_addr: address)

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            throw ArtNetError.bindFailed(e)
        }
        return fd
    }

    // MARK: - Ricezione (coda `queue`)

    private func drain(fd: Int32) {
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: Int = rxBuffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        recvfrom(fd, buf.baseAddress, buf.count, 0, sp, &fromLen)
                    }
                }
            }
            if n <= 0 { break }
            process(length: n, from: from)
        }
    }

    private func process(length: Int, from: sockaddr_in) {
        let packet: ArtNetPacket? = rxBuffer.withUnsafeBufferPointer {
            ArtNetPacket.parse(UnsafeBufferPointer(rebasing: $0[0..<length]))
        }
        guard let packet else { return }

        switch packet {
        case .dmx(let port, _, let data):
            dmx.write(port: port, bytes: data)
            let sender = ipv4String(from.sin_addr)
            stateLock.lock()
            statTotal += 1
            statSender = sender
            stateLock.unlock()
        case .poll:
            stateLock.lock()
            statPolls += 1
            stateLock.unlock()
            respondToPoll(from: from)
        case .sync, .other:
            break
        }
    }

    private func respondToPoll(from: sockaddr_in) {
        stateLock.lock()
        let cfg = nodeConfig
        let fd = sendFD
        stateLock.unlock()
        guard fd >= 0 else { return }

        let universes = cfg.universes.isEmpty ? [0] : cfg.universes
        let base = UInt16((cfg.net << 8) | (cfg.subNet << 4))
        let recent = Set(dmx.recentUniverses(maxAge: 3))

        // Risposta unicast al mittente + broadcast diretto se la rete è fisica.
        let senderAddr = from.sin_addr.s_addr
        let loopback = ipv4InAddr("127.0.0.1")
        var targets: [in_addr_t] = [senderAddr]
        if let b = cfg.broadcast, let ba = ipv4InAddr(b), ba != senderAddr, senderAddr != loopback {
            targets.append(ba)
        }

        var bank = 0
        for start in stride(from: 0, to: universes.count, by: 4) {
            let slice = Array(universes[start..<min(start + 4, universes.count)])
            let active = slice.map { recent.contains(base + UInt16($0 & 0x0F)) }
            let packet = PollReplyBuilder.build(config: cfg, bank: bank, universes: slice, active: active)
            for t in targets { send(packet, to: t, fd: fd) }
            bank += 1
        }
    }

    private func send(_ bytes: [UInt8], to ip: in_addr_t, fd: Int32) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ArtNet.port.bigEndian
        addr.sin_addr = in_addr(s_addr: ip)
        bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Statistiche (main thread, ogni 0.5 s)

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(now - lastTick, 0.001)
        lastTick = now

        let counters = dmx.takeCounters()
        var hz: [UInt16: Double] = [:]
        var sum = 0
        for (k, v) in counters {
            hz[k] = Double(v) / dt
            sum += v
        }
        totalHz = Double(sum) / dt
        universeHz = hz

        stateLock.lock()
        let total = statTotal
        let polls = statPolls
        let sender = statSender
        stateLock.unlock()
        totalPackets = total
        pollCount = polls
        lastSender = sender
        activeUniverses = dmx.recentUniverses(maxAge: 3).sorted()

        tickCount += 1
        if tickCount % 6 == 0 { refreshInterfaces() }
    }
}
