// 3D-verktygens data och mätning: ytor/kanter/kroppar ur <del>-ytor.json, uppdelning i kroppar, mått för yta/kant/objekt.
// Ren beräkning (ingen SceneKit-scen) så att det går att testa utan vy. Allt i modellens ram, mm.
import AppKit
import SceneKit
import simd

typealias V3 = SIMD3<Float>

struct FaceData {
    let id: Int
    let typ: String
    let radie: Double?
    let area: Double
    let centrum: V3?
    let normal: V3?
    let v: [V3]
    let t: [Int32]
    var kropp: Int
    var isPlane: Bool { typ == "plan" }
    var isCylinder: Bool { typ.hasPrefix("cyl") }
    var isCone: Bool { typ == "kon" || typ.hasPrefix("cone") }
}

struct EdgeData {
    let id: Int
    let typ: String            // linje | cirkel | båge | spline
    let langd: Double
    let radie: Double?
    let centrum: V3?
    let pts: [V3]
    let ytor: [Int]
    var kropp: Int
}

struct BodyData {
    let n: Int                 // kropp-index (id i "<del>#<n>")
    var namn: String
    var volym: Double?
    var ytor: [Int]
    var lo: V3
    var hi: V3
}

struct PartData {
    var faces: [Int: FaceData] = [:]
    var order: [Int] = []
    var edges: [EdgeData] = []
    var bodies: [BodyData] = []
    var hasEdges: Bool { !edges.isEmpty }
}

// MARK: Inläsning

