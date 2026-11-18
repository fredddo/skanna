// 3D-verktygen i vyn (Välj/info, Mät, Flytta, Peka, Explode, under-objekt, kantval, färgbyte).
// Allt här är visning – ändrar aldrig modellen. Tillståndet bor i Runner (Verktyg.swift); Coordinator läser och skriver det.
//
// Publika funktioner (arbetsytan styr annars via Runner-fälten: tool, explode, offsets, matning, traff, selectedPart):
//   clearSelection(), clearMeasurement(), resetLayout()
import AppKit
import SceneKit
import simd

/// Ett löv-objekt: en hel del (en kropp) eller ett under-objekt ("<del>#<n>") i en del med flera kroppar.
final class Leaf {
    let id: String
    let del: String
    let node: SCNNode                 // delens nod (en kropp) eller kroppens grupp-nod
    let body: Int?                    // kropp-index när delen har flera kroppar
    var namn: String
    var lo: V3, hi: V3
    var mat: SCNMaterial
    var edgeMat: SCNMaterial
    var edges: [EdgeData] = []
    var faceIds: [Int] = []
    var edgeNode: SCNNode?
    var multi: Bool { id != del }
    var center: V3 { (lo + hi) / 2 }
    init(id: String, del: String, node: SCNNode, body: Int?, namn: String, lo: V3, hi: V3, mat: SCNMaterial, edgeMat: SCNMaterial) {
        self.id = id; self.del = del; self.node = node; self.body = body; self.namn = namn; self.lo = lo; self.hi = hi; self.mat = mat; self.edgeMat = edgeMat
    }
}

/// Mätetikettens nod och vad den ska hålla sig undan (världskoordinater) – storlek i skärmpunkter.
struct MatEtikett { let node: SCNNode; let a: V3; let b: V3?; let w: Float; let h: Float }

struct EdgeRef { let leaf: Leaf; let edge: EdgeData; let px: Float; let local: V3 }
struct SnapPick { let kind: String; let leaf: Leaf; let local: V3; let px: Float; let edge: Int?; let face: Int?; let normal: V3? }
struct HitInfo { let world: V3; let node: SCNNode; let leafId: String?; let del: String?; let face: Int?; let normal: V3? }

func v3(_ s: SCNVector3) -> V3 { V3(Float(s.x), Float(s.y), Float(s.z)) }
func sv(_ p: V3) -> SCNVector3 { SCNVector3(p.x, p.y, p.z) }
func d3(_ p: V3) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), Double(p.z)) }
func f3(_ p: SIMD3<Double>) -> V3 { V3(Float(p.x), Float(p.y), Float(p.z)) }

extension ModelView.Coordinator {
    // MARK: Hjälpare

