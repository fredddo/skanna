// Ritläget (verktyget Rita, D): rita streck i vyn som på en pappersutskrift – modellen står still medan man ritar.
// Startpunkten fäster mot kanter/hörn (fyrkanten vid pennspetsen), resten av strecket är fritt (⇧ = rak linje).
// Streck ritade från samma kameraläge blir en ritning; när den skickas sparas cad/ritningar/<id>.json + .png och en ny
// chattråd öppnas med ritningen som referens (se AGENT.md, "Ritningar"). Strecken ligger i ett plan vinkelrätt mot blicken
// genom kamerans mål: från ritvyn ser de ut exakt som ritat, vrider man bort vyn tonas de ut.
import AppKit
import SceneKit
import simd

// MARK: - Data (också filformatet för Claude)

struct RitTraff: Codable, Equatable {
    var del: String?                // del-id, "skanning" för skanningen
    var objekt: String?             // under-objekt "<del>#<n>"
    var yta: Int?                   // ytans id i <del>-ytor.json
    var punkt: [Double]             // träffpunkten på modellen, modellens ram (mm)
    var normal: [Double]?           // ytans normal (plana ytor)
}

struct RitProv: Codable, Equatable {
    var px: [Double]                // läge i vyn (punkter, origo uppe till vänster); bildpixel = px × bild_skala
    var strale: [Double]            // strålens riktning från kameran (enhetsvektor)
    var plan: [Double]              // där strålen skär ritplanet (mm)
    var traff: RitTraff?            // första synliga yta strålen träffar, nil = tomrum
}

struct RitFast: Codable, Equatable {
    var slag: String                // "kant" | "hörn"
    var del: String
    var objekt: String?
    var kant: Int?                  // kantens id i <del>-ytor.json ("kanter")
    var punkt: [Double]             // exakt punkt på kanten (modellens ram, mm)
}

struct RitStreck: Codable, Equatable {
    var rak: Bool                   // ritat med ⇧ (rak linje)
    var start: RitFast?             // startpunkten fäste mot en kant/ett hörn
    var prov: [RitProv]             // strecket var ~6:e punkt, med stråle och träff
    var linje: [[Double]]           // strecket i ritplanet (mm), för att visa det igen
}

struct RitVisning: Codable, Equatable {
    var dolda: [String]
    var flyttade: [String: [Double]]   // tillfälligt flyttade delar/objekt (mm) – bilden visar dem flyttade
    var explode: Double
    var snitt: Bool
    var sprangflyttade: [String: [Double]]? = nil   // egna flyttar i sprängvyn (mm vid explode 1)
}

struct Ritning: Codable, Equatable, Identifiable {
    var id: String
    var tid: String
    var bild: String?               // "ritningar/<id>.png" (sätts när ritningen skickas)
    var bild_skala: Double?         // bildpixlar per punkt i vyn
    var vy: [Double]                // vyns storlek (punkter): bredd, höjd
    var kamera: [Double]            // kamerans 4×4-transform i modellens ram, kolumnvis
    var kamera_pos: [Double]
    var kamera_fram: [Double]       // blickriktning
    var kamera_upp: [Double]
    var kamera_hoger: [Double]
    var fov: Double                 // lodrätt synfält (grader)
    var mal: [Double]               // kamerans mål (orbit)
    var plan_punkt: [Double]        // ritplanet: genom målet, vinkelrätt mot blicken
    var plan_normal: [Double]
    var mm_per_px: Double           // i ritplanet
    var foto: String?               // ritad ovanpå detta foto (fotoläget)
    var visning: RitVisning?
    var streck: [RitStreck]
}

// MARK: - Runner: skicka, visa, kasta

extension Runner {
    var ritningarMapp: URL? { cadFolder?.appendingPathComponent("ritningar", isDirectory: true) }

    /// Ritningens bild (PNG) när den hade `n` streck – tas av 3D-vyn när ett streck är klart.
    func ritBild(_ r: Ritning) -> Data? { ritBilder["\(r.id)#\(r.streck.count)"] }