/// Läser hela <del>-ytor.json (ytor, kanter, kroppar) och delar upp i kroppar. Gamla filer utan kanter/kropp fungerar.
func loadPartData(_ url: URL) -> PartData? {
    struct F: Decodable { let id: Int; let typ: String; let area: Double?; let centrum: [Double]?; let normal: [Double]?
        let radie: Double?; let kropp: Int?; let v: [Float]; let t: [Int32] }
    struct E: Decodable { let id: Int; let typ: String?; let langd: Double?; let radie: Double?; let centrum: [Double]?; let p: [Float]; let ytor: [Int]? }
    struct K: Decodable { let id: Int; let namn: String?; let volym: Double? }
    struct Root: Decodable { let ytor: [F]; let kanter: [E]?; let kroppar: [K]? }
    guard let data = try? Data(contentsOf: url), let root = try? JSONDecoder().decode(Root.self, from: data) else { return nil }
    func vec(_ a: [Double]?) -> V3? { a.flatMap { $0.count == 3 ? V3(Float($0[0]), Float($0[1]), Float($0[2])) : nil } }
    var pd = PartData()
    var haveKropp = true
    for f in root.ytor {
        let n = f.v.count / 3
        guard n >= 3, f.t.count >= 3 else { continue }
        let pts = (0..<n).map { V3(f.v[3 * $0], f.v[3 * $0 + 1], f.v[3 * $0 + 2]) }
        var area = f.area ?? 0
        if f.area == nil {
            for k in stride(from: 0, to: f.t.count - 2, by: 3) {
                let a = Int(f.t[k]), b = Int(f.t[k + 1]), c = Int(f.t[k + 2])
                if a < n, b < n, c < n { area += Double(simd_length(simd_cross(pts[b] - pts[a], pts[c] - pts[a])) / 2) }
            }
        }
        if f.kropp == nil { haveKropp = false }
        pd.faces[f.id] = FaceData(id: f.id, typ: f.typ, radie: f.radie, area: area, centrum: vec(f.centrum), normal: vec(f.normal),
                                  v: pts, t: f.t, kropp: f.kropp ?? 0)
        pd.order.append(f.id)
    }
    guard !pd.faces.isEmpty else { return nil }
    // kroppar: fältet "kropp" per yta, annars union-find över ytor som delar hörnpunkter (0,01 mm)
    var vertexBody: [SIMD3<Int32>: Int] = [:]
    func q(_ p: V3) -> SIMD3<Int32> { SIMD3(Int32((p.x * 100).rounded()), Int32((p.y * 100).rounded()), Int32((p.z * 100).rounded())) }
    if !haveKropp {
        let ids = pd.order
        var parent = Array(0..<ids.count)
        func find(_ i: Int) -> Int { var x = i; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func union(_ a: Int, _ b: Int) { let (ra, rb) = (find(a), find(b)); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        var gridA: [SIMD3<Int32>: Int] = [:], gridB: [SIMD3<Int32>: Int] = [:]
        for (i, id) in ids.enumerated() {
            for p in pd.faces[id]!.v {
                let a = q(p)
                let b = SIMD3<Int32>(Int32((p.x * 100).rounded(.down)), Int32((p.y * 100).rounded(.down)), Int32((p.z * 100).rounded(.down)))
                if let j = gridA[a] { union(i, j) } else { gridA[a] = i }
                if let j = gridB[b] { union(i, j) } else { gridB[b] = i }
            }
        }
        // kroppsnummer i ordning efter lägsta yt-id
        var number: [Int: Int] = [:]
        for i in 0..<ids.count { let r = find(i); if number[r] == nil { number[r] = number.count } }
        for (i, id) in ids.enumerated() { pd.faces[id]!.kropp = number[find(i)] ?? 0 }
    }
    for id in pd.order { for p in pd.faces[id]!.v { vertexBody[q(p)] = pd.faces[id]!.kropp } }
    // BodyData
    let named = Dictionary(uniqueKeysWithValues: (root.kroppar ?? []).map { ($0.id, $0) })
    var bodies: [Int: BodyData] = [:]
    for id in pd.order {
        let f = pd.faces[id]!
        var b = bodies[f.kropp] ?? BodyData(n: f.kropp, namn: named[f.kropp]?.namn ?? "Kropp \(f.kropp + 1)", volym: named[f.kropp]?.volym, ytor: [],
                                           lo: V3(repeating: .infinity), hi: V3(repeating: -.infinity))
        b.ytor.append(id)
        for p in f.v { b.lo = simd_min(b.lo, p); b.hi = simd_max(b.hi, p) }
        bodies[f.kropp] = b
    }
    pd.bodies = bodies.values.sorted { $0.n < $1.n }
    for e in root.kanter ?? [] {
        let n = e.p.count / 3
        guard n >= 2 else { continue }
        let pts = (0..<n).map { V3(e.p[3 * $0], e.p[3 * $0 + 1], e.p[3 * $0 + 2]) }
        let body = e.ytor?.compactMap { pd.faces[$0]?.kropp }.first ?? vertexBody[q(pts[0])] ?? 0
        var len = e.langd ?? 0
        if e.langd == nil { for i in 1..<n { len += Double(simd_length(pts[i] - pts[i - 1])) } }
        pd.edges.append(EdgeData(id: e.id, typ: e.typ ?? "spline", langd: len, radie: e.radie, centrum: vec(e.centrum), pts: pts, ytor: e.ytor ?? [], kropp: body))
    }
    return pd
}

// MARK: Formatering

/// Decimalkomma, äkta minustecken.
func mm(_ x: Double, _ d: Int = 1) -> String {
    String(format: "%.\(d)f", x).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
}

// MARK: Geometri

private func eigenSym3(_ m: [[Double]]) -> (vals: [Double], vecs: [[Double]]) {
    var a = m
    var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    for _ in 0..<60 {
        if a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2] < 1e-20 { break }
        for (p, q) in [(0, 1), (0, 2), (1, 2)] {
            if abs(a[p][q]) < 1e-300 { continue }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 { let x = a[k][p], y = a[k][q]; a[k][p] = c * x - s * y; a[k][q] = s * x + c * y }
            for k in 0..<3 { let x = a[p][k], y = a[q][k]; a[p][k] = c * x - s * y; a[q][k] = s * x + c * y }
            for k in 0..<3 { let x = v[k][p], y = v[k][q]; v[k][p] = c * x - s * y; v[k][q] = s * x + c * y }
        }
    }
    return ([a[0][0], a[1][1], a[2][2]], (0..<3).map { i in [v[0][i], v[1][i], v[2][i]] })
}

/// Minsta-kvadrat-cirkel (Kåsa) i planet.
private func fitCircle(_ pts: [SIMD2<Double>]) -> (c: SIMD2<Double>, r: Double)? {
    guard pts.count >= 3 else { return nil }
    let m = pts.reduce(SIMD2<Double>(0, 0), +) / Double(pts.count)
    var A = [[Double]](repeating: [0, 0, 0], count: 3), b = [Double](repeating: 0, count: 3)
    for p in pts {
        let x = p.x - m.x, y = p.y - m.y
        let row = [x, y, 1.0], rhs = x * x + y * y
        for i in 0..<3 { for j in 0..<3 { A[i][j] += row[i] * row[j] }; b[i] += row[i] * rhs }
    }
    // Gauss med pivotering
    var M = (0..<3).map { A[$0] + [b[$0]] }
    for i in 0..<3 {
        let piv = (i..<3).max { abs(M[$0][i]) < abs(M[$1][i]) }!
        if abs(M[piv][i]) < 1e-12 { return nil }
        M.swapAt(i, piv)
        for r in 0..<3 where r != i { let f = M[r][i] / M[i][i]; for c in i..<4 { M[r][c] -= f * M[i][c] } }
    }
    let sol = (0..<3).map { M[$0][3] / M[$0][$0] }
    let cx = sol[0] / 2, cy = sol[1] / 2
    let r2 = sol[2] + cx * cx + cy * cy
    guard r2 > 0 else { return nil }
    return (SIMD2(cx + m.x, cy + m.y), r2.squareRoot())
}

/// Cylinder/kon: axel, längd längs axeln och radie i båda ändar.
struct Rund { var axis: SIMD3<Double>; var langd: Double; var r0: Double; var r1: Double; var mitt: SIMD3<Double> }

func measureRound(_ f: FaceData) -> Rund? {
    func d(_ p: V3) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), Double(p.z)) }
    var M = [[Double]](repeating: [0, 0, 0], count: 3)
    for k in stride(from: 0, to: f.t.count - 2, by: 3) {
        let a = Int(f.t[k]), b = Int(f.t[k + 1]), c = Int(f.t[k + 2])
        guard a < f.v.count, b < f.v.count, c < f.v.count else { continue }
        let n = simd_cross(d(f.v[b]) - d(f.v[a]), d(f.v[c]) - d(f.v[a]))
        let l = simd_length(n)
        guard l > 1e-12 else { continue }
        for i in 0..<3 { for j in 0..<3 { M[i][j] += n[i] * n[j] / l } }
    }
    let (vals, vecs) = eigenSym3(M)
    // cylinder: axeln är vinkelrät mot alla normaler (minsta egenvärdet); kon: egenvektorn som skiljer sig mest från de två andra
    let k = f.isCylinder ? (0..<3).min { vals[$0] < vals[$1] }!
        : (0..<3).max { abs(vals[$0] - (vals[0] + vals[1] + vals[2] - vals[$0]) / 2) < abs(vals[$1] - (vals[0] + vals[1] + vals[2] - vals[$1]) / 2) }!
    let axis = simd_normalize(SIMD3(vecs[k][0], vecs[k][1], vecs[k][2]))
    guard axis.x.isFinite else { return nil }
    let helper: SIMD3<Double> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
    let e1 = simd_normalize(simd_cross(axis, helper)), e2 = simd_cross(axis, e1)
    let pts = f.v.map(d)
    let s = pts.map { simd_dot($0, axis) }
    guard let lo = s.min(), let hi = s.max(), hi - lo > 1e-6 else { return nil }
    func slice(_ keep: (Double) -> Bool) -> (SIMD2<Double>, Double)? {
        let sel = zip(pts, s).filter { keep($0.1) }.map { SIMD2(simd_dot($0.0, e1), simd_dot($0.0, e2)) }
        return fitCircle(sel)
    }
    let len = hi - lo
    let c0 = slice { $0 <= lo + 0.12 * len }, c1 = slice { $0 >= hi - 0.12 * len }
    let rFile = f.isCylinder ? f.radie : nil
    let r0 = rFile ?? c0?.1 ?? 0, r1 = rFile ?? c1?.1 ?? 0
    let cc = c0?.0 ?? c1?.0 ?? SIMD2(0, 0)
    let mitt = e1 * cc.x + e2 * cc.y + axis * ((lo + hi) / 2)
    return Rund(axis: axis, langd: len, r0: r0, r1: r1, mitt: mitt)
}

