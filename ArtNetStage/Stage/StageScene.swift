import SceneKit
import QuartzCore
import AppKit
import simd

enum CameraPreset {
    case front, side, top, threeQuarter
}

/// Possiede la scena SceneKit, il rig camera e il loop a 60 fps.
///
/// Thread:
/// - **main**: rig camera (nodi `pivot → pitch → camera`, animati con `SCNTransaction`), hitTest, API pubblica;
/// - **render** (`updateAtTime`): aggiornamento di fixture, oggetti, palco e selezione.
///   Il main thread consegna i dati al render thread tramite `pending` protetto da `lock`.
final class StageController: NSObject, SCNSceneRendererDelegate {

    // MARK: - Parametri del rig camera

    /// Limite del nodo pitch (rotazione attorno a X): ±85°, per evitare il gimbal lock ai poli.
    static let pitchLimit = 85.0
    /// Con `false` la camera non scende mai sotto il piano del palco (il palco resta sempre in basso).
    /// Con `true` è consentita tutta la corsa del pitch, fino a -85° (vista dal basso).
    static let allowCameraBelowStage = false
    /// Altezza (sopra il piano del palco) del punto attorno a cui orbita la camera.
    static let lookHeight = 1.8
    static let minDistance = 3.0
    static let maxDistance = 60.0

    // MARK: - Scena

    let scene = SCNScene()

    /// Rig: `pivotNode` ruota in yaw (asse Y) e si sposta con il pan, `pitchNode` ruota in pitch (asse X),
    /// `cameraNode` è figlio di `pitchNode` e si allontana lungo +Z (zoom). `allowsCameraControl` non è usato.
    private let pivotNode = SCNNode()
    private let pitchNode = SCNNode()
    let cameraNode = SCNNode()

    private let envRoot = SCNNode()
    private let fixturesRoot = SCNNode()
    private let objectsRoot = SCNNode()
    private let labelNode = SCNNode()

    private let dmx: DMXStore
    private let lock = NSLock()

    /// Chiamato (main thread) quando l'utente clicca nella vista 3D: UUID di fixture/oggetto oppure nil.
    var onPick: ((UUID?) -> Void)?

    // MARK: - Stato lato main (camera)

    private struct Rig {
        var yaw: Double        // gradi, rotazione attorno all'asse Y
        var pitch: Double      // gradi di elevazione sopra l'orizzonte (nodo pitch: eulerAngles.x = -pitch)
        var dist: Double       // metri dal pivot
        var tx: Double         // posizione del pivot sul piano del palco
        var tz: Double
    }
    private var rig = Rig(yaw: 38, pitch: 22, dist: 20, tx: 0, tz: 0)
    private var uiStage = StageConfig()

    // MARK: - Stato lato render

    private struct Pending {
        var fixtures: [PatchedFixture]?
        var portBase: Int?
        var stage: StageConfig?
        var objects: [StageObject]?
        var selectionChanged = false
        var selection: UUID?
    }
    private var pending = Pending()

    private var portBase = 0
    private var stage = StageConfig()
    private var renderers: [UUID: FixtureRenderer] = [:]
    private var objectRenderers: [UUID: StageObjectRenderer] = [:]
    private var selectedID: UUID?
    private var lastTime: TimeInterval = 0
    /// Materiali (dopo il flatten) di tutta la struttura delle americane: il colore si aggiorna qui senza ricostruire la geometria.
    private var trussMaterials: [SCNMaterial] = []

    // MARK: - Init

    init(dmx: DMXStore) {
        self.dmx = dmx
        super.init()
        buildStaticScene()
        buildRig()
        scene.rootNode.addChildNode(envRoot)
        scene.rootNode.addChildNode(fixturesRoot)
        scene.rootNode.addChildNode(objectsRoot)
        rebuildEnvironment()
        applyRig(duration: 0)
    }

    // MARK: - API dati (main thread)

    func setFixtures(_ fixtures: [PatchedFixture], portBase: Int) {
        lock.lock()
        pending.fixtures = fixtures
        pending.portBase = portBase
        lock.unlock()
    }

