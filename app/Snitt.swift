// Snitt: klipp bort allt på kamerans sida om ett huvudplan (shader modifier) och fyll snittytorna i delens färg.
import AppKit
import SceneKit

enum Snitt {
    /// Fragment-shader: kasta bort det som ligger på planets positiva sida (dot(n, p) − d > 0), p i världsram.
    static let shader = """
    #pragma arguments
    float4 clipPlane;
    #pragma body
    float4 wp = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    if (dot(clipPlane.xyz, wp.xyz) - clipPlane.w > 0.0) { discard_fragment(); }
    """

    /// Snedstreck i snittytan: mm-täthet ur världskoordinater i planets två axlar.
    static let hatch = """
    #pragma arguments
    float3 hu;
    float3 hv;
    float3 hatchColor;
    float hatchAngle;
    float hatchPitch;
    #pragma body
    float4 wp = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float a = dot(wp.xyz, hu), b = dot(wp.xyz, hv);
    float t = (a * cos(hatchAngle) + b * sin(hatchAngle)) / hatchPitch;
    float f = fract(t);
    float dd = min(f, 1.0 - f);
    float fw = fwidth(t);
    float k = 1.0 - smoothstep(0.07 - fw, 0.07 + fw, dd);
    _surface.diffuse.rgb = mix(_surface.diffuse.rgb, hatchColor, clamp(k, 0.0, 1.0));
    """

    /// Sätt (eller nollställ med n = 0) klipplanet på ett material.
    static func apply(_ m: SCNMaterial, _ plane: SIMD4<Float>) {
        if m.shaderModifiers?[.fragment] == nil { m.shaderModifiers = [.fragment: shader] }
        m.setValue(NSValue(scnVector4: SCNVector4(plane.x, plane.y, plane.z, plane.w)), forKey: "clipPlane")
    }