/// Planets utsträckning: minsta omslutande rektangel i planet (l ≥ b).
func planeExtent(_ f: FaceData) -> (Double, Double)? {
    var n = f.normal.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) } ?? SIMD3(0, 0, 0)
    if simd_length(n) < 0.5 {
        for k in stride(from: 0, to: f.t.count - 2, by: 3) {
            let a = Int(f.t[k]), b = Int(f.t[k + 1]), c = Int(f.t[k + 2])
            guard a < f.v.count, b < f.v.count, c < f.v.count else { continue }
            let x = simd_cross(f.v[b] - f.v[a], f.v[c] - f.v[a]); n += SIMD3(Double(x.x), Double(x.y), Double(x.z))
        }
    }
    guard simd_length(n) > 1e-9 else { return nil }
    n = simd_normalize(n)
    let helper: SIMD3<Double> = abs(n.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
    let u = simd_normalize(simd_cross(helper, n)), w = simd_cross(n, u)
    let pts = f.v.map { p -> SIMD2<Double> in let q = SIMD3(Double(p.x), Double(p.y), Double(p.z)); return SIMD2(simd_dot(q, u), simd_dot(q, w)) }
    func box(_ deg: Double) -> (Double, Double, Double) {
        let c = cos(deg * .pi / 180), s = sin(deg * .pi / 180)
        var lo = SIMD2<Double>(.infinity, .infinity), hi = SIMD2<Double>(-.infinity, -.infinity)
        for p in pts { let r = SIMD2(c * p.x + s * p.y, -s * p.x + c * p.y); lo = simd_min(lo, r); hi = simd_max(hi, r) }
        let d = hi - lo
        return (d.x * d.y, d.x, d.y)
    }
    var best = (Double.infinity, 0.0, 0.0, 0.0)
    for k in 0..<90 { let b = box(Double(k)); if b.0 < best.0 { best = (b.0, b.1, b.2, Double(k)) } }
    var a = best.3 - 1
    while a <= best.3 + 1 { let b = box(a); if b.0 < best.0 - 1e-9 { best = (b.0, b.1, b.2, a) }; a += 0.1 }
    return (max(best.1, best.2), min(best.1, best.2))
}