    func setStage(_ s: StageConfig) {
        lock.lock()
        pending.stage = s
        lock.unlock()
        uiStage = s
        applyRig(duration: 0.25)       // il pivot segue l'altezza del palco
    }

    func setObjects(_ objects: [StageObject]) {
        lock.lock()
        pending.objects = objects
        lock.unlock()
    }

    func setSelection(_ id: UUID?) {
        lock.lock()
        pending.selectionChanged = true
        pending.selection = id
        lock.unlock()
    }

    // MARK: - Rig camera (main thread)

    private func clamped(_ r: Rig) -> Rig {
        var c = r
        c.dist = min(max(c.dist, Self.minDistance), Self.maxDistance)

        var minPitch = -Self.pitchLimit
        if !Self.allowCameraBelowStage {
            // La camera deve restare almeno 0.4 m sopra il piano del palco.
            let pivotY = uiStage.baseHeight + Self.lookHeight
            let minCamY = uiStage.baseHeight + 0.4
            let s = min(max((minCamY - pivotY) / c.dist, -1), 1)
            minPitch = max(minPitch, asin(s) * 180 / Double.pi)
        }
        c.pitch = min(max(c.pitch, minPitch), Self.pitchLimit)

        let hx = uiStage.width / 2 + 10
        let hz = uiStage.depth / 2 + 10
        c.tx = min(max(c.tx, -hx), hx)
        c.tz = min(max(c.tz, -hz), hz)
        return c
    }

