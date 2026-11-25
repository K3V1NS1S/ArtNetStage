import Foundation
import Darwin
import SystemConfiguration

// MARK: - Utilità IPv4

func ipv4String(_ a: in_addr) -> String {
    let v = UInt32(bigEndian: a.s_addr)
    return "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
}

func ipv4Bytes(_ s: String) -> [UInt8]? {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return nil }
    let bytes = parts.compactMap { UInt8($0) }
    return bytes.count == 4 ? bytes : nil
}

/// Indirizzo IPv4 in network byte order (pronto per `sockaddr_in.sin_addr.s_addr`).
func ipv4InAddr(_ s: String) -> in_addr_t? {
    guard let b = ipv4Bytes(s) else { return nil }
    let host = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    return host.bigEndian
}

// MARK: - Modelli

struct InterfaceAddress: Hashable {
    let ip: String
    let netmask: String
    let broadcast: String?
}

struct NetInterface: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var displayName: String
    var kind: String
    var isUp: Bool
    var hasLink: Bool
    var isLoopback: Bool
    var mac: [UInt8]?
    var ipv4: [InterfaceAddress]

    var linkText: String {
        if isLoopback { return "Sempre attivo" }
        if !isUp { return "Interfaccia spenta" }
        return hasLink ? "Link attivo" : "Nessun link (cavo scollegato)"
    }

    var macString: String {
        guard let mac else { return "—" }
        return mac.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

// MARK: - Scanner

enum NetInterfaceScanner {

    static func scan() -> [NetInterface] {
        let sc = systemConfigurationNames()
        var items: [String: NetInterface] = [:]

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }

            let name = String(cString: p.pointee.ifa_name)
            let flags = Int32(p.pointee.ifa_flags)

            var item = items[name] ?? NetInterface(
                name: name,
                displayName: sc[name]?.name ?? name,
                kind: sc[name]?.kind ?? (name.hasPrefix("lo") ? "Loopback" : "Altro"),
                isUp: false,
                hasLink: false,
                isLoopback: false,
                mac: nil,
                ipv4: []
            )
            item.isUp = (flags & IFF_UP) != 0
            item.hasLink = (flags & IFF_RUNNING) != 0
            item.isLoopback = (flags & IFF_LOOPBACK) != 0

            if let sa = p.pointee.ifa_addr {
                let family = Int32(sa.pointee.sa_family)
                if family == AF_INET {
                    let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let ipv = UInt32(bigEndian: sin.sin_addr.s_addr)
                    var maskValue: UInt32 = 0xFFFF_FF00
                    if let nm = p.pointee.ifa_netmask {
                        let m = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        maskValue = UInt32(bigEndian: m.sin_addr.s_addr)
                    }
                    var bcast: String? = nil
                    if (flags & IFF_BROADCAST) != 0 && maskValue != 0xFFFF_FFFF {
                        let bv = ipv | ~maskValue
                        bcast = ipv4String(in_addr(s_addr: bv.bigEndian))
                    }
                    item.ipv4.append(InterfaceAddress(
                        ip: ipv4String(sin.sin_addr),
                        netmask: ipv4String(in_addr(s_addr: maskValue.bigEndian)),
                        broadcast: bcast
                    ))
                } else if family == AF_LINK {
                    let (nlen, alen) = sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) {
                        (Int($0.pointee.sdl_nlen), Int($0.pointee.sdl_alen))
                    }
                    if alen == 6, let offset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) {
                        let bytes = UnsafeRawPointer(sa).advanced(by: offset + nlen).assumingMemoryBound(to: UInt8.self)
                        item.mac = (0..<6).map { bytes[$0] }
                    }
                }
            }
            items[name] = item
        }

        let hidden = ["utun", "awdl", "llw", "gif", "stf", "ap", "anpi", "XHC", "vmenet", "bridge100"]
        let list = items.values.filter { itf in
            if hidden.contains(where: { itf.name.hasPrefix($0) }) { return false }
            return !itf.ipv4.isEmpty || itf.kind == "Ethernet" || itf.kind == "Wi-Fi"
        }
        return list.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.name < b.name
        }
    }

    private static func rank(_ i: NetInterface) -> Int {
        switch i.kind {
        case "Ethernet": return 0
        case "Wi-Fi": return 1
        case "Loopback": return 3
        default: return 2
        }
    }

    private static func systemConfigurationNames() -> [String: (name: String, kind: String)] {
        var out: [String: (name: String, kind: String)] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return out }
        for itf in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(itf) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(itf) as String?) ?? bsd
            let type = (SCNetworkInterfaceGetInterfaceType(itf) as String?) ?? ""
            let kind: String
            if type == (kSCNetworkInterfaceTypeEthernet as String) {
                kind = "Ethernet"
            } else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                kind = "Wi-Fi"
            } else {
                kind = "Altro"
            }
            out[bsd] = (name, kind)
        }
        return out
    }
}

// MARK: - Alias IP

enum IPAliasTool {

    enum AliasError: LocalizedError {
        case invalid(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let m): return m
            case .failed(let m): return m.isEmpty ? "Operazione annullata o non riuscita." : m
            }
        }
    }

    static func isValidInterface(_ s: String) -> Bool {
        s.range(of: #"^[a-z]+[0-9]{1,3}$"#, options: .regularExpression) != nil
    }

    static func isValidIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    /// Comando equivalente da eseguire a mano nel Terminale.
    static func command(add: Bool, interface: String, ip: String, mask: String) -> String {
        add ? "sudo ifconfig \(interface) alias \(ip) netmask \(mask)"
            : "sudo ifconfig \(interface) -alias \(ip)"
    }

    /// Esegue `ifconfig` con i privilegi di amministratore tramite AppleScript (richiede la password).
    /// Gli argomenti sono validati rigorosamente prima di comporre lo script.
    static func run(add: Bool, interface: String, ip: String, mask: String,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        guard isValidInterface(interface) else {
            completion(.failure(AliasError.invalid("Nome interfaccia non valido: \(interface)")))
            return
        }
        guard isValidIPv4(ip) else {
            completion(.failure(AliasError.invalid("Indirizzo IP non valido: \(ip)")))
            return
        }
        if add && !isValidIPv4(mask) {
            completion(.failure(AliasError.invalid("Netmask non valida: \(mask)")))
            return
        }

        let shell = add
            ? "/sbin/ifconfig \(interface) alias \(ip) netmask \(mask)"
            : "/sbin/ifconfig \(interface) -alias \(ip)"
        let script = "do shell script \"\(shell)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = process.terminationStatus
            DispatchQueue.main.async {
                if status == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(AliasError.failed(message)))
                }
            }
        }
    }
}