/// Ray–triangel (Möller–Trumbore); avstånd t > 0 eller nil.
private func rayTri(_ o: V3, _ d: V3, _ a: V3, _ b: V3, _ c: V3) -> Float? {
    let e1 = b - a, e2 = c - a
    let p = simd_cross(d, e2)
    let det = simd_dot(e1, p)
    if abs(det) < 1e-12 { return nil }
    let inv = 1 / det
    let tv = o - a
    let u = simd_dot(tv, p) * inv
    if u < -1e-6 || u > 1 + 1e-6 { return nil }
    let qv = simd_cross(tv, e1)
    let v = simd_dot(d, qv) * inv
    if v < -1e-6 || u + v > 1 + 1e-6 { return nil }
    let t = simd_dot(e2, qv) * inv
    return t > 1e-4 ? t : nil
}

extension PartData {
    /// Tjocklek: avstånd längs −normalen från en punkt på planet (eller dess största trianglar) till närmaste motsatta, parallella plana yta i delen.
    func thickness(of f: FaceData, from p: V3?) -> Double? {
        guard f.isPlane, let n0 = f.normal, simd_length(n0) > 0.5 else { return nil }
        let n = simd_normalize(n0), dir = -n
        let opposite = faces.values.filter { g in
            g.id != f.id && g.isPlane && (g.normal.map { simd_dot(simd_normalize($0), n) < -0.999 } ?? false)
        }
        func cast(_ o: V3) -> Double? {
            var best: Float?
            for g in opposite {
                for k in stride(from: 0, to: g.t.count - 2, by: 3) {
                    let a = Int(g.t[k]), b = Int(g.t[k + 1]), c = Int(g.t[k + 2])
                    guard a < g.v.count, b < g.v.count, c < g.v.count else { continue }
                    if let t = rayTri(o, dir, g.v[a], g.v[b], g.v[c]), best == nil || t < best! { best = t }
                }
            }
            return best.map(Double.init)
        }
        if let p, let t = cast(p + dir * 0.001) { return t + 0.001 }
        // trianglarnas tyngdpunkter, största först
        var tris: [(Float, V3)] = []
        for k in stride(from: 0, to: f.t.count - 2, by: 3) {
            let a = Int(f.t[k]), b = Int(f.t[k + 1]), c = Int(f.t[k + 2])
            guard a < f.v.count, b < f.v.count, c < f.v.count else { continue }
            tris.append((simd_length(simd_cross(f.v[b] - f.v[a], f.v[c] - f.v[a])), (f.v[a] + f.v[b] + f.v[c]) / 3))
        }
        for (_, c) in tris.sorted(by: { $0.0 > $1.0 }).prefix(6) { if let t = cast(c + dir * 0.001) { return t + 0.001 } }
        return nil
    }

