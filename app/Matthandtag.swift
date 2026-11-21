// Måtthandtag i 3D-vyn: parametriska mått (del-skriptens prj.parametrar) får ett handtag på delen när den är vald (Välj).
// Dra handtaget längs måttet eller klicka för att skriva in ett värde – delen byggs om. Var handtaget sitter kommer från
// prj.mattlinje i skriptet; saknas den används känslighetsbygget (cad/kanslighet.py): ytan som flyttas mest när måttet
// ändras. Medan musen står på ett handtag (eller på måttet i Mått-listan) färgas allt som ändras med måttet – även i
// andra delar – så att relationerna syns.
import AppKit
import SceneKit
import simd

struct Handtag {
    let namn: String
    let kort: String
    let enhet: String?
    let varde: Double            // värdet som visas (väntande värde medan delen byggs om)
    let del: String
    let fran: V3?                // måttlinjens start (lokalt i delen); nil = automatiskt handtag (bara pil)
    let till: V3                 // handtagets läge (lokalt)
    let dir: V3                  // riktningen handtaget dras i (enhetsvektor)
    let faktor: Float            // ändring av måttet per mm handtaget flyttas
    let auto: Bool
}

struct HandtagDrag {
    let h: Handtag
    let start: Double
    let u: SIMD2<Float>          // skärmförflyttning (px) per mm längs måttet
    var mm: Float = 0            // hur långt handtaget dragits (mm, längs dir)
    var px: Float = 0            // hur långt musen rört sig (för att skilja klick från drag)
    var varde: Double
}

extension ModelView.Coordinator {
    // MARK: Vilka handtag

    func beraknaHandtag() -> [Handtag] {
        guard let run, run.canEdit, tool == .valj, snapped == nil, !run.snittPlaceras, let cad = run.cad else { return [] }
        let sel = run.selectedPart, rel = run.relParam, dragNamn = handtagDrag?.h.namn
        if sel == nil && rel == nil && dragNamn == nil { return [] }
        var ut: [Handtag] = []
        for p in cad.parametrar ?? [] {
            guard let v0 = p.varde, p.grupp != nil, p.enhet != "st" else { continue }
            func visa(_ del: String?) -> Bool { (sel != nil && del == sel) || p.namn == rel || p.namn == dragNamn }
            let g = p.grupp ?? ""
            let kort = p.namn.hasPrefix(g + ": ") ? String(p.namn.dropFirst(g.count + 2)) : p.namn
            // väntande värde (handtaget släpptes, bygget pågår): visa det nya
            var v = v0
            if let pv = vantandeVarden[p.namn] { if abs(pv - v0) < 1e-6 { vantandeVarden[p.namn] = nil } else { v = pv } }
            if let m = cad.mattlinjer?.first(where: { $0.namn == p.namn }), m.fran.count == 3, m.till.count == 3 {
                let del = m.del ?? sel ?? ""
                guard visa(del), leaves.values.contains(where: { $0.del == del }) else { continue }
                let a = f3(SIMD3(m.fran[0], m.fran[1], m.fran[2])), b = f3(SIMD3(m.till[0], m.till[1], m.till[2]))
                let l = simd_length(b - a)
                guard l > 1e-4 else { continue }
                let dir = (b - a) / l
                let f = Float(m.faktor ?? 1)
                let flytt = dir * Float(v - v0) / f
                ut.append(Handtag(namn: p.namn, kort: kort, enhet: p.enhet, varde: v, del: del, fran: a, till: b + flytt,
                                  dir: dir, faktor: f, auto: false))
            } else if let k = run.kanslighet?.parametrar[p.namn], let delar = k.delar, !delar.isEmpty {
                let del = sel.flatMap { delar[$0] != nil ? $0 : nil } ?? delar.max { $0.value.max < $1.value.max }!.key
                guard visa(del), let d = delar[del], let pd = partData[del] else { continue }
                // ytan som flyttas mest (plana ytor först: där sitter ett handtag naturligt)
                var bast: (V3, V3, Float)?
                for (fid, vv) in d.ytor where vv.count == 3 {
                    guard let id = Int(fid), let face = pd.faces[id], let c = face.centrum else { continue }
                    let vec = V3(Float(vv[0]), Float(vv[1]), Float(vv[2]))
                    let l = simd_length(vec) * (face.isPlane ? 1.2 : 1)
                    if bast == nil || l > bast!.2 { bast = (c, vec, l) }
                }
                guard let (c, vec, _) = bast, simd_length(vec) >= 0.2 else { continue }
                let dir = simd_normalize(vec)
                let f = 1 / simd_length(vec)
                ut.append(Handtag(namn: p.namn, kort: kort, enhet: p.enhet, varde: v, del: del, fran: nil,
                                  till: c + dir * Float(v - v0) / f, dir: dir, faktor: f, auto: true))
            }
        }
        return ut
    }