    /// Spara den väntande ritningen i cad/ritningar/ och returnera (json, png, förankring).
    func sparaRitning(_ r0: Ritning) -> (json: String, png: String?, plats: PickPoint?) {
        var r = r0
        let fm = FileManager.default
        guard let dir = ritningarMapp else { return ("", nil, nil) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = r.id.replacingOccurrences(of: ":", with: "-")
        var png: String?
        if let d = ritBild(r) {
            try? d.write(to: dir.appendingPathComponent(base + ".png"), options: .atomic)
            png = "ritningar/\(base).png"
            r.bild = png
            r.bild_skala = ritBildSkala["\(r.id)#\(r.streck.count)"]
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: dir.appendingPathComponent(base + ".json"), options: .atomic) }
        // nålen: startens fästpunkt, annars första träffen på modellen
        var plats: PickPoint?
        for s in r.streck {
            if let f = s.start { plats = PickPoint(pos: f.punkt.map { ($0 * 10).rounded() / 10 }, target: f.del, del: f.del); break }
            if let t = s.prov.lazy.compactMap(\.traff).first {
                plats = PickPoint(pos: t.punkt.map { ($0 * 10).rounded() / 10 }, target: t.del ?? "skanning", yta: t.yta, del: t.del); break
            }
        }
        return ("ritningar/\(base).json", png, plats)
    }

    /// Kasta den väntande ritningen (går att ångra).
    func kastaRitning() {
        guard ritning != nil else { return }
        noteChange("Kasta ritning", immediate: true)
        ritning = nil
    }

    /// Läs en skickad ritning.
    func lasRitning(_ rel: String) -> Ritning? {
        guard let f = cadFolder else { return nil }
        return (try? Data(contentsOf: f.appendingPathComponent(rel))).flatMap { try? JSONDecoder().decode(Ritning.self, from: $0) }
    }

    /// Visa en skickad ritning: kameran flyger tillbaka till ritvyn och strecken syns.
    func visaRitning(_ rel: String) {
        guard let r = lasRitning(rel) else { toast = "Hittar inte ritningen \(rel)"; return }
        visadRitning = r
        ritBegaran = r
    }

    func arVisad(_ rel: String) -> Bool { visadRitning.map { "ritningar/" + $0.id.replacingOccurrences(of: ":", with: "-") + ".json" == rel } ?? false }

    /// Den väntande ritningens vy igen.
    func visaVantandeRitning() { if let r = ritning { ritBegaran = r } }

    /// Efter skick: ritningen hör till tråden och ska inte komma tillbaka med ⌘Z.
    func glomVantandeRitning() {
        let ritSteg: Set<String> = ["Rita", "Streck", "Kasta ritning"]
        undoStack = undoStack.filter { !ritSteg.contains($0.namn) }.map { var x = $0; x.bild.ritning = nil; return x }
        redoStack = redoStack.filter { !ritSteg.contains($0.namn) }.map { var x = $0; x.bild.ritning = nil; return x }
        ritning = nil
        settleUndo()
    }
}

// MARK: - Pennmarkören

enum Penna {
    /// En penna snett mot nedre vänstra hörnet; spetsen är markörens punkt.
    static let markor: NSCursor = {
        let S: CGFloat = 28
        let img = NSImage(size: NSSize(width: S, height: S), flipped: true) { _ in
            let T = CGPoint(x: 3, y: 25)
            let d = CGPoint(x: 0.7071, y: -0.7071), n = CGPoint(x: 0.7071, y: 0.7071)
            func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: T.x + d.x * a + n.x * b, y: T.y + d.y * a + n.y * b) }
            let body = NSBezierPath()
            body.move(to: T); body.line(to: p(8, 3.4)); body.line(to: p(27, 3.4)); body.line(to: p(27, -3.4)); body.line(to: p(8, -3.4)); body.close()
            NSColor.white.setFill(); body.fill()
            NSColor.black.setStroke(); body.lineWidth = 1.3; body.stroke()
            let tip = NSBezierPath(); tip.move(to: T); tip.line(to: p(3.4, 1.45)); tip.line(to: p(3.4, -1.45)); tip.close()
            NSColor.black.setFill(); tip.fill()
            let band = NSBezierPath(); band.move(to: p(22, 3.4)); band.line(to: p(22, -3.4)); band.lineWidth = 1.3; band.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 3, y: 25))
    }()
}

// MARK: - 3D-vyn