    func bodyBounds(_ n: Int?) -> (V3, V3)? {
        let bs = n.map { k in bodies.filter { $0.n == k } } ?? bodies
        guard !bs.isEmpty else { return nil }
        return (bs.map(\.lo).reduce(V3(repeating: .infinity), simd_min), bs.map(\.hi).reduce(V3(repeating: -.infinity), simd_max))
    }
}

// MARK: Info

enum Matt3D {
    static func dims(_ lo: V3, _ hi: V3) -> String {
        let d = hi - lo
        return "\(mm(Double(d.x))) × \(mm(Double(d.y))) × \(mm(Double(d.z))) mm"
    }

    static func volym(_ v: Double) -> String { v >= 1000 ? "\(mm(v / 1000, 2)) cm³" : "\(mm(v, 1)) mm³" }

    /// Objekt: omslutande låda i modellens axlar, volym om kroppar finns.
    static func objekt(namn: String, lo: V3, hi: V3, volym: Double?, ytor: Int?) -> Info {
        var rows: [(String, String)] = [("Längd × bredd × höjd", dims(lo, hi))]
        if let volym { rows.append(("Volym", Matt3D.volym(volym))) }
        if let ytor { rows.append(("Ytor", "\(ytor)")) }
        return Info(rubrik: namn, rader: rows)
    }

    /// Objekt ur kroppsdata (hel del eller en kropp); tar även med största cylinderns Ø/längd om den dominerar.
    static func objekt(namn: String, part: PartData, body: Int?) -> Info? {
        guard let (lo, hi) = part.bodyBounds(body) else { return nil }
        let bs = body.map { k in part.bodies.filter { $0.n == k } } ?? part.bodies
        let vols = bs.compactMap(\.volym)
        var info = objekt(namn: namn, lo: lo, hi: hi, volym: vols.count == bs.count && !vols.isEmpty ? vols.reduce(0, +) : nil, ytor: bs.reduce(0) { $0 + $1.ytor.count })
        let ids = Set(bs.flatMap(\.ytor))
        let total = ids.compactMap { part.faces[$0]?.area }.reduce(0, +)
        if let c = ids.compactMap({ part.faces[$0] }).filter({ $0.isCylinder }).max(by: { $0.area < $1.area }), c.area > 0.3 * total, let r = measureRound(c) {
            info.rader.append(("Största cylinder Ø", "\(mm(2 * max(r.r0, r.r1), 2)) mm"))
            info.rader.append(("… längd", "\(mm(r.langd, 2)) mm"))
        }
        return info
    }

