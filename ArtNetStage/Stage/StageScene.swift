import SceneKit
import AppKit
import simd

enum CameraPreset {
    case front, top, threeQuarter
}

/// Possiede la scena SceneKit e il loop a 60 fps: ogni frame legge il buffer DMX e aggiorna le fixture.
/// Tutte le modifiche al grafo di scena avvengono dentro `updateAtTime` (render thread);
/// il main thread consegna solo dati tramite `lock`.
final class StageController: NSObject, SCNSceneRendererDelegate {

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let fixturesRoot = SCNNode()
    private let dmx: DMXStore
    private let lock = NSLock()

    private var pendingFixtures: [PatchedFixture]?
    private var pendingPortBase: Int?
    private var portBase = 0
    private var renderers: [UUID: FixtureRenderer] = [:]
    private var lastTime: TimeInterval = 0

    private struct CamState {
        var yaw: Double
        var pitch: Double
        var dist: Double
        var tx: Double
        var ty: Double
        var tz: Double
    }
    private var camGoal = CamState(yaw: 38, pitch: 20, dist: 20, tx: 0, ty: 2.2, tz: 0)
    private var camCur = CamState(yaw: 38, pitch: 20, dist: 20, tx: 0, ty: 2.2, tz: 0)

    init(dmx: DMXStore) {
        self.dmx = dmx
        super.init()
        buildEnvironment()
        buildCamera()
        scene.rootNode.addChildNode(fixturesRoot)
    }

    // MARK: - API (main thread)

    func setFixtures(_ fixtures: [PatchedFixture], portBase: Int) {
        lock.lock()
        pendingFixtures = fixtures
        pendingPortBase = portBase
        lock.unlock()
    }

    func setPreset(_ preset: CameraPreset) {
        lock.lock()
        defer { lock.unlock() }
        var goal: CamState
        switch preset {
        case .front: goal = CamState(yaw: 0, pitch: 6, dist: 21, tx: 0, ty: 2.5, tz: 0)
        case .top: goal = CamState(yaw: 0, pitch: 89, dist: 24, tx: 0, ty: 0, tz: 0)
        case .threeQuarter: goal = CamState(yaw: 38, pitch: 20, dist: 20, tx: 0, ty: 2.2, tz: 0)
        }
        // Scegli la rotazione equivalente più vicina per non fare giri completi.
        goal.yaw += 360 * ((camCur.yaw - goal.yaw) / 360).rounded()
        camGoal = goal
    }

    func orbit(dx: Double, dy: Double) {
        lock.lock()
        camGoal.yaw -= dx * 0.4
        camGoal.pitch = min(max(camGoal.pitch + dy * 0.4, 2), 89)
        lock.unlock()
    }

    func pan(dx: Double, dy: Double) {
        lock.lock()
        let yaw = camGoal.yaw * Double.pi / 180
        let s = camGoal.dist * 0.0016
        camGoal.tx -= cos(yaw) * dx * s
        camGoal.tz += sin(yaw) * dx * s
        camGoal.ty = min(max(camGoal.ty + dy * s, -1), 12)
        lock.unlock()
    }

    func zoom(factor: Double) {
        lock.lock()
        camGoal.dist = min(max(camGoal.dist * factor, 3), 80)
        lock.unlock()
    }

    // MARK: - Loop di rendering

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(max(time - lastTime, 0), 0.1)
        lastTime = time

        applyPending()
        updateCamera(dt: dt)