    /// Scrive lo stato del rig sui nodi. Con `duration > 0` la transizione è animata da `SCNTransaction`.
    private func applyRig(duration: TimeInterval,
                          timing: CAMediaTimingFunctionName = .easeInEaseOut) {
        rig = clamped(rig)
        let r = rig
        let toRad = Double.pi / 180

        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: timing)
        pivotNode.position = SCNVector3(CGFloat(r.tx), CGFloat(uiStage.baseHeight + Self.lookHeight), CGFloat(r.tz))
        pivotNode.eulerAngles = SCNVector3(0, CGFloat(r.yaw * toRad), 0)
        pitchNode.eulerAngles = SCNVector3(CGFloat(-r.pitch * toRad), 0, 0)
        cameraNode.position = SCNVector3(0, 0, CGFloat(r.dist))
        SCNTransaction.commit()
    }

    /// Orbita: ruota attorno all'asse verticale e inclina entro i limiti del pitch.
    func orbit(dx: Double, dy: Double) {
        rig.yaw -= dx * 0.4
        rig.pitch += dy * 0.4
        applyRig(duration: 0)
    }

    /// Pan sul piano del palco: il punto guardato scorre sempre sul pavimento, mai in verticale.
    func pan(dx: Double, dy: Double) {
        let yaw = rig.yaw * Double.pi / 180
        let s = rig.dist * 0.0016
        // destra dello schermo = (cos yaw, 0, -sin yaw); avanti sul pavimento = (-sin yaw, 0, -cos yaw)
        rig.tx += (-cos(yaw) * dx - sin(yaw) * dy) * s
        rig.tz += (sin(yaw) * dx - cos(yaw) * dy) * s
        applyRig(duration: 0)
    }

    /// Zoom: una breve transizione rende fluidi anche i singoli scatti della rotellina.
    func zoom(factor: Double) {
        rig.dist *= factor
        applyRig(duration: 0.12, timing: .easeOut)
    }

    private func fitDistance() -> Double {
        max(uiStage.width, uiStage.depth * 1.4, 8) * 1.6
    }

    /// Anima la camera verso una vista preimpostata (SCNTransaction, 0.9 s).
    func setPreset(_ preset: CameraPreset) {
        let fit = fitDistance()
        var goal: Rig
        switch preset {
        case .front:
            goal = Rig(yaw: 0, pitch: 8, dist: fit, tx: 0, tz: 0)
        case .side:
            goal = Rig(yaw: 90, pitch: 8, dist: max(uiStage.depth * 2.4, uiStage.width * 0.9, 14), tx: 0, tz: 0)
        case .top:
            goal = Rig(yaw: 0, pitch: Self.pitchLimit, dist: fit * 1.05, tx: 0, tz: 0)
        case .threeQuarter:
            goal = Rig(yaw: 38, pitch: 22, dist: fit, tx: 0, tz: 0)
        }
        // Rotazione equivalente più vicina, per non fare giri completi.
        goal.yaw += 360 * ((rig.yaw - goal.yaw) / 360).rounded()
        rig = goal
        applyRig(duration: 0.9)
    }

    func cameraSnapshot() -> CameraSnapshot {
        CameraSnapshot(yaw: rig.yaw, pitch: rig.pitch, dist: rig.dist, tx: rig.tx, tz: rig.tz)
    }

    func applyCamera(_ s: CameraSnapshot) {
        var goal = Rig(yaw: s.yaw, pitch: s.pitch, dist: s.dist, tx: s.tx, tz: s.tz)
        goal.yaw += 360 * ((rig.yaw - goal.yaw) / 360).rounded()
        rig = goal
        applyRig(duration: 0.9)
    }

    // MARK: - Selezione dalla vista 3D (main thread)

    /// hitTest sul punto cliccato: seleziona la fixture o l'oggetto più vicino alla camera.
    /// Coni di luce, macchie a terra e contorni (nodi "ignore") vengono saltati.
    func pick(at point: CGPoint, in view: SCNView) {
        let options: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true
        ]
        let camPos = cameraNode.simdWorldPosition
        let results = view.hitTest(point, options: options)
        let sorted = results.sorted { a, b in
            Self.distance(from: camPos, to: a.worldCoordinates) < Self.distance(from: camPos, to: b.worldCoordinates)
        }
        for hit in sorted {
            if let id = entityID(for: hit.node) {
                onPick?(id)
                return
            }
        }
        onPick?(nil)
    }

    private static func distance(from p: SIMD3<Float>, to v: SCNVector3) -> Float {
        simd_distance(p, SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)))
    }

    private func entityID(for node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let n = current {
            if n.name == SceneHelpers.ignoreName { return nil }
            if let name = n.name, let id = UUID(uuidString: name) { return id }
            current = n.parent
        }
        return nil
    }

    // MARK: - Loop di rendering (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(max(time - lastTime, 0), 0.1)
        lastTime = time

        applyPending()

        let snapshot = dmx.snapshot()
        for r in renderers.values {
            let port = UInt16(clamping: portBase + r.fixture.universe)
            r.update(data: snapshot[port], dt: dt, time: time)
        }
    }

    private func applyPending() {
        lock.lock()
        let p = pending
        pending = Pending()
        lock.unlock()

        if let b = p.portBase { portBase = b }

        if let st = p.stage {
            let old = stage
            stage = st
            let geometryChanged = old.width != st.width || old.depth != st.depth
                || old.baseHeight != st.baseHeight || old.trussHeight != st.trussHeight
                || old.showTruss != st.showTruss
            if geometryChanged {
                rebuildEnvironment()
            } else if old.trussColorHex != st.trussColorHex {
                applyTrussColor()          // aggiornamento in tempo reale del solo materiale
            }
            for r in renderers.values { r.setStage(st) }
            for o in objectRenderers.values { o.update(o.object, deckY: st.baseHeight) }
        }

        if let fixtures = p.fixtures {
            var newMap: [UUID: FixtureRenderer] = [:]
            for f in fixtures {
                if let existing = renderers[f.id], existing.signature == FixtureRenderer.signature(for: f) {
                    existing.updateFixture(f)
                    newMap[f.id] = existing
                } else {
                    renderers[f.id]?.nodes.forEach { $0.removeFromParentNode() }
                    let r = FixtureRenderer(fixture: f, stage: stage)
                    r.nodes.forEach { fixturesRoot.addChildNode($0) }
                    newMap[f.id] = r
                }
            }
            for (id, r) in renderers where newMap[id] == nil {
                r.nodes.forEach { $0.removeFromParentNode() }
            }
            renderers = newMap
        }

        if let objects = p.objects {
            var newMap: [UUID: StageObjectRenderer] = [:]
            for o in objects {
                if let existing = objectRenderers[o.id], existing.object.kind == o.kind {
                    existing.update(o, deckY: stage.baseHeight)
                    newMap[o.id] = existing
                } else {
                    objectRenderers[o.id]?.node.removeFromParentNode()
                    let r = StageObjectRenderer(object: o, deckY: stage.baseHeight)
                    objectsRoot.addChildNode(r.node)
                    newMap[o.id] = r
                }
            }
            for (id, r) in objectRenderers where newMap[id] == nil {
                r.node.removeFromParentNode()
            }
            objectRenderers = newMap
        }

        if p.selectionChanged { selectedID = p.selection }
        if p.selectionChanged || p.fixtures != nil || p.objects != nil {
            for (id, r) in renderers { r.setSelected(id == selectedID) }
            for (id, r) in objectRenderers { r.setSelected(id == selectedID) }
        }
    }

    // MARK: - Costruzione scena

    private func buildRig() {
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

        scene.rootNode.addChildNode(pivotNode)
        pivotNode.addChildNode(pitchNode)
        pitchNode.addChildNode(cameraNode)
    }

    /// Elementi che non dipendono dalle dimensioni del palco: sfondo, luce ambientale, suolo, scritta.
    private func buildStaticScene() {
        scene.background.contents = NSColor(white: 0.012, alpha: 1)

        // Luce ambientale molto debole: corpi delle fixture e oggetti restano appena visibili.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 220
        ambient.light?.color = NSColor(white: 0.3, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.materials = [SceneHelpers.constantMaterial(NSColor(white: 0.012, alpha: 1))]
        let floorNode = SCNNode(geometry: floor)
        floorNode.castsShadow = false
        scene.rootNode.addChildNode(floorNode)

        let text = SCNText(string: "PUBBLICO", extrusionDepth: 0.01)
        text.font = NSFont.systemFont(ofSize: 0.45, weight: .bold)
        text.flatness = 0.05
        text.materials = [SceneHelpers.constantMaterial(NSColor(white: 0.22, alpha: 1))]
        labelNode.geometry = text
        let (mn, mx) = text.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation((mx.x + mn.x) / 2, (mx.y + mn.y) / 2, 0)
        labelNode.simdEulerAngles = SIMD3<Float>(-Float.pi / 2, 0, 0)
        labelNode.castsShadow = false
        scene.rootNode.addChildNode(labelNode)
    }

    /// Ricostruisce pedana, griglia, contorno e americane in base a `stage`.
    private func rebuildEnvironment() {
        envRoot.childNodes.forEach { $0.removeFromParentNode() }

        let st = stage
        let w = Float(st.width)
        let d = Float(st.depth)
        let base = Float(st.baseHeight)

        // Pedana: la faccia superiore sta a `baseHeight`.
        let thickness = max(base, 0.05)
        let box = SCNBox(width: CGFloat(w), height: CGFloat(thickness), length: CGFloat(d), chamferRadius: 0)
        let side = SceneHelpers.constantMaterial(NSColor(white: 0.075, alpha: 1))
        let top = SceneHelpers.constantMaterial(NSColor(white: 0.035, alpha: 1))
        box.materials = [side, side, side, side, top, side]      // fronte, destra, retro, sinistra, sopra, sotto
        let deck = SCNNode(geometry: box)
        deck.simdPosition = SIMD3<Float>(0, base + 0.004 - thickness / 2, 0)
        envRoot.addChildNode(deck)

        // Griglia metrica sulla pedana (1 m, linee marcate ogni 5 m).
        let gy = base + 0.008
        var minor: [(SIMD3<Float>, SIMD3<Float>)] = []
        var major: [(SIMD3<Float>, SIMD3<Float>)] = []
        let xMax = Int((w / 2).rounded(.down))
        let zMax = Int((d / 2).rounded(.down))
        for x in -xMax...xMax {
            let seg = (SIMD3<Float>(Float(x), gy, -d / 2), SIMD3<Float>(Float(x), gy, d / 2))
            if x % 5 == 0 { major.append(seg) } else { minor.append(seg) }
        }
        for z in -zMax...zMax {
            let seg = (SIMD3<Float>(-w / 2, gy, Float(z)), SIMD3<Float>(w / 2, gy, Float(z)))
            if z % 5 == 0 { major.append(seg) } else { minor.append(seg) }
        }
        envRoot.addChildNode(SCNNode(geometry: SceneHelpers.lineGeometry(minor, color: NSColor(white: 0.10, alpha: 1))))
        envRoot.addChildNode(SCNNode(geometry: SceneHelpers.lineGeometry(major, color: NSColor(white: 0.24, alpha: 1))))

        // Contorno della pedana.
        let oy = base + 0.010
        let outline: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3<Float>(-w / 2, oy, -d / 2), SIMD3<Float>(w / 2, oy, -d / 2)),
            (SIMD3<Float>(w / 2, oy, -d / 2), SIMD3<Float>(w / 2, oy, d / 2)),
            (SIMD3<Float>(w / 2, oy, d / 2), SIMD3<Float>(-w / 2, oy, d / 2)),
            (SIMD3<Float>(-w / 2, oy, d / 2), SIMD3<Float>(-w / 2, oy, -d / 2))
        ]
        envRoot.addChildNode(SCNNode(geometry: SceneHelpers.lineGeometry(
            outline, color: NSColor(srgbRed: 0.1, green: 0.45, blue: 0.9, alpha: 1))))

        // Griglia a terra attorno alla pedana (solo se la pedana è rialzata).
        if base > 0.02 {
            var ground: [(SIMD3<Float>, SIMD3<Float>)] = []
            let ex = Int((w / 2).rounded(.up)) + 6
            let ez = Int((d / 2).rounded(.up)) + 6
            for x in stride(from: -ex, through: ex, by: 2) {
                ground.append((SIMD3<Float>(Float(x), 0.004, -Float(ez)), SIMD3<Float>(Float(x), 0.004, Float(ez) + 2)))
            }
            for z in stride(from: -ez, through: ez + 2, by: 2) {
                ground.append((SIMD3<Float>(-Float(ex), 0.004, Float(z)), SIMD3<Float>(Float(ex), 0.004, Float(z))))
            }
            envRoot.addChildNode(SCNNode(geometry: SceneHelpers.lineGeometry(ground, color: NSColor(white: 0.06, alpha: 1))))
        }

        // Americane (presenti/assenti): lunghezza = larghezza del palco, altezza = base + altezza americana.
        trussMaterials.removeAll()
        if st.showTruss {
            let ty = base + Float(st.trussHeight)
            for z in [Float(st.frontTrussZ), Float(st.backTrussZ)] {
                let truss = makeTruss(length: w, y: ty, z: z)
                envRoot.addChildNode(truss)
                // Dopo flattenedClone i materiali sono quelli della geometria risultante: si raccolgono da lì.
                truss.enumerateHierarchy { n, _ in
                    if let g = n.geometry { self.trussMaterials.append(contentsOf: g.materials) }
                }
            }
            applyTrussColor()
        }

        // Indicazione del lato pubblico (+Z).
        labelNode.simdPosition = SIMD3<Float>(0, 0.01, d / 2 + 1.3)

        envRoot.enumerateHierarchy { n, _ in n.castsShadow = false }
    }

    /// Applica `stage.trussColorHex` a tutta la struttura delle americane (`diffuse`), con un leggero
    /// bagliore proprio (`emission`) perché il colore resti leggibile anche nel black-box buio.
    private func applyTrussColor() {
        let c = parseHex(stage.trussColorHex)
        let diffuse = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        let glow = NSColor(srgbRed: CGFloat(c.x * 0.18), green: CGFloat(c.y * 0.18), blue: CGFloat(c.z * 0.18), alpha: 1)
        for m in trussMaterials {
            m.diffuse.contents = diffuse
            m.emission.contents = glow
        }
    }

    /// Americana a sezione quadrata con tralicci verticali e due montanti fino a terra.
    private func makeTruss(length: Float, y: Float, z: Float) -> SCNNode {
        let root = SCNNode()
        let metal = SCNMaterial()
        metal.lightingModel = .blinn
        metal.diffuse.contents = NSColor(white: 0.66, alpha: 1)     // il colore reale arriva da applyTrussColor()
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
        // Un'unica geometria per americana: una sola draw call anche con palchi larghi.
        return root.flattenedClone()
    }
}
