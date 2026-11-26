import Foundation

/// Buffer DMX indicizzato per Port-Address Art-Net a 15 bit (Net:SubNet:Universe).
/// Scritto dalla coda del socket UDP, letto dal renderer SceneKit e dalla UI.
final class DMXStore {
    private let lock = NSLock()
    private var universes: [UInt16: [UInt8]] = [:]
    private var lastRx: [UInt16: TimeInterval] = [:]
    private var counters: [UInt16: Int] = [:]

    func write(port: UInt16, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        var buf = universes[port] ?? [UInt8](repeating: 0, count: 512)
        let n = min(bytes.count, 512)
        for i in 0..<n { buf[i] = bytes[i] }
        universes[port] = buf
        lastRx[port] = ProcessInfo.processInfo.systemUptime
        counters[port, default: 0] += 1
    }

    /// Copia dei 512 valori dell'universo (zeri se non ancora ricevuto).
    func universe(_ port: UInt16) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return universes[port] ?? [UInt8](repeating: 0, count: 512)
    }

    /// Istantanea di tutti gli universi (copy-on-write: costo trascurabile).
    func snapshot() -> [UInt16: [UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return universes
    }

    /// Port-Address che hanno ricevuto dati negli ultimi `maxAge` secondi.
    func recentUniverses(maxAge: TimeInterval) -> [UInt16] {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return lastRx.filter { now - $0.value <= maxAge }.map { $0.key }
    }

    /// Restituisce e azzera i contatori di pacchetti per universo (per calcolare gli Hz).
    func takeCounters() -> [UInt16: Int] {
        lock.lock()
        defer { lock.unlock() }
        let c = counters
        counters.removeAll()
        return c
    }

    func blackout() {
        lock.lock()
        defer { lock.unlock() }
        for key in universes.keys {
            universes[key] = [UInt8](repeating: 0, count: 512)
        }
    }
}
