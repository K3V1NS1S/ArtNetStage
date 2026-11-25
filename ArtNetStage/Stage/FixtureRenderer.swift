import SceneKit
import AppKit
import simd

// MARK: - Utilità

fileprivate func colorKey(_ c: SIMD3<Float>) -> UInt32 {
    func q(_ v: Float) -> UInt32 { UInt32(max(0, min(255, v * 255))) }
    return (q(c.x) << 16) | (q(c.y) << 8) | q(c.z)
}

fileprivate func nsColor(_ c: SIMD3<Float>, scale: Float = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat(min(max(c.x * scale, 0), 1)),
        green: CGFloat(min(max(c.y * scale, 0), 1)),
        blue: CGFloat(min(max(c.z * scale, 0), 1)),
        alpha: 1
    )
}

// MARK: - Mappa canali

/// Indici (0-based) dei canali per ruolo, calcolati una sola volta per profilo.
struct ChannelMap {
    var dimmer: Int?
    var red: Int?
    var green: Int?
    var blue: Int?
    var white: Int?
    var wheel: Int?
    var pan: Int?
    var panFine: Int?
    var tilt: Int?
    var tiltFine: Int?
    var speed: Int?
    var strobe: Int?
    var gobo: Int?
    var prism: Int?
    var colorMode: ColorMode = .rgb
    /// Slot della ruota ordinati per valore DMX crescente = ordine fisico lungo la ruota.
    var wheelSlots: [(from: Int, to: Int, rgb: SIMD3<Float>)] = []
    var goboSlots: [(from: Int, to: Int, mask: GoboMask?)] = []

    var hasRGB: Bool { red != nil || green != nil || blue != nil }
    var hasRGBW: Bool { hasRGB || white != nil }

    init(profile: FixtureProfile) {
        func first(_ role: ChannelRole) -> Int? {
            profile.channels.firstIndex(where: { $0.role == role })
        }
        dimmer = first(.dimmer)
        red = first(.red)
        green = first(.green)
        blue = first(.blue)
        white = first(.white)
        wheel = first(.colorWheel)
        pan = first(.pan)
        panFine = first(.panFine)
        tilt = first(.tilt)
        tiltFine = first(.tiltFine)
        speed = first(.panTiltSpeed)
        strobe = first(.strobe)
        gobo = first(.gobo)
        prism = first(.prism)
        colorMode = profile.colorMode
        if let w = wheel {
            wheelSlots = profile.channels[w].wheelSlots
                .sorted { $0.from < $1.from }
                .map { (from: $0.from, to: $0.to, rgb: parseHex($0.colorHex)) }
        }
        if gobo != nil {
            goboSlots = profile.gobos.map {
                (from: $0.from, to: $0.to, mask: GoboMaskCache.mask(for: $0))
            }
        }
    }

    /// Indice (nell'ordine della ruota) dello slot che contiene il valore DMX; nil se il valore cade fuori da ogni slot.
    func wheelSlotIndex(for value: Int) -> Int? {
        wheelSlots.firstIndex { value >= $0.from && value <= $0.to }
    }

    /// Maschera attiva al valore DMX del canale Gobo; nil = gobo aperto (nessuna sagomatura).
    func goboMask(for value: Int) -> GoboMask? {
        for s in goboSlots where value >= s.from && value <= s.to { return s.mask }
        return nil
    }
}

// MARK: - Cono di luce volumetrico

/// Cono additivo con dissolvenza lungo l'asse (colori per vertice). Asse +Y, apice in origine.
final class BeamVisual {
    let node = SCNNode()
    private let outer: SCNNode
    private let inner: SCNNode?
    private let outerMat: SCNMaterial
    private let innerMat: SCNMaterial?
    private var lastKey: UInt32 = .max
    private var lastAngle = -1.0
    private var lastLength = -1.0

    // Modalità gobo: al posto del cono pieno, un fascio di raggi sagomato dalla maschera.
    private var rayNode: SCNNode?
    private var rayMat: SCNMaterial?
    private var shaped = false

    private static let baseCone: SCNGeometry = makeCone()

    init(core: Bool) {
        let om = BeamVisual.makeMaterial()
        let og = BeamVisual.baseCone.copy() as! SCNGeometry
        og.materials = [om]
        let on = SCNNode(geometry: og)
        on.renderingOrder = 100
        outerMat = om
        outer = on

        if core {
            let im = BeamVisual.makeMaterial()
            let ig = BeamVisual.baseCone.copy() as! SCNGeometry
            ig.materials = [im]
            let inn = SCNNode(geometry: ig)
            inn.renderingOrder = 101
            innerMat = im
            inner = inn
        } else {
            innerMat = nil
            inner = nil
        }

        node.name = SceneHelpers.ignoreName
        node.addChildNode(on)
        if let inner { node.addChildNode(inner) }
        node.isHidden = true
    }