/// Ritlägets tillstånd i 3D-vyn (Coordinator har en instans).
final class RitTillstand {
    // fästning vid pennspetsen
    var fast: (pick: SnapPick, edge: EdgeRef?)?
    var fastNyckel = ""
    let markor = SCNNode()
    // pågående streck
    var aktiv = false
    var punkter: [CGPoint] = []        // vyns punkter (origo nere till vänster, som NSView)
    var rakFran: Int?                  // ⇧: rak linje från punkter[rakFran]
    var sista = CGPoint.zero
    var rakHela = false
    var start: RitFast?
    var plan: (p: V3, n: V3, z: Float)?
    var levande = SCNNode()
    var pending: Ritning?              // ritningen strecket hör till (väntande eller ny)
    // visade ritningar
    let rot = SCNNode()
    var nyckel = ""
}

/// Nod för en ritning: bär ritvyns blickriktning för uttoningen.
final class RitNod: SCNNode { var fram = V3(0, 0, -1) }

extension ModelView.Coordinator {
    static let pennFarg = NSColor(calibratedRed: 0.88, green: 0.13, blue: 0.54, alpha: 1)

    // MARK: Fästning vid pennspetsen (hover)

    /// Kant inom ~16 px (håller fast vid den kant den följer), hörn inom 8 px. Bara synliga, inte bortklippta.
    func ritHover(_ p: NSPoint?) {
        guard let p else { ritSattFast(nil); return }
        var corner: SnapPick?
        for c in snapCandidates(p, maxPx: 8).filter({ $0.kind == "hörn" }).prefix(3) where !occluded(c.local + offset(of: c.leaf)) { corner = c; break }
        if let c = corner {
            let e = c.edge.flatMap { id in c.leaf.edges.first { $0.id == id } }.map { EdgeRef(leaf: c.leaf, edge: $0, px: c.px, local: c.local) }
            ritSattFast((c, e)); return
        }
        let cands = edgeCandidates(p, maxPx: 16).prefix(6).filter { !occluded($0.local + offset(of: $0.leaf)) }
        guard var best = cands.first else { ritSattFast(nil); return }
        // klibbig: följ samma kant tills en annan är tydligt närmare
        if let cur = cands.first(where: { "\($0.leaf.id)|\($0.edge.id)" == rit.fastNyckel }), cur.px <= best.px + 5 { best = cur }
        let pick = SnapPick(kind: "kant", leaf: best.leaf, local: best.local, px: best.px, edge: best.edge.id, face: nil, normal: nil)
        ritSattFast((pick, best))
    }

    func ritSattFast(_ f: (pick: SnapPick, edge: EdgeRef?)?) {
        rit.fast = f
        rit.fastNyckel = f?.edge.map { "\($0.leaf.id)|\($0.edge.id)" } ?? ""
        setHoverEdge(f?.edge)
        guard let f, let root = view?.scene?.rootNode else { rit.markor.removeFromParentNode(); return }
        if rit.markor.geometry == nil {
            let S: CGFloat = 32
            let img = NSImage(size: NSSize(width: S, height: S), flipped: false) { r in
                let b = NSBezierPath(rect: r.insetBy(dx: 5, dy: 5)); b.lineWidth = 4; NSColor.white.setStroke(); b.stroke()
                b.lineWidth = 2; NSColor(calibratedRed: 0.1, green: 0.55, blue: 1, alpha: 1).setStroke(); b.stroke()
                return true
            }
            let g = SCNPlane(width: 1, height: 1)
            let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.isDoubleSided = true
            g.materials = [m]
            rit.markor.geometry = g
            rit.markor.renderingOrder = 106
            rit.markor.constraints = [SCNBillboardConstraint()]
            setMarkMask(rit.markor)
        }
        if rit.markor.parent !== root { root.addChildNode(rit.markor) }
        rit.markor.simdPosition = f.pick.local + offset(of: f.pick.leaf)
        updateOverlayScale()
        view?.satTips(f.pick.kind == "hörn" ? "hörn" : f.edge.map { "\(partNames[$0.leaf.del] ?? $0.leaf.del) · \(kantNamn($0.edge.id))" })
    }

    // MARK: Kamera och ritplan

