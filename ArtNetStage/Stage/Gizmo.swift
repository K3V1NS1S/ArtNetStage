import SceneKit
import AppKit
import simd

/// Gumball 3D: tre frecce (X rosso, Y verde verticale, Z blu) per lo spostamento e tre archi per la rotazione.
///
/// Le parti sono sempre visibili e cliccabili anche se coperte dall'oggetto: `readsFromDepthBuffer = false`
/// e `renderingOrder` molto alto. Il gizmo mantiene una dimensione costante sullo schermo (`setScale`).
/// La radice si chiama come i nodi "ignore" (non viene mai selezionata dal click normale); i singoli
/// manici hanno il nome `gizmo.m0…2` (frecce) e `gizmo.r0…2` (archi).
final class Gizmo {

    enum Handle: Equatable {
        case move(Int)       // 0 = X, 1 = Y, 2 = Z
        case rotate(Int)     // 0 = attorno a X, 1 = attorno a Y, 2 = attorno a Z

        var axis: Int {
            switch self {
            case .move(let a), .rotate(let a): return a
            }
        }
    }

    let root = SCNNode()

    private var moveNodes: [SCNNode] = []
    private var rotateNodes: [SCNNode] = []
    private var materials: [Handle: [SCNMaterial]] = [:]
    private var active: Handle?