    /// Attiva o disattiva la sagomatura gobo.
    /// - `shaped == false`: cono pieno normale.
    /// - `shaped == true` con `source`: il cono pieno sparisce e compare il fascio di raggi della maschera.
    /// - `shaped == true` senza `source`: maschera completamente nera, il fascio non si vede.
    func setRays(_ source: SCNGeometry?, shaped: Bool) {
        rayNode?.removeFromParentNode()
        rayNode = nil
        rayMat = nil
        self.shaped = shaped

        if shaped, let source, let copy = source.copy() as? SCNGeometry {
            let m = BeamVisual.makeMaterial()
            copy.materials = [m]
            let n = SCNNode(geometry: copy)
            n.renderingOrder = 102
            n.castsShadow = false
            node.addChildNode(n)
            rayNode = n
            rayMat = m
        }
        // Forza il riapplicare di scala e colore al prossimo update.
        lastKey = .max
        lastAngle = -1
        lastLength = -1
    }

    func update(color: SIMD3<Float>, intensity: Float, halfAngleDeg: Double, length: Double) {
        let c = color * intensity
        if max(c.x, max(c.y, c.z)) < 0.004 {
            node.isHidden = true
            return
        }
        node.isHidden = false
        outer.isHidden = shaped
        inner?.isHidden = shaped
        rayNode?.isHidden = !shaped

        if abs(halfAngleDeg - lastAngle) > 0.01 || abs(length - lastLength) > 0.01 {
            lastAngle = halfAngleDeg
            lastLength = length
            let r = Float(length * tan(halfAngleDeg * Double.pi / 180))
            outer.simdScale = SIMD3<Float>(r, Float(length), r)
            inner?.simdScale = SIMD3<Float>(r * 0.4, Float(length), r * 0.4)
            rayNode?.simdScale = SIMD3<Float>(r, Float(length), r)
        }

        let key = colorKey(c)
        if key != lastKey {
            lastKey = key
            outerMat.multiply.contents = nsColor(c, scale: 0.32)
            innerMat?.multiply.contents = nsColor(c, scale: 0.6)
            rayMat?.multiply.contents = nsColor(c, scale: 0.85)
        }
    }

    func hide() { node.isHidden = true }

    private static func makeMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white      // modulato dai colori per vertice
        m.multiply.contents = NSColor.black     // tinta + intensità, aggiornata solo se cambia
        m.blendMode = .add                      // blending additivo
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }

    /// Cono unitario: anello 0 (y=0, raggio piccolo, luminoso) → anello 5 (y=1, raggio 1, nero).
    private static func makeCone() -> SCNGeometry {
        let segments = 32
        let rings = 6
        var vertices: [SCNVector3] = []
        var colors: [SIMD4<Float>] = []

        for r in 0..<rings {
            let t = Float(r) / Float(rings - 1)
            let radius = 0.03 + 0.97 * t
            let b = powf(1 - t, 1.4)
            for s in 0..<segments {
                let a = Float(s) / Float(segments) * 2 * Float.pi
                vertices.append(SCNVector3(CGFloat(cosf(a) * radius), CGFloat(t), CGFloat(sinf(a) * radius)))
                colors.append(SIMD4<Float>(b, b, b, 1))
            }
        }

        var indices: [Int32] = []
        for r in 0..<(rings - 1) {
            for s in 0..<segments {
                let s2 = (s + 1) % segments
                let a = Int32(r * segments + s)
                let b = Int32(r * segments + s2)
                let c = Int32((r + 1) * segments + s)
                let d = Int32((r + 1) * segments + s2)
                indices += [a, b, c, b, d, c]
            }
        }

        let vSrc = SCNGeometrySource(vertices: vertices)
        let cData = Data(bytes: colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let cSrc = SCNGeometrySource(
            data: cData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vSrc, cSrc], elements: [element])
    }
}

// MARK: - Macchia di luce sul pavimento

final class SpotVisual {
    let node = SCNNode()
    private let mat: SCNMaterial
    private let planeNode: SCNNode
    private var lastKey: UInt32 = .max
    private var lastRoll: Float = .nan
    private var maskImage: NSImage?

    private static let radialImage: NSImage = {
        let w = 128
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [
            CGColor(gray: 1.0, alpha: 1),
            CGColor(gray: 0.55, alpha: 1),
            CGColor(gray: 0.15, alpha: 1),
            CGColor(gray: 0.0, alpha: 1)
        ] as CFArray
        let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.3, 0.7, 1])!
        let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(w) / 2)
        ctx.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0,
            endCenter: center, endRadius: CGFloat(w) / 2,
            options: [.drawsAfterEndLocation]
        )
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: w))
    }()

    init() {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = SpotVisual.radialImage
        material.multiply.contents = NSColor.black
        material.blendMode = .add
        material.isDoubleSided = true
        material.writesToDepthBuffer = false

        let plane = SCNPlane(width: 1, height: 1)
        plane.materials = [material]
        let pn = SCNNode(geometry: plane)
        pn.simdEulerAngles = SIMD3<Float>(-Float.pi / 2, 0, 0)   // sdraiato sul pavimento
        pn.renderingOrder = 90
        pn.castsShadow = false
        mat = material
        planeNode = pn
        node.name = SceneHelpers.ignoreName
        node.addChildNode(pn)
        node.isHidden = true
    }

    /// Sagoma la macchia con una maschera gobo (nil = alone radiale normale).
    func setMask(_ image: NSImage?) {
        maskImage = image
        mat.diffuse.contents = image ?? SpotVisual.radialImage
        lastRoll = .nan
        if image == nil { planeNode.simdOrientation = simd_quatf(angle: -Float.pi / 2, axis: [1, 0, 0]) }
    }

    /// `roll` ruota l'immagine attorno alla normale della macchia (rotazione del gobo rispetto al fascio).
    func update(position: SIMD3<Float>, yaw: Float, diameter: Float, stretch: Float, color: SIMD3<Float>, roll: Float = 0) {
        if max(color.x, max(color.y, color.z)) < 0.004 {
            node.isHidden = true
            return
        }
        node.isHidden = false
        node.simdPosition = position
        node.simdEulerAngles = SIMD3<Float>(0, yaw, 0)
        node.simdScale = SIMD3<Float>(diameter, 1, diameter * stretch)
        if maskImage != nil, !(abs(roll - lastRoll) < 0.002) {
            lastRoll = roll
            // Prima ruota l'immagine attorno alla propria normale, poi la sdraia sul pavimento.
            planeNode.simdOrientation = simd_quatf(angle: -Float.pi / 2, axis: [1, 0, 0])
                * simd_quatf(angle: roll, axis: [0, 0, 1])
        }
        let key = colorKey(color)
        if key != lastKey {
            lastKey = key
            mat.multiply.contents = nsColor(color, scale: 0.8)
        }
    }

    func hide() { node.isHidden = true }
}

