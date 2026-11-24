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
    var wheelSlots: [(from: Int, to: Int, rgb: SIMD3<Float>)] = []

    var hasRGBW: Bool { red != nil || green != nil || blue != nil || white != nil }

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
        if let w = wheel {
            wheelSlots = profile.channels[w].wheelSlots.map {
                (from: $0.from, to: $0.to, rgb: parseHex($0.colorHex))
            }
        }
    }

    /// Scatto netto: restituisce il colore dello slot che contiene il valore DMX (bianco se nessuno).
    func wheelColor(for value: Int) -> SIMD3<Float> {
        for s in wheelSlots where value >= s.from && value <= s.to { return s.rgb }
        return SIMD3<Float>(1, 1, 1)
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

    func update(color: SIMD3<Float>, intensity: Float, halfAngleDeg: Double, length: Double) {
        let c = color * intensity
        if max(c.x, max(c.y, c.z)) < 0.004 {
            node.isHidden = true
            return
        }
        node.isHidden = false

        if abs(halfAngleDeg - lastAngle) > 0.01 || abs(length - lastLength) > 0.01 {
            lastAngle = halfAngleDeg
            lastLength = length
            let r = Float(length * tan(halfAngleDeg * Double.pi / 180))
            outer.simdScale = SIMD3<Float>(r, Float(length), r)
            inner?.simdScale = SIMD3<Float>(r * 0.4, Float(length), r * 0.4)
        }

        let key = colorKey(c)
        if key != lastKey {
            lastKey = key
            outerMat.multiply.contents = nsColor(c, scale: 0.32)
            innerMat?.multiply.contents = nsColor(c, scale: 0.6)
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
    private let mat = SCNMaterial()
    private var lastKey: UInt32 = .max

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
        mat.lightingModel = .constant
        mat.diffuse.contents = SpotVisual.radialImage
        mat.multiply.contents = NSColor.black
        mat.blendMode = .add
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false

        let plane = SCNPlane(width: 1, height: 1)
        plane.materials = [mat]
        let planeNode = SCNNode(geometry: plane)
        planeNode.simdEulerAngles = SIMD3<Float>(-Float.pi / 2, 0, 0)   // sdraiato sul pavimento
        planeNode.renderingOrder = 90
        node.name = SceneHelpers.ignoreName
        node.addChildNode(planeNode)
        node.isHidden = true
    }

    func update(position: SIMD3<Float>, yaw: Float, diameter: Float, stretch: Float, color: SIMD3<Float>) {
        if max(color.x, max(color.y, color.z)) < 0.004 {
            node.isHidden = true
            return
        }
        node.isHidden = false
        node.simdPosition = position
        node.simdEulerAngles = SIMD3<Float>(0, yaw, 0)
        node.simdScale = SIMD3<Float>(diameter, 1, diameter * stretch)
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

    /// SCNLight di tipo spot lungo l'asse del fascio (+Y locale). La luce spot punta verso -Z,
    /// quindi il nodo viene ruotato di +90° attorno a X.
    private func addLight(outerAngle: Double, at position: SIMD3<Float>, range: Double) {
        let light = SCNLight()
        light.type = .spot
        light.color = NSColor.white
        light.intensity = 0
        let outer = CGFloat(min(max(outerAngle * Self.lightConeScale, 4), 120))
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

        // Intensità master (lineare) + strobe/shutter (0-9 = aperto)
        var intensity: Float = 1
        if let v = ch(map.dimmer) { intensity = Float(v) / 255 }
        if let s = ch(map.strobe), s >= 10 {
            let freq = 1.0 + Double(s - 10) / 245.0 * 15.0
            let phase = (time * freq).truncatingRemainder(dividingBy: 1)
            if phase > 0.3 { intensity = 0 }
        }

        // Colore: miscelazione RGBW continua × ruota colori a scatto
        var color = SIMD3<Float>(1, 1, 1)
        if map.hasRGBW {
            let r = Float(ch(map.red) ?? 0) / 255
            let g = Float(ch(map.green) ?? 0) / 255
            let b = Float(ch(map.blue) ?? 0) / 255
            let w = Float(ch(map.white) ?? 0) / 255
            color = simd_min(SIMD3<Float>(r + w, g + w, b + w), SIMD3<Float>(repeating: 1))
        }
        if let wv = ch(map.wheel) { color *= map.wheelColor(for: wv) }

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

        beams.first?.update(color: color, intensity: intensity, halfAngleDeg: half, length: length)
        updateLight(color: color, level: intensity)

        if let lm = lensMat {
            let lv = SIMD3<Float>(repeating: 0.1) + color * intensity * 0.9
            let key = colorKey(lv)
            if key != lastLensKey {
                lastLensKey = key
                lm.diffuse.contents = nsColor(lv)
            }
        }

        if let spot {
            if let h = hit {
                let p = origin + dir * h.t
                let diameter = Float(2 * Double(h.t) * tan(half * Double.pi / 180)) + 0.12
                let stretch = min(1 / max(abs(dir.y), 0.12), 8)
                let falloff = 1 / (1 + 0.05 * h.t)
                spot.update(
                    position: SIMD3<Float>(p.x, h.y + 0.012, p.z),
                    yaw: atan2f(dir.x, dir.z),
                    diameter: diameter,
                    stretch: stretch,
                    color: color * intensity * falloff
                )
            } else {
                spot.hide()
            }
        }
    }

    private func updateLight(color: SIMD3<Float>, level: Float) {
        guard let light = lightNode?.light else { return }
        let target = level * lightGain
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