    static func yta(namn: String, part: PartData, face f: FaceData, near: V3?) -> Info {
        var rows: [(String, String)] = []
        let r = f.isPlane ? nil : (f.isCylinder || f.isCone) ? measureRound(f) : nil
        if f.isPlane {
            rows.append(("Area", "\(mm(f.area, 1)) mm²"))
            if let (l, b) = planeExtent(f) { rows.append(("Utsträckning i planet", "\(mm(l, 1)) × \(mm(b, 1)) mm")) }
            if let t = part.thickness(of: f, from: near) { rows.append(("Tjocklek", "\(mm(t, 2)) mm")) }
        } else if f.isCylinder {
            let rad = f.radie ?? r.map { ($0.r0 + $0.r1) / 2 } ?? 0
            rows.append(("Ø", "\(mm(2 * rad, 2)) mm"))
            if let r { rows.append(("Längd längs axeln", "\(mm(r.langd, 2)) mm")) }
            rows.append(("Radie", "\(mm(rad, 2)) mm"))
            rows.append(("Area", "\(mm(f.area, 1)) mm²"))
        } else if f.isCone {
            if let r {
                rows.append(("Ø stor / liten", "\(mm(2 * max(r.r0, r.r1), 2)) / \(mm(2 * min(r.r0, r.r1), 2)) mm"))
                rows.append(("Längd längs axeln", "\(mm(r.langd, 2)) mm"))
            }
            rows.append(("Area", "\(mm(f.area, 1)) mm²"))
        } else {
            rows.append(("Area", "\(mm(f.area, 1)) mm²"))
            if let rad = f.radie { rows.append(("Radie", "\(mm(rad, 2)) mm")) }
            var lo = V3(repeating: .infinity), hi = V3(repeating: -.infinity)
            for p in f.v { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            rows.append(("Längd × bredd × höjd", dims(lo, hi)))
        }
        return Info(rubrik: "\(namn) · yta \(f.id) (\(f.typ))", rader: rows)
    }

    static func kant(namn: String, _ e: EdgeData) -> Info {
        var rows: [(String, String)] = [("Längd", "\(mm(e.langd, 2)) mm")]
        if (e.typ == "cirkel" || e.typ == "båge"), let r = e.radie {
            rows.append(("Radie", "\(mm(r, 2)) mm"))
            rows.append(("Ø", "\(mm(2 * r, 2)) mm"))
        }
        return Info(rubrik: "\(namn) · kant \(e.id) (\(e.typ))", rader: rows)
    }

    /// Färdig mätning ur två träffar (modellens ram). Parallella plana ytor ger vinkelrätt avstånd.
    static func matning(a: Traff, b: Traff, aPlan: Bool, bPlan: Bool) -> Matning {
        let d = b.pos - a.pos
        var dist = simd_length(d)
        var perp = false
        var angle: Double?
        if aPlan, bPlan, let na = a.normal, let nb = b.normal, simd_length(na) > 0.5, simd_length(nb) > 0.5 {
            let c = simd_dot(simd_normalize(na), simd_normalize(nb))
            angle = acos(max(-1, min(1, c))) * 180 / .pi
            if abs(c) > 0.9999 { dist = abs(simd_dot(d, simd_normalize(na))); perp = true }
        }
        var text = "\(mm(dist, 2)) mm"
        text += " (Δx \(mm(abs(d.x), 1)) · Δy \(mm(abs(d.y), 1)) · Δz \(mm(abs(d.z), 1)))"
        if perp { text = "\(mm(dist, 2)) mm vinkelrätt mellan parallella ytor" }
        else if let angle { text += " · vinkel \(mm(angle, 1))°" }
        return Matning(a: a, b: b, avstand: dist, dx: abs(d.x), dy: abs(d.y), dz: abs(d.z), vinkel: angle, text: text)
    }
}

// MARK: Rör (tjock linje för valda/hovrade kanter)

enum Ror {
    /// Sexsidigt rör längs en polylinje.
    static func geometry(_ pts: [V3], radius: Float) -> SCNGeometry? {
        guard pts.count >= 2 else { return nil }
        var verts: [SCNVector3] = [], norms: [SCNVector3] = [], idx: [Int32] = []
        let sides = 6
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let d = b - a
            guard simd_length(d) > 1e-6 else { continue }
            let z = simd_normalize(d)
            let h: V3 = abs(z.z) < 0.9 ? V3(0, 0, 1) : V3(1, 0, 0)
            let x = simd_normalize(simd_cross(z, h)), y = simd_cross(z, x)
            let base = Int32(verts.count)
            for s in 0..<sides {
                let ang = Float(s) / Float(sides) * 2 * .pi
                let n = x * cos(ang) + y * sin(ang)
                for p in [a, b] { let q = p + n * radius; verts.append(SCNVector3(q.x, q.y, q.z)); norms.append(SCNVector3(n.x, n.y, n.z)) }
            }
            for s in 0..<sides {
                let s2 = (s + 1) % sides
                let (a0, b0, a1, b1) = (base + Int32(2 * s), base + Int32(2 * s + 1), base + Int32(2 * s2), base + Int32(2 * s2 + 1))
                idx += [a0, b0, a1, a1, b0, b1]
            }
        }
        guard !idx.isEmpty else { return nil }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    /// Alla kanter i en kropp som en linjegeometri (en dragning per polylinje).
    static func lines(_ edges: [EdgeData]) -> SCNGeometry? {
        var verts: [SCNVector3] = [], idx: [Int32] = []
        for e in edges {
            let base = Int32(verts.count)
            verts += e.pts.map { SCNVector3($0.x, $0.y, $0.z) }
            for i in 0..<(e.pts.count - 1) { idx += [base + Int32(i), base + Int32(i + 1)] }
        }
        guard !idx.isEmpty else { return nil }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
    }
}