// MARK: - Fixture

final class FixtureRenderer {
    private(set) var fixture: PatchedFixture
    private var stage: StageConfig
    let signature: Int

    /// Nodo con posizione/yaw della luce nel mondo. Il nome è l'UUID della fixture (usato dal hitTest).
    let node = SCNNode()
    /// La macchia sul pavimento vive in coordinate mondo, quindi in un nodo separato.
    let spotNode = SCNNode()
    var nodes: [SCNNode] { [node, spotNode] }

    private let mountNode = SCNNode()
    private let panNode = SCNNode()
    private let tiltNode = SCNNode()
    private let map: ChannelMap

    private var beams: [BeamVisual] = []
    private var pixelMats: [SCNMaterial] = []
    private var pixelKeys: [UInt32] = []
    private var lensMat: SCNMaterial?
    private var lastLensKey: UInt32 = .max
    private var spot: SpotVisual?
    private var selectionBox: SCNNode?

    // Luce reale (SCNLight spot): illumina oggetti e manichini.
    private var lightNode: SCNNode?
    private var lastLightKey: UInt32 = .max
    private var lastLightIntensity: Float = -1
    private var lightGain: Float = 1400

    /// Se la zona illuminata non coincide con il cono visibile, regola questo fattore.
    private static let lightConeScale = 1.0

    private var curPan = 0.0
    private var curTilt = 0.0
    private var primed = false

    // Ruota colori: posizione continua in "unità di slot" (0 = primo slot) e slot di destinazione.
    private var wheelPos = 0.0
    private var wheelTarget = 0
    private var wheelPrimed = false
    /// Velocità della ruota in slot al secondo, e durata massima del transito completo.
    private static let wheelSlotsPerSecond = 14.0
    private static let wheelMaxTransit = 0.7

    // Strobo: fase in periodi (0..<1), apertura per il 30% del periodo.
    private var strobePhase = 0.0
    private static let strobeDuty = 0.3

    // Gobo e prisma
    private var curMask: GoboMask?
    private var lightMask: GoboMask?
    private var prismAngle = 0.0                 // gradi
    private var prismNode: SCNNode?
    private var subBeams: [BeamVisual] = []
    private var subSpots: [SpotVisual] = []
    private var baseLightOuter: CGFloat = 25
    private var lastLightOuter: CGFloat = -1
    private var lightGainScale: Float = 1
    private static let mainRayGrid = 28
    private static let subRayGrid = 12

    private var pivotHeight: Float = 0.3
    private var lensDistance: Float = 0.27
    private var maxBeamLength = 14.0

    /// Cambia se cambiano profilo o tipo di montaggio (richiede ricostruzione della geometria).
    static func signature(for f: PatchedFixture) -> Int {
        var h = Hasher()
        h.combine(f.profile)
        h.combine(f.mount)
        return h.finalize()
    }

    init(fixture: PatchedFixture, stage: StageConfig) {
        self.fixture = fixture
        self.stage = stage
        self.signature = FixtureRenderer.signature(for: fixture)
        self.map = ChannelMap(profile: fixture.profile)
        build()
    }

    func updateFixture(_ f: PatchedFixture) {
        fixture = f
        applyPlacement()
    }

    func setStage(_ s: StageConfig) {
        stage = s
        applyPlacement()
        lightNode?.light?.castsShadow = s.beamShadows
    }

    func setSelected(_ selected: Bool) {
        selectionBox?.isHidden = !selected
    }

    // MARK: Costruzione

