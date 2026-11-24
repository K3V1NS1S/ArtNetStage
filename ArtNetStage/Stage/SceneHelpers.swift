import SceneKit
import AppKit
import simd

enum SceneHelpers {

    /// I nodi con questo nome (coni di luce, macchie a terra, contorni di selezione) sono ignorati dal hitTest.
    static let ignoreName = "ignore"

    static func constantMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        return m
    }

    /// Insieme di segmenti come geometria a linee. Con `xray` le linee restano visibili attraverso le superfici.
    static func lineGeometry(_ segments: [(SIMD3<Float>, SIMD3<Float>)], color: NSColor, xray: Bool = false) -> SCNGeometry {
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
        let m = constantMaterial(color)
        if xray {
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
        }
        g.materials = [m]
        return g
    }

    /// Contorno di selezione: i 12 spigoli di un parallelepipedo, nascosto di default.
    static func wireBox(size: SIMD3<Float>, center: SIMD3<Float>) -> SCNNode {
        func v(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            SIMD3<Float>(center.x + x, center.y + y, center.z + z)
        }
        let h = size / 2
        let p: [SIMD3<Float>] = [
            v(-h.x, -h.y, -h.z), v(h.x, -h.y, -h.z), v(h.x, -h.y, h.z), v(-h.x, -h.y, h.z),
            v(-h.x, h.y, -h.z), v(h.x, h.y, -h.z), v(h.x, h.y, h.z), v(-h.x, h.y, h.z)
        ]
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]
        let segments: [(SIMD3<Float>, SIMD3<Float>)] = edges.map { (p[$0.0], p[$0.1]) }
        let g = lineGeometry(segments, color: NSColor(srgbRed: 0.15, green: 0.9, blue: 1.0, alpha: 1), xray: true)
        let n = SCNNode(geometry: g)
        n.name = ignoreName
        n.renderingOrder = 200
        n.isHidden = true
        return n
    }
}
