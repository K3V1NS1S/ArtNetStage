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

    /// Gumball di spostamento/rotazione dell'elemento selezionato.
    let gizmo = Gizmo()

    private let dmx: DMXStore
    private let lock = NSLock()

    /// Chiamato (main thread) quando l'utente clicca nella vista 3D: UUID di fixture/oggetto oppure nil.
    var onPick: ((UUID?) -> Void)?

    /// Gumball (main thread): nuovo valore di una coordinata del modello. `axis` 0 = X, 1 = Y (altezza sopra il
    /// piano del palco), 2 = Z. Per una fixture il valore è `x`/`y`/`z` della luce, per un oggetto idem.
    var onGizmoTranslate: ((UUID, Int, Double) -> Void)?
    /// Gumball (main thread): nuovo angolo in gradi. `axis` 0 = arco rosso (tilt / inclinazione),
    /// 1 = arco verde (orientamento base / yaw), 2 = arco blu (pan / rollio).
    var onGizmoRotate: ((UUID, Int, Double) -> Void)?
    /// Gumball (main thread): inizio e rilascio del trascinamento (la cronologia annulla/ripristina chiude un solo passo).
    var onGizmoDragBegan: (() -> Void)?
    var onGizmoDragEnded: (() -> Void)?

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
    private var uiFixtures: [PatchedFixture] = []
    private var uiObjects: [StageObject] = []
    private var uiSelection: UUID?

    // MARK: - Stato lato render

    private struct Pending {
        var fixtures: [PatchedFixture]?
        var portBase: Int?
        var stage: StageConfig?
        var objects: [StageObject]?
        var selectionChanged = false
        var selection: UUID?
        var ambient: Double?
        var master: Double?
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

    // Luminosità (render thread)
    private var ambientNode = SCNNode()
    private var ambientLevel = Float(SceneModel.defaultAmbient)
    private var beamMaster = Float(SceneModel.defaultBeamMaster)
    private var roomMaterials: [SCNMaterial] = []
    private var deckSideMat: SCNMaterial?
    private var deckTopMat: SCNMaterial?
    private var labelMat: SCNMaterial?

    /// Guadagno applicato ai materiali «senza luce» (palco, americane, scritta): 1 al livello predefinito.
    private var elementGain: Float { ambientLevel / Float(SceneModel.defaultAmbient) }

    // MARK: - Init

    init(dmx: DMXStore) {
        self.dmx = dmx
        super.init()
        buildStaticScene()
        buildRig()
        scene.rootNode.addChildNode(envRoot)
        scene.rootNode.addChildNode(fixturesRoot)
        scene.rootNode.addChildNode(objectsRoot)
        scene.rootNode.addChildNode(gizmo.root)
        rebuildEnvironment()
        applyRig(duration: 0)
    }

    // MARK: - API dati (main thread)

    func setFixtures(_ fixtures: [PatchedFixture], portBase: Int) {
        uiFixtures = fixtures
        lock.lock()
        pending.fixtures = fixtures
        pending.portBase = portBase
        lock.unlock()
    }

    /// Aggiorna subito una sola luce nella scena 3D (trascinamento del Gumball), senza aspettare il giro del modello dati:
    /// la luce resta incollata al cursore anche se l'interfaccia è occupata.
    func previewFixture(_ f: PatchedFixture) {
        if let i = uiFixtures.firstIndex(where: { $0.id == f.id }) { uiFixtures[i] = f }
        lock.lock()
        var list = pending.fixtures ?? uiFixtures
        if let i = list.firstIndex(where: { $0.id == f.id }) { list[i] = f }
        pending.fixtures = list
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
        uiObjects = objects
        lock.lock()
        pending.objects = objects
        lock.unlock()
        if povID != nil { applyRig(duration: 0) }       // la vista POV segue il manichino se viene spostato o ruotato
    }

    /// Luminosità elementi di scena (0...1) e master luci (0...2).
    func setBrightness(ambient: Double, master: Double) {
        lock.lock()
        pending.ambient = ambient
        pending.master = master
        lock.unlock()
    }

    func setSelection(_ id: UUID?) {
        uiSelection = id
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
        if let id = povID {
            if let o = uiObjects.first(where: { $0.id == id && $0.kind == .mannequin }) {
                applyPOV(o, duration: duration, timing: timing)
                return
            }
            povID = nil                                   // il manichino è stato eliminato: si torna alla vista orbitale
            configurePOVCamera(false)
            rig.yaw += 360 * ((povLastYaw - rig.yaw) / 360).rounded()
        }
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
        if let cam = cameraNode.camera {
            cam.usesOrthographicProjection = orthoActive
            if orthoActive {
                // `orthographicScale` è lo stato dello zoom in ortogonale (rotellina / pizzico lo cambiano direttamente);
                // all'ingresso vale distanza × tan(FOV/2): stessa inquadratura della prospettiva.
                cam.orthographicScale = orthoScale
            }
        }
        SCNTransaction.commit()
    }

    /// Orbita: ruota attorno all'asse verticale e inclina entro i limiti del pitch.
    func orbit(dx: Double, dy: Double) {
        if povID != nil {                                  // POV: ci si guarda intorno ruotando lo sguardo
            let k = 0.25 * povFOV / 60
            povYawOffset += dx * k
            povPitch = min(max(povPitch + dy * k, -80), 80)
            applyRig(duration: 0)
            return
        }
        rig.yaw -= dx * 0.4
        rig.pitch += dy * 0.4
        applyRig(duration: 0)
    }

    /// Pan sul piano del palco: il punto guardato scorre sempre sul pavimento, mai in verticale.
    func pan(dx: Double, dy: Double) {
        if povID != nil { return }
        let yaw = rig.yaw * Double.pi / 180
        let s = rig.dist * 0.0016
        // destra dello schermo = (cos yaw, 0, -sin yaw); avanti sul pavimento = (-sin yaw, 0, -cos yaw)
        rig.tx += (-cos(yaw) * dx - sin(yaw) * dy) * s
        rig.tz += (sin(yaw) * dx - cos(yaw) * dy) * s
        applyRig(duration: 0)
    }

    /// Zoom: una breve transizione rende fluidi anche i singoli scatti della rotellina.
    func zoom(factor: Double) {
        if povID != nil { return }                         // in POV l'ingrandimento si regola con lo slider FOV
        if orthoActive {
            // In ortogonale la distanza Z non cambia l'inquadratura: si agisce direttamente su orthographicScale.
            orthoScale = min(max(orthoScale * factor, Self.minOrthoScale), Self.maxOrthoScale)
            applyRig(duration: 0.12, timing: .easeOut)
            return
        }
        rig.dist *= factor
        applyRig(duration: 0.12, timing: .easeOut)
    }

    private func fitDistance() -> Double {
        max(uiStage.width, uiStage.depth * 1.4, 8) * 1.6
    }

    /// Anima la camera verso una vista preimpostata (SCNTransaction, 0.9 s).
    func setPreset(_ preset: CameraPreset) {
        leavePOVForOrbit()
        lastPreset = preset
        // Ortogonale solo per Frontale / Laterale / Superiore con «Orto» attivo; 3/4 torna in prospettiva.
        let wantsOrtho = orthoEnabled && preset != .threeQuarter
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
        orthoActive = wantsOrtho
        if wantsOrtho { orthoScale = orthoScaleMatching(distance: goal.dist) }
        applyRig(duration: 0.9)
    }

    func cameraSnapshot() -> CameraSnapshot {
        CameraSnapshot(yaw: rig.yaw, pitch: rig.pitch, dist: rig.dist, tx: rig.tx, tz: rig.tz)
    }

    func applyCamera(_ s: CameraSnapshot) {
        leavePOVForOrbit()
        orthoActive = false
        lastPreset = nil
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

    // MARK: - Gumball (main thread)

    private struct GizmoDrag {
        var handle: Gizmo.Handle
        var id: UUID
        var startPoint: CGPoint
        var startValue: Double
        var axisScreen = SIMD2<Double>(0, 0)      // spostamento: vettore schermo di 1 m lungo l'asse
        var axisLenSq = 1.0
        var centerScreen = CGPoint.zero           // rotazione: centro del gizmo sullo schermo
        var lastAngle = 0.0
        var total = 0.0
        var sign = 1.0
    }
    private var drag: GizmoDrag?

    var isDraggingGizmo: Bool { drag != nil }

    private static func vec(_ v: SIMD3<Float>) -> SCNVector3 {
        SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z))
    }

    /// Prima del normale click: se il punto cade su una freccia o su un arco del Gumball restituisce il manico.
    /// Il hitTest è limitato ai nodi del gizmo (`rootNode`), quindi funziona anche se l'oggetto lo copre.
    func gizmoHandle(at point: CGPoint, in view: SCNView) -> Gizmo.Handle? {
        guard gizmo.isVisible, uiSelection != nil else { return nil }
        let options: [SCNHitTestOption: Any] = [
            .rootNode: gizmo.root,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: true
        ]
        let camPos = cameraNode.simdWorldPosition
        let results = view.hitTest(point, options: options)
        let sorted = results.sorted { a, b in
            Self.distance(from: camPos, to: a.worldCoordinates) < Self.distance(from: camPos, to: b.worldCoordinates)
        }
        for hit in sorted {
            if let h = Gizmo.handle(for: hit.node) { return h }
        }
        return nil
    }

    /// Avvia il trascinamento vincolato a un solo asse. Restituisce false se non è possibile
    /// (per esempio l'asse è quasi parallelo alla direzione di vista).
    func beginGizmoDrag(_ handle: Gizmo.Handle, at point: CGPoint, in view: SCNView) -> Bool {
        guard let id = uiSelection else { return false }
        let center = gizmo.root.simdWorldPosition
        let axis = Gizmo.axisVector(handle.axis)

        var startValue = 0.0
        if let f = uiFixtures.first(where: { $0.id == id }) {
            switch handle {
            case .move(let a): startValue = a == 0 ? f.x : (a == 1 ? f.y : f.z)
            case .rotate(let a): startValue = a == 0 ? f.staticTilt : (a == 1 ? f.yaw : f.staticPan)
            }
        } else if let o = uiObjects.first(where: { $0.id == id }) {
            switch handle {
            case .move(let a): startValue = a == 0 ? o.x : (a == 1 ? o.y : o.z)
            case .rotate(let a): startValue = a == 0 ? o.pitchDeg : (a == 1 ? o.yaw : o.rollDeg)
            }
        } else {
            return false
        }

        var d = GizmoDrag(handle: handle, id: id, startPoint: point, startValue: startValue)
        switch handle {
        case .move:
            let p0 = view.projectPoint(Self.vec(center))
            let p1 = view.projectPoint(Self.vec(center + axis))
            let v = SIMD2<Double>(Double(p1.x - p0.x), Double(p1.y - p0.y))
            let l2 = v.x * v.x + v.y * v.y
            guard l2 > 16 else { return false }
            d.axisScreen = v
            d.axisLenSq = l2
        case .rotate:
            let c = view.projectPoint(Self.vec(center))
            d.centerScreen = CGPoint(x: CGFloat(c.x), y: CGFloat(c.y))
            d.lastAngle = atan2(Double(point.y - CGFloat(c.y)), Double(point.x - CGFloat(c.x)))
            // Visto dal lato +asse, una rotazione positiva appare antioraria sullo schermo.
            let toCamera = cameraNode.simdWorldPosition - center
            d.sign = simd_dot(axis, toCamera) >= 0 ? 1 : -1
        }
        gizmo.setActive(handle)
        drag = d
        onGizmoDragBegan?()
        return true
    }

    /// Aggiorna il modello con il movimento del cursore proiettato sull'asse scelto.
    /// Il movimento è sempre continuo; con `snap` (tasto ⇧ Shift premuto) lo spostamento va a passi di 10 cm e la rotazione a passi di 15°.
    func updateGizmoDrag(to point: CGPoint, snap: Bool) {
        guard var d = drag else { return }
        switch d.handle {
        case .move(let axis):
            let dx = Double(point.x - d.startPoint.x)
            let dy = Double(point.y - d.startPoint.y)
            let meters = (dx * d.axisScreen.x + dy * d.axisScreen.y) / d.axisLenSq
            // Senza Shift: spostamento continuo, esattamente quello del cursore. Con Shift: multipli di 10 cm dallo spostamento iniziale.
            let deltaMeters = snap ? (meters / Self.snapMove).rounded() * Self.snapMove : meters
            var v = d.startValue + deltaMeters
            if axis == 1 { v = max(v, 0) }          // l'altezza è sopra il piano del palco
            onGizmoTranslate?(d.id, axis, v)
        case .rotate(let axis):
            let ang = atan2(Double(point.y - d.centerScreen.y), Double(point.x - d.centerScreen.x))
            var delta = ang - d.lastAngle
            while delta > Double.pi { delta -= 2 * Double.pi }
            while delta < -Double.pi { delta += 2 * Double.pi }
            d.total += delta
            d.lastAngle = ang
            // Senza Shift: rotazione continua. Con Shift: multipli di 15° dalla rotazione iniziale.
            let deltaDeg = d.sign * d.total * 180 / Double.pi
            var v = d.startValue + (snap ? (deltaDeg / Self.snapAngle).rounded() * Self.snapAngle : deltaDeg)
            v -= 360 * ((v + 180) / 360).rounded(.down)       // riporta in [-180, 180)
            onGizmoRotate?(d.id, axis, v)
            drag = d
        }
    }

    private static let snapMove = 0.1        // metri, solo con ⇧
    private static let snapAngle = 15.0      // gradi, solo con ⇧

    func endGizmoDrag() {
        let wasDragging = drag != nil
        drag = nil
        gizmo.setActive(nil)
        if wasDragging { onGizmoDragEnded?() }
    }

    // MARK: - Occlusione dei fasci (render thread)

    /// Raycast lungo il segmento contro oggetti, manichini e stativi: distanza dal punto `a` e normale di impatto.
    /// Usa `hitTestWithSegment` su `objectsRoot` (che è alla radice, quindi coordinate locali = mondo).
    private func occlusion(from a: SIMD3<Float>, to b: SIMD3<Float>) -> (t: Float, normal: SIMD3<Float>)? {
        guard !objectRenderers.isEmpty, simd_distance(a, b) > 0.01 else { return nil }
        let results = objectsRoot.hitTestWithSegment(from: Self.vec(a), to: Self.vec(b), options: nil)
        for hit in results where entityID(for: hit.node) != nil {
            let p = SIMD3<Float>(Float(hit.worldCoordinates.x), Float(hit.worldCoordinates.y), Float(hit.worldCoordinates.z))
            let n = SIMD3<Float>(Float(hit.worldNormal.x), Float(hit.worldNormal.y), Float(hit.worldNormal.z))
            let len = simd_length(n)
            return (simd_distance(a, p), len > 1e-5 ? n / len : SIMD3<Float>(0, 1, 0))
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
            r.update(data: snapshot[port], dt: dt, time: time, master: beamMaster)
        }
        updateGizmo()
    }

    /// Posiziona il Gumball al centro dell'elemento selezionato e ne mantiene costante la dimensione a schermo.
    private func updateGizmo() {
        guard let id = selectedID else {
            if gizmo.isVisible { gizmo.hide() }
            return
        }
        if let r = renderers[id] {
            let smoke = r.fixture.profile.type == .smokeMachine
            gizmo.show(at: r.worldCenter, rotations: smoke ? [false, true, false] : [true, true, true])
        } else if let o = objectRenderers[id] {
            let stand = o.object.kind.isStand
            gizmo.show(at: o.worldCenter(deckY: stage.baseHeight), rotations: stand ? [false, true, false] : [true, true, true])
        } else {
            if gizmo.isVisible { gizmo.hide() }
            return
        }
        gizmo.setScale(cameraPosition: cameraNode.presentation.simdWorldPosition)
    }

    private func applyPending() {
        lock.lock()
        let p = pending
        pending = Pending()
        lock.unlock()

        if let b = p.portBase { portBase = b }
        if let m = p.master { beamMaster = Float(min(max(m, 0), 2)) }
        var brightnessChanged = false
        if let a = p.ambient {
            ambientLevel = Float(min(max(a, 0), 1))
            brightnessChanged = true
        }

        if let st = p.stage {
            let old = stage
            stage = st
            let geometryChanged = old.width != st.width || old.depth != st.depth
                || old.baseHeight != st.baseHeight || old.trussHeight != st.trussHeight
                || old.showTruss != st.showTruss
                || old.environment != st.environment || old.roomWidth != st.roomWidth
                || old.roomDepth != st.roomDepth || old.ceilingHeight != st.ceilingHeight
            if geometryChanged {
                rebuildEnvironment()
            } else {
                if old.trussColorHex != st.trussColorHex {
                    applyTrussColor()      // aggiornamento in tempo reale del solo materiale
                }
                if old.deckColorHex != st.deckColorHex || old.deckBrightness != st.deckBrightness {
                    applyDeckAppearance()
                }
                if old.roomColorHex != st.roomColorHex || old.roomBrightness != st.roomBrightness {
                    applyRoomAppearance()
                }
            }
            for r in renderers.values { r.setStage(st) }
            for o in objectRenderers.values { o.update(o.object, deckY: st.baseHeight) }
        }

        if let fixtures = p.fixtures {
            var newMap: [UUID: FixtureRenderer] = [:]
            for f in fixtures {
                if let existing = renderers[f.id], existing.hasSameStructure(as: f) {
                    existing.updateFixture(f)
                    newMap[f.id] = existing
                } else {
                    renderers[f.id]?.nodes.forEach { $0.removeFromParentNode() }
                    let r = FixtureRenderer(fixture: f, stage: stage)
                    r.occluder = { [weak self] a, b in self?.occlusion(from: a, to: b) }
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

        if brightnessChanged { applyElementBrightness() }

        if p.selectionChanged { selectedID = p.selection }
        if p.selectionChanged || p.fixtures != nil || p.objects != nil {
            for (id, r) in renderers { r.setSelected(id == selectedID) }
            for (id, r) in objectRenderers { r.setSelected(id == selectedID) }
        }
    }

    // MARK: - Proiezione ortogonale (main thread)

    /// Pulsante «Orto» attivo: le viste Frontale, Laterale e Superiore usano la proiezione ortogonale.
    private var orthoEnabled = false
    /// La camera è attualmente in proiezione ortogonale.
    private var orthoActive = false
    private var lastPreset: CameraPreset?

    /// Attiva o disattiva «Orto». Se la vista corrente è Frontale / Laterale / Superiore il cambio è immediato.
    func setOrthographic(_ on: Bool) {
        orthoEnabled = on
        guard povID == nil else { return }
        let want = on && (lastPreset == .front || lastPreset == .side || lastPreset == .top)
        if want && !orthoActive {
            orthoScale = orthoScaleMatching(distance: rig.dist)       // stessa scala visiva della prospettiva
        } else if !want && orthoActive {
            rig.dist = orthoScale / Self.tanHalfFOV()                 // si torna in prospettiva mantenendo lo zoom raggiunto
        }
        orthoActive = want
        applyRig(duration: 0.25)
    }

    /// Scala ortogonale (metà altezza visibile) che mostra l'inquadratura di una camera prospettica a `distance`:
    /// `orthographicScale = distance × tan(fieldOfView / 2)`.
    private func orthoScaleMatching(distance: Double) -> Double {
        min(max(distance * Self.tanHalfFOV(), Self.minOrthoScale), Self.maxOrthoScale)
    }

    private static func tanHalfFOV() -> Double {
        tan(Double(Self.defaultFOV) * Double.pi / 180 / 2)
    }

    /// Zoom corrente in ortogonale (metà altezza visibile, in metri).
    private var orthoScale = 10.0
    private static let minOrthoScale = 0.5
    private static let maxOrthoScale = 120.0

    // MARK: - Vista in prima persona dal manichino (main thread)

    private var povID: UUID?
    /// Rotazione dello sguardo rispetto all'orientamento del manichino (gradi) e inclinazione (positiva = verso l'alto).
    private var povYawOffset = 0.0
    private var povPitch = 0.0
    private var povFOV = 75.0
    private var povLastYaw = 0.0
    static let povMinFOV = 35.0
    static let povMaxFOV = 110.0
    private static let defaultFOV: CGFloat = 48

    /// Manichino da cui si sta guardando (nil = vista orbitale).
    var povObjectID: UUID? { povID }

    /// Entra nella vista dal manichino `objectID`, o cambia manichino se la vista POV è già attiva.
    /// La camera va all'altezza degli occhi guardando dove è rivolta la faccia del manichino (+Z ruotato dal suo yaw).
    func enterPOV(objectID: UUID, fov: Double) {
        guard uiObjects.contains(where: { $0.id == objectID && $0.kind == .mannequin }) else { return }
        let wasActive = povID != nil
        if !wasActive { povLastYaw = rig.yaw }
        orthoActive = false                       // il POV è sempre in prospettiva
        cameraNode.camera?.usesOrthographicProjection = false
        povID = objectID
        povFOV = min(max(fov, Self.povMinFOV), Self.povMaxFOV)
        povYawOffset = 0
        povPitch = 0
        configurePOVCamera(true)
        applyRig(duration: wasActive ? 0.5 : 0.9)
    }

    /// Campo visivo (gradi, orizzontale) in tempo reale: `SCNCamera.fieldOfView`.
    func setPOVFieldOfView(_ fov: Double) {
        povFOV = min(max(fov, Self.povMinFOV), Self.povMaxFOV)
        guard povID != nil else { return }
        configurePOVCamera(true)
    }

    /// Torna alla vista orbitale mantenendo l'ultima inquadratura orbitale.
    func exitPOV() {
        guard povID != nil else { return }
        leavePOVForOrbit()
        applyRig(duration: 0.9)
    }

    /// Esce dalla modalità POV senza animare: serve prima di un preset o di un ripristino camera.
    private func leavePOVForOrbit() {
        guard povID != nil else { return }
        povID = nil
        configurePOVCamera(false)
        rig.yaw += 360 * ((povLastYaw - rig.yaw) / 360).rounded()
    }

    /// Ottica: in POV il FOV è orizzontale e regolabile; in orbita tornano i valori originali.
    private func configurePOVCamera(_ on: Bool) {
        guard let cam = cameraNode.camera else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        cam.projectionDirection = on ? .horizontal : .vertical
        cam.fieldOfView = on ? CGFloat(povFOV) : Self.defaultFOV
        SCNTransaction.commit()
    }

    /// Posizione degli occhi del manichino (sul piano del palco + altezza della testa), spostata in avanti
    /// quanto basta per restare fuori dalla sfera della testa.
    private func povEye(of o: StageObject) -> SIMD3<Float> {
        let sy = Float(max(o.height, 0.01)) / 1.75
        let sz = Float(max(o.depth, 0.01)) / 0.3
        let yaw = Float(o.yaw) * Float.pi / 180
        // Fronte del manichino = +Z locale (verso il pubblico con yaw 0), ruotato dallo yaw dell'oggetto.
        let fwd = SIMD3<Float>(sinf(yaw), 0, cosf(yaw))
        let ahead = 0.26 * sz           // davanti alla faccia (naso incluso), oltre il piano vicino della camera
        let base = SIMD3<Float>(Float(o.x), Float(uiStage.baseHeight + o.y), Float(o.z))
        return base + SIMD3<Float>(0, 1.63 * sy, 0) + fwd * ahead
    }

    private func applyPOV(_ o: StageObject, duration: TimeInterval, timing: CAMediaTimingFunctionName) {
        let toRad = Double.pi / 180
        // La camera guarda lungo il suo −Z: per guardare lungo il +Z del manichino serve yaw + 180°.
        var yaw = o.yaw + 180 + povYawOffset
        yaw += 360 * ((povLastYaw - yaw) / 360).rounded()       // rotazione equivalente più vicina: niente giri a vuoto
        povLastYaw = yaw
        let eye = povEye(of: o)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: timing)
        pivotNode.position = SCNVector3(CGFloat(eye.x), CGFloat(eye.y), CGFloat(eye.z))
        pivotNode.eulerAngles = SCNVector3(0, CGFloat(yaw * toRad), 0)
        pitchNode.eulerAngles = SCNVector3(CGFloat(povPitch * toRad), 0, 0)
        cameraNode.position = SCNVector3(0, 0, 0)
        SCNTransaction.commit()
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
        // v2.1: sfondo trasparente; lo sfondo (scuro, tinto dalla sezione, oppure nero con «Blackout UI»)
        // è quello della finestra e non dipende dalla luminosità degli elementi.
        scene.background.contents = NSColor.clear

        // Luce ambientale / di servizio: la sua intensità segue lo slider «Luminosità Elementi Scena».
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor.white
        ambient.light?.intensity = CGFloat(Self.ambientIntensity(for: ambientLevel))
        scene.rootNode.addChildNode(ambient)
        ambientNode = ambient

        let floor = SCNFloor()
        floor.reflectivity = 0
        // v2.1: il suolo non disegna colore (solo profondità), così si vede lo sfondo unico della finestra.
        let floorMat = SceneHelpers.constantMaterial(NSColor.black)
        floorMat.colorBufferWriteMask = []
        floor.materials = [floorMat]
        let floorNode = SCNNode(geometry: floor)
        floorNode.castsShadow = false
        scene.rootNode.addChildNode(floorNode)

        let text = SCNText(string: "PUBBLICO", extrusionDepth: 0.01)
        text.font = NSFont.systemFont(ofSize: 0.45, weight: .bold)
        text.flatness = 0.05
        let labelMaterial = SceneHelpers.constantMaterial(NSColor(white: 0.22, alpha: 1))
        labelMat = labelMaterial
        text.materials = [labelMaterial]
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
        deckSideMat = side
        deckTopMat = top
        applyDeckAppearance()
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

        // Ambiente chiuso (v2.4): pareti di fondo/sinistra/destra e soffitto; il lato +Z (pubblico) resta aperto.
        roomMaterials.removeAll()
        if st.environment == .closed {
            envRoot.addChildNode(makeRoom(stage: st))
            applyRoomAppearance()
        }

        // Indicazione del lato pubblico (+Z).
        labelNode.simdPosition = SIMD3<Float>(0, 0.01, d / 2 + 1.3)

        envRoot.enumerateHierarchy { n, _ in n.castsShadow = false }
        applyElementBrightness()
    }

    /// Sala chiusa: quattro piani a una sola faccia rivolta verso l'interno. Visti da fuori (dietro la parete o dall'alto
    /// sul soffitto) vengono scartati, così le viste Laterale e Superiore restano libere. I nodi sono «ignore» per il
    /// click di selezione; i fasci li incontrano con `roomHit` (stesso raycast `trace` degli oggetti di scena).
    private func makeRoom(stage st: StageConfig) -> SCNNode {
        let root = SCNNode()
        root.name = SceneHelpers.ignoreName
        let rw = CGFloat(st.roomWidth)
        let rd = CGFloat(st.roomDepth)
        let top = CGFloat(st.baseHeight + st.ceilingHeight)       // il soffitto è misurato dal piano del palco
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.isDoubleSided = false
        mat.diffuse.contents = NSColor.gray
        roomMaterials = [mat]

        func plane(_ w: CGFloat, _ h: CGFloat) -> SCNNode {
            let p = SCNPlane(width: w, height: h)
            p.widthSegmentCount = max(1, Int(w / 2))              // più segmenti: l'illuminazione dei fasci resta morbida
            p.heightSegmentCount = max(1, Int(h / 2))
            p.materials = [mat]
            let n = SCNNode(geometry: p)
            n.name = SceneHelpers.ignoreName
            n.castsShadow = false
            return n
        }
        // Fondo: z = -rd/2, normale +Z (interno).
        let back = plane(rw, top)
        back.position = SCNVector3(0, top / 2, -rd / 2)
        // Sinistra: x = -rw/2, normale +X.
        let left = plane(rd, top)
        left.position = SCNVector3(-rw / 2, top / 2, 0)
        left.eulerAngles = SCNVector3(0, CGFloat.pi / 2, 0)
        // Destra: x = +rw/2, normale -X.
        let right = plane(rd, top)
        right.position = SCNVector3(rw / 2, top / 2, 0)
        right.eulerAngles = SCNVector3(0, -CGFloat.pi / 2, 0)
        // Soffitto: y = top, normale -Y.
        let ceiling = plane(rw, rd)
        ceiling.position = SCNVector3(0, top, 0)
        ceiling.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)

        for n in [back, left, right, ceiling] { root.addChildNode(n) }
        return root
    }

    /// Colore e luminosità / riflettività delle superfici interne: `diffuse` (risposta ai fasci e alla luce ambiente) più un
    /// leggero bagliore proprio perché la sala resti leggibile anche nel black-box.
    private func applyRoomAppearance() {
        let c = parseHex(stage.roomColorHex)
        let k = Float(min(max(stage.roomBrightness, 0), 1.5))
        func col(_ f: Float) -> NSColor {
            NSColor(srgbRed: CGFloat(min(c.x * f, 1)), green: CGFloat(min(c.y * f, 1)), blue: CGFloat(min(c.z * f, 1)), alpha: 1)
        }
        for m in roomMaterials {
            m.diffuse.contents = col(k)
            m.emission.contents = col(k * 0.05)
        }
    }

    /// Intensità dell'`SCNLight` ambient per un livello 0...1 (1 = 1600, cioè 1.6 volte il colore base).
    private static func ambientIntensity(for level: Float) -> Float { level * 1600 }

    /// Colore e luminosità del piano del palco (v1.4): dipendono solo da `stage.deckColorHex` e
    /// `stage.deckBrightness`, non dallo slider «Elementi scena». Le fiancate sono un po' più chiare del piano.
    private func applyDeckAppearance() {
        let c = parseHex(stage.deckColorHex)
        let k = Float(min(max(stage.deckBrightness, 0), 1.5)) * 0.5
        func col(_ f: Float) -> NSColor {
            NSColor(srgbRed: CGFloat(min(c.x * k * f, 1)), green: CGFloat(min(c.y * k * f, 1)),
                    blue: CGFloat(min(c.z * k * f, 1)), alpha: 1)
        }
        deckTopMat?.diffuse.contents = col(1)
        deckSideMat?.diffuse.contents = col(2.14)
    }

    /// «Luminosità Elementi Scena»: luce ambiente + materiali senza illuminazione (pedana, scritta, bagliore delle
    /// americane). Lo sfondo non cambia. Non tocca le luci delle fixture.
    private func applyElementBrightness() {
        ambientNode.light?.intensity = CGFloat(Self.ambientIntensity(for: ambientLevel))
        let g = elementGain
        labelMat?.diffuse.contents = NSColor(white: CGFloat(min(0.22 * g, 0.9)), alpha: 1)
        applyTrussColor()
    }

    /// Applica `stage.trussColorHex` a tutta la struttura delle americane (`diffuse`), con un leggero
    /// bagliore proprio (`emission`) perché il colore resti leggibile anche nel black-box buio.
    private func applyTrussColor() {
        let c = parseHex(stage.trussColorHex)
        let diffuse = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        let k = min(0.18 * elementGain, 0.8)
        let glow = NSColor(srgbRed: CGFloat(c.x * k), green: CGFloat(c.y * k), blue: CGFloat(c.z * k), alpha: 1)
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
