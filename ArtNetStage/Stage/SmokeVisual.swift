import SceneKit
import QuartzCore
import AppKit

/// Fumo della macchina DMX: un solo `SCNParticleSystem` a basso numero di particelle (sprite billboard sfumati),
/// senza alcun calcolo volumetrico. Il canale DMX (0–255) regola frequenza di emissione e velocità del getto.
final class SmokeVisual {
    let node = SCNNode()
    private let system = SCNParticleSystem()
    private var lastLevel: Float = -1
    private var active = false

    /// Particelle emesse al secondo a pieno canale. Con vita media ~5 s restano meno di ~100 sprite vivi.
    private static let maxBirthRate: CGFloat = 16

    /// Sprite sfumato: bianco al centro, trasparente ai bordi.
    private static let puff: NSImage = {
        let w = 64
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.85),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray
        let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.5, 1])!
        let c = CGPoint(x: CGFloat(w) / 2, y: CGFloat(w) / 2)
        ctx.drawRadialGradient(
            gradient, startCenter: c, startRadius: 0,
            endCenter: c, endRadius: CGFloat(w) / 2,
            options: []
        )
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: w))
    }()

    init() {
        node.name = SceneHelpers.ignoreName

        system.birthRate = 0
        system.loops = true
        system.particleImage = SmokeVisual.puff
        system.particleLifeSpan = 4.5
        system.particleLifeSpanVariation = 1.2
        system.particleVelocity = 1.0
        system.particleVelocityVariation = 0.4
        system.emittingDirection = SCNVector3(0, 1, 0.55)
        system.spreadingAngle = 26
        system.acceleration = SCNVector3(0, 0.10, 0)
        system.particleSize = 0.40
        system.particleSizeVariation = 0.15
        system.particleColor = NSColor(white: 0.88, alpha: 0.30)
        system.particleAngularVelocity = 0.4
        system.particleAngularVelocityVariation = 0.8
        system.blendMode = .alpha
        system.isLightingEnabled = false
        system.isAffectedByGravity = false
        system.isAffectedByPhysicsFields = false
        system.sortingMode = .none
        system.isLocal = false                       // le particelle restano nel mondo dopo l'emissione
        system.writesToDepthBuffer = false

        // Dissolvenza in entrata/uscita e crescita del puff durante la vita della particella.
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 1.0, 0.7, 0.0]
        fade.keyTimes = [0.0, 0.12, 0.6, 1.0]
        fade.duration = 1.0
        let grow = CAKeyframeAnimation()
        grow.values = [0.45, 1.4, 2.6]
        grow.keyTimes = [0.0, 0.5, 1.0]
        grow.duration = 1.0
        system.propertyControllers = [
            .opacity: SCNParticlePropertyController(animation: fade),
            .size: SCNParticlePropertyController(animation: grow)
        ]
        node.addParticleSystem(system)
    }

    /// `level` 0...1 dal canale DMX.
    func update(level: Float) {
        let on = level > 0.02
        if on == active, abs(level - lastLevel) < 0.01 { return }
        active = on
        lastLevel = level
        if on {
            system.birthRate = SmokeVisual.maxBirthRate * CGFloat(level)
            system.particleVelocity = 0.5 + 1.0 * CGFloat(level)
        } else {
            system.birthRate = 0
        }
    }
}