    private func build() {
        let body = Self.flatMaterial(white: 0.09)
        let trim = Self.flatMaterial(white: 0.22)

        node.name = fixture.id.uuidString
        node.addChildNode(mountNode)
        mountNode.addChildNode(panNode)
        panNode.addChildNode(tiltNode)

        let selSize: SIMD3<Float>
        let selCenter: SIMD3<Float>

        switch fixture.profile.type {
        case .movingHeadBeam, .movingHeadSpot:
            pivotHeight = 0.30
            lensDistance = 0.27
            maxBeamLength = 18
            mountNode.addChildNode(shape(SCNCylinder(radius: 0.14, height: 0.10), body, at: [0, 0.05, 0]))
            for sx: Float in [-1, 1] {
                panNode.addChildNode(shape(
                    SCNBox(width: 0.04, height: 0.30, length: 0.09, chamferRadius: 0.01), trim, at: [sx * 0.14, 0.25, 0]))
            }
            tiltNode.simdPosition = [0, pivotHeight, 0]
            tiltNode.addChildNode(shape(SCNCylinder(radius: 0.11, height: 0.30), body, at: [0, 0.10, 0]))
            addLens(radius: 0.085, at: lensDistance)
            addBeam(core: true, at: [0, lensDistance + 0.005, 0])
            addLight(outerAngle: fixture.profile.beamAngle, at: [0, lensDistance + 0.02, 0], range: maxBeamLength)
            let s = SpotVisual()
            spot = s
            spotNode.addChildNode(s.node)
            if map.prism != nil { buildPrism() }
            selSize = [0.42, 0.62, 0.36]
            selCenter = [0, 0.30, 0]

        case .parLED:
            pivotHeight = 0.12
            lensDistance = 0.175
            maxBeamLength = 12
            mountNode.addChildNode(shape(SCNBox(width: 0.22, height: 0.02, length: 0.14, chamferRadius: 0), trim, at: [0, 0.01, 0]))
            for sx: Float in [-1, 1] {
                panNode.addChildNode(shape(
                    SCNBox(width: 0.02, height: 0.20, length: 0.06, chamferRadius: 0), trim, at: [sx * 0.11, 0.11, 0]))
            }
            tiltNode.simdPosition = [0, pivotHeight, 0]
            tiltNode.addChildNode(shape(SCNCylinder(radius: 0.085, height: 0.20), body, at: [0, 0.07, 0]))
            addLens(radius: 0.07, at: lensDistance)
            addBeam(core: true, at: [0, lensDistance + 0.005, 0])
            addLight(outerAngle: fixture.profile.beamAngle, at: [0, lensDistance + 0.02, 0], range: maxBeamLength)
            let s = SpotVisual()
            spot = s
            spotNode.addChildNode(s.node)
            if map.prism != nil { buildPrism() }
            selSize = [0.30, 0.36, 0.26]
            selCenter = [0, 0.14, 0]

        case .ledBar:
            let n = max(1, fixture.profile.pixelConfig?.count ?? 1)
            let pitch: Float = 0.1
            pivotHeight = 0.05
            lensDistance = 0.035
            maxBeamLength = 5
            tiltNode.simdPosition = [0, pivotHeight, 0]
            tiltNode.addChildNode(shape(
                SCNBox(width: CGFloat(pitch) * CGFloat(n) + 0.04, height: 0.06, length: 0.08, chamferRadius: 0.005),
                body, at: [0, 0, 0]))
            for i in 0..<n {
                let x = (Float(i) - Float(n - 1) / 2) * pitch
                let g = SCNBox(width: CGFloat(pitch) * 0.8, height: 0.006, length: 0.05, chamferRadius: 0)
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = NSColor(white: 0.1, alpha: 1)
                g.materials = [m]
                let ln = SCNNode(geometry: g)
                ln.simdPosition = [x, 0.031, 0]
                tiltNode.addChildNode(ln)
                pixelMats.append(m)
                addBeam(core: false, at: [x, lensDistance, 0])
            }
            pixelKeys = Array(repeating: UInt32.max, count: n)
            // Una sola luce per tutta la barra, con il colore medio dei pixel.
            addLight(outerAngle: fixture.profile.beamAngle + 20, at: [0, 0.07, 0], range: maxBeamLength)
            selSize = [pitch * Float(n) + 0.12, 0.16, 0.14]
            selCenter = [0, 0.05, 0]
        }

        // I corpi delle fixture NON proiettano ombra: la luce nasce dentro di loro e si auto-oscurerebbe.
        node.enumerateHierarchy { n, _ in n.castsShadow = false }

        let box = SceneHelpers.wireBox(size: selSize, center: selCenter)
        mountNode.addChildNode(box)
        selectionBox = box

        applyPlacement()
    }

