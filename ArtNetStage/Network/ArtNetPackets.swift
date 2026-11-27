import Foundation

enum ArtNet {
    static let port: UInt16 = 6454
    /// "Art-Net\0"
    static let header: [UInt8] = [0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00]
}

enum ArtNetPacket {
    case poll
    case dmx(portAddress: UInt16, sequence: UInt8, data: [UInt8])
    case sync
    case other(opCode: UInt16)

    /// Layout ArtDmx: ID[0-7] OpCode[8-9] ProtVer[10-11] Sequence[12] Physical[13]
    /// SubUni[14] Net[15] Length[16-17] Data[18...]
    static func parse(_ buf: UnsafeBufferPointer<UInt8>) -> ArtNetPacket? {
        guard buf.count >= 12 else { return nil }
        for i in 0..<8 where buf[i] != ArtNet.header[i] { return nil }

        let op = UInt16(buf[8]) | (UInt16(buf[9]) << 8)
        switch op {
        case 0x2000:
            return .poll
        case 0x5000:
            guard buf.count >= 18 else { return nil }
            let sequence = buf[12]
            let subUni = buf[14]
            let net = buf[15]
            let length = (Int(buf[16]) << 8) | Int(buf[17])
            let avail = min(length, buf.count - 18, 512)
            guard avail > 0 else { return nil }
            let port = (UInt16(net & 0x7F) << 8) | UInt16(subUni)
            return .dmx(portAddress: port, sequence: sequence, data: Array(buf[18..<(18 + avail)]))
        case 0x5200:
            return .sync
        default:
            return .other(opCode: op)
        }
    }
}

/// Identità del nodo dichiarata nell'ArtPollReply.
struct NodeConfig {
    var shortName = "ArtNet Stage"
    var longName = "ArtNet Stage - Visualizzatore macOS"
    var ip = "127.0.0.1"
    var broadcast: String? = nil
    var mac: [UInt8] = [0x02, 0x00, 0x00, 0x41, 0x4E, 0x53]
    var net = 0
    var subNet = 0
    var universes: [Int] = [0]
}

enum PollReplyBuilder {
    /// Costruisce un ArtPollReply (239 byte, Art-Net 4). Un reply descrive al massimo 4 porte:
    /// per più universi se ne invia uno per "bank" con BindIndex crescente.
    static func build(config: NodeConfig, bank: Int, universes: [Int], active: [Bool]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 239)

        func put(_ offset: Int, _ bytes: [UInt8]) {
            for (i, b) in bytes.enumerated() where offset + i < p.count {
                p[offset + i] = b
            }
        }
        func putString(_ offset: Int, _ s: String, maxLen: Int) {
            put(offset, Array(s.utf8.prefix(maxLen - 1)))
        }

        let ip = ipv4Bytes(config.ip) ?? [0, 0, 0, 0]

        put(0, ArtNet.header)                       // ID
        put(8, [0x00, 0x21])                        // OpCode ArtPollReply (0x2100, lo-hi)
        put(10, ip)                                 // IP address
        put(14, [UInt8(ArtNet.port & 0xFF), UInt8(ArtNet.port >> 8)])  // Port (lo-hi)
        put(16, [0x00, 0x01])                       // VersInfo
        p[18] = UInt8(config.net & 0x7F)            // NetSwitch
        p[19] = UInt8(config.subNet & 0x0F)         // SubSwitch
        put(20, [0x00, 0xFF])                       // OEM (generico)
        p[22] = 0                                   // UbeaVersion
        p[23] = 0xD0                                // Status1: indicatori normali, front panel
        put(24, [0xF0, 0x7F])                       // ESTA code 0x7FF0 (prototipi), lo-hi
        putString(26, config.shortName, maxLen: 18) // PortName
        putString(44, config.longName, maxLen: 64)  // LongName
        putString(108, "#0001 [\(String(format: "%04d", bank))] Visualizzatore Art-Net OK", maxLen: 64)

        let n = min(universes.count, 4)
        p[172] = 0
        p[173] = UInt8(n)                           // NumPorts
        for i in 0..<n {
            p[174 + i] = 0x80                       // PortTypes: uscita DMX512 da Art-Net
            p[182 + i] = (active.indices.contains(i) && active[i]) ? 0x80 : 0x00  // GoodOutput
            p[190 + i] = UInt8(universes[i] & 0x0F) // SwOut
        }
        p[200] = 0x00                               // Style: StNode
        put(201, Array(config.mac.prefix(6)))       // MAC
        put(207, ip)                                // BindIp
        p[211] = UInt8(min(bank + 1, 255))          // BindIndex
        p[212] = 0x0A                               // Status2: 15-bit Port-Address, IP manuale
        return p
    }
}