    /// Delens förskjutning i vyn (flytt/sprängvy), så att handtagen följer med.
    func delForskjutning(_ del: String) -> V3 {
        if let n = partNodes[del], leaves[del] == nil { return n.simdWorldPosition }
        return leaves.values.first(where: { $0.del == del }).map(offset(of:)) ?? .zero
    }

    // MARK: Ritning

    func ritaHandtag(force: Bool = false) {
        guard let root = view?.scene?.rootNode else { return }
        if overlay.parent !== root { root.addChildNode(overlay) }
        var hs = beraknaHandtag()
        if let d = handtagDrag, let i = hs.firstIndex(where: { $0.namn == d.h.namn }) {
            let h = hs[i]
            hs[i] = Handtag(namn: h.namn, kort: h.kort, enhet: h.enhet, varde: d.varde, del: h.del, fran: h.fran,
                            till: d.h.till + d.h.dir * Float(d.varde - d.start) / d.h.faktor, dir: h.dir, faktor: h.faktor, auto: h.auto)
        }
        // hovern följer måttets namn, inte platsen i listan (listan ändras med val, projekt och bygge)
        let hNy = hoverNamn.flatMap { n in hs.firstIndex { $0.namn == n } }
        if hNy != hoverHandtag { hoverHandtag = hNy; if hNy == nil { hoverNamn = nil }; DispatchQueue.main.async { [weak self] in self?.visaRelation() } }
        let key = hs.map { "\($0.namn)=\($0.varde)@\($0.till)" }.joined(separator: ",") + "|\(hoverHandtag ?? -1)|\(layoutKey)"
        guard force || key != handtagKey else { return }
        handtagKey = key
        handtag = hs
        handtagNode.removeFromParentNode()
        handtagNode = SCNNode()
        handtagScaled = []
        handtagEtiketter = []
        guard !hs.isEmpty else { return }
        let bla = NSColor.systemBlue, lila = NSColor.systemIndigo
        func mat(_ c: NSColor) -> SCNMaterial { let x = SCNMaterial(); x.diffuse.contents = c; x.lightingModel = .constant; x.readsFromDepthBuffer = false; x.isDoubleSided = true; return x }
        let alla = hs.count <= 3
        for (i, h) in hs.enumerated() {
            let off = delForskjutning(h.del)
            let farg = h.auto ? lila : bla
            let b = h.till + off
            if let a0 = h.fran {
                let a = a0 + off
                let len = simd_length(b - a)
                if len > 1e-4 {
                    let cyl = SCNCylinder(radius: 1, height: CGFloat(len)); cyl.materials = [mat(farg.withAlphaComponent(0.85))]
                    let n = SCNNode(geometry: cyl); n.simdPosition = (a + b) / 2
                    n.look(at: sv(b), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 1, 0)); n.renderingOrder = 110
                    handtagNode.addChildNode(n); handtagScaled.append((n, -1.0))
                }
                let s = SCNSphere(radius: 1); s.materials = [mat(farg)]
                let e = SCNNode(geometry: s); e.simdPosition = a; e.renderingOrder = 111
                handtagNode.addChildNode(e); handtagScaled.append((e, 2.5))
            } else {
                // automatiskt handtag: en kort pil i dragriktningen
                let kon = SCNCone(topRadius: 0, bottomRadius: 0.9, height: 2.2); kon.materials = [mat(farg)]
                let n = SCNNode(geometry: kon); n.renderingOrder = 112
                n.simdOrientation = simd_quatf(from: V3(0, 1, 0), to: h.dir)
                n.simdPosition = h.dir * 2.4
                let holder = SCNNode(); holder.simdPosition = b
                holder.addChildNode(n)
                handtagNode.addChildNode(holder); handtagScaled.append((holder, 4))
            }
            let s = SCNSphere(radius: 1); s.materials = [mat(hoverHandtag == i ? NSColor.systemOrange : farg)]
            let knopp = SCNNode(geometry: s); knopp.simdPosition = b; knopp.renderingOrder = 113
            handtagNode.addChildNode(knopp); handtagScaled.append((knopp, hoverHandtag == i ? 7.5 : 5.5))
            // etikett "bredd 52,5 mm": alltid när handtagen är få, annars för handtaget under musen/som dras/i Mått-listan
            let visa = alla || hoverHandtag == i || h.namn == handtagDrag?.h.namn || h.namn == run?.relParam
            guard visa else { handtagEtiketter.append((i, b, .zero, .zero, nil)); continue }
            let text = "\(h.kort) \(ParamStyle.format(h.varde, unit: h.enhet))\(h.enhet.map { " \($0)" } ?? "")"
            let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
            let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: hoverHandtag == i ? NSColor.systemOrange : farg]
            let ts = (text as NSString).size(withAttributes: attr)
            let W = ceil(ts.width + 22), H = ceil(ts.height + 12)
            let img = NSImage(size: NSSize(width: W, height: H))
            img.lockFocus()
            NSColor(white: 1, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H), xRadius: H * 0.3, yRadius: H * 0.3).fill()
            (text as NSString).draw(at: NSPoint(x: 11, y: 6), withAttributes: attr)
            img.unlockFocus()
            let w = Float(W / 2), hh = Float(H / 2)                     // px på skärmen (bilden ritas i dubbel upplösning)
            let plan = SCNPlane(width: CGFloat(w), height: CGFloat(hh))
            let pm = mat(.white); pm.diffuse.contents = img; pm.transparencyMode = .aOne; plan.materials = [pm]
            let pn = SCNNode(geometry: plan); pn.renderingOrder = 114
            let dx = w / 2 + 10, dy: Float = 0
            pn.simdPosition = V3(dx, dy, 0)
            let holder = SCNNode(); holder.simdPosition = b; holder.constraints = [SCNBillboardConstraint()]
            holder.addChildNode(pn)
            handtagNode.addChildNode(holder); handtagScaled.append((holder, 1))
            handtagEtiketter.append((i, b, SIMD2(dx, dy), SIMD2(w, hh), pn))
        }
        setMarkMask(handtagNode)
        overlay.addChildNode(handtagNode)
        updateOverlayScale()
    }

    /// Etiketterna får inte täcka varandra: den översta står kvar, de andra flyttas nedåt tills de är fria (per bildruta).
    func placeraHandtagEtiketter() {
        guard let v = view, handtagEtiketter.contains(where: { $0.4 != nil }) else { return }
        var lagda: [(SIMD2<Float>, SIMD2<Float>)] = []
        let ordning = handtagEtiketter.indices.filter { handtagEtiketter[$0].4 != nil }
            .map { k -> (Int, SIMD2<Float>) in let s = v.projectPoint(sv(handtagEtiketter[k].1)); return (k, SIMD2(Float(s.x), Float(s.y))) }
            .sorted { $0.1.y > $1.1.y }
        for (k, s) in ordning {
            let e = handtagEtiketter[k]
            var off = SIMD2<Float>(e.3.x / 2 + 10, 0)
            func krock(_ o: SIMD2<Float>) -> Bool {
                let c = s + o
                return lagda.contains { abs($0.0.x - c.x) < ($0.1.x + e.3.x) / 2 + 2 && abs($0.0.y - c.y) < ($0.1.y + e.3.y) / 2 + 2 }
            }
            var n = 0
            while krock(off) && n < 30 { off.y -= e.3.y + 3; n += 1 }
            lagda.append((s + off, e.3))
            handtagEtiketter[k].2 = off
            e.4?.simdPosition = V3(off.x, off.y, 0)
        }
    }

    // MARK: Träff

    /// Handtaget (eller dess etikett) under pekaren, i vyns koordinater.
    func handtagVid(_ p: NSPoint) -> Int? {
        guard let v = view, !handtag.isEmpty else { return nil }
        let q = SIMD2<Float>(Float(p.x), Float(p.y))
        var bast: (Int, Float)?
        for (i, w, off, size, etikett) in handtagEtiketter {
            let s = v.projectPoint(sv(w))
            guard s.z > 0, s.z < 1 else { continue }
            let c = SIMD2<Float>(Float(s.x), Float(s.y))
            let d = simd_length(q - c)
            if d <= 10, bast == nil || d < bast!.1 { bast = (i, d) }
            let lc = c + off
            if etikett != nil, abs(q.x - lc.x) <= size.x / 2, abs(q.y - lc.y) <= size.y / 2, bast == nil { bast = (i, 11) }
        }
        return bast?.0
    }

    // MARK: Hover och relationer

    func setHoverHandtag(_ i: Int?) {
        guard i != hoverHandtag else { return }
        hoverHandtag = i
        hoverNamn = i.flatMap { $0 < handtag.count ? handtag[$0].namn : nil }
        visaRelation()
        ritaHandtag(force: true)
    }

    /// Färga allt som ändras med måttet (dras, hovras eller hovras i Mått-listan).
    func visaRelation() {
        let namn = handtagDrag?.h.namn ?? hoverHandtag.flatMap { $0 < handtag.count ? handtag[$0].namn : nil } ?? run?.relParam
        var nya = Set<String>()
        if let namn, let k = run?.kanslighet?.parametrar[namn], let delar = k.delar {
            for (del, d) in delar {
                for (fid, v) in d.ytor where v.count == 3 && simd_length(SIMD3(v[0], v[1], v[2])) >= 0.05 { nya.insert("\(del):\(fid)") }
            }
        }
        guard nya != relYtor else { return }
        let andrade = nya.symmetricDifference(relYtor)
        relYtor = nya
        partsRoot.enumerateHierarchy { n, _ in if let k = faceKey(n), andrade.contains(k) { restyle(n) } }
    }

    func handtagTips(_ i: Int) -> String {
        let h = handtag[i]
        var s = "\(h.kort): \(ParamStyle.format(h.varde, unit: h.enhet)) \(h.enhet ?? "") – dra för att ändra (⇧ hela mm), klicka för att skriva in"
        if let k = run?.kanslighet?.parametrar[h.namn] {
            if let fel = k.fel { s += "\nKunde inte räkna ut vad som ändras: \(fel)" }
            let delar = (k.delar ?? [:]).sorted { $0.value.max > $1.value.max }
            if !delar.isEmpty {
                s += "\nÄndrar (färgat): " + delar.map { d in
                    (partNames[d.key] ?? d.key) + " \(ParamStyle.format(d.value.max, unit: "mm")) mm per \(h.enhet ?? "mm")"
                        + (d.value.ny_form == true ? ", ny form" : "")
                }.joined(separator: " · ")
            }
        } else if run?.kanslighetKor == true {
            s += "\nRäknar ut vad måttet påverkar …"
        }
        if h.auto { s += "\n(handtaget sitter där delen ändras mest – skriptet saknar måttlinje)" }
        return s
    }

    // MARK: Dra och klicka

    func beginHandtagDrag(_ p: NSPoint) -> Bool {
        guard tool == .valj, let i = handtagVid(p), let v = view else { return false }
        let h = handtag[i]
        let w = h.till + delForskjutning(h.del)
        let s0 = v.projectPoint(sv(w)), s1 = v.projectPoint(sv(w + h.dir))
        var u = SIMD2<Float>(Float(s1.x - s0.x), Float(s1.y - s0.y))
        if simd_length(u) < 0.05 { u = SIMD2(0.05, 0) }
        handtagDrag = HandtagDrag(h: h, start: h.varde, u: u, varde: h.varde)
        visaRelation()
        return true
    }

    func dragHandtag(_ dx: CGFloat, _ dy: CGFloat) {
        guard var d = handtagDrag else { return }
        let m = SIMD2<Float>(Float(dx), Float(-dy))      // NSEvent: y nedåt; vyn: y uppåt
        d.px += simd_length(m)
        d.mm += simd_dot(m, d.u) / simd_length_squared(d.u)
        let hel = NSEvent.modifierFlags.contains(.shift)
        let steg: Double = d.h.enhet == "°" ? (hel ? 5 : 1) : (hel ? 1 : 0.5)
        var v = d.start + Double(d.mm * d.h.faktor)
        v = (v / steg).rounded() * steg
        if d.h.enhet != "°" { v = max(v, steg) }
        d.varde = v
        handtagDrag = d
        view?.satTips("\(d.h.kort): \(ParamStyle.format(v, unit: d.h.enhet)) \(d.h.enhet ?? "")  (var \(ParamStyle.format(d.start, unit: d.h.enhet)))")
        ritaHandtag()
    }

    func endHandtagDrag() {
        guard let d = handtagDrag, let run, let v = view else { handtagDrag = nil; return }
        handtagDrag = nil
        if d.px < 3 {
            // klick: inmatningsruta vid handtaget
            let s = v.projectPoint(sv(d.h.till + delForskjutning(d.h.del)))
            run.mattInmatning = MattInmatning(namn: d.h.namn, kort: d.h.kort, varde: d.h.varde, enhet: d.h.enhet,
                                              punkt: CGPoint(x: s.x, y: v.bounds.height - s.y))
        } else if abs(d.varde - d.start) > 1e-9 {
            vantandeVarden[d.h.namn] = d.varde
            run.setParam(d.h.namn, String(d.varde), unit: d.h.enhet)
        }
        visaRelation()
        ritaHandtag(force: true)
    }
}