    func ritKameraLika(_ r: Ritning) -> Bool {
        guard let pov = view?.pointOfView, r.kamera_pos.count == 3, r.kamera_fram.count == 3 else { return false }
        let pos = V3(Float(r.kamera_pos[0]), Float(r.kamera_pos[1]), Float(r.kamera_pos[2]))
        let fram = V3(Float(r.kamera_fram[0]), Float(r.kamera_fram[1]), Float(r.kamera_fram[2]))
        let d = simd_length(pov.simdWorldPosition - pos)
        let ang = acos(max(-1, min(1, simd_dot(simd_normalize(pov.simdWorldFront), simd_normalize(fram)))))
        return d < max(0.3, 0.002 * dist) && ang < 0.004
    }

    func ritNy() -> Ritning? {
        guard let v = view, let pov = v.pointOfView else { return nil }
        let c = pov.simdWorldTransform.columns
        let cam = [c.0, c.1, c.2, c.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
        let fram = simd_normalize(pov.simdWorldFront)
        let planP = target
        let depth = max(simd_dot(planP - pov.simdWorldPosition, fram), 1)
        let fov = Double(pov.camera?.fieldOfView ?? 34)
        let mmPerPx = Double(depth) * 2 * tan(fov * .pi / 360) / Double(max(v.bounds.height, 1))
        let vis = run.map { r in RitVisning(dolda: r.hidden.sorted(), flyttade: r.offsets.mapValues { [$0.x, $0.y, $0.z] }, explode: r.explode, snitt: sectionOn,
                                              sprangflyttade: r.sprangOffsets.isEmpty ? nil : r.sprangOffsets.mapValues { [$0.x, $0.y, $0.z] }) }
        return Ritning(id: isoNu(), tid: isoNu(), bild: nil, bild_skala: nil, vy: [Double(v.bounds.width), Double(v.bounds.height)],
                       kamera: cam, kamera_pos: dd(pov.simdWorldPosition), kamera_fram: dd(fram), kamera_upp: dd(pov.simdWorldUp),
                       kamera_hoger: dd(pov.simdWorldRight), fov: fov, mal: dd(target), plan_punkt: dd(planP), plan_normal: dd(-fram),
                       mm_per_px: mmPerPx, foto: snapped?.bild, visning: vis, streck: [])
    }

    private func dd(_ p: V3) -> [Double] { [Double(p.x), Double(p.y), Double(p.z)].map { ($0 * 1000).rounded() / 1000 } }

    /// Skärmpunkt → punkt i ritplanet.
    func ritPaPlan(_ p: CGPoint) -> V3? {
        guard let v = view, let pl = rit.plan else { return nil }
        return v3(v.unprojectPoint(SCNVector3(p.x, p.y, CGFloat(pl.z))))
    }

    // MARK: Ritandet (mus ned/drag/upp från HoverSCNView)

    func ritBorja(_ p: NSPoint, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard let run, run.tool == .rita, !run.mellanslag, let v = view, v.scene != nil else { return false }
        let pending = run.ritning.flatMap { ritKameraLika($0) ? $0 : nil }
        guard let r = pending ?? ritNy() else { return false }
        let pp = V3(Float(r.plan_punkt[0]), Float(r.plan_punkt[1]), Float(r.plan_punkt[2]))
        let z = Float(v.projectPoint(sv(pp)).z)
        rit.plan = (pp, V3(Float(r.plan_normal[0]), Float(r.plan_normal[1]), Float(r.plan_normal[2])), z)
        var start = CGPoint(x: p.x, y: p.y)
        rit.start = nil
        if let f = rit.fast {
            let w = f.pick.local + offset(of: f.pick.leaf)
            let s = v.projectPoint(sv(w))
            start = CGPoint(x: s.x, y: s.y)
            rit.start = RitFast(slag: f.pick.kind == "hörn" ? "hörn" : "kant", del: f.pick.leaf.del, objekt: f.pick.leaf.multi ? f.pick.leaf.id : nil,
                                kant: f.pick.edge.flatMap { $0 >= harleddKant ? nil : $0 }, punkt: dd(f.pick.local))
        }
        rit.aktiv = true
        rit.punkter = [start]
        rit.sista = start
        rit.rakFran = flags.contains(.shift) ? 0 : nil
        rit.rakHela = flags.contains(.shift)
        rit.pending = r
        ritSattFast(nil)
        if hovered != nil { let old = hovered; hovered = nil; restyle(old) }
        view?.satTips(nil)
        ritRitaLevande()
        return true
    }

    func ritDra(_ p: NSPoint, _ flags: NSEvent.ModifierFlags) {
        guard rit.aktiv else { return }
        let q = CGPoint(x: p.x, y: p.y)
        if flags.contains(.shift) {
            if rit.rakFran == nil { rit.rakFran = rit.punkter.count - 1 }
        } else if let k = rit.rakFran {
            // ⇧ släppt: den raka biten blir kvar, fortsätt på fri hand därifrån
            rit.punkter = Array(rit.punkter.prefix(k + 1)) + [rit.sista]
            rit.rakFran = nil
            rit.rakHela = false
        }
        rit.sista = q
        if rit.rakFran == nil {
            if let l = rit.punkter.last, hypot(l.x - q.x, l.y - q.y) < 1.5 { return }
            rit.punkter.append(q)
            rit.rakHela = false
        }
        ritRitaLevande()
    }

    /// Strecket som det ser ut nu (med den raka biten).
    private func ritAktuella() -> [CGPoint] {
        if let k = rit.rakFran { return Array(rit.punkter.prefix(k + 1)) + [rit.sista] }
        return rit.punkter
    }

    func ritRitaLevande() {
        rit.levande.removeFromParentNode()
        let pts = ritAktuella().compactMap(ritPaPlan)
        guard pts.count >= 2, let r = rit.pending, let root = view?.scene?.rootNode else { return }
        rit.levande = ritNod(pts, mmPerPx: r.mm_per_px, alpha: 1)
        root.addChildNode(rit.levande)
    }

    func ritSlut(_ p: NSPoint) {
        guard rit.aktiv, let run, let v = view, var r = rit.pending else { return }
        rit.aktiv = false
        rit.levande.removeFromParentNode()
        let pts = ritAktuella()
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard pts.count >= 2, length >= 4 else { return }   // ett klick är inget streck
        let rak = rit.rakHela && rit.rakFran == 0
        // prov var ~6:e punkt längs strecket: stråle, punkt i ritplanet och första synliga träff
        var prov: [RitProv] = []
        let H = Double(v.bounds.height)
        func provAt(_ q: CGPoint) {
            let near = v3(v.unprojectPoint(SCNVector3(q.x, q.y, 0))), far = v3(v.unprojectPoint(SCNVector3(q.x, q.y, 1)))
            let dir = simd_normalize(far - near)
            guard let pl = ritPaPlan(q) else { return }
            var t: RitTraff?
            if let h = visibleHits(NSPoint(x: q.x, y: q.y)).first.map(decode) {
                let leaf = h.leafId.flatMap { leaves[$0] }
                let local = h.world - (leaf.map(offset(of:)) ?? .zero)
                t = RitTraff(del: h.del ?? (leaf == nil ? "skanning" : nil), objekt: leaf?.multi == true ? leaf?.id : nil, yta: h.face,
                             punkt: dd(local), normal: h.normal.map(dd))
            }
            prov.append(RitProv(px: [Double(q.x), H - Double(q.y)].map { ($0 * 10).rounded() / 10 }, strale: dd(dir).map { ($0 * 1e4).rounded() / 1e4 },
                                plan: dd(pl), traff: t))
        }
        provAt(pts[0])
        var acc: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst()) {
            let seg = hypot(b.x - a.x, b.y - a.y)
            var s: CGFloat = 6 - acc
            while s <= seg { provAt(CGPoint(x: a.x + (b.x - a.x) * s / seg, y: a.y + (b.y - a.y) * s / seg)); s += 6 }
            acc = (acc + seg).truncatingRemainder(dividingBy: 6)
        }
        if let l = pts.last { provAt(l) }
        let linje = pts.compactMap(ritPaPlan).map(dd)
        let nyRitning = run.ritning == nil || run.ritning!.id != r.id
        if nyRitning && run.ritning != nil { run.toast = "Ny vy – ny ritning. Den förra (inte skickad) får du tillbaka med ⌘Z." }
        run.noteChange(nyRitning ? "Rita" : "Streck", immediate: true)
        r.streck.append(RitStreck(rak: rak, start: rit.start, prov: prov, linje: linje))
        run.ritning = r
        rit.pending = nil
        run.skrivFokus += 1
        ritSync()
        // bilden tas när strecket syns i vyn
        let key = "\(r.id)#\(r.streck.count)"
        DispatchQueue.main.async { [weak self, weak run] in
            guard let self, let v = self.view, let run else { return }
            SCNTransaction.flush()
            let img = v.snapshot()
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                run.ritBilder[key] = png
                run.ritBildSkala[key] = Double(rep.pixelsWide) / max(Double(v.bounds.width), 1)
                run.objectWillChange.send()   // miniatyren i skrivfältet
            }
        }
    }

    // MARK: Visning (väntande ritning + en skickad ritning som visas)

    func ritNod(_ pts: [V3], mmPerPx: Double, alpha: CGFloat) -> SCNNode {
        let m = SCNMaterial()
        m.diffuse.contents = Self.pennFarg.withAlphaComponent(alpha)
        m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false; m.isDoubleSided = true
        let n = SCNNode()
        if let g = Ror.geometry(pts, radius: Float(mmPerPx) * 1.4) { g.materials = [m]; n.geometry = g }
        // runda ändar
        for p in [pts.first, pts.last].compactMap({ $0 }) {
            let s = SCNSphere(radius: CGFloat(mmPerPx) * 1.4); s.materials = [m]
            let sn = SCNNode(geometry: s); sn.simdPosition = p; n.addChildNode(sn)
        }
        n.renderingOrder = 104
        setMarkMask(n)
        return n
    }

    func ritSync() {
        guard let run, let root = view?.scene?.rootNode else { return }
        if rit.rot.parent !== root { root.addChildNode(rit.rot); rit.nyckel = "" }
        let key = [run.ritning.map { "\($0.id)#\($0.streck.count)" } ?? "-", run.visadRitning?.id ?? "-"].joined(separator: "|")
        guard key != rit.nyckel else { return }
        rit.nyckel = key
        rit.rot.childNodes.forEach { $0.removeFromParentNode() }
        for (r, alpha) in [(run.visadRitning, 0.55), (run.ritning, 1.0)] {
            guard let r, r.kamera_fram.count == 3 else { continue }
            let node = RitNod()
            node.fram = V3(Float(r.kamera_fram[0]), Float(r.kamera_fram[1]), Float(r.kamera_fram[2]))
            for s in r.streck {
                let pts = s.linje.filter { $0.count == 3 }.map { V3(Float($0[0]), Float($0[1]), Float($0[2])) }
                if pts.count >= 2 { node.addChildNode(ritNod(pts, mmPerPx: r.mm_per_px, alpha: CGFloat(alpha))) }
            }
            rit.rot.addChildNode(node)
        }
        ritTona()
    }

    /// Strecken gäller från ritvyn: synliga inom ~1,5°, borta vid ~10° (anropas varje bildruta).
    func ritTona() {
        guard let pov = view?.pointOfView else { return }
        let f = simd_normalize(pov.simdWorldFront)
        for case let n as RitNod in rit.rot.childNodes {
            let a = acos(max(-1, min(1, simd_dot(f, simd_normalize(n.fram))))) * 180 / .pi
            let o = CGFloat(max(0, min(1, 1 - (a - 1.5) / 8.5)))
            if abs(n.opacity - o) > 0.01 { n.opacity = o }
        }
    }

    /// Kameran tillbaka till ritvyn (eller fotot den ritades på).
    func ritFlygTill(_ r: Ritning) {
        if let f = r.foto, let fi = photos.first(where: { $0.bild == f }) { snap(fi, animated: true); return }
        leavePhoto()
        guard r.kamera.count == 16, let pov = view?.pointOfView else { return }
        let k = r.kamera.map { Float($0) }
        if r.mal.count == 3 { target = V3(Float(r.mal[0]), Float(r.mal[1]), Float(r.mal[2])) }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        pov.simdTransform = simd_float4x4(columns: (SIMD4(k[0], k[1], k[2], k[3]), SIMD4(k[4], k[5], k[6], k[7]),
                                                     SIMD4(k[8], k[9], k[10], k[11]), SIMD4(k[12], k[13], k[14], k[15])))
        SCNTransaction.commit()
        syncFromPov()
    }
}