    static func makeMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.specular.contents = NSColor(white: 0.3, alpha: 1)
        m.lightingModel = .blinn
        m.isDoubleSided = true
        return m
    }

    /// Kroppens färg: delens färg, med varannan kropp lite ljusare/mörkare.
    static func bodyColor(_ base: NSColor, _ k: Int) -> NSColor {
        guard k > 0 else { return base }
        let step = 0.13 * Double((k + 1) / 2)
        return k % 2 == 1 ? (base.blended(withFraction: CGFloat(step), of: .white) ?? base) : (base.blended(withFraction: CGFloat(step), of: .black) ?? base)
    }

    func isVisible(_ n: SCNNode) -> Bool {
        var x: SCNNode? = n
        while let y = x { if y.isHidden { return false }; x = y.parent }
        return true
    }

    func leafID(of n: SCNNode) -> String? {
        var x: SCNNode? = n
        while let y = x {
            if let name = y.name {
                if name.hasPrefix("obj-") { return String(name.dropFirst(4)) }
                if name.hasPrefix("del-") { return String(name.dropFirst(4)) }
                if name.hasPrefix("fyll-") { return String(name.dropFirst(5)) }
            }
            x = y.parent
        }
        return nil
    }

    func offset(of leaf: Leaf) -> V3 { leaf.node.simdWorldPosition }
    func offset(of t: Traff) -> V3 { leaves[t.objekt ?? t.del ?? ""].map(offset(of:)) ?? .zero }
    func displayName(_ leaf: Leaf) -> String { (partNames[leaf.del] ?? leaf.del) + (leaf.multi ? " · \(leaf.namn)" : "") }

    func isClipped(_ w: V3) -> Bool { sectionOn && simd_dot(V3(clip.x, clip.y, clip.z), w) - clip.w > 0.01 }

    func setMarkMask(_ n: SCNNode) { n.enumerateHierarchy { x, _ in x.categoryBitMask = 2 } }

    /// Träffar under pekaren som syns (inte markeringar, inte bortklippt).
    func visibleHits(_ p: NSPoint) -> [SCNHitTestResult] {
        guard let v = view else { return [] }
        let opts: [SCNHitTestOption: Any] = [.ignoreHiddenNodes: true, .categoryBitMask: 1,
                                             .searchMode: (sectionOn ? SCNHitTestSearchMode.all : .closest).rawValue]
        return v.hitTest(p, options: opts).filter { h in
            var x: SCNNode? = h.node
            while let y = x { if y === marksNode || y === overlay { return false }; x = y.parent }
            return !isClipped(v3(h.worldCoordinates)) || h.node.name?.hasPrefix("fyll-") == true
        }
    }

    func decode(_ h: SCNHitTestResult) -> HitInfo {
        let w = v3(h.worldCoordinates)
        let leafId = leafID(of: h.node)
        let del = leafId.flatMap { leaves[$0]?.del } ?? partID(of: h.node)
        var face: Int?, normal: V3?
        if let fn = faceNode(h.node), let k = faceKey(fn), let (_, id) = split(k) {
            face = id
            if let pd = del.flatMap({ partData[$0] }), let f = pd.faces[id], f.isPlane { normal = f.normal }
        }
        return HitInfo(world: w, node: h.node, leafId: leafId, del: del, face: face, normal: normal)
    }

    func photoPixel(_ p: NSPoint) -> [Double]? {
        guard let f = snapped, let v = view else { return nil }
        var sx = Double(p.x / v.bounds.width), sy = Double(1 - p.y / v.bounds.height)
        if fit.axis == 0 { sx = (sx - 0.5) / fit.f + 0.5 } else { sy = (sy - 0.5) / fit.f + 0.5 }
        return [(sx * f.bredd).rounded(), (sy * f.hojd).rounded()]
    }

    // MARK: Skärmprojektion (egen matris: snabb nog för tusentals kantpunkter per musrörelse)

    func makeProjector() -> ((V3) -> SIMD2<Float>?)? {
        guard let v = view, let pov = v.pointOfView else { return nil }
        let w = Float(v.bounds.width), h = Float(v.bounds.height)
        guard w > 0, h > 0 else { return nil }
        if snapped != nil {
            return { p in
                let s = v.projectPoint(sv(p))
                guard s.z > 0, s.z < 1 else { return nil }
                return SIMD2(Float(s.x), Float(s.y))
            }
        }
        let V = pov.simdWorldTransform.inverse
        let fov = Float(pov.camera?.fieldOfView ?? 34)
        let f = 1 / tan(fov * .pi / 360), aspect = w / h
        return { p in
            let c = V * SIMD4<Float>(p, 1)
            let depth = -c.z
            if depth < 1 { return nil }
            return SIMD2((f / aspect * c.x / depth * 0.5 + 0.5) * w, (f * c.y / depth * 0.5 + 0.5) * h)
        }
    }

    /// Är punkten skymd av geometri framför den? (träffar mellan kameran och punkten, med tolerans)
    func occluded(_ w: V3) -> Bool {
        guard let pov = view?.pointOfView else { return false }
        let cam = pov.simdWorldPosition
        let dist = simd_length(w - cam)
        let opts: [String: Any] = [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue, SCNHitTestOption.backFaceCulling.rawValue: false, SCNHitTestOption.ignoreHiddenNodes.rawValue: true, SCNHitTestOption.categoryBitMask.rawValue: 1]
        let tol = max(0.25, 0.003 * dist)
        for h in partsRoot.hitTestWithSegment(from: sv(cam), to: sv(w), options: opts) {
            let hw = v3(h.worldCoordinates)
            if simd_length(hw - cam) < dist - tol && !isClipped(hw) { return true }
        }
        return false
    }

    // MARK: Kantval

    private func distToSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> (Float, Float) {
        let ab = b - a, l2 = simd_dot(ab, ab)
        let t = l2 > 1e-9 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
        return (simd_length(p - (a + ab * t)), t)
    }

    func edgeCandidates(_ p: NSPoint, maxPx: Float) -> [EdgeRef] {
        guard let proj = makeProjector() else { return [] }
        let m = SIMD2<Float>(Float(p.x), Float(p.y))
        var out: [EdgeRef] = []
        for leaf in leaves.values where !leaf.edges.isEmpty && isVisible(leaf.node) {
            let t = leaf.node.simdWorldPosition
            for e in leaf.edges {
                var best: (Float, V3)?
                var prev = proj(e.pts[0] + t)
                for i in 1..<e.pts.count {
                    let cur = proj(e.pts[i] + t)
                    defer { prev = cur }
                    guard let a = prev, let b = cur else { continue }
                    if m.x < min(a.x, b.x) - maxPx || m.x > max(a.x, b.x) + maxPx || m.y < min(a.y, b.y) - maxPx || m.y > max(a.y, b.y) + maxPx { continue }
                    let (d, s) = distToSegment(m, a, b)
                    if best == nil || d < best!.0 { best = (d, e.pts[i - 1] + (e.pts[i] - e.pts[i - 1]) * s) }
                }
                if let (d, loc) = best, d <= maxPx, !isClipped(loc + t) { out.append(EdgeRef(leaf: leaf, edge: e, px: d, local: loc)) }
            }
        }
        return out.sorted { $0.px < $1.px }
    }

    func pickEdge(_ p: NSPoint, maxPx: Float = 6) -> EdgeRef? {
        for c in edgeCandidates(p, maxPx: maxPx).prefix(4) where !occluded(c.local + offset(of: c.leaf)) { return c }
        return nil
    }

    // MARK: Fästpunkter (mätning)

    func snapCandidates(_ p: NSPoint, maxPx: Float = 8) -> [SnapPick] {
        guard let proj = makeProjector() else { return [] }
        let m = SIMD2<Float>(Float(p.x), Float(p.y))
        var out: [SnapPick] = []
        func add(_ kind: String, _ leaf: Leaf, _ local: V3, _ t: V3, edge: Int? = nil, face: Int? = nil, normal: V3? = nil) {
            guard let s = proj(local + t) else { return }
            let d = simd_length(s - m)
            if d <= maxPx, !isClipped(local + t) { out.append(SnapPick(kind: kind, leaf: leaf, local: local, px: d, edge: edge, face: face, normal: normal)) }
        }
        for leaf in leaves.values where isVisible(leaf.node) {
            let t = leaf.node.simdWorldPosition
            for e in leaf.edges {
                add("hörn", leaf, e.pts[0], t, edge: e.id)
                if simd_length(e.pts[e.pts.count - 1] - e.pts[0]) > 1e-3 { add("hörn", leaf, e.pts[e.pts.count - 1], t, edge: e.id) }
                // mitt längs kurvan
                var len: Float = 0
                for i in 1..<e.pts.count { len += simd_length(e.pts[i] - e.pts[i - 1]) }
                var acc: Float = 0
                for i in 1..<e.pts.count {
                    let s = simd_length(e.pts[i] - e.pts[i - 1])
                    if acc + s >= len / 2 { add("kantmitt", leaf, e.pts[i - 1] + (e.pts[i] - e.pts[i - 1]) * (s > 0 ? (len / 2 - acc) / s : 0), t, edge: e.id); break }
                    acc += s
                }
                if e.typ == "cirkel" || e.typ == "båge", let c = e.centrum { add("cirkelcentrum", leaf, c, t, edge: e.id) }
            }
            if let pd = partData[leaf.del] {
                for fid in leaf.faceIds { if let f = pd.faces[fid], let c = f.centrum { add("ytcentrum", leaf, c, t, face: fid, normal: f.isPlane ? f.normal : nil) } }
            }
        }
        return out.sorted { $0.px < $1.px }
    }

    func pickSnap(_ p: NSPoint) -> SnapPick? {
        for c in snapCandidates(p).prefix(4) where !occluded(c.local + offset(of: c.leaf)) { return c }
        return nil
    }

    /// Mätpunkt under pekaren: hörn/kantmitt/centrum inom 5 px, annars närmaste punkt på en kant inom 8 px
    /// (så att man kan mäta mellan t.ex. två böjda gavlars yttersta punkter), annars ytan.
    func measureSnap(_ p: NSPoint) -> (pick: SnapPick, edge: EdgeRef?)? {
        guard snapped == nil else { return nil }
        if let s = pickSnap(p), s.px <= 5 { return (s, nil) }
        if let e = pickEdge(p, maxPx: 8) {
            return (SnapPick(kind: "på kanten", leaf: e.leaf, local: e.local, px: e.px, edge: e.edge.id, face: nil, normal: nil), e)
        }
        return nil
    }

    // MARK: Hover (kant, fästpunkt)

    func setHoverEdge(_ e: EdgeRef?) {
        let key = e.map { "\($0.leaf.id)|\($0.edge.id)" } ?? ""
        guard key != hoverEdgeKey else { return }
        hoverEdgeKey = key
        hlHover.removeFromParentNode()
        guard let e, let g = Ror.geometry(e.edge.pts, radius: Float(radius) * 0.003) else { return }
        let m = SCNMaterial(); m.diffuse.contents = NSColor(calibratedRed: 0.35, green: 0.85, blue: 1, alpha: 1); m.lightingModel = .constant
        g.materials = [m]
        hlHover = SCNNode(geometry: g); hlHover.renderingOrder = 59
        setMarkMask(hlHover)
        e.leaf.node.addChildNode(hlHover)
    }

    func setSnapMarker(_ s: SnapPick?) {
        snapMarker.removeFromParentNode()
        view?.toolTip = nil
        guard let s, let root = view?.scene?.rootNode else { return }
        let m = SCNMaterial(); m.diffuse.contents = NSColor.systemOrange; m.lightingModel = .constant; m.readsFromDepthBuffer = false
        let g = SCNSphere(radius: 1); g.materials = [m]
        snapMarker = SCNNode(geometry: g)
        snapMarker.simdPosition = s.local + offset(of: s.leaf)
        snapMarker.renderingOrder = 102
        setMarkMask(snapMarker)
        root.addChildNode(snapMarker)
        updateOverlayScale()
        view?.toolTip = s.kind
    }

    /// Hover: kant (Välj) eller fästpunkt (Mät) först, annars ytan under pekaren.
    func hover(_ p: NSPoint?) {
        guard let v = view else { return }
        if dragLeaf != nil { return }
        if tool == .rita {
            // Rita: fyrkanten fäster mot kanter/hörn, ytan under pennspetsen lyses upp
            ritHover(p)
            let hit = p.flatMap { v.hitTest($0, options: [.rootNode: partsRoot, .ignoreHiddenNodes: true, .categoryBitMask: 1]).first.flatMap { faceNode($0.node) } }
            if hit !== hovered { let old = hovered; hovered = hit; restyle(old); restyle(hit) }
            if rit.fast == nil { v.toolTip = nil }
            return
        }
        var edge: EdgeRef?
        var snap: SnapPick?
        if let p, snapped == nil {
            if tool == .valj || tool == .peka { edge = pickEdge(p) } else if tool == .mat, let m = measureSnap(p) { snap = m.pick; edge = m.edge }
        }
        setHoverEdge(edge)
        setSnapMarker(snap)
        var hit: SCNNode?
        if let p, edge == nil || tool == .mat, tool != .flytta {
            hit = v.hitTest(p, options: [.rootNode: partsRoot, .ignoreHiddenNodes: true, .categoryBitMask: 1]).first.flatMap { faceNode($0.node) }
        }
        if hit !== hovered {
            let old = hovered
            hovered = hit
            restyle(old); restyle(hit)
        }
        if let s = snap {
            v.toolTip = s.kind
        } else if let e = edge {
            let name = partNames[e.leaf.del] ?? e.leaf.del
            v.toolTip = "\(name) · \(kantNamn(e.edge.id)) · \(e.edge.typ) \(mm(e.edge.langd, 2)) mm"
        } else {
            v.toolTip = hit.flatMap { faceKey($0) }.flatMap { k in split(k).map { "\(partNames[$0.0] ?? $0.0) · yta \($0.1) · \(faceInfo[k] ?? "")" } }
        }
    }

    // MARK: Markering och info

    func commit(_ t: Traff?, _ info: Info?, part: String?) {
        guard let run else { return }
        handledTraff = t
        knownSelectedPart = part
        run.traff = t
        run.info = info
        if run.selectedPart != part { run.selectedPart = part }
        onSelectPart?(part)
        selectedLeaf = t?.objekt
        restyleParts()
        refreshHighlights()
        let key = t.flatMap { tr in tr.yta.flatMap { y in tr.del.map { "\($0):\(y)" } } }
        if key != selectedFace {
            let old = selectedFace
            selectedFace = key
            partsRoot.enumerateHierarchy { n, _ in if let k = faceKey(n), k == old || k == key { restyle(n) } }
        }
    }

    func clearSelection() {
        commit(nil, nil, part: nil)
        run?.pick = nil
    }

    func objectInfo(_ leaf: Leaf, whole: Bool = false) -> Info {
        let name = whole ? (partNames[leaf.del] ?? leaf.del) : displayName(leaf)
        if let pd = partData[leaf.del], let i = Matt3D.objekt(namn: name, part: pd, body: leaf.multi && !whole ? leaf.body : nil) { return i }
        return Matt3D.objekt(namn: name, lo: leaf.lo, hi: leaf.hi, volym: nil, ytor: nil)
    }

    func scanInfo() -> Info {
        let (lo, hi) = worldBounds(scan)
        guard lo.x.isFinite else { return Info(rubrik: "Skanning", rader: []) }
        return Matt3D.objekt(namn: "Skanning", lo: lo, hi: hi, volym: nil, ytor: nil)
    }

    func objectTraff(_ leaf: Leaf, pos: V3, foto: String? = nil, px: [Double]? = nil) -> Traff {
        Traff(slag: .objekt, del: leaf.del, objekt: leaf.multi ? leaf.id : nil, pos: d3(pos), foto: foto, fotoPx: px)
    }

    func selectObject(_ leaf: Leaf, pos: V3) {
        commit(objectTraff(leaf, pos: pos), objectInfo(leaf), part: leaf.del)
    }

    func selectFace(_ leaf: Leaf, _ fid: Int, pos: V3, px: [Double]?) {
        guard let pd = partData[leaf.del], let f = pd.faces[fid] else { selectObject(leaf, pos: pos); return }
        let t = Traff(slag: .yta, del: leaf.del, objekt: leaf.multi ? leaf.id : nil, yta: fid, pos: d3(pos),
                      normal: f.isPlane ? f.normal.map(d3) : nil, foto: snapped?.bild, fotoPx: px)
        commit(t, Matt3D.yta(namn: displayName(leaf), part: pd, face: f, near: pos), part: leaf.del)
    }

    func selectEdge(_ e: EdgeRef) {
        let t = Traff(slag: .kant, del: e.leaf.del, objekt: e.leaf.multi ? e.leaf.id : nil, kant: e.edge.id >= harleddKant ? nil : e.edge.id, pos: d3(e.local))
        commit(t, Matt3D.kant(namn: displayName(e.leaf), e.edge), part: e.leaf.del)
    }

    func selectScan(pos: V3, px: [Double]?) {
        commit(Traff(slag: .objekt, del: "skanning", pos: d3(pos), foto: snapped?.bild, fotoPx: px), scanInfo(), part: "skanning")
    }

    /// Klick i verktyget Välj (och Flytta): kant → kant; ny del → objekt; samma objekt igen → yta; tomrum → inget.
    func handleSelect(_ p: NSPoint, _ hits: [SCNHitTestResult], faces: Bool) {
        if snapped == nil, faces, let e = pickEdge(p) { selectEdge(e); return }
        guard let h = hits.first.map(decode) else { clearSelection(); return }
        let px = photoPixel(p)
        guard let id = h.leafId, let leaf = leaves[id] else { selectScan(pos: h.world, px: px); return }
        let pos = h.world - offset(of: leaf)
        let current = run?.traff.flatMap { $0.objekt ?? $0.del }
        if faces, current == leaf.id, let f = h.face { selectFace(leaf, f, pos: pos, px: px) } else { selectObject(leaf, pos: pos) }
    }

    func handlePeka(_ p: NSPoint, _ hits: [SCNHitTestResult]) {
        guard let h = hits.first.map(decode) else { clearSelection(); return }
        let px = photoPixel(p)
        if let k = h.del, let fn = faceNode(h.node), let fk = faceKey(fn), let (part, id) = split(fk) {
            if let id2 = h.leafId, let leaf = leaves[id2] { selectFace(leaf, id, pos: h.world - offset(of: leaf), px: px) }
            onPick?(sv(h.world), partNames[part] ?? part, k, id, faceInfo[fk], snapped?.bild, px)
        } else if let id = h.leafId, let leaf = leaves[id] {
            selectObject(leaf, pos: h.world - offset(of: leaf))
            onPick?(sv(h.world), partNames[leaf.del] ?? leaf.del, leaf.del, nil, nil, snapped?.bild, px)
        } else {
            selectScan(pos: h.world, px: px)
            onPick?(sv(h.world), "skanning", nil, nil, nil, snapped?.bild, px)
        }
    }

    // MARK: Mätning

    func handleMeasure(_ p: NSPoint, _ hits: [SCNHitTestResult]) {
        guard let run else { return }
        var t: Traff?
        if let s = measureSnap(p)?.pick {
            t = Traff(slag: .punkt, del: s.leaf.del, objekt: s.leaf.multi ? s.leaf.id : nil, yta: s.face, kant: s.edge.flatMap { $0 >= harleddKant ? nil : $0 },
                      pos: d3(s.local), normal: s.normal.map(d3))
        } else if let h = hits.first.map(decode) {
            if let id = h.leafId, let leaf = leaves[id] {
                t = Traff(slag: .punkt, del: leaf.del, objekt: leaf.multi ? leaf.id : nil, yta: h.face, pos: d3(h.world - offset(of: leaf)), normal: h.normal.map(d3))
            } else {
                t = Traff(slag: .punkt, del: "skanning", pos: d3(h.world))
            }
        }
        guard let t else { return }
        if var m = run.matning, m.b == nil {
            let aPlan = m.a.yta != nil && m.a.normal != nil && m.a.kant == nil
            let bPlan = t.yta != nil && t.normal != nil && t.kant == nil
            m = Matt3D.matning(a: m.a, b: t, aPlan: aPlan, bPlan: bPlan)
            run.matning = m
        } else {
            run.matning = Matning(a: t, b: nil, avstand: nil, dx: nil, dy: nil, dz: nil, vinkel: nil, text: "Klicka på andra punkten")
        }
        redrawMeasure(force: true)
    }

    func clearMeasurement() { run?.matning = nil; redrawMeasure(force: true) }

    /// Mätningen i 3D: linje, ändpunkter och etikett, ritat genom modellen i konstant skärmstorlek.
    func redrawMeasure(force: Bool = false) {
        guard let root = view?.scene?.rootNode else { return }
        if overlay.parent !== root { root.addChildNode(overlay); matKey = "" }
        let key = "\(String(describing: run?.matning))|\(layoutKey)"
        guard force || key != matKey else { return }
        matKey = key
        measureNode.removeFromParentNode()
        measureNode = SCNNode()
        scaled = []
        matEtikett = nil
        guard let m = run?.matning else { return }
        let red = NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.15, alpha: 1)
        func mat(_ c: NSColor) -> SCNMaterial { let x = SCNMaterial(); x.diffuse.contents = c; x.lightingModel = .constant; x.readsFromDepthBuffer = false; x.isDoubleSided = true; return x }
        func dot(_ p: V3) {
            let g = SCNSphere(radius: 1); g.materials = [mat(red)]
            let n = SCNNode(geometry: g); n.simdPosition = p; n.renderingOrder = 100
            measureNode.addChildNode(n); scaled.append((n, 4))
        }
        let a = f3(m.a.pos) + offset(of: m.a)
        dot(a)
        var labelPos = a
        var labelEnd: V3?
        if let tb = m.b {
            let b = f3(tb.pos) + offset(of: tb)
            var end = b
            if let n = m.a.normal, m.avstand != nil, Matt3D.isPerpendicular(m) {
                let nn = simd_normalize(f3(n))
                end = a + nn * Float(simd_dot(d3(f3(tb.pos) - f3(m.a.pos)), simd_normalize(n)))
                dot(b)
            }
            dot(end)
            let d = end - a, len = simd_length(d)
            if len > 1e-4 {
                let cyl = SCNCylinder(radius: 1, height: CGFloat(len)); cyl.materials = [mat(red)]
                let n = SCNNode(geometry: cyl)
                n.simdPosition = (a + end) / 2
                n.look(at: sv(end), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 1, 0))
                n.renderingOrder = 99
                measureNode.addChildNode(n); scaled.append((n, -1.2))
            }
            labelPos = (a + end) / 2
            labelEnd = end
        }
        let text = m.b == nil ? "Klicka på andra punkten" : m.text
        // etiketten som en bild (text + platta i ett), så att plattan alltid passar texten exakt
        let font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: red]
        let ts = (text as NSString).size(withAttributes: attr)
        let padX: CGFloat = 14, padY: CGFloat = 8
        let W = ceil(ts.width + 2 * padX), H = ceil(ts.height + 2 * padY)
        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor(white: 1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H), xRadius: H * 0.3, yRadius: H * 0.3).fill()
        (text as NSString).draw(at: NSPoint(x: padX, y: padY), withAttributes: attr)
        img.unlockFocus()
        let k: CGFloat = 10 / 26                     // 26 pt i bilden ≈ 10 enheter (som texten var förut)
        let bg = SCNPlane(width: W * k, height: H * k)
        let bm = mat(.white); bm.diffuse.contents = img; bm.transparencyMode = .aOne; bg.materials = [bm]
        let bn = SCNNode(geometry: bg); bn.renderingOrder = 102
        let holder = SCNNode(); holder.simdPosition = labelPos   // läget sätts per bildruta (placeMeasureLabel)
        let inner = SCNNode(); inner.addChildNode(bn)
        holder.addChildNode(inner)
        holder.constraints = [SCNBillboardConstraint()]
        measureNode.addChildNode(holder); scaled.append((holder, 1.1))
        matEtikett = MatEtikett(node: holder, a: a, b: labelEnd, w: Float(W * k * 1.1), h: Float(H * k * 1.1))
        setMarkMask(measureNode)
        overlay.addChildNode(measureNode)
        updateOverlayScale()
    }

    /// Mätetiketten på skärmen: på linjen när linjen är lång nog att synas på båda sidor om etiketten,
    /// annars bredvid linjen, så långt ut att rutan inte täcker mätpunkterna.
    func placeMeasureLabel() {
        guard let e = matEtikett, let v = view else { return }
        let pa = v.projectPoint(sv(e.a))
        let a2 = SIMD2<Float>(Float(pa.x), Float(pa.y))
        var center = a2, depth = Float(pa.z)
        var dir = SIMD2<Float>(0, 1)                          // ut från linjen (skärmens y uppåt)
        var along: Float = 0
        if let b = e.b {
            let pb = v.projectPoint(sv(b))
            let b2 = SIMD2<Float>(Float(pb.x), Float(pb.y))
            center = (a2 + b2) / 2; depth = Float((pa.z + pb.z) / 2)
            let d = b2 - a2
            along = simd_length(d)
            if along > 1 {
                let u = d / along
                // halva rutans utsträckning längs linjen: får den plats mellan punkterna med marginal → på linjen
                let halfAlong = abs(u.x) * e.w / 2 + abs(u.y) * e.h / 2
                if along / 2 > halfAlong + 22 { e.node.simdPosition = simd_float3(v3(v.unprojectPoint(SCNVector3(CGFloat(center.x), CGFloat(center.y), CGFloat(depth))))); return }
                dir = SIMD2(-u.y, u.x)
                if dir.y < 0 || (abs(dir.y) < 1e-3 && dir.x < 0) { dir = -dir }   // helst uppåt/höger
            }
        }
        let halfOut = abs(dir.x) * e.w / 2 + abs(dir.y) * e.h / 2
        let p = center + dir * (halfOut + 16)
        e.node.simdPosition = v3(v.unprojectPoint(SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(depth))))
    }

    /// Konstant skärmstorlek: en enhet i noden = `px` pixlar (negativt tal = bara tvärsnittet, för linjen).
    func updateOverlayScale() {
        guard let v = view, let pov = v.pointOfView else { return }
        placeMeasureLabel()
        let cam = pov.simdWorldPosition
        let perPx = 2 * tan(Float(17 * Double.pi / 180)) / Float(max(v.bounds.height, 1))
        func s(_ n: SCNNode, _ px: Float) {
            let u = max(simd_length(n.simdWorldPosition - cam), 1) * perPx
            if px < 0 { let k = -px * u; n.scale = SCNVector3(k, 1, k) } else { let k = px * u; n.scale = SCNVector3(k, k, k) }
        }
        for (n, px) in scaled { s(n, px) }
        if snapMarker.parent != nil { s(snapMarker, 4.5) }
        if rit.markor.parent != nil { s(rit.markor, 15) }
    }

    // MARK: Markerade kanter (tjock, ljus linje)

    func refreshHighlights() {
        var key = ""
        var target: (Leaf, EdgeData)?
        if let t = run?.traff, t.slag == .kant, let k = t.kant, let leaf = leaves[t.objekt ?? t.del ?? ""], let e = leaf.edges.first(where: { $0.id == k }) {
            target = (leaf, e); key = "\(leaf.id)|\(k)"
        }
        guard key != selEdgeKey else { return }
        selEdgeKey = key
        hlSel.removeFromParentNode()
        guard let (leaf, e) = target, let g = Ror.geometry(e.pts, radius: Float(radius) * 0.005) else { return }
        let m = SCNMaterial(); m.diffuse.contents = NSColor(calibratedRed: 1, green: 0.95, blue: 0.45, alpha: 1); m.lightingModel = .constant
        m.emission.contents = NSColor(calibratedRed: 1, green: 0.9, blue: 0.3, alpha: 1)
        g.materials = [m]
        hlSel = SCNNode(geometry: g); hlSel.renderingOrder = 60
        setMarkMask(hlSel)
        leaf.node.addChildNode(hlSel)
    }

    // MARK: Flytt och explode

    func explodeVector(_ leaf: Leaf) -> V3 {
        let d = leaf.center - asmCenter
        let l = simd_length(d)
        guard l > 1e-3 else { return .zero }
        return d / l * Float(run?.explode ?? 0) * 0.9 * radius
    }

    func applyLayout(animated: Bool) {
        guard let run else { return }
        let key = "\(run.explode)|" + run.offsets.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        guard key != layoutKey else { return }
        layoutKey = key
        func off(_ id: String) -> V3 { run.offsets[id].map(f3) ?? .zero }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && !sectionOn && dragLeaf == nil ? 0.3 : 0
        for leaf in leaves.values {
            if leaf.multi {
                partNodes[leaf.del]?.simdPosition = off(leaf.del)
                leaf.node.simdPosition = explodeVector(leaf) + off(leaf.id)
            } else {
                leaf.node.simdPosition = explodeVector(leaf) + off(leaf.del)
            }
        }
        SCNTransaction.commit()
        if sectionOn { rebuildSectionFill(force: true) }
        redrawMeasure(force: true)
        if animated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.redrawMeasure(force: true) } }
    }

    func resetLayout() { run?.offsets = [:]; run?.explode = 0; applyLayout(animated: true) }

    func beginItemDrag(_ p: NSPoint, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard tool == .flytta, snapped == nil else { return false }
        guard let h = visibleHits(p).first, let id = leafID(of: h.node), let leaf = leaves[id] else { return false }
        dragLeaf = leaf
        dragWhole = flags.contains(.option)
        setHoverEdge(nil)
        return true
    }

    func itemDrag(_ dx: CGFloat, _ dy: CGFloat) {
        guard let leaf = dragLeaf, let v = view, let pov = v.pointOfView, let run else { return }
        let id = dragWhole ? leaf.del : leaf.id
        let cam = pov.simdWorldPosition
        let centerW = leaf.center + offset(of: leaf)
        let depth = max(simd_dot(centerW - cam, pov.simdWorldFront), 1)
        let k = depth * 2 * tan(Float(17 * Double.pi / 180)) / Float(max(v.bounds.height, 1))
        let delta = pov.simdWorldRight * Float(dx) * k - pov.simdWorldUp * Float(dy) * k
        run.offsets[id] = (run.offsets[id] ?? .zero) + d3(delta)
        applyLayout(animated: false)
    }

    func endItemDrag() { dragLeaf = nil }

    /// Dubbelklick på ett objekt i Flytta: tillbaka till sin plats. Returnerar om klicket togs om hand.
    func itemReset(_ p: NSPoint) -> Bool {
        guard tool == .flytta, let run else { return false }
        guard let h = visibleHits(p).first, let id = leafID(of: h.node), let leaf = leaves[id] else { return false }
        run.offsets[leaf.id] = nil
        run.offsets[leaf.del] = nil
        applyLayout(animated: true)
        return true
    }

    // MARK: Färger

    func applyColors(_ specs: [PartSpec]) {
        var changed = false
        for s in specs where specColors[s.id] != s.color {
            specColors[s.id] = s.color
            var k = 0
            for leaf in leaves.values.filter({ $0.del == s.id }).sorted(by: { $0.id < $1.id }) {
                let c = ModelView.Coordinator.bodyColor(s.color, k)
                leaf.mat.diffuse.contents = c
                leaf.edgeMat.diffuse.contents = c.blended(withFraction: 0.35, of: .black) ?? c
                k += 1
            }
            changed = true
        }
        if changed, sectionOn { rebuildSectionFill(force: true) }
    }

    // MARK: Synk med Runner (anropas från updateNSView)

    func syncTools(parts specs: [PartSpec]) {
        guard let run, let root = view?.scene?.rootNode else { return }
        if overlay.parent !== root { root.addChildNode(overlay); matKey = "" }
        if lastTool != tool { lastTool = tool; setHoverEdge(nil); setSnapMarker(nil); ritSattFast(nil) }
        ritSync()
        applyColors(specs)
        applyLayout(animated: true)
        // markering som arbetsytan satt (objektträdet): ge den info
        if run.traff != handledTraff {
            let t = run.traff
            handledTraff = t
            DispatchQueue.main.async { [weak self] in
                guard let self, let run = self.run else { return }
                if let t, run.info == nil, let del = t.del {
                    if del == "skanning" { run.info = self.scanInfo() }
                    else if let leaf = self.leaves[t.objekt ?? del] { run.info = t.objekt == nil ? self.objectInfo(leaf, whole: false) : self.objectInfo(leaf) }
                    if run.selectedPart != del { run.selectedPart = del }
                    self.knownSelectedPart = del
                }
                self.selectedLeaf = t?.objekt
                self.restyleParts(); self.refreshHighlights()
            }
        } else if run.selectedPart != knownSelectedPart {
            // delen valdes i trädet: markera objektet
            let sp = run.selectedPart
            knownSelectedPart = sp
            if let sp, sp == "skanning" || partNodes[sp] != nil, run.traff?.del != sp {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let run = self.run else { return }
                    if sp == "skanning" { self.commit(Traff(slag: .objekt, del: sp, pos: .zero), self.scanInfo(), part: sp) }
                    else if let leaf = self.leaves.values.filter({ $0.del == sp }).sorted(by: { $0.id < $1.id }).first {
                        let whole = self.leaves.values.filter { $0.del == sp }.count > 1
                        self.commit(Traff(slag: .objekt, del: sp, pos: d3(leaf.center)), whole ? self.objectInfo(leaf, whole: true) : self.objectInfo(leaf), part: sp)
                    }
                    _ = run
                }
            } else if sp == nil, run.traff != nil {
                DispatchQueue.main.async { [weak self] in self?.commit(nil, nil, part: nil) }
            }
        }
        selectedLeaf = run.traff?.objekt
        refreshHighlights()
        redrawMeasure()
    }

    /// Efter ny inläsning: publicera under-objekt och släpp markeringar som inte längre finns.
    func afterLoad(parts specs: [PartSpec]) {
        guard let run else { return }
        var uo: [String: [UnderObjekt]] = [:]
        for (del, pd) in partData where pd.bodies.count > 1 {
            uo[del] = pd.bodies.map { UnderObjekt(id: "\(del)#\($0.n)", del: del, namn: $0.namn, ytor: $0.ytor) }
        }
        run.underObjekt = uo
        specColors = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0.color) })
        layoutKey = ""; matKey = ""; hoverEdgeKey = ""; selEdgeKey = ""
        if let t = run.traff, let del = t.del, del != "skanning", leaves[t.objekt ?? del] == nil { commit(nil, nil, part: nil) }
        syncTools(parts: specs)
    }
}

extension Matt3D {
    static func isPerpendicular(_ m: Matning) -> Bool {
        guard let b = m.b, let na = m.a.normal, let nb = b.normal, m.a.yta != nil, b.yta != nil, m.a.kant == nil, b.kant == nil else { return false }
        return abs(simd_dot(simd_normalize(na), simd_normalize(nb))) > 0.9999
    }
}