    private func shape(_ g: SCNGeometry, _ m: SCNMaterial, at p: SIMD3<Float>) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = p
        return n
    }

    private func addLens(radius: CGFloat, at y: Float) {
        let cyl = SCNCylinder(radius: radius, height: 0.01)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 0.1, alpha: 1)
        cyl.materials = [m]
        let n = SCNNode(geometry: cyl)
        n.simdPosition = [0, y, 0]
        tiltNode.addChildNode(n)
        lensMat = m
    }

    private func addBeam(core: Bool, at p: SIMD3<Float>) {
        let b = BeamVisual(core: core)
        b.node.simdPosition = p
        tiltNode.addChildNode(b.node)
        beams.append(b)
    }

    /// Prisma radiale: un gruppo di sotto-fasci (cono + macchia a terra) attorno all'asse ottico.
    /// Restano nascosti finché il canale Prisma non è attivo.
    private func buildPrism() {
        let n = min(max(fixture.profile.prismFacets, 2), 24)
        let group = SCNNode()
        group.name = SceneHelpers.ignoreName
        group.simdPosition = [0, lensDistance + 0.005, 0]
        tiltNode.addChildNode(group)
        prismNode = group

        for _ in 0..<n {
            let b = BeamVisual(core: false)
            group.addChildNode(b.node)
            subBeams.append(b)

            let s = SpotVisual()
            spotNode.addChildNode(s.node)
            subSpots.append(s)
        }
    }

    /// SCNLight di tipo spot lungo l'asse del fascio (+Y locale). La luce spot punta verso -Z,
    /// quindi il nodo viene ruotato di +90° attorno a X.
    private func addLight(outerAngle: Double, at position: SIMD3<Float>, range: Double) {
        let light = SCNLight()
        light.type = .spot
        light.color = NSColor.white
        light.intensity = 0
        let outer = CGFloat(min(max(outerAngle * Self.lightConeScale, 4), 120))
        baseLightOuter = outer
        lastLightOuter = outer
        light.spotOuterAngle = outer
        light.spotInnerAngle = outer * 0.6
        light.attenuationStartDistance = 1
        light.attenuationEndDistance = CGFloat(range * 1.3)
        light.attenuationFalloffExponent = 1
        light.zNear = 0.2
        light.zFar = CGFloat(range * 1.3)
        light.castsShadow = stage.beamShadows
        light.shadowRadius = 3
        light.shadowSampleCount = 8
        light.shadowColor = NSColor(white: 0, alpha: 0.65)
        light.shadowMapSize = CGSize(width: 1024, height: 1024)

        let n = SCNNode()
        n.light = light
        n.simdPosition = position
        n.simdEulerAngles = SIMD3<Float>(Float.pi / 2, 0, 0)
        tiltNode.addChildNode(n)
        lightNode = n

        // I fasci stretti concentrano più luce: guadagno maggiore con angoli piccoli.
        lightGain = 1400 * Float(min(4, max(1, 28 / max(fixture.profile.beamAngle, 1))))
    }

    private static func flatMaterial(white: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(white: white, alpha: 1)
        m.specular.contents = NSColor(white: 0.35, alpha: 1)
        return m
    }

    // MARK: Posizionamento

    private static func rad(_ deg: Double) -> Float { Float(deg * Double.pi / 180) }

    private static func mountQuat(_ m: MountOrientation) -> simd_quatf {
        switch m {
        case .floor: return simd_quatf(angle: 0, axis: [1, 0, 0])
        case .truss: return simd_quatf(angle: Float.pi, axis: [1, 0, 0])          // appesa: +Y locale → verso il basso
        case .vertical: return simd_quatf(angle: Float.pi / 2, axis: [1, 0, 0])   // laterale: +Y locale → verso il pubblico (+Z)
        }
    }

    /// `y` della fixture è l'altezza sopra il piano del palco: l'altezza della base si somma qui.
    private var worldBase: SIMD3<Float> {
        SIMD3<Float>(Float(fixture.x), Float(stage.baseHeight + fixture.y), Float(fixture.z))
    }

    private func applyPlacement() {
        node.simdPosition = worldBase
        node.simdEulerAngles = SIMD3<Float>(0, Self.rad(fixture.yaw), 0)
        mountNode.simdOrientation = Self.mountQuat(fixture.mount)
    }

    // MARK: Aggiornamento per frame

    private func slew(_ cur: Double, _ target: Double, speed: Double, dt: Double) -> Double {
        let delta = target - cur
        let eased = delta * min(1, 14 * dt)        // smorzamento esponenziale
        let maxStep = speed * dt                   // limite di velocità dei motori
        return cur + max(-maxStep, min(maxStep, eased))
    }

    /// Punto in cui il fascio incontra il piano del palco (se dentro la pedana) oppure il suolo.
    private func floorHit(origin: SIMD3<Float>, dir: SIMD3<Float>) -> (t: Float, y: Float)? {
        guard dir.y < -0.01 else { return nil }
        let deckY = Float(stage.baseHeight)
        let hw = Float(stage.width) / 2
        let hd = Float(stage.depth) / 2
        if origin.y > deckY {
            let t = (origin.y - deckY) / -dir.y
            let p = origin + dir * t
            if abs(p.x) <= hw && abs(p.z) <= hd { return (t, deckY) }
        }
        if origin.y > 0.001 {
            return (origin.y / -dir.y, 0)
        }
        return nil
    }

    func update(data: [UInt8]?, dt: Double, time: Double) {
        let d = data ?? []
        let start = fixture.startAddress - 1
        let count = fixture.profile.channelCount

        func ch(_ i: Int?) -> Int? {
            guard let i else { return nil }
            guard i >= 0, i < count else { return 0 }
            let a = start + i
            return (a >= 0 && a < d.count) ? Int(d[a]) : 0
        }

        // Intensità master (lineare) + strobo (valori 0-9 = shutter aperto)
        var intensity: Float = 1
        if let v = ch(map.dimmer) { intensity = Float(v) / 255 }
        intensity *= strobeLevel(ch(map.strobe), dt: dt)

        // Colore: ruota (con transito fisico) oppure RGB / RGBW (cambio diretto)
        let color = beamColor(ch: ch, dt: dt)

        // Pan / Tilt (8 o 16 bit) con velocità motori
        if fixture.profile.type.isMover {
            var targetPan = 0.0
            var targetTilt = 0.0
            if let c = ch(map.pan) {
                let norm: Double
                if let f = ch(map.panFine) { norm = Double(c * 256 + f) / 65535 } else { norm = Double(c) / 255 }
                targetPan = (norm - 0.5) * fixture.profile.panRange
            }
            if let c = ch(map.tilt) {
                let norm: Double
                if let f = ch(map.tiltFine) { norm = Double(c * 256 + f) / 65535 } else { norm = Double(c) / 255 }
                targetTilt = (norm - 0.5) * fixture.profile.tiltRange
            }
            if fixture.invertPan { targetPan = -targetPan }
            if fixture.invertTilt { targetTilt = -targetTilt }

            var speed = 300.0
            if let s = ch(map.speed) {
                let n = Double(s) / 255
                speed = 6 + 394 * (1 - n) * (1 - n)     // 0 = veloce, 255 = lentissimo
            }
            if !primed {
                curPan = targetPan
                curTilt = targetTilt
                primed = true
            } else {
                curPan = slew(curPan, targetPan, speed: speed, dt: dt)
                curTilt = slew(curTilt, targetTilt, speed: speed, dt: dt)
            }
        }

        let panDeg = fixture.staticPan + curPan
        let tiltDeg = fixture.staticTilt + curTilt
        panNode.simdEulerAngles = SIMD3<Float>(0, Self.rad(panDeg), 0)
        tiltNode.simdEulerAngles = SIMD3<Float>(Self.rad(tiltDeg), 0, 0)

        // Geometria del fascio nel mondo (per lunghezza del cono e macchia sul pavimento)
        let yawQ = simd_quatf(angle: Self.rad(fixture.yaw), axis: [0, 1, 0])
        let placeQ = yawQ * Self.mountQuat(fixture.mount)
        let headQ = placeQ
            * simd_quatf(angle: Self.rad(panDeg), axis: [0, 1, 0])
            * simd_quatf(angle: Self.rad(tiltDeg), axis: [1, 0, 0])
        let dir = headQ.act(SIMD3<Float>(0, 1, 0))
        let origin = worldBase + placeQ.act(SIMD3<Float>(0, pivotHeight, 0)) + dir * lensDistance

        let half = fixture.profile.beamAngle / 2
        var length = maxBeamLength
        var hit: (t: Float, y: Float)? = nil
        if let h = floorHit(origin: origin, dir: dir), h.t > 0.05, Double(h.t) < maxBeamLength {
            length = Double(h.t)
            hit = h
        }

        if fixture.profile.type == .ledBar {
            updatePixels(ch: ch, intensity: intensity, half: half, length: length)
            return
        }

        // Gobo e prisma
        let mask = ch(map.gobo).flatMap { map.goboMask(for: $0) }
        let prismOn = updatePrism(value: ch(map.prism), dt: dt)
        applyMask(mask)
        refreshLight(prismOn: prismOn, half: half)

        if prismOn {
            beams.first?.hide()
            spot?.hide()
            updateSubBeams(
                color: color, intensity: intensity, half: half,
                headQ: headQ, origin: origin
            )
            updateLight(color: color, level: intensity)
        } else {
            for b in subBeams { b.hide() }
            for s in subSpots { s.hide() }

            beams.first?.update(color: color, intensity: intensity, halfAngleDeg: half, length: length)
            updateLight(color: color, level: intensity)

            if let spot {
                if let h = hit {
                    updateSpot(
                        spot, hit: h, origin: origin, dir: dir, half: half,
                        color: color * intensity, right: headQ.act(SIMD3<Float>(1, 0, 0))
                    )
                } else {
                    spot.hide()
                }
            }
        }

        if let lm = lensMat {
            let lv = SIMD3<Float>(repeating: 0.1) + color * intensity * 0.9
            let key = colorKey(lv)
            if key != lastLensKey {
                lastLensKey = key
                lm.diffuse.contents = nsColor(lv)
            }
        }
    }

    // MARK: Colore, strobo

    /// Colore del fascio secondo la modalità del profilo.
    /// - RGB / RGBW: valori dei canali applicati direttamente, senza transizioni.
    /// - Ruota Colori: la ruota si muove fisicamente verso lo slot richiesto e, se non è adiacente,
    ///   attraversa gli slot intermedi mostrandone brevemente i colori.
    private func beamColor(ch: (Int?) -> Int?, dt: Double) -> SIMD3<Float> {
        let white = SIMD3<Float>(1, 1, 1)
        switch map.colorMode {
        case .rgb:
            guard map.hasRGB else { return white }
            return SIMD3<Float>(
                Float(ch(map.red) ?? 0) / 255,
                Float(ch(map.green) ?? 0) / 255,
                Float(ch(map.blue) ?? 0) / 255
            )
        case .rgbw:
            guard map.hasRGBW else { return white }
            let r = Float(ch(map.red) ?? 0) / 255
            let g = Float(ch(map.green) ?? 0) / 255
            let b = Float(ch(map.blue) ?? 0) / 255
            let w = Float(ch(map.white) ?? 0) / 255
            return simd_min(SIMD3<Float>(r + w, g + w, b + w), SIMD3<Float>(repeating: 1))
        case .wheel:
            return wheelColor(value: ch(map.wheel), dt: dt)
        }
    }

    private func wheelColor(value: Int?, dt: Double) -> SIMD3<Float> {
        let slots = map.wheelSlots
        guard !slots.isEmpty else { return SIMD3<Float>(1, 1, 1) }

        // Un valore fuori da ogni slot non sposta la ruota: resta dov'è.
        if let v = value, let idx = map.wheelSlotIndex(for: v) { wheelTarget = idx }
        wheelTarget = min(max(wheelTarget, 0), slots.count - 1)
        let target = Double(wheelTarget)

        if !wheelPrimed {
            wheelPos = target                // all'avvio la ruota è già in posizione, senza transito
            wheelPrimed = true
        } else if wheelPos != target {
            let distance = abs(target - wheelPos)
            // Velocità costante, ma il transito più lungo dura al massimo `wheelMaxTransit` secondi.
            let speed = max(Self.wheelSlotsPerSecond, distance / Self.wheelMaxTransit)
            let step = speed * dt
            if distance <= step {
                wheelPos = target
            } else {
                wheelPos += target > wheelPos ? step : -step
            }
        }

        // Tra due slot la finestra della ruota li mostra entrambi: miscela proporzionale alla posizione.
        let lo = min(max(Int(wheelPos.rounded(.down)), 0), slots.count - 1)
        let hi = min(lo + 1, slots.count - 1)
        let f = Float(wheelPos - Double(lo))
        let a = slots[lo].rgb
        let b = slots[hi].rgb
        return a + (b - a) * f
    }

    /// Fattore 0...1 di apertura dello shutter per il frame corrente.
    /// La frequenza va da 1 Hz (DMX 10) a `strobeMaxHz` (DMX 255). Il lampeggio è integrato sull'intervallo del
    /// frame, così a frequenze alte il visualizzatore mostra l'ampiezza reale invece di perdere i flash per aliasing.
    private func strobeLevel(_ value: Int?, dt: Double) -> Float {
        guard let s = value, s >= 10 else {
            strobePhase = 0
            return 1
        }
        let maxHz = max(fixture.profile.strobeMaxHz, 0.5)
        let minHz = min(1.0, maxHz)
        let freq = minHz + Double(s - 10) / 245.0 * (maxHz - minHz)

        func openTime(_ u: Double) -> Double {      // tempo di apertura cumulato, in periodi
            let whole = u.rounded(.down)
            return whole * Self.strobeDuty + min(u - whole, Self.strobeDuty)
        }
        let u0 = strobePhase
        let u1 = u0 + freq * max(dt, 1e-6)
        let open = (openTime(u1) - openTime(u0)) / (u1 - u0)
        strobePhase = u1 - u1.rounded(.down)
        return Float(min(max(open, 0), 1))
    }

    // MARK: Gobo, prisma

    /// Applica (o toglie) la maschera gobo al cono visibile, alla macchia a terra e ai sotto-fasci del prisma.
    private func applyMask(_ mask: GoboMask?) {
        guard curMask !== mask else { return }
        curMask = mask
        let shaped = mask != nil
        beams.first?.setRays(mask?.rays(grid: Self.mainRayGrid), shaped: shaped)
        spot?.setMask(mask?.spotImage)
        for b in subBeams { b.setRays(mask?.rays(grid: Self.subRayGrid), shaped: shaped) }
        for s in subSpots { s.setMask(mask?.spotImage) }
    }

    /// Aggiorna la rotazione del prisma. Restituisce true se il prisma è inserito.
    /// Inserito da `prismInFrom`; fermo fino alla soglia di rotazione; oltre, ruota con velocità
    /// proporzionale a (valore − soglia) fino a `prismMaxRPM` a DMX 255.
    private func updatePrism(value: Int?, dt: Double) -> Bool {
        guard !subBeams.isEmpty, let v = value else { return false }
        let p = fixture.profile
        guard v >= max(p.prismInFrom, 1) else { return false }
        if v > p.prismRotateThreshold {
            let span = Double(max(255 - p.prismRotateThreshold, 1))
            let n = Double(v - p.prismRotateThreshold) / span
            prismAngle += n * p.prismMaxRPM * 6.0 * dt          // 1 giro/min = 6 gradi/s
            prismAngle = prismAngle.truncatingRemainder(dividingBy: 360)
        }
        return true
    }

    /// Scostamento angolare (gradi) dell'asse di ogni sotto-fascio rispetto all'asse ottico.
    private func prismRadius(half: Double) -> Double {
        min(30, max(2.5, half * 1.6))
    }

    /// Un SCNLight solo: con il prisma si allarga per coprire la corona di sotto-fasci
    /// (il gobo resta sui coni e sulle macchie, non sulla luce, perché verrebbe stirato).
    private func refreshLight(prismOn: Bool, half: Double) {
        guard let light = lightNode?.light else { return }

        let wanted: GoboMask? = prismOn ? nil : curMask
        if lightMask !== wanted {
            lightMask = wanted
            light.gobo?.contents = wanted?.image
        }

        var outer = baseLightOuter
        lightGainScale = 1
        if prismOn {
            outer = CGFloat(min(120, 2 * (prismRadius(half: half) + half)))
            outer = max(outer, baseLightOuter)
            lightGainScale = Float(min(3, outer / max(baseLightOuter, 1)))
        }
        if abs(outer - lastLightOuter) > 0.01 {
            lastLightOuter = outer
            light.spotOuterAngle = outer
            light.spotInnerAngle = outer * 0.6
        }
    }

    private func updateSubBeams(
        color: SIMD3<Float>, intensity: Float, half: Double,
        headQ: simd_quatf, origin: SIMD3<Float>
    ) {
        let n = subBeams.count
        let delta = Self.rad(prismRadius(half: half))
        let base = Float(prismAngle * Double.pi / 180)

        for k in 0..<n {
            let phi = base + Float(k) / Float(n) * 2 * Float.pi
            // Prima inclina il sotto-fascio di `delta` verso +Z, poi lo fa ruotare attorno all'asse ottico.
            let subQ = simd_quatf(angle: phi, axis: [0, 1, 0]) * simd_quatf(angle: delta, axis: [1, 0, 0])
            subBeams[k].node.simdOrientation = subQ

            let dir = headQ.act(subQ.act(SIMD3<Float>(0, 1, 0)))
            var length = maxBeamLength
            var hit: (t: Float, y: Float)? = nil
            if let h = floorHit(origin: origin, dir: dir), h.t > 0.05, Double(h.t) < maxBeamLength {
                length = Double(h.t)
                hit = h
            }
            subBeams[k].update(color: color, intensity: intensity, halfAngleDeg: half, length: length)

            if let h = hit {
                updateSpot(
                    subSpots[k], hit: h, origin: origin, dir: dir, half: half,
                    color: color * intensity, right: headQ.act(subQ.act(SIMD3<Float>(1, 0, 0)))
                )
            } else {
                subSpots[k].hide()
            }
        }
    }

    /// Macchia a terra di un fascio. `right` è l'asse destro dell'immagine del gobo nel mondo.
    private func updateSpot(
        _ spot: SpotVisual, hit h: (t: Float, y: Float), origin: SIMD3<Float>, dir: SIMD3<Float>,
        half: Double, color: SIMD3<Float>, right: SIMD3<Float>
    ) {
        let p = origin + dir * h.t
        let diameter = Float(2 * Double(h.t) * tan(half * Double.pi / 180)) + 0.12
        let stretch = min(1 / max(abs(dir.y), 0.12), 8)
        let falloff = 1 / (1 + 0.05 * h.t)
        let yaw = atan2f(dir.x, dir.z)
        spot.update(
            position: SIMD3<Float>(p.x, h.y + 0.012, p.z),
            yaw: yaw,
            diameter: diameter,
            stretch: stretch,
            color: color * falloff,
            roll: curMask == nil ? 0 : goboRoll(dir: dir, right: right, yaw: yaw)
        )
    }

    /// Angolo di rotazione dell'immagine del gobo nella macchia a terra, nel riferimento della macchia
    /// (asse X = orizzontale perpendicolare al fascio, asse Y = verso la fixture lungo la proiezione).
    private func goboRoll(dir: SIMD3<Float>, right: SIMD3<Float>, yaw: Float) -> Float {
        let planeX = SIMD3<Float>(cosf(yaw), 0, -sinf(yaw))
        var along = simd_cross(dir, planeX)
        let len = simd_length(along)
        guard len > 1e-4 else { return 0 }
        along /= len
        let a = simd_dot(right, planeX)
        let b = simd_dot(right, along)
        return atan2f(-b, a)
    }

    private func updateLight(color: SIMD3<Float>, level: Float) {
        guard let light = lightNode?.light else { return }
        let target = level * lightGain * lightGainScale
        let key = colorKey(color)
        if key != lastLightKey {
            lastLightKey = key
            light.color = nsColor(color)
        }
        if abs(target - lastLightIntensity) > 2 || ((target == 0) != (lastLightIntensity == 0)) {
            lastLightIntensity = target
            light.intensity = CGFloat(target)
        }
    }

    private func updatePixels(ch: (Int?) -> Int?, intensity: Float, half: Double, length: Double) {
        let pc = fixture.profile.pixelConfig
        var acc = SIMD3<Float>(repeating: 0)
        for i in 0..<beams.count {
            var r: Float = 0, g: Float = 0, b: Float = 0, w: Float = 0
            if let pc {
                for (k, comp) in pc.components.enumerated() {
                    let idx = pc.firstChannel + i * pc.stride + k
                    let v = Float(ch(idx) ?? 0) / 255
                    switch comp {
                    case .r: r = v
                    case .g: g = v
                    case .b: b = v
                    case .w: w = v
                    }
                }
            } else {
                r = Float(ch(map.red) ?? 0) / 255
                g = Float(ch(map.green) ?? 0) / 255
                b = Float(ch(map.blue) ?? 0) / 255
                w = Float(ch(map.white) ?? 0) / 255
            }
            let c = simd_min(SIMD3<Float>(r + w, g + w, b + w), SIMD3<Float>(repeating: 1)) * intensity
            acc += c
            beams[i].update(color: c, intensity: 1, halfAngleDeg: half, length: length)

            if i < pixelMats.count {
                let lv = SIMD3<Float>(repeating: 0.1) + c * 0.9
                let key = colorKey(lv)
                if key != pixelKeys[i] {
                    pixelKeys[i] = key
                    pixelMats[i].diffuse.contents = nsColor(lv)
                }
            }
        }

        let avg = acc / Float(max(beams.count, 1))
        let level = max(avg.x, max(avg.y, avg.z))
        let lightColor = level > 0.001 ? avg / level : SIMD3<Float>(1, 1, 1)
        updateLight(color: lightColor, level: level)
    }
}