    /// Alla trianglar (i världsram) under en nod; linjegeometri (kanter) hoppas över.
    static func triangles(_ root: SCNNode) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        root.enumerateHierarchy { node, _ in
            guard let g = node.geometry, let vs = g.sources(for: .vertex).first else { return }
            let M = node.simdWorldTransform
            var verts: [SIMD3<Float>] = []
            verts.reserveCapacity(vs.vectorCount)
            vs.data.withUnsafeBytes { raw in
                for i in 0..<vs.vectorCount {
                    let o = vs.dataOffset + i * vs.dataStride
                    var p = SIMD3<Float>(0, 0, 0)
                    if vs.usesFloatComponents && vs.bytesPerComponent == 4 {
                        p = SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                  raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                    } else if vs.usesFloatComponents && vs.bytesPerComponent == 8 {
                        p = SIMD3(Float(raw.loadUnaligned(fromByteOffset: o, as: Double.self)), Float(raw.loadUnaligned(fromByteOffset: o + 8, as: Double.self)),
                                  Float(raw.loadUnaligned(fromByteOffset: o + 16, as: Double.self)))
                    }
                    let w = M * SIMD4<Float>(p, 1)
                    verts.append(SIMD3(w.x, w.y, w.z))
                }
            }
            for el in g.elements where el.primitiveType == .triangles || el.primitiveType == .polygon {
                el.data.withUnsafeBytes { raw in
                    func idx(_ k: Int) -> Int {
                        switch el.bytesPerIndex {
                        case 1: return Int(raw.load(fromByteOffset: k, as: UInt8.self))
                        case 2: return Int(raw.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self))
                        default: return Int(raw.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self))
                        }
                    }
                    func tri(_ a: Int, _ b: Int, _ c: Int) {
                        guard a < verts.count, b < verts.count, c < verts.count else { return }
                        out += [verts[a], verts[b], verts[c]]
                    }
                    if el.primitiveType == .triangles {
                        for t in 0..<el.primitiveCount { tri(idx(3 * t), idx(3 * t + 1), idx(3 * t + 2)) }
                    } else {
                        // polygon: först antal hörn per polygon, sedan indexen; triangulera som solfjäder
                        var k = el.primitiveCount
                        for p in 0..<el.primitiveCount {
                            let n = idx(p)
                            if n >= 3 { for j in 1..<(n - 1) { tri(idx(k), idx(k + j), idx(k + j + 1)) } }
                            k += n
                        }
                    }
                }
            }
        }
        return out
    }

    /// Snittsegment mellan trianglarna och planet dot(n, p) = d.
    static func segments(_ tris: [SIMD3<Float>], n: SIMD3<Float>, d: Float) -> [(SIMD3<Float>, SIMD3<Float>)] {
        var segs: [(SIMD3<Float>, SIMD3<Float>)] = []
        func cut(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ sa: Float, _ sb: Float) -> SIMD3<Float> {
            // kanonisk ordning så att grannar räknar fram exakt samma punkt
            let swap = (a.x, a.y, a.z) > (b.x, b.y, b.z)
            let (p, q, sp, sq) = swap ? (b, a, sb, sa) : (a, b, sa, sb)
            return p + (q - p) * (sp / (sp - sq))
        }
        var i = 0
        while i + 2 < tris.count {
            let p = [tris[i], tris[i + 1], tris[i + 2]]
            i += 3
            let s = p.map { simd_dot(n, $0) - d }
            let pos = s.map { $0 > 0 }
            if pos[0] == pos[1] && pos[1] == pos[2] { continue }
            var pts: [SIMD3<Float>] = []
            for (a, b) in [(0, 1), (1, 2), (2, 0)] where pos[a] != pos[b] { pts.append(cut(p[a], p[b], s[a], s[b])) }
            if pts.count == 2 { segs.append((pts[0], pts[1])) }
        }
        return segs
    }

    /// Kedja segment till slingor. closed = kedjan kom tillbaka till start (öppna meshar ger öppna kedjor).
    static func loops(_ segs: [(SIMD3<Float>, SIMD3<Float>)]) -> [(pts: [SIMD3<Float>], closed: Bool)] {
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3(Int32((p.x * 500).rounded()), Int32((p.y * 500).rounded()), Int32((p.z * 500).rounded())) }
        var adj: [SIMD3<Int32>: [Int]] = [:]
        for (i, s) in segs.enumerated() { adj[key(s.0), default: []].append(i); adj[key(s.1), default: []].append(i) }
        var used = [Bool](repeating: false, count: segs.count)
        var out: [(pts: [SIMD3<Float>], closed: Bool)] = []
        for start in 0..<segs.count where !used[start] {
            used[start] = true
            var loop = [segs[start].0, segs[start].1]
            var cur = key(segs[start].1)
            let first = key(segs[start].0)
            while cur != first {
                guard let next = adj[cur]?.first(where: { !used[$0] }) else { break }
                used[next] = true
                let s = segs[next]
                let p = key(s.0) == cur ? s.1 : s.0
                loop.append(p)
                cur = key(p)
            }
            if cur == first { loop.removeLast() }
            if loop.count >= 2 { out.append((loop, cur == first && loop.count >= 3)) }
        }
        return out
    }

    /// Planets bas: u × v = axeln (positiv riktning).
    static func basis(axis: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        switch axis {
        case 0: return ([0, 1, 0], [0, 0, 1], [1, 0, 0])
        case 1: return ([0, 0, 1], [1, 0, 0], [0, 1, 0])
        default: return ([1, 0, 0], [0, 1, 0], [0, 0, 1])
        }
    }

    /// Fylld snittyta (even-odd) i planet, som nod i världsram.
    static func fill(_ loops: [(pts: [SIMD3<Float>], closed: Bool)], axis: Int, coord: Float, color: NSColor, variant: Int = 0) -> SCNNode? {
        let closed = loops.filter(\.closed).map(\.pts)
        guard !closed.isEmpty else { return nil }
        let (u, v, w) = basis(axis: axis)
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        for l in closed {
            path.move(to: NSPoint(x: CGFloat(simd_dot(l[0], u)), y: CGFloat(simd_dot(l[0], v))))
            for p in l.dropFirst() { path.line(to: NSPoint(x: CGFloat(simd_dot(p, u)), y: CGFloat(simd_dot(p, v)))) }
            path.close()
        }
        let shape = SCNShape(path: path, extrusionDepth: 0)
        let m = SCNMaterial()
        m.diffuse.contents = color.blended(withFraction: 0.1, of: .white) ?? color
        m.lightingModel = .constant
        m.isDoubleSided = true
        // snedstreck som på en tvärsnittsritning: konstant täthet i mm (världskoordinater), vinkel och delning växlar per del
        let ang = Float(variant % 2 == 0 ? 45 : 135) * .pi / 180
        let pitch: Float = variant % 4 < 2 ? 1.5 : 2.2
        let dark = color.blended(withFraction: 0.55, of: .black) ?? color
        let rgb = dark.usingColorSpace(.deviceRGB) ?? dark
        m.shaderModifiers = [.surface: hatch]
        m.setValue(NSValue(scnVector3: SCNVector3(u.x, u.y, u.z)), forKey: "hu")
        m.setValue(NSValue(scnVector3: SCNVector3(v.x, v.y, v.z)), forKey: "hv")
        m.setValue(NSValue(scnVector3: SCNVector3(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)), forKey: "hatchColor")
        m.setValue(NSNumber(value: ang), forKey: "hatchAngle")
        m.setValue(NSNumber(value: pitch), forKey: "hatchPitch")
        shape.materials = [m]
        let node = SCNNode(geometry: shape)
        node.simdTransform = simd_float4x4(columns: (SIMD4(u, 0), SIMD4(v, 0), SIMD4(w, 0), SIMD4(w * coord, 1)))
        node.renderingOrder = 20
        return node
    }

    /// Snittlinjer (för skanningen, som inte är sluten).
    static func lines(_ segs: [(SIMD3<Float>, SIMD3<Float>)], color: NSColor) -> SCNNode? {
        guard !segs.isEmpty else { return nil }
        let pts = segs.flatMap { [SCNVector3($0.0.x, $0.0.y, $0.0.z), SCNVector3($0.1.x, $0.1.y, $0.1.z)] }
        let src = SCNGeometrySource(vertices: pts)
        let el = SCNGeometryElement(indices: (0..<Int32(pts.count)).map { $0 }, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [el])
        let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .constant
        g.materials = [m]
        let n = SCNNode(geometry: g); n.renderingOrder = 21
        return n
    }
}