    private static let axisColors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.22, blue: 0.20, alpha: 1),   // X rosso
        NSColor(srgbRed: 0.25, green: 0.85, blue: 0.30, alpha: 1),   // Y verde
        NSColor(srgbRed: 0.25, green: 0.50, blue: 1.00, alpha: 1)    // Z blu
    ]
    private static let highlight = NSColor(srgbRed: 1.0, green: 0.88, blue: 0.2, alpha: 1)

    // Spessori in unità del gizmo (v2.5: sottili, per non coprire i dettagli di fixture e oggetti).
    private static let shaftRadius: CGFloat = 0.010
    private static let coneRadius: CGFloat = 0.036
    private static let arcPipeRadius: CGFloat = 0.008
    /// Geometria di collisione invisibile, più spessa di quella visibile: il gizmo resta fine ma facile da afferrare.
    private static let hitShaftRadius: CGFloat = 0.075
    private static let hitConeRadius: CGFloat = 0.11
    private static let hitArcRadius: CGFloat = 0.08
    private static let hitOpacity: CGFloat = 0.001

    /// Raggio dell'arco di rotazione e lunghezza delle frecce, in unità del gizmo (scalato poi a schermo).
    private static let arcRadius: Float = 0.62
    private static let arrowLength: Float = 1.0

    /// Distanza dalla camera → fattore di scala: la lunghezza di una freccia vale circa il 14% della distanza.
    private static let screenFactor: Float = 0.14

    init() {
        root.name = SceneHelpers.ignoreName
        root.isHidden = true

        for axis in 0..<3 {
            let m = makeArrow(axis: axis)
            m.name = "gizmo.m\(axis)"
            root.addChildNode(m)
            moveNodes.append(m)

            let r = makeArc(axis: axis)
            r.name = "gizmo.r\(axis)"
            root.addChildNode(r)
            rotateNodes.append(r)
        }

        // Sempre sopra a tutto, senza test di profondità.
        root.enumerateHierarchy { n, _ in
            n.renderingOrder = 10_000
            n.castsShadow = false
            if let g = n.geometry {
                for m in g.materials {
                    m.readsFromDepthBuffer = false
                    m.writesToDepthBuffer = false
                }
            }
        }
    }

    // MARK: Costruzione

    private func material(for axis: Int, handle: Handle) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = Self.axisColors[axis]
        m.isDoubleSided = true
        materials[handle, default: []].append(m)
        return m
    }

    /// Materiale della geometria di collisione: non fa parte dei materiali evidenziati (non cambia colore) e non si vede.
    private func hitMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        m.isDoubleSided = true
        return m
    }

    /// Freccia lungo l'asse: cilindro + cono terminale.
    private func makeArrow(axis: Int) -> SCNNode {
        let h = Handle.move(axis)
        let len = CGFloat(Self.arrowLength)

        let shaft = SCNCylinder(radius: Self.shaftRadius, height: len * 0.80)
        shaft.materials = [material(for: axis, handle: h)]
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.simdPosition = [0, Float(len) * 0.40, 0]

        // Cono affusolato e compatto.
        let cone = SCNCone(topRadius: 0, bottomRadius: Self.coneRadius, height: len * 0.20)
        cone.materials = [material(for: axis, handle: h)]
        let coneNode = SCNNode(geometry: cone)
        coneNode.simdPosition = [0, Float(len) * 0.90, 0]

        let arrow = SCNNode()
        arrow.addChildNode(shaftNode)
        arrow.addChildNode(coneNode)

        // Collisione invisibile attorno all'asta e alla punta (stessi nodi figli della freccia → stesso manico).
        let hitShaft = SCNCylinder(radius: Self.hitShaftRadius, height: len * 0.96)
        hitShaft.materials = [hitMaterial()]
        let hitShaftNode = SCNNode(geometry: hitShaft)
        hitShaftNode.simdPosition = [0, Float(len) * 0.48, 0]
        hitShaftNode.opacity = Self.hitOpacity
        arrow.addChildNode(hitShaftNode)

        let hitCone = SCNCone(topRadius: 0, bottomRadius: Self.hitConeRadius, height: len * 0.26)
        hitCone.materials = [hitMaterial()]
        let hitConeNode = SCNNode(geometry: hitCone)
        hitConeNode.simdPosition = [0, Float(len) * 0.89, 0]
        hitConeNode.opacity = Self.hitOpacity
        arrow.addChildNode(hitConeNode)
        // La freccia è costruita lungo +Y: si ruota sugli altri assi.
        switch axis {
        case 0: arrow.simdEulerAngles = SIMD3<Float>(0, 0, -Float.pi / 2)
        case 2: arrow.simdEulerAngles = SIMD3<Float>(Float.pi / 2, 0, 0)
        default: break
        }
        return arrow
    }

    /// Arco di 90° nel quadrante positivo del piano perpendicolare all'asse (fra le due frecce del piano).
    private func makeArc(axis: Int) -> SCNNode {
        let h = Handle.rotate(axis)
        let container = SCNNode()
        let segments = 14
        let a0 = Float.pi / 2 * 0.12
        let a1 = Float.pi / 2 * 0.88
        let R = Self.arcRadius

        func point(_ t: Float) -> SIMD3<Float> {
            let c = R * cosf(t), s = R * sinf(t)
            switch axis {
            case 0: return [0, c, s]      // piano YZ
            case 1: return [c, 0, s]      // piano XZ (orizzontale)
            default: return [c, s, 0]     // piano XY
            }
        }

        for i in 0..<segments {
            let t0 = a0 + (a1 - a0) * Float(i) / Float(segments)
            let t1 = a0 + (a1 - a0) * Float(i + 1) / Float(segments)
            let p0 = point(t0), p1 = point(t1)
            let d = p1 - p0
            let len = simd_length(d)
            let cyl = SCNCylinder(radius: Self.arcPipeRadius, height: CGFloat(len) * 1.15)
            cyl.materials = [material(for: axis, handle: h)]
            let n = SCNNode(geometry: cyl)
            n.simdPosition = (p0 + p1) / 2
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: d / len)
            container.addChildNode(n)

            // Tubo di collisione invisibile, più spesso, lungo lo stesso segmento.
            let hit = SCNCylinder(radius: Self.hitArcRadius, height: CGFloat(len) * 1.15)
            hit.materials = [hitMaterial()]
            let hn = SCNNode(geometry: hit)
            hn.simdPosition = n.simdPosition
            hn.simdOrientation = n.simdOrientation
            hn.opacity = Self.hitOpacity
            container.addChildNode(hn)
        }
        return container
    }

    // MARK: Stato

    /// Mostra il gizmo in `center`. `rotations` indica quali archi sono disponibili (X, Y, Z).
    func show(at center: SIMD3<Float>, rotations: [Bool]) {
        root.isHidden = false
        root.simdPosition = center
        for i in 0..<3 {
            let on = i < rotations.count ? rotations[i] : true
            rotateNodes[i].isHidden = !on
        }
    }

    func hide() {
        root.isHidden = true
        setActive(nil)
    }

    var isVisible: Bool { !root.isHidden }

    /// Dimensione costante sullo schermo.
    func setScale(cameraPosition: SIMD3<Float>) {
        let d = simd_distance(cameraPosition, root.simdPosition)
        let s = max(d * Self.screenFactor, 0.05)
        root.simdScale = SIMD3<Float>(repeating: s)
    }

    /// Evidenzia il manico in uso (giallo); nil = colori normali.
    func setActive(_ handle: Handle?) {
        guard handle != active else { return }
        if let old = active { tint(old, color: nil) }
        active = handle
        if let h = handle { tint(h, color: Self.highlight) }
    }

    private func tint(_ handle: Handle, color: NSColor?) {
        guard let mats = materials[handle] else { return }
        let c = color ?? Self.axisColors[handle.axis]
        for m in mats { m.diffuse.contents = c }
    }

    /// Manico a cui appartiene il nodo colpito (risale lungo i genitori).
    static func handle(for node: SCNNode) -> Handle? {
        var current: SCNNode? = node
        while let n = current {
            if let name = n.name, name.hasPrefix("gizmo.") {
                let tail = name.dropFirst("gizmo.".count)
                guard tail.count == 2, let axis = Int(String(tail.dropFirst())), (0..<3).contains(axis) else { return nil }
                if tail.hasPrefix("m") { return .move(axis) }
                if tail.hasPrefix("r") { return .rotate(axis) }
                return nil
            }
            current = n.parent
        }
        return nil
    }

    /// Versore dell'asse nel mondo.
    static func axisVector(_ axis: Int) -> SIMD3<Float> {
        switch axis {
        case 0: return [1, 0, 0]
        case 1: return [0, 1, 0]
        default: return [0, 0, 1]
        }
    }
}

extension Gizmo.Handle: Hashable {}