        let snapshot = dmx.snapshot()
        for r in renderers.values {
            let port = UInt16(clamping: portBase + r.fixture.universe)
            r.update(data: snapshot[port], dt: dt, time: time)
        }
    }

    private func applyPending() {
        lock.lock()
        let fixtures = pendingFixtures
        let base = pendingPortBase
        pendingFixtures = nil
        pendingPortBase = nil
        lock.unlock()

        if let base { portBase = base }
        guard let fixtures else { return }

        var newMap: [UUID: FixtureRenderer] = [:]
        for f in fixtures {
            if let existing = renderers[f.id], existing.signature == FixtureRenderer.signature(for: f) {
                existing.updateFixture(f)
                newMap[f.id] = existing
            } else {
                renderers[f.id]?.nodes.forEach { $0.removeFromParentNode() }
                let r = FixtureRenderer(fixture: f)
                r.nodes.forEach { fixturesRoot.addChildNode($0) }
                newMap[f.id] = r
            }
        }
        for (id, r) in renderers where newMap[id] == nil {
            r.nodes.forEach { $0.removeFromParentNode() }
        }
        renderers = newMap
    }

    private func updateCamera(dt: Double) {
        lock.lock()
        let k = 1 - exp(-9 * dt)
        camCur.yaw += (camGoal.yaw - camCur.yaw) * k
        camCur.pitch += (camGoal.pitch - camCur.pitch) * k
        camCur.dist += (camGoal.dist - camCur.dist) * k
        camCur.tx += (camGoal.tx - camCur.tx) * k
        camCur.ty += (camGoal.ty - camCur.ty) * k
        camCur.tz += (camGoal.tz - camCur.tz) * k
        let c = camCur
        lock.unlock()

        let yaw = c.yaw * Double.pi / 180
        let pitch = c.pitch * Double.pi / 180
        let cp = cos(pitch)
        let target = SIMD3<Float>(Float(c.tx), Float(c.ty), Float(c.tz))
        let pos = SIMD3<Float>(
            Float(c.tx + c.dist * cp * sin(yaw)),
            Float(c.ty + c.dist * sin(pitch)),
            Float(c.tz + c.dist * cp * cos(yaw))
        )
        cameraNode.simdPosition = pos
        cameraNode.simdLook(at: target)
    }

    // MARK: - Ambiente

    private func buildCamera() {
        let cam = SCNCamera()
        cam.fieldOfView = 48
        cam.zNear = 0.1
        cam.zFar = 250
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        cam.exposureOffset = 0
        cam.bloomIntensity = 0.7
        cam.bloomThreshold = 0.55
        cam.bloomBlurRadius = 10
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        updateCamera(dt: 1.0 / 60.0)
    }

    private func constantMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    private func buildEnvironment() {
        scene.background.contents = NSColor(white: 0.012, alpha: 1)

        // Luce ambientale molto debole: i corpi delle fixture restano appena visibili.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 220
        ambient.light?.color = NSColor(white: 0.3, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Pavimento "black box"
        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.materials = [constantMaterial(NSColor(white: 0.012, alpha: 1))]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        // Pedana del palco 12 × 8 m
        let deck = SCNNode(geometry: SCNBox(width: 12, height: 0.06, length: 8, chamferRadius: 0))
        deck.geometry?.materials = [constantMaterial(NSColor(white: 0.035, alpha: 1))]
        deck.simdPosition = [0, -0.028, 0]
        scene.rootNode.addChildNode(deck)

        // Griglia metrica (1 m, linee marcate ogni 5 m) e contorno del palco
        var minor: [(SIMD3<Float>, SIMD3<Float>)] = []
        var major: [(SIMD3<Float>, SIMD3<Float>)] = []
        for x in -10...10 {
            let seg = (SIMD3<Float>(Float(x), 0.006, -8), SIMD3<Float>(Float(x), 0.006, 10))
            if x % 5 == 0 { major.append(seg) } else { minor.append(seg) }
        }
        for z in -8...10 {
            let seg = (SIMD3<Float>(-10, 0.006, Float(z)), SIMD3<Float>(10, 0.006, Float(z)))
            if z % 5 == 0 { major.append(seg) } else { minor.append(seg) }
        }
        scene.rootNode.addChildNode(SCNNode(geometry: Self.lineGeometry(minor, color: NSColor(white: 0.10, alpha: 1))))
        scene.rootNode.addChildNode(SCNNode(geometry: Self.lineGeometry(major, color: NSColor(white: 0.24, alpha: 1))))

        let outline: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([-6, 0.008, -4], [6, 0.008, -4]),
            ([6, 0.008, -4], [6, 0.008, 4]),
            ([6, 0.008, 4], [-6, 0.008, 4]),
            ([-6, 0.008, 4], [-6, 0.008, -4])
        ]
        scene.rootNode.addChildNode(SCNNode(geometry: Self.lineGeometry(outline, color: NSColor(srgbRed: 0.1, green: 0.45, blue: 0.9, alpha: 1))))

        // Due americane (truss) a 5 m di altezza
        scene.rootNode.addChildNode(makeTruss(length: 12, y: 5.0, z: 0))
        scene.rootNode.addChildNode(makeTruss(length: 12, y: 5.0, z: -3.5))

        // Indicazione del lato pubblico (+Z)
        let text = SCNText(string: "PUBBLICO", extrusionDepth: 0.01)
        text.font = NSFont.systemFont(ofSize: 0.45, weight: .bold)
        text.flatness = 0.05
        text.materials = [constantMaterial(NSColor(white: 0.22, alpha: 1))]
        let textNode = SCNNode(geometry: text)
        let (mn, mx) = text.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation((mx.x + mn.x) / 2, (mx.y + mn.y) / 2, 0)
        textNode.simdEulerAngles = SIMD3<Float>(-Float.pi / 2, 0, 0)
        textNode.simdPosition = [0, 0.01, 5.3]
        scene.rootNode.addChildNode(textNode)
    }

    private func makeTruss(length: Float, y: Float, z: Float) -> SCNNode {
        let root = SCNNode()
        let metal = SCNMaterial()
        metal.lightingModel = .blinn
        metal.diffuse.contents = NSColor(white: 0.40, alpha: 1)
        metal.specular.contents = NSColor(white: 0.5, alpha: 1)

        let off: Float = 0.15
        let corners: [(Float, Float)] = [(off, off), (off, -off), (-off, off), (-off, -off)]
        for (dy, dz) in corners {
            let c = SCNCylinder(radius: 0.02, height: CGFloat(length))
            c.materials = [metal]
            let n = SCNNode(geometry: c)
            n.simdEulerAngles = SIMD3<Float>(0, 0, Float.pi / 2)
            n.simdPosition = SIMD3<Float>(0, dy, dz)
            root.addChildNode(n)
        }

        var x = -length / 2
        while x <= length / 2 + 0.01 {
            for dz: Float in [-off, off] {
                let p = SCNCylinder(radius: 0.008, height: 0.3)
                p.materials = [metal]
                let n = SCNNode(geometry: p)
                n.simdPosition = SIMD3<Float>(x, 0, dz)
                root.addChildNode(n)
            }
            x += 1.0
        }

        for sx: Float in [-1, 1] {
            let t = SCNCylinder(radius: 0.05, height: CGFloat(y))
            t.materials = [metal]
            let n = SCNNode(geometry: t)
            n.simdPosition = SIMD3<Float>(sx * (length / 2 + 0.1), -y / 2, 0)
            root.addChildNode(n)
        }

        root.simdPosition = SIMD3<Float>(0, y, z)
        return root
    }

    private static func lineGeometry(_ segments: [(SIMD3<Float>, SIMD3<Float>)], color: NSColor) -> SCNGeometry {
        var verts: [SCNVector3] = []
        var idx: [Int32] = []
        for (a, b) in segments {
            idx.append(Int32(verts.count))
            verts.append(SCNVector3(CGFloat(a.x), CGFloat(a.y), CGFloat(a.z)))
            idx.append(Int32(verts.count))
            verts.append(SCNVector3(CGFloat(b.x), CGFloat(b.y), CGFloat(b.z)))
        }
        let src = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: idx, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        g.materials = [m]
        return g
    }
}
