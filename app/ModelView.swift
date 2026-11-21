// 3D-vyn: skanning + CAD-delar i SceneKit, egen kamerastyrning (som Bambu Studio), vykub och fotoläge.
import AppKit
import SceneKit
import SwiftUI

struct ModelView: NSViewRepresentable {
    let url: URL?                         // skanningen (nil i modellprojekt utan skanning)
    var run: Runner? = nil                // appens tillstånd: verktyg, mätning, info, flytt, under-objekt (Verktyg.swift)
    var parts: [PartSpec] = []
    var hidden: Set<String> = []          // "skanning" och/eller del-id
    /// Skanningens stil: 0 = textur, 1 = form, 2 = trådnät, 3 = genomskinlig
    let scanStyle: Int
    /// 0 = vit, 1 = grå, 2 = mörk
    let background: Int
    var marks: [CadInfo.Markering] = []
    var selectedFace: String? = nil       // "del:id"
    var photos: [FotoInfo] = []           // pålitliga bildrutor med kamerans läge
    var photoFolder: URL? = nil
    var followPhotos = false
    var overlayOpacity = 0.35
    var cadStyle = 0                      // 0 fyllt, 1 kanter, 2 båda
    var viewRequest: ViewRequest? = nil
    var rotationMode = 0                  // 0 fri (arcball, som Fusions orbit), 1 svarvbord
    var upSign: Float = -1                // −1: −Z upp (skanningar), +1: +Z upp (modellprojekt)
    var section = false                   // snitt på: klipp bort kamerans sida om ett huvudplan
    var partOpacity: [String: Double] = [:]   // opacitet per del (och "skanning")
    var photoOpacity = 1.0                // fotots opacitet i fotoläget
    var selectedPart: String? = nil
    var sectionCoord: Double? = nil       // reglaget i verktygsraden flyttar planet längs sin axel
    var background3D: NSColor { [NSColor.white, NSColor(white: 0.55, alpha: 1), NSColor(white: 0.13, alpha: 1)][background] }
    /// etikett, läge, intervall (modellens utsträckning längs planets axel)
    var onSection: ((String?, Double, ClosedRange<Double>) -> Void)? = nil
    var onSelectPart: ((String?) -> Void)? = nil
    var onSnap: ((FotoInfo?) -> Void)? = nil
    var onNote: ((String?) -> Void)? = nil
    var onFollowChange: ((Bool) -> Void)? = nil
    /// punkt, mål, del, yta, ytatyp, foto, fotopixel
    var onPick: ((SCNVector3, String, String?, Int?, String?, String?, [Double]?) -> Void)? = nil

    final class Coordinator: NSObject, SCNSceneRendererDelegate, NSGestureRecognizerDelegate {
        // upp = −Z (skanningar: skalets öppning) eller +Z (modellprojekt, som i build123d/Bambu Studio)
        var U = SIMD3<Float>(0, 0, -1), E1 = SIMD3<Float>(1, 0, 0), E2 = SIMD3<Float>(0, -1, 0)
        var upSign: Float = -1
        func setUp(_ sign: Float) {
            guard sign != upSign else { return }
            upSign = sign
            U = SIMD3<Float>(0, 0, sign); E2 = SIMD3<Float>(0, sign, 0)
            let names = sign < 0 ? ["BOTTEN", "GAVEL\n+X", "TOPP", "GAVEL\n−X", "SIDA\n+Y", "SIDA\n−Y"]
                                 : ["TOPP", "HÖGER\n+X", "BOTTEN", "VÄNSTER\n−X", "BAK\n+Y", "FRAM\n−Y"]
            (cubeBox.geometry as? SCNBox)?.materials = names.map { Coordinator.faceMaterial($0) }
            if let v = view, v.scene != nil, snapped == nil { syncFromPov(); applyCamera(animated: false) }
        }
        var yaw: Float = -0.6, pitch: Float = 0.6, dist: Float = 200
        var target = SIMD3<Float>(0, 0, 0)
        func dir(_ y: Float, _ p: Float) -> SIMD3<Float> { cos(p) * (cos(y) * E1 + sin(y) * E2) + sin(p) * U }
        func applyCamera(animated: Bool) {
            guard let pov = view?.pointOfView else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.35 : 0
            pov.simdPosition = target + dir(yaw, pitch) * dist
            pov.simdLook(at: target, up: U, localFront: [0, 0, -1])
            SCNTransaction.commit()
        }
        func syncFromPov() {
            guard let pov = view?.pointOfView else { return }
            let v = pov.simdWorldPosition - target
            dist = max(simd_length(v), 1)
            let d = v / dist
            pitch = asin(max(-1, min(1, simd_dot(d, U))))
            yaw = atan2(simd_dot(d, E2), simd_dot(d, E1))
        }
        func leavePhoto() { if snapped != nil { unsnap(); syncFromPov() } }
        func orbit(_ dx: CGFloat, _ dy: CGFloat) {
            if follow, snapped != nil { scrub(dx); return }   // fotoläge: spola i videon
            leavePhoto()
            yaw -= Float(dx) * 0.01
            pitch = max(-1.55, min(1.55, pitch + Float(dy) * 0.01))
            applyCamera(animated: false)
        }
        func pan(_ dx: CGFloat, _ dy: CGFloat) {
            guard let pov = view?.pointOfView, let v = view else { return }
            if follow, snapped != nil { return }                // fotoläge: bilden ligger still
            leavePhoto()
            // en pixel ≈ dist · 2·tan(fov/2) / vyns höjd
            let k = dist * 2 * tan(Float(17 * Double.pi / 180)) / Float(max(v.bounds.height, 1))
            target += -pov.simdWorldRight * Float(dx) * k + pov.simdWorldUp * Float(dy) * k
            applyCamera(animated: false)
        }
        // Paneler släcks/tänds (⇥, Esc): 3D-vyn byter storlek och läge i fönstret. Flytta kameran i takt med det
        // så att modellen ligger still på skärmen i stället för att panorera med vyns mitt.
        private var panelRekt: NSRect?
        private var panelTimer: Timer?
        private var panelObs: NSObjectProtocol?
        func foljPanelbyten() {
            guard panelObs == nil else { return }
            panelObs = NotificationCenter.default.addObserver(forName: Runner.panelerByts, object: nil, queue: .main) { [weak self] _ in
                self?.panelerByts()
            }
        }
        func panelerByts() {
            guard let v = view, v.window != nil else { return }
            panelRekt = v.convert(v.bounds, to: nil)
            // Kompensationen sker i vyns layoutpass (onLayout) – samma pass som storleksbytet, så ingen bild ritas
            // med gammal kamera och ny vy (det var det som fick modellen att darra). Timern städar bara upp efteråt.
            panelTimer?.invalidate()
            panelTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.kompenseraPanelbyte(); self?.panelRekt = nil }
            }
        }
        func kompenseraPanelbyte() {
            guard let v = view, v.window != nil, let pov = v.pointOfView, let r0 = panelRekt, snapped == nil else { return }
            let r1 = v.convert(v.bounds, to: nil)
            guard abs(r1.midX - r0.midX) > 0.01 || abs(r1.midY - r0.midY) > 0.01 else { return }
            panelRekt = r1
            let dx = Float(r0.midX - r1.midX), dy = Float(r0.midY - r1.midY)
            let k = dist * 2 * tan(Float(17 * Double.pi / 180)) / Float(max(v.bounds.height, 1))
            target -= pov.simdWorldRight * dx * k + pov.simdWorldUp * dy * k
            applyCamera(animated: false)
        }
        func zoom(_ amount: CGFloat, at p: NSPoint? = nil) {
            if follow, snapped != nil { return }
            leavePhoto()
            let old = dist
            dist = max(radius * 0.25, min(radius * 25, dist * exp(-Float(amount))))
            // mot pekaren: punkten under pekaren (i planet genom målet) ligger kvar under pekaren
            if let p, let v = view, old > 0 {
                let z = v.projectPoint(sv(target)).z
                let under = v3(v.unprojectPoint(SCNVector3(p.x, p.y, z)))
                target = under + (target - under) * (dist / old)
            }
            applyCamera(animated: false)
        }
        /// Avstånd så att hela modellen (en sfär med radius) ryms både på höjden och bredden i vyn.
        func fitDistance() -> Float {
            let size = view?.bounds.size ?? CGSize(width: 4, height: 3)
            let aspect = Float(max(size.width, 1) / max(size.height, 1))
            let half = Float(17 * Double.pi / 180)                      // fieldOfView 34° (lodrätt)
            let hHalf = atan(tan(half) * aspect)
            return radius / sin(min(half, hHalf)) * 1.08
        }
        func fitView() {
            leavePhoto()
            target = center; dist = fitDistance()
            applyCamera(animated: true)
        }
        /// Klick inne i vykuben ska bara gå till kuben, inte bli en nål i modellen.
        func gestureRecognizerShouldBegin(_ g: NSGestureRecognizer) -> Bool {
            guard let cv = cubeView, let v = view else { return true }
            return !cv.frame.contains(g.location(in: v))
        }
        weak var view: SCNView?
        var onPick: ((SCNVector3, String, String?, Int?, String?, String?, [Double]?) -> Void)?
        // --- vykub
        var cubeView: SCNView?
        let cubeCam = SCNNode()
        let cubeBox = SCNNode()
        let cubeDots = SCNNode()
        var dotsKey = ""
        func setupCube(on v: SCNView) {
            let size: CGFloat = 132
            let cv = SCNView(frame: NSRect(x: v.bounds.width - size - 8, y: v.bounds.height - size - 8, width: size, height: size))
            cv.autoresizingMask = [.minXMargin, .minYMargin]
            cv.backgroundColor = .clear
            cv.autoenablesDefaultLighting = true
            cv.antialiasingMode = .multisampling4X
            let scene = SCNScene()
            let box = SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0.12)
            // SCNBox-ordning: +Z, +X, −Z, −X, +Y, −Y  (öppningen = −Z = TOPP)
            box.materials = ["BOTTEN", "GAVEL\n+X", "TOPP", "GAVEL\n−X", "SIDA\n+Y", "SIDA\n−Y"].map { Coordinator.faceMaterial($0) }
            cubeBox.geometry = box
            scene.rootNode.addChildNode(cubeBox)
            scene.rootNode.addChildNode(cubeDots)
            let cam = SCNCamera(); cam.usesOrthographicProjection = true; cam.orthographicScale = 2.9
            cubeCam.camera = cam
            scene.rootNode.addChildNode(cubeCam)
            cv.scene = scene
            cv.pointOfView = cubeCam
            let click = NSClickGestureRecognizer(target: self, action: #selector(cubeClicked(_:)))
            cv.addGestureRecognizer(click)
            let tv = TipsVy(frame: cv.bounds); tv.autoresizingMask = [.width, .height]
            tv.text = "Klicka en sida för vyn, eller en prick för det fotot"; cv.addSubview(tv)
            v.addSubview(cv)
            cubeView = cv
        }
        static func faceMaterial(_ text: String) -> SCNMaterial {
            let img = NSImage(size: NSSize(width: 256, height: 256))
            img.lockFocus()
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 256, height: 256).fill()
            NSColor(white: 0.6, alpha: 1).setStroke(); let p = NSBezierPath(rect: NSRect(x: 4, y: 4, width: 248, height: 248)); p.lineWidth = 6; p.stroke()
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 50, weight: .bold), .foregroundColor: NSColor(white: 0.25, alpha: 1), .paragraphStyle: para]
            let lines = text.components(separatedBy: "\n").count
            NSAttributedString(string: text, attributes: attr).draw(in: NSRect(x: 0, y: 128 - CGFloat(lines) * 32, width: 256, height: CGFloat(lines) * 64))
            img.unlockFocus()
            let m = SCNMaterial(); m.diffuse.contents = img; m.lightingModel = .lambert
            return m
        }
        func updateDots() {
            let key = photos.map(\.bild).joined() + "|" + (snapped?.bild ?? "")
            guard key != dotsKey else { return }
            dotsKey = key
            cubeDots.childNodes.forEach { $0.removeFromParentNode() }
            for f in photos where f.K != nil {
                let p = SIMD3<Float>(pose(f).columns.3.x, pose(f).columns.3.y, pose(f).columns.3.z)
                let d = simd_normalize(p - center)
                let isSnap = f.bild == snapped?.bild
                let g = SCNSphere(radius: isSnap ? 0.16 : (f.vy != nil ? 0.11 : 0.075))
                let m = SCNMaterial(); m.lightingModel = .constant
                m.diffuse.contents = isSnap ? NSColor.systemRed : (f.vy != nil ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.55))
                g.materials = [m]
                let n = SCNNode(geometry: g); n.simdPosition = d * 1.85; n.name = "foto:" + f.bild
                cubeDots.addChildNode(n)
            }
        }
        @objc func cubeClicked(_ g: NSClickGestureRecognizer) {
            guard let cv = cubeView, g.state == .ended else { return }
            let hits = cv.hitTest(g.location(in: cv), options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let h = hits.first else { return }
            if let name = h.node.name, name.hasPrefix("foto:") { goTo(name); return }
            if h.node === cubeBox {
                let n = h.localNormal
                let names: [(Float, String)] = [(Float(n.z) * -upSign, "Botten"), (Float(n.z) * upSign, "Topp"), (Float(n.x), "+X"), (Float(-n.x), "−X"), (Float(n.y), "+Y"), (Float(-n.y), "−Y")]
                if let best = names.max(by: { $0.0 < $1.0 }) { goTo(best.1) }
            }
        }
        /// Vykuben följer huvudkamerans vridning varje bildruta.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let pov = renderer.pointOfView else { return }
            let o = pov.simdWorldOrientation
            cubeCam.simdOrientation = o
            cubeCam.simdPosition = simd_act(o, SIMD3<Float>(0, 0, 6))
            updateOverlayScale()
            ritTona()
        }
        // --- foton
        var photos: [FotoInfo] = []
        var folder: URL?
        var follow = false
        var opacity = 0.35
        var cadStyle = -1
        var snapped: FotoInfo?
        var onSnap: ((FotoInfo?) -> Void)?
        var lastRequest: UUID?
        var images: [String: NSImage] = [:]
        var edgeNodes: [String: SCNNode] = [:]
        var fit: (axis: Int, f: Double) = (0, 1)
        var photoPlane = SCNNode()
        /// Fotot som en platta i kamerans ram, så stor och förskjuten att den täcker exakt kamerans bild (samma projektion som CAD).
        static func makePhotoPlane(_ f: FotoInfo, image: NSImage?) -> SCNNode {
            guard let K = f.K else { return SCNNode() }
            let (fx, fy, cx, cy) = (K[0][0], K[1][1], K[0][2], K[1][2])
            let d = 4000.0
            let plane = SCNPlane(width: CGFloat(f.bredd * d / fx), height: CGFloat(f.hojd * d / fy))
            let m = SCNMaterial()
            m.diffuse.contents = image
            m.lightingModel = .constant
            m.writesToDepthBuffer = false
            m.readsFromDepthBuffer = false
            plane.materials = [m]
            let n = SCNNode(geometry: plane)
            n.name = "fotoplatta"
            n.position = SCNVector3((f.bredd / 2 - cx) * d / fx, (cy - f.hojd / 2) * d / fy, -d)
            n.renderingOrder = -1000
            return n
        }
        var center = SIMD3<Float>(0, 0, 0)
        var radius: Float = 100

        func pose(_ f: FotoInfo) -> simd_float4x4 {
            let T = f.kamera_till_modell
            return simd_float4x4(columns: (
                SIMD4<Float>(Float(T[0][0]), Float(T[1][0]), Float(T[2][0]), 0),
                SIMD4<Float>(Float(T[0][1]), Float(T[1][1]), Float(T[2][1]), 0),
                SIMD4<Float>(Float(T[0][2]), Float(T[1][2]), Float(T[2][2]), 0),
                SIMD4<Float>(Float(T[0][3]), Float(T[1][3]), Float(T[2][3]), 1)))
        }
        func normalCamera() -> SCNCamera {
            let c = SCNCamera(); c.fieldOfView = 34; c.zNear = 1; c.zFar = 5000; return c
        }
        /// Projektion ur intrinsics, anpassad så att hela fotot syns i vyn utan att förvrängas (svarta kanter vid behov).
        func photoCamera(_ f: FotoInfo, view: CGSize) -> SCNCamera {
            let cam = SCNCamera()
            guard let K = f.K, view.width > 0, view.height > 0 else { return cam }
            let (fx, fy, cx, cy) = (K[0][0], K[1][1], K[0][2], K[1][2])
            let (W, H, n, fr) = (f.bredd, f.hojd, 1.0, 5000.0)
            let av = Double(view.width / view.height), ap = W / H
            fit = av > ap ? (0, ap / av) : (1, av / ap)
            var P = SCNMatrix4()
            P.m11 = CGFloat(2 * fx / W); P.m22 = CGFloat(2 * fy / H)
            P.m31 = CGFloat(1 - 2 * cx / W); P.m32 = CGFloat(2 * cy / H - 1)
            if fit.axis == 0 { P.m11 *= CGFloat(fit.f); P.m31 *= CGFloat(fit.f) } else { P.m22 *= CGFloat(fit.f); P.m32 *= CGFloat(fit.f) }
            P.m33 = CGFloat(-(fr + n) / (fr - n)); P.m34 = -1; P.m43 = CGFloat(-2 * fr * n / (fr - n)); P.m44 = 0
            cam.projectionTransform = P
            return cam
        }
        func snap(_ f: FotoInfo, animated: Bool) {
            guard let v = view, let pov = v.pointOfView, let scene = v.scene, let folder else { return }
            let key = f.bild
            if images[key] == nil {
                images[key] = Coordinator.loadImage(folder.appendingPathComponent(f.bild))
                imageOrder.append(key)
                if imageOrder.count > 40 { images[imageOrder.removeFirst()] = nil }
            }
            pov.camera = photoCamera(f, view: v.bounds.size)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.35 : 0
            pov.simdTransform = pose(f)
            SCNTransaction.commit()
            _ = scene
            photoPlane.removeFromParentNode()
            photoPlane = Coordinator.makePhotoPlane(f, image: images[key])
            photoPlane.geometry?.firstMaterial?.transparency = CGFloat(photoOpacity)
            pov.addChildNode(photoPlane)
            v.backgroundColor = photoOpacity < 0.999 ? bgColor : .black
            snapped = f
            restyleParts()
            updateDots()
            onSnap?(f)
        }
        var imageOrder: [String] = []
        /// Förminskad bild (snabb att läsa och visa) – räcker för skärmen.
        static func loadImage(_ url: URL) -> NSImage? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                                         kCGImageSourceCreateThumbnailWithTransform: false]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        // --- fotoläge: dra = spola i videon
        var scrubAcc: CGFloat = 0
        var scrubDir = 0
        var onNote: ((String?) -> Void)?
        func yawOf(_ f: FotoInfo) -> Float {
            let p = SIMD3<Float>(pose(f).columns.3.x, pose(f).columns.3.y, pose(f).columns.3.z) - center
            return atan2(simd_dot(p, E2), simd_dot(p, E1))
        }
        /// Ett steg i filmen åt det håll som motsvarar att vrida modellen som dx (dx>0 = som orbit åt höger).
        func scrub(_ dx: CGFloat) {
            guard let cur = snapped, let i = photos.firstIndex(of: cur), photos.count > 1 else { return }
            scrubAcc += dx
            let stepPx: CGFloat = 7
            guard abs(scrubAcc) >= stepPx else { return }
            let n = Int(abs(scrubAcc) / stepPx) * (scrubAcc > 0 ? 1 : -1)
            scrubAcc -= CGFloat(n) * stepPx
            // åt vilket håll i filmen motsvarar "dra åt höger"? orbit(dx>0) minskar yaw → välj riktningen där yaw minskar.
            // Räknas över ±6 bilder och låses under hela dragningen (annars vänder bruset riktningen).
            scrubDir = 1   // ren spolning: dra åt höger = framåt i filmen, åt vänster = bakåt
            let forward = scrubDir
            let ni = max(0, min(photos.count - 1, i + n * forward))
            if ni != i { snap(photos[ni], animated: false); onNote?(nil) }
        }
        func enterPhotoMode() {
            guard let pov = view?.pointOfView, !photos.isEmpty else { onNote?("Inga bildrutor med kameraläge för den här skanningen"); return }
            let dir = simd_normalize(pov.simdWorldPosition - center)
            if let f = nearest(from: dir, maxAngle: 180) { snap(f, animated: true); noteAngle(f, dir) }
        }
        func noteAngle(_ f: FotoInfo, _ dir: SIMD3<Float>) {
            let p = SIMD3<Float>(pose(f).columns.3.x, pose(f).columns.3.y, pose(f).columns.3.z)
            let a = acos(max(-1, min(1, simd_dot(simd_normalize(p - center), dir)))) * 180 / .pi
            onNote?(a > 20 ? String(format: "Närmaste bild är %.0f° från den vyn", a) : nil)
        }
        func unsnap() {
            guard snapped != nil, let v = view else { return }
            snapped = nil
            photoPlane.removeFromParentNode()
            v.pointOfView?.camera = normalCamera()
            restyleParts()
            updateDots()
            onSnap?(nil)
        }
        func nearest(from dir: SIMD3<Float>, maxAngle: Float = 25) -> FotoInfo? {
            var best: (FotoInfo, Float)?
            for f in photos where f.K != nil {
                let p = SIMD3<Float>(pose(f).columns.3.x, pose(f).columns.3.y, pose(f).columns.3.z)
                let d = simd_normalize(p - center)
                let a = acos(max(-1, min(1, simd_dot(d, dir)))) * 180 / .pi
                if best == nil || a < best!.1 { best = (f, a) }
            }
            guard let b = best, b.1 <= maxAngle else { return nil }
            return b.0
        }
        func snapToNearest(animated: Bool) {
            guard follow, let pov = view?.pointOfView else { return }
            let dir = simd_normalize(pov.simdWorldPosition - center)
            if let f = nearest(from: dir) { snap(f, animated: animated) }
        }
        func dragStarted() { scrubAcc = 0; scrubDir = 0; if !(follow && snapped != nil) { leavePhoto() } }
        func dragEnded() { if follow && snapped == nil { enterPhotoMode() } }   // inga hopp när man släpper i fotoläget
        /// Ytornas genomskinlighet och kanternas synlighet efter stil och om ett foto visas.
        func restyleParts() {
            let faces = cadStyle != 1
            for leaf in leaves.values {
                let m = leaf.mat
                m.transparency = CGFloat(partOpacity[(snapped != nil ? "foto/" : "3d/") + leaf.del] ?? (snapped != nil ? opacity : 1))
                m.colorBufferWriteMask = faces ? .all : []
                let sel = selectedLeaf != nil ? leaf.id == selectedLeaf : leaf.del == selectedPart
                m.emission.contents = sel ? NSColor(white: 0.22, alpha: 1) : NSColor.black
            }
            scan.opacity = CGFloat(partOpacity["3d/skanning"] ?? 1)
            (photoPlane.geometry?.firstMaterial)?.transparency = CGFloat(photoOpacity)
            if snapped != nil { view?.backgroundColor = photoOpacity < 0.999 ? bgColor : .black }
            for (_, n) in edgeNodes { n.isHidden = cadStyle == 0 }
            scan.isHidden = snapped != nil || scanHiddenByUser
        }
        var scanHiddenByUser = false
        var onFollowChange: ((Bool) -> Void)?
        func goTo(_ name: String) {
            if name == "lämna-foto" { unsnap(); syncFromPov(); follow = false; onFollowChange?(false); onNote?(nil); return }
            if name.hasPrefix("foto:"), let f = photos.first(where: { $0.bild == String(name.dropFirst(5)) }) {
                if !follow { follow = true; onFollowChange?(true) }   // pricken/pilarna = fotoläge, knappen ska visa det
                snap(f, animated: true); return
            }
            let views: [String: (Float, Float)] = [
                "Topp": (-.pi / 2, 1.55), "Botten": (-.pi / 2, -1.55),
                "+X": (0, 0), "−X": (.pi, 0), "+Y": (-.pi / 2 * -upSign, 0), "−Y": (.pi / 2 * -upSign, 0), "Persp": (-0.6, 0.6)]
            if name == "Hela" { fitView(); return }
            guard let (y, p) = views[name] else { return }
            unsnap()
            yaw = y; pitch = p; target = center; dist = fitDistance()
            if follow, let f = nearest(from: dir(y, p), maxAngle: 180) {
                applyCamera(animated: false); snap(f, animated: true); noteAngle(f, dir(y, p)); return
            }
            onNote?(nil)
            applyCamera(animated: true)
        }
        var faceInfo: [String: String] = [:]       // "del:id" → typ (+ radie)
        var baseMats: [String: SCNMaterial] = [:]  // del → material
        var partNames: [String: String] = [:]
        let hoverMat: SCNMaterial = { let m = SCNMaterial(); m.diffuse.contents = NSColor.systemBlue; m.lightingModel = .blinn; m.isDoubleSided = true; return m }()
        let selMat: SCNMaterial = { let m = SCNMaterial(); m.diffuse.contents = NSColor.systemRed; m.lightingModel = .blinn; m.isDoubleSided = true; return m }()
        weak var hovered: SCNNode?
        var selectedFace: String?
        var marksKey: [CadInfo.Markering] = []
        var marksNode = SCNNode()
        var key = ""
        var scan = SCNNode()
        var partsRoot = SCNNode()
        var partNodes: [String: SCNNode] = [:]
        var originals: [ObjectIdentifier: [SCNMaterial]] = [:]
        var appliedStyle = -1
        var keep: [AnyObject] = []   // håll inlästa scener vid liv så noderna inte pekar på frigjort minne

        func faceNode(_ n: SCNNode) -> SCNNode? { var x: SCNNode? = n; while let y = x { if y.name?.hasPrefix("yta-") == true { return y }; x = y.parent }; return nil }
        /// "yta-<del>:<id>" → ("del", id)
        func faceKey(_ n: SCNNode) -> String? { n.name.map { String($0.dropFirst(4)) } }
        func split(_ k: String) -> (String, Int)? {
            guard let i = k.lastIndex(of: ":"), let id = Int(k[k.index(after: i)...]) else { return nil }
            return (String(k[..<i]), id)
        }
        func restyle(_ n: SCNNode?) {
            guard let n, let k = faceKey(n), split(k) != nil else { return }
            n.geometry?.materials = [k == selectedFace ? selMat : (n === hovered ? hoverMat : (relYtor.contains(k) ? relMat : (leafID(of: n).flatMap { leaves[$0]?.mat } ?? SCNMaterial())))]
        }
        // --- val av del och opacitet
        var partOpacity: [String: Double] = [:]
        var photoOpacity = 1.0
        var bgColor = NSColor.white
        var selectedPart: String?
        var onSelectPart: ((String?) -> Void)?
        func partID(of n: SCNNode) -> String? {
            var x: SCNNode? = n
            while let y = x { if let name = y.name, name.hasPrefix("del-") { return String(name.dropFirst(4)) }; x = y.parent }
            return nil
        }

        // --- snitt
        var sectionOn = false
        var clip = SIMD4<Float>(0, 0, 0, 1)        // (n, d): bort med allt där dot(n, p) − d > 0
        var sectionAxis = 2
        var sectionCoord: Float = 0
        var sectionNode = SCNNode()
        var triCache: [String: [SIMD3<Float>]] = [:]
        var sectionKey = ""
        var onSection: ((String?, Double, ClosedRange<Double>) -> Void)?
        var sectionRange: ClosedRange<Double> = 0...1
        var sectionSign: Float = 1
        var lastSeenCoord: Double?

        // --- 3D-verktyg (3DVerktyg.swift)
        weak var run: Runner?
        var partData: [String: PartData] = [:]
        var leaves: [String: Leaf] = [:]
        var tool: Verktyg = .valj
        var lastTool: Verktyg = .valj
        var overlay = SCNNode()
        var measureNode = SCNNode()
        var scaled: [(SCNNode, Float)] = []
        var snapMarker = SCNNode()
        var hlHover = SCNNode(), hlSel = SCNNode()
        var hoverEdgeKey = "", selEdgeKey = "", matKey = "", layoutKey = ""
        var dragLeaf: Leaf?
        var dragWhole = false
        var dragStart = V3.zero, dragTotal = V3.zero, dragAxis: Int?
        var axelLinje = SCNNode()
        // måtthandtag (Matthandtag.swift)
        var handtag: [Handtag] = []
        var handtagNode = SCNNode()
        var handtagScaled: [(SCNNode, Float)] = []
        var handtagEtiketter: [(Int, V3, SIMD2<Float>, SIMD2<Float>, SCNNode?)] = []   // (index, världsläge, etikettens förskjutning px, storlek px, etikettnod)
        var handtagKey = ""
        var handtagDrag: HandtagDrag?
        var hoverHandtag: Int?
        var hoverNamn: String?
        var vantandeVarden: [String: Double] = [:]
        var relYtor = Set<String>()
        var relParamVisad: String?
        let relMat: SCNMaterial = { let m = SCNMaterial(); m.diffuse.contents = NSColor.systemOrange; m.lightingModel = .blinn; m.isDoubleSided = true; return m }()
        var shiftNere: () -> Bool = { NSEvent.modifierFlags.contains(.shift) }
        var spelTimer: Timer?
        var spelStart: CFTimeInterval = 0
        var knownSelectedPart: String?
        var handledTraff: Traff?
        var selectedLeaf: String?
        var specColors: [String: NSColor] = [:]
        var asmCenter = V3(0, 0, 0)
        let rit = RitTillstand()             // Rita.swift
        var cursorKey = ""
        var matEtikett: MatEtikett?          // mätetiketten placeras per bildruta (3DVerktyg.swift)

        func sectionLabel() -> String {
            String(format: "Snitt: %@ = %@", ["X", "Y", "Z"][sectionAxis],
                   String(format: "%.1f", sectionCoord).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−"))
        }

        /// Planets utsträckning längs en axel över det som syns.
        func sectionBounds(_ k: Int) -> ClosedRange<Double> {
            let visible = SCNNode()
            for (_, n) in partNodes where isVisible(n) { visible.addChildNode(n.clone()) }
            if visible.childNodes.isEmpty && !scan.isHidden { visible.addChildNode(scan.clone()) }
            var (lo, hi) = worldBounds(visible.childNodes.isEmpty ? partsRoot : visible)
            if !lo[k].isFinite || !hi[k].isFinite { lo = center - radius; hi = center + radius }
            return Double(lo[k])...Double(max(hi[k], lo[k] + 0.1))
        }

        /// Huvudplanet närmast blickriktningen och vilken sida som är kamerans.
        func lookAxis() -> (Int, Float)? {
            guard let pov = view?.pointOfView else { return nil }
            let look = pov.simdWorldFront
            let a = [abs(look.x), abs(look.y), abs(look.z)]
            let k = a.firstIndex(of: a.max()!)!
            return (k, look[k] <= 0 ? 1 : -1)
        }

        func setPlane(axis k: Int, sign: Float, coord: Float, range: ClosedRange<Double>? = nil) {
            var axis = SIMD3<Float>(0, 0, 0); axis[k] = 1
            sectionAxis = k; sectionSign = sign; sectionCoord = coord
            sectionRange = range ?? sectionBounds(k)
            clip = SIMD4(axis * sign, sign * coord)
            onSection?(sectionLabel(), Double(coord), sectionRange)
            applyClip()
            rebuildSectionFill(force: true)
        }

        func setSection(_ on: Bool) {
            guard on != sectionOn else { return }
            sectionOn = on
            if on, let (k, sign) = lookAxis() {
                let r = sectionBounds(k)
                setPlane(axis: k, sign: sign, coord: Float((r.lowerBound + r.upperBound) / 2), range: r)
            } else {
                clip = SIMD4(0, 0, 0, 1)
                onSection?(nil, 0, 0...1)
                applyClip()
                rebuildSectionFill(force: true)
            }
        }

        /// Nästa klick lägger planet genom klickpunkten (samma axelval som annars).
        /// Klickplacering: planet går genom klickpunkten och är vänt mot betraktaren (huvudplanet närmast skärmens plan),
        /// kamerans sida tas bort. ⌥-klick: lodrätt plan på skärmen genom punkten (skär tvärs igenom det man pekar på).
        func placeSection(at world: V3) {
            sectionOn = true   // medan man väljer var snittet ska gå visas modellen hel (arbetsytan skickar section = false)
            guard let pov = view?.pointOfView else { return }
            if !NSEvent.modifierFlags.contains(.option), let (k, sign) = lookAxis() {
                // 0,1 mm in i materialet (bort från kameran): klickar man på en yta som vetter mot en hamnar planet
                // annars exakt i ytan och ritas flimrigt – nu syns ett rent snitt strax under ytan; reglaget går djupare
                setPlane(axis: k, sign: sign, coord: world[k] - sign * 0.1); return
            }
            let right = pov.simdWorldRight
            let a = [abs(right.x), abs(right.y), abs(right.z)]
            let k = a.firstIndex(of: a.max()!)!
            let cam = pov.simdWorldPosition
            let sign: Float = cam[k] - world[k] >= 0 ? 1 : -1
            setPlane(axis: k, sign: sign, coord: world[k])
        }

        /// En sparad snittvy: exakt det planet, kamera och mål.
        func applySaved(_ s: SparadSnitt) {
            sectionOn = true
            snapped == nil ? () : unsnap()
            setPlane(axis: max(0, min(2, s.axel)), sign: s.tecken < 0 ? -1 : 1, coord: Float(s.lage))
            if let m = s.mal, m.count == 3 { target = SIMD3(Float(m[0]), Float(m[1]), Float(m[2])) }
            if let k = s.kamera, k.count == 16, let pov = view?.pointOfView {
                let f = k.map { Float($0) }
                pov.simdTransform = simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]), SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
                syncFromPov()
            }
        }

        /// En sparad vy: kamera och mål (lager/snitt sätts av Runner).
        var appliedVy: SparadVy?
        func applyVy(_ s: SparadVy) {
            if let b = s.foto {
                guard let f = photos.first(where: { $0.bild == b }) else { onNote?("Bildrutan i vyn finns inte längre"); return }
                if s.mal.count == 3 { target = SIMD3(Float(s.mal[0]), Float(s.mal[1]), Float(s.mal[2])) }
                if !follow { follow = true; onFollowChange?(true) }
                snap(f, animated: snapped != nil); onNote?(nil)
                return
            }
            if snapped != nil { unsnap() }
            if s.mal.count == 3 { target = SIMD3(Float(s.mal[0]), Float(s.mal[1]), Float(s.mal[2])) }
            guard s.kamera.count == 16, let pov = view?.pointOfView else { return }
            let f = s.kamera.map { Float($0) }
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.35
            pov.simdTransform = simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]), SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
            SCNTransaction.commit()
            syncFromPov()
        }

        func currentSaved() -> SparadSnitt? {
            guard sectionOn, let pov = view?.pointOfView else { return nil }
            let c = pov.simdTransform.columns
            let cam = [c.0, c.1, c.2, c.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
            let name = sectionLabel().replacingOccurrences(of: "Snitt:", with: "Snitt")
            return SparadSnitt(id: isoNu(), namn: name, axel: sectionAxis, lage: Double(sectionCoord), tecken: Double(sectionSign),
                               kamera: cam, mal: [Double(target.x), Double(target.y), Double(target.z)])
        }

        /// Reglaget: flytta planet längs sin axel.
        func moveSection(to v: Float) {
            guard sectionOn, abs(v - sectionCoord) > 1e-4 else { return }
            sectionCoord = v
            var axis = SIMD3<Float>(0, 0, 0); axis[sectionAxis] = 1
            clip = SIMD4(axis * sectionSign, sectionSign * v)
            onSection?(sectionLabel(), Double(v), sectionRange)
            applyClip()
            rebuildSectionFill(force: true)
        }

        /// Klipplanet på alla material i skanningen och delarna (också hover/val-materialen).
        func applyClip() {
            var mats: [SCNMaterial] = [hoverMat, selMat]
            for root in [scan, partsRoot] { root.enumerateHierarchy { n, _ in if let g = n.geometry { mats += g.materials } } }
            var seen = Set<ObjectIdentifier>()
            for m in mats where seen.insert(ObjectIdentifier(m)).inserted { Snitt.apply(m, clip) }
        }

        /// Fyll snittytorna (delar, snedstreckat) och rita snittlinjer (skanning) för synliga objekt; följer flyttade objekt.
        func rebuildSectionFill(force: Bool = false) {
            let vis = leaves.values.filter { isVisible($0.node) }.sorted { $0.id < $1.id }
            let scanVisible = !scan.isHidden
            var layout = ""
            for l in vis { layout += "\(l.id)\(l.node.simdWorldPosition);" }
            let k = sectionOn ? "\(clip)|\(layout)|\(scanVisible)|\(key)" : ""
            guard force || k != sectionKey else { return }
            sectionKey = k
            sectionNode.childNodes.forEach { $0.removeFromParentNode() }
            guard sectionOn, let root = view?.scene?.rootNode else { sectionNode.removeFromParentNode(); return }
            if sectionNode.parent !== root { root.addChildNode(sectionNode) }
            let n = SIMD3(clip.x, clip.y, clip.z), d = clip.w
            if scanVisible {
                if triCache["skanning"] == nil { triCache["skanning"] = Snitt.triangles(scan) }
                if let l = Snitt.lines(Snitt.segments(triCache["skanning"]!, n: n, d: d), color: NSColor(white: 0.35, alpha: 1)) { sectionNode.addChildNode(l) }
            }
            for (i, leaf) in vis.enumerated() {
                if triCache[leaf.id] == nil {
                    let solid = SCNNode()
                    leaf.node.childNodes.filter { ($0.name?.hasPrefix("yta-") ?? false) || ($0.name?.hasPrefix("stl-") ?? false) }.forEach { solid.addChildNode($0.clone()) }
                    triCache[leaf.id] = Snitt.triangles(solid)   // i delens egen ram; flytten läggs på nedan
                }
                let t = leaf.node.simdWorldPosition
                let color = (leaf.mat.diffuse.contents as? NSColor) ?? .systemOrange
                let segs = Snitt.segments(triCache[leaf.id]!, n: n, d: d - simd_dot(n, t)).map { ($0.0 + t, $0.1 + t) }
                let loops = Snitt.loops(segs)
                if let f = Snitt.fill(loops, axis: sectionAxis, coord: sectionCoord, color: color, variant: i) { f.name = "fyll-\(leaf.id)"; sectionNode.addChildNode(f) }
                // öppna kedjor (t.ex. en skannad del som inte är sluten): bara linjer
                let open = loops.filter { !$0.closed }.flatMap { l in zip(l.pts, l.pts.dropFirst()).map { ($0, $1) } }
                if let l = Snitt.lines(open, color: color.blended(withFraction: 0.4, of: .black) ?? color) { sectionNode.addChildNode(l) }
            }
        }

        @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let v = view, g.state == .ended else { return }
            click(at: g.location(in: v))
        }

        /// Ett klick i vyn (också anropbart direkt, t.ex. från tester): placerar snitt eller kör aktivt verktyg.
        func click(at p: NSPoint) {
            guard view != nil, let run else { return }
            if tool == .valj, handtagVid(p) != nil { return }   // handtaget sköts av mus ned/upp (Matthandtag.swift)
            if run.mattInmatning != nil { run.mattInmatning = nil }
            let hits = visibleHits(p)
            // Snitt som placeras: klicket lägger planet och gör inget annat
            if run.snittPlaceras {
                if let h = hits.first { placeSection(at: v3(h.worldCoordinates)); run.snittPlaceras = false }
                return
            }
            switch tool {
            case .valj: handleSelect(p, hits, faces: true)
            case .flytta: handleSelect(p, hits, faces: false)
            case .mat: handleMeasure(p, hits)
            case .peka: handlePeka(p, hits)
            case .rita: break                 // ritas med mus ned/drag/upp (Rita.swift)
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }


    func makeNSView(context: Context) -> SCNView {
        let v = HoverSCNView()
        v.onHover = { [weak coord = context.coordinator] p in coord?.hover(p) }
        context.coordinator.foljPanelbyten()
        v.onLayout = { [weak coord = context.coordinator] in coord?.kompenseraPanelbyte() }
        v.onDragStart = { [weak coord = context.coordinator] in coord?.dragStarted() }
        v.onDragEnd = { [weak coord = context.coordinator] in coord?.dragEnded() }
        v.onOrbit = { [weak coord = context.coordinator] dx, dy in coord?.orbit(dx, dy) }
        v.onPan = { [weak coord = context.coordinator] dx, dy in coord?.pan(dx, dy) }
        v.onZoom = { [weak coord = context.coordinator] a, p in coord?.zoom(a, at: p) }
        v.onFit = { [weak coord = context.coordinator] in coord?.fitView() }
        v.onCapture = { [weak coord = context.coordinator] p, f in
            guard let coord else { return false }
            return coord.beginHandtagDrag(p) || coord.beginItemDrag(p, f)
        }
        v.onItemDrag = { [weak coord = context.coordinator] dx, dy in
            if coord?.handtagDrag != nil { coord?.dragHandtag(dx, dy) } else { coord?.itemDrag(dx, dy) }
        }
        v.onItemDragEnd = { [weak coord = context.coordinator] in
            if coord?.handtagDrag != nil { coord?.endHandtagDrag() } else { coord?.endItemDrag() }
        }
        v.onDoubleClick = { [weak coord = context.coordinator] p in coord?.itemReset(p) ?? false }
        v.onDrawBegin = { [weak coord = context.coordinator] p, f in coord?.ritBorja(p, f) ?? false }
        v.onDrawMove = { [weak coord = context.coordinator] p, f in coord?.ritDra(p, f) }
        v.onDrawEnd = { [weak coord = context.coordinator] p in coord?.ritSlut(p) }
        v.cursorProvider = { [weak coord = context.coordinator] in
            guard let c = coord, c.tool == .rita else { return nil }
            return c.run?.mellanslag == true ? NSCursor.openHand : Penna.markor
        }
        v.allowsCameraControl = false   // egen styrning (se Coordinator.orbit/pan/zoom)
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        // som i CAD-program: svarvbord runt modellens mitt, "upp" = skalets öppning (−Z), ingen eftersläpning
        v.delegate = context.coordinator
        context.coordinator.view = v
        context.coordinator.setupCube(on: v)
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delegate = context.coordinator
        click.numberOfClicksRequired = 1
        v.addGestureRecognizer(click)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        c.setUp(upSign)
        c.run = run
        c.tool = run?.tool ?? .valj
        let cursorKey = "\(c.tool)|\(run?.mellanslag == true)"
        if c.cursorKey != cursorKey { c.cursorKey = cursorKey; v.window?.invalidateCursorRects(for: v); (v as? HoverSCNView)?.refreshCursor() }
        c.onSection = onSection
        c.onSelectPart = onSelectPart
        if c.partOpacity != partOpacity || c.photoOpacity != photoOpacity || c.selectedPart != selectedPart {
            c.partOpacity = partOpacity; c.photoOpacity = photoOpacity; c.selectedPart = selectedPart
            c.restyleParts()
        }
        if v.scene != nil && !c.key.isEmpty {
            if let r = run?.ritBegaran {
                c.ritFlygTill(r)
                DispatchQueue.main.async { run?.ritBegaran = nil }
            }
            if let s = run?.snittBegaran {
                c.applySaved(s)
                DispatchQueue.main.async { run?.snittBegaran = nil }
            }
            c.setSection(section)
            if section, let sc = sectionCoord {
                if c.lastSeenCoord != sc { c.lastSeenCoord = sc; c.moveSection(to: Float(sc)) }
            } else if !section { c.lastSeenCoord = nil }
        }
        c.onPick = onPick
        c.onSnap = onSnap
        c.photos = photos
        c.folder = photoFolder
        c.updateDots()
        c.onNote = onNote
        c.onFollowChange = onFollowChange
        if c.follow != followPhotos {
            c.follow = followPhotos
            if followPhotos { DispatchQueue.main.async { c.enterPhotoMode() } } else { c.unsnap(); c.syncFromPov(); c.onNote?(nil) }
        }
        if c.relParamVisad != run?.relParam { c.relParamVisad = run?.relParam; c.visaRelation() }
        if v.scene != nil && !c.key.isEmpty { c.ritaHandtag() }
        // efter fotolägesväxeln ovan, annars slår den av fotoläget som en sparad fotovy just slog på
        c.setSpelar((run?.spelar ?? false) && c.snapped == nil)
        // en gång per begäran, och asynkront: fotoläget ändrar Runner-state som annars ritar om vyn mitt i uppdateringen
        if run?.vyBegaran == nil { c.appliedVy = nil }
        if v.scene != nil && !c.key.isEmpty, let vy = run?.vyBegaran, vy != c.appliedVy {
            c.appliedVy = vy
            DispatchQueue.main.async { c.applyVy(vy); run?.vyBegaran = nil }
        }
        if c.opacity != overlayOpacity || c.cadStyle != cadStyle { c.opacity = overlayOpacity; c.cadStyle = cadStyle; c.restyleParts() }
        c.scanHiddenByUser = hidden.contains("skanning")
        if let r = viewRequest, r.id != c.lastRequest, v.scene != nil, !c.key.isEmpty {
            c.lastRequest = r.id
            if r.name == "spara-snitt" {
                if let s = c.currentSaved() { run?.saveSection(s) }
            } else if r.name == "spara-vy" {
                if let pov = v.pointOfView {
                    let m = pov.simdTransform.columns
                    let cam = [m.0, m.1, m.2, m.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
                    let bild = v.snapshot()
                    run?.saveVy(kamera: cam, mal: [Double(c.target.x), Double(c.target.y), Double(c.target.z)],
                                snitt: c.snapped == nil ? c.currentSaved() : nil, foto: c.snapped?.bild, bild: bild)
                }
            } else { DispatchQueue.main.async { c.goTo(r.name) } }
        }
        let effFace: String? = run?.traff != nil ? run?.traff.flatMap { t in t.yta.flatMap { y in t.del.map { "\($0):\(y)" } } } : selectedFace
        if c.selectedFace != effFace {
            let old = c.selectedFace
            c.selectedFace = effFace
            c.partsRoot.enumerateHierarchy { n, _ in if let k = c.faceKey(n), k == old || k == effFace { c.restyle(n) } }
        }
        c.bgColor = background3D
        v.backgroundColor = c.snapped != nil ? (photoOpacity < 0.999 ? background3D : .black) : background3D
        let scanPath = url?.path ?? "-"
        let key = scanPath + "|" + parts.map { "\($0.id)=\($0.url.path)@\($0.stamp.timeIntervalSince1970)" }.joined(separator: ",")
        if c.key != key {
            let firstLoad = !c.key.hasPrefix(scanPath + "|") || (url == nil && c.partNodes.isEmpty)
            c.key = key
            let (target, specs) = (url, parts)
            DispatchQueue.global(qos: .userInitiated).async {
                let scanScene = target.flatMap { try? SCNScene(url: $0, options: [.checkConsistency: false]) }
                let scanFailed = target != nil && scanScene == nil
                let loaded: [(PartSpec, [CadFace], SCNGeometry?, PartData?)] = specs.map { p in
                    p.url.pathExtension == "json" ? (p, loadFaces(p.url) ?? [], nil, loadPartData(p.url)) : (p, [], loadSTL(p.url), nil)
                }
                DispatchQueue.main.async {
                    guard c.key == key else { return }
                    if scanFailed { c.onNote?("Kunde inte läsa skanningen \(target?.lastPathComponent ?? "")") }
                    let root = SCNScene()
                    let scan = SCNNode(), partsRoot = SCNNode()
                    scanScene?.rootNode.childNodes.forEach { scan.addChildNode($0) }
                    c.faceInfo = [:]; c.baseMats = [:]; c.partNodes = [:]; c.partNames = [:]; c.edgeNodes = [:]
                    c.leaves = [:]; c.partData = [:]
                    c.snapped = nil
                    var asmLo = V3(repeating: .infinity), asmHi = V3(repeating: -.infinity)
                    for (spec, faces, stl, pdata) in loaded {
                        c.partNames[spec.id] = c.run?.parts.first { $0.id == spec.id }?.namn ?? spec.id
                        let node = SCNNode(); node.name = "del-\(spec.id)"
                        partsRoot.addChildNode(node)
                        c.partNodes[spec.id] = node
                        if let pdata { c.partData[spec.id] = pdata }
                        let bodies = faces.isEmpty ? [0] : (pdata?.bodies.map(\.n) ?? [0])
                        let multi = bodies.count > 1
                        for (k, b) in bodies.enumerated() {
                            let leafId = multi ? "\(spec.id)#\(b)" : spec.id
                            let group: SCNNode
                            if multi { group = SCNNode(); group.name = "obj-\(leafId)"; node.addChildNode(group) } else { group = node }
                            let color = Coordinator.bodyColor(spec.color, k)
                            let m = Coordinator.makeMaterial(color)
                            let edgeMat = SCNMaterial()
                            edgeMat.diffuse.contents = color.blended(withFraction: 0.35, of: .black) ?? color
                            edgeMat.lightingModel = .constant
                            var lo = V3(repeating: .infinity), hi = V3(repeating: -.infinity)
                            var faceIds: [Int] = []
                            if let stl {
                                let n = SCNNode(geometry: stl); n.name = "stl-\(spec.id)"; n.geometry?.materials = [m]; group.addChildNode(n)
                                let (a, z) = stl.boundingBox; lo = V3(Float(a.x), Float(a.y), Float(a.z)); hi = V3(Float(z.x), Float(z.y), Float(z.z))
                            }
                            let edges = SCNNode(); edges.name = "kanter-\(leafId)"
                            let myFaces = faces.filter { (pdata?.faces[$0.id]?.kropp ?? 0) == b || !multi }
                            for f in myFaces {
                                let n = SCNNode(geometry: f.geometry); n.name = "yta-\(spec.id):\(f.id)"
                                n.geometry?.materials = [m]
                                group.addChildNode(n)
                                faceIds.append(f.id)
                                if pdata?.hasEdges != true, let e = f.edges { e.materials = [edgeMat]; let en = SCNNode(geometry: e); en.renderingOrder = 50; edges.addChildNode(en) }
                                c.faceInfo["\(spec.id):\(f.id)"] = f.typ + (f.radie.map { String(format: " r=%.2f", $0) } ?? "")
                                if pdata == nil { let (a, z) = f.geometry.boundingBox; lo = simd_min(lo, V3(Float(a.x), Float(a.y), Float(a.z))); hi = simd_max(hi, V3(Float(z.x), Float(z.y), Float(z.z))) }
                            }
                            var leafEdges: [EdgeData] = []
                            if let pdata, pdata.hasEdges {
                                leafEdges = pdata.edges.filter { !multi || $0.kropp == b }
                                if let g = Ror.lines(leafEdges) { g.materials = [edgeMat]; let en = SCNNode(geometry: g); en.renderingOrder = 50; edges.addChildNode(en) }
                            }
                            if let pdata, let bd = pdata.bodies.first(where: { $0.n == b }) { lo = bd.lo; hi = bd.hi }
                            c.setMarkMask(edges)   // kantlinjer syns men tas inte med i träffar
                            group.addChildNode(edges)
                            c.edgeNodes[leafId] = edges
                            let leaf = Leaf(id: leafId, del: spec.id, node: group, body: multi ? b : nil,
                                            namn: pdata?.bodies.first(where: { $0.n == b })?.namn ?? "Kropp \(b + 1)", lo: lo, hi: hi, mat: m, edgeMat: edgeMat)
                            leaf.edges = leafEdges; leaf.faceIds = faceIds; leaf.edgeNode = edges
                            c.leaves[leafId] = leaf
                            if k == 0 { c.baseMats[spec.id] = m }
                            if lo.x.isFinite { asmLo = simd_min(asmLo, lo); asmHi = simd_max(asmHi, hi) }
                        }
                    }
                    c.asmCenter = asmLo.x.isFinite ? (asmLo + asmHi) / 2 : .zero
                    root.rootNode.addChildNode(scan)
                    root.rootNode.addChildNode(partsRoot)
                    c.originals = [:]
                    scan.enumerateHierarchy { node, _ in
                        guard let g = node.geometry else { return }
                        g.materials.forEach { $0.isDoubleSided = true }   // ingen genomsikt på bakvända ytor
                        c.originals[ObjectIdentifier(g)] = g.materials
                    }
                    c.hovered = nil
                    c.keep = scanScene.map { [$0] } ?? []
                    c.scan = scan
                    c.partsRoot = partsRoot
                    c.appliedStyle = -1
                    let (lo, hi) = worldBounds(partsRoot.childNodes.isEmpty ? scan : partsRoot)
                    c.center = (lo + hi) / 2
                    c.radius = simd_length(hi - lo) / 2
                    if !c.radius.isFinite || c.radius < 1 { c.center = .zero; c.radius = 80 }
                    let camera = firstLoad ? nil : v.pointOfView?.clone()
                    v.scene = root
                    if let camera { root.rootNode.addChildNode(camera); v.pointOfView = camera; c.syncFromPov() } else {
                        let cam = SCNNode(); cam.camera = c.normalCamera()
                        root.rootNode.addChildNode(cam); v.pointOfView = cam
                        c.target = c.center; c.dist = c.fitDistance(); c.yaw = -0.6; c.pitch = 0.6
                        c.applyCamera(animated: false)
                    }
                    c.triCache = [:]
                    c.sectionNode = SCNNode()
                    c.applyClip()
                    c.rebuildSectionFill(force: true)
                    c.dotsKey = ""
                    c.updateDots()
                    c.onSnap?(nil)
                    c.restyleParts()
                    c.afterLoad(parts: specs)
                    if c.follow { DispatchQueue.main.async { c.enterPhotoMode() } }   // Foto var redan på
                    self.applyStyle(v, c)
                    if c.selectedFace != nil { partsRoot.enumerateHierarchy { n, _ in c.restyle(n) } }
                }
            }
            return
        }
        applyStyle(v, c)
        c.syncTools(parts: parts)
        applyMarks(v, c)
    }

    private func applyMarks(_ v: SCNView, _ c: Coordinator) {
        guard let root = v.scene?.rootNode else { return }
        if c.marksNode.parent !== root { root.addChildNode(c.marksNode); c.marksKey = [] }
        guard c.marksKey != marks else { return }
        c.marksKey = marks
        c.marksNode.childNodes.forEach { $0.removeFromParentNode() }
        let red = NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.15, alpha: 1)
        func mat(_ color: NSColor, _ alpha: CGFloat = 1) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color.withAlphaComponent(alpha)
            m.lightingModel = .constant
            m.readsFromDepthBuffer = false     // syns genom modellen
            m.isDoubleSided = true
            return m
        }
        func vec(_ a: [Double]?) -> SCNVector3? { guard let a, a.count == 3 else { return nil }; return SCNVector3(a[0], a[1], a[2]) }
        func sphere(_ p: SCNVector3, _ r: CGFloat) {
            let g = SCNSphere(radius: r); g.materials = [mat(red)]
            let n = SCNNode(geometry: g); n.position = p; n.renderingOrder = 100; c.marksNode.addChildNode(n)
        }
        var placed: [SCNVector3] = []
        func label(_ text: String?, at p: SCNVector3) {
            guard let text, !text.isEmpty else { return }
            let near = placed.filter { q in let d = SCNVector3(q.x - p.x, q.y - p.y, q.z - p.z); return sqrt(d.x * d.x + d.y * d.y + d.z * d.z) < 14 }.count
            placed.append(p)
            let t = SCNText(string: text, extrusionDepth: 0)
            t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            t.flatness = 0.2
            t.materials = [mat(red)]
            let (lo, hi) = t.boundingBox
            let tn = SCNNode(geometry: t)
            tn.pivot = SCNMatrix4MakeTranslation((hi.x + lo.x) / 2, lo.y - 3 - CGFloat(near) * 14, 0)   // krockar → nästa rad
            tn.scale = SCNVector3(0.45, 0.45, 0.45)
            tn.renderingOrder = 101
            let holder = SCNNode(); holder.position = p
            holder.constraints = [SCNBillboardConstraint()]
            holder.addChildNode(tn)
            c.marksNode.addChildNode(holder)
        }
        for m in marks {
            switch m.typ {
            case "matt":
                guard let a = vec(m.fran), let b = vec(m.till) else { continue }
                let d = SCNVector3(b.x - a.x, b.y - a.y, b.z - a.z)
                let len = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
                let cyl = SCNCylinder(radius: 0.35, height: len); cyl.materials = [mat(red)]
                let n = SCNNode(geometry: cyl)
                n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
                n.look(at: b, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 1, 0))
                n.renderingOrder = 100
                c.marksNode.addChildNode(n)
                sphere(a, 0.9); sphere(b, 0.9)
                label(m.text, at: n.position)
            case "pin", "pin_ny":
                guard let p = vec(m.pos) else { continue }
                let color = m.typ == "pin" ? NSColor.systemOrange : red
                let g = SCNSphere(radius: m.typ == "pin" ? 1.1 : 1.4); g.materials = [mat(color)]
                let n = SCNNode(geometry: g); n.position = p; n.renderingOrder = 100; c.marksNode.addChildNode(n)
                label(m.text, at: p)
            case "punkt":
                guard let p = vec(m.pos) else { continue }
                sphere(p, 1.6); label(m.text, at: p)
            case "omrade":
                guard let lo = vec(m.min), let hi = vec(m.max) else { continue }
                let box = SCNBox(width: abs(hi.x - lo.x), height: abs(hi.y - lo.y), length: abs(hi.z - lo.z), chamferRadius: 0)
                box.materials = [mat(red, 0.18)]
                let n = SCNNode(geometry: box)
                n.position = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
                n.renderingOrder = 99
                c.marksNode.addChildNode(n)
                label(m.text, at: SCNVector3(n.position.x, n.position.y, min(lo.z, hi.z)))
            default: continue
            }
        }
    }

    private func applyStyle(_ v: SCNView, _ c: Coordinator) {
        guard v.scene != nil else { return }
        c.scan.isHidden = hidden.contains("skanning") || c.snapped != nil
        for (id, n) in c.partNodes { n.isHidden = hidden.contains(id) }
        for leaf in c.leaves.values where leaf.multi { leaf.node.isHidden = hidden.contains(leaf.id) }
        c.rebuildSectionFill()
        guard c.appliedStyle != scanStyle else { return }
        c.appliedStyle = scanStyle
        let grey = SCNMaterial()
        grey.diffuse.contents = NSColor(white: 0.78, alpha: 1)
        grey.specular.contents = NSColor(white: 0.25, alpha: 1)
        grey.shininess = 0.3
        grey.lightingModel = .blinn
        grey.isDoubleSided = true
        if scanStyle == 2 { grey.fillMode = .lines; grey.diffuse.contents = NSColor(white: 0.35, alpha: 1) }
        if scanStyle == 3 {
            grey.transparency = 0.3
            grey.writesToDepthBuffer = false
            grey.diffuse.contents = NSColor(white: 0.45, alpha: 1)
        }
        c.scan.enumerateHierarchy { node, _ in
            guard let g = node.geometry, let orig = c.originals[ObjectIdentifier(g)] else { return }
            g.materials = scanStyle == 0 ? orig : orig.map { _ in grey }
        }
        c.scan.renderingOrder = scanStyle == 3 ? 10 : 0
        c.scan.enumerateHierarchy { n, _ in n.renderingOrder = scanStyle == 3 ? 10 : 0 }
        c.applyClip()
    }
}


/// Läser en STL (binär eller ASCII) till en egen SCNGeometry med platta normaler. Inga externa referenser.
func loadSTL(_ url: URL) -> SCNGeometry? {
    guard let data = try? Data(contentsOf: url), data.count > 84 else { return nil }
    var tris: [SIMD3<Float>] = []
    let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
    if 84 + Int(count) * 50 == data.count {
        tris.reserveCapacity(Int(count) * 3)
        data.withUnsafeBytes { raw in
            for i in 0..<Int(count) {
                let base = 84 + i * 50 + 12
                for k in 0..<3 {
                    let o = base + k * 12
                    tris.append(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                      raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                }
            }
        }
    } else if let text = String(data: data, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.first == "vertex", parts.count >= 4,
               let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) { tris.append(SIMD3(x, y, z)) }
        }
    }
    guard tris.count >= 3, tris.count % 3 == 0 else { return nil }
    var normals: [SIMD3<Float>] = []
    normals.reserveCapacity(tris.count)
    for i in stride(from: 0, to: tris.count, by: 3) {
        let n = simd_normalize(simd_cross(tris[i + 1] - tris[i], tris[i + 2] - tris[i]))
        let nn = n.x.isNaN ? SIMD3<Float>(0, 0, 1) : n
        normals += [nn, nn, nn]
    }
    let vsrc = SCNGeometrySource(vertices: tris.map { SCNVector3($0.x, $0.y, $0.z) })
    let nsrc = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
    let idx = (0..<Int32(tris.count)).map { $0 }
    let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
    return SCNGeometry(sources: [vsrc, nsrc], elements: [el])
}

/// SCNView som rapporterar musens läge (för att lysa upp ytan under pekaren).
final class HoverSCNView: SCNView {
    var onHover: ((NSPoint?) -> Void)?
    /// Anropas i fönstrets layoutpass, efter att vyn fått ny storlek/plats men före nästa bild ritas.
    var onLayout: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true; onLayout?() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); onLayout?() }
    override func layout() { super.layout(); onLayout?() }
    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); onLayout?() }
    /// SwiftUI flyttar vyns värdvy (inte själva SCNView:n) när en panel försvinner – följ alla förfäders ramar.
    private var ramObs: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ramObs.forEach { NotificationCenter.default.removeObserver($0) }
        ramObs = []
        var s = superview
        while let v = s {
            v.postsFrameChangedNotifications = true
            ramObs.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLayout?() }
            })
            s = v.superview
        }
    }
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onScroll: (() -> Void)?
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat, NSPoint?) -> Void)?
    var onFit: (() -> Void)?
    var onCapture: ((NSPoint, NSEvent.ModifierFlags) -> Bool)?
    var onItemDrag: ((CGFloat, CGFloat) -> Void)?
    var onItemDragEnd: (() -> Void)?
    var onDoubleClick: ((NSPoint) -> Bool)?
    var onDrawBegin: ((NSPoint, NSEvent.ModifierFlags) -> Bool)?
    var onDrawMove: ((NSPoint, NSEvent.ModifierFlags) -> Void)?
    var onDrawEnd: ((NSPoint) -> Void)?
    var cursorProvider: (() -> NSCursor?)?
    private var drawing = false
    private var lastDraw = NSPoint.zero
    private var capturing = false
    private var dragging = false
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        dragging = false
        capturing = false
        let p = convert(event.locationInWindow, from: nil)
        drawing = onDrawBegin?(p, event.modifierFlags) ?? false   // Rita: musen ritar, modellen står still
        if drawing { lastDraw = p; return }
        if event.clickCount == 2 { if onDoubleClick?(p) != true { onFit?() }; return }
        capturing = onCapture?(p, event.modifierFlags) ?? false
    }
    override func mouseDragged(with event: NSEvent) {
        if drawing { lastDraw = convert(event.locationInWindow, from: nil); onDrawMove?(lastDraw, event.modifierFlags); return }
        if capturing { dragging = true; onItemDrag?(event.deltaX, event.deltaY); return }
        if !dragging { dragging = true; onDragStart?() }
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) {
            onPan?(event.deltaX, event.deltaY)
        } else {
            onOrbit?(event.deltaX, event.deltaY)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if drawing { drawing = false; onDrawEnd?(convert(event.locationInWindow, from: nil)); return }
        if capturing { capturing = false; dragging = false; onItemDragEnd?(); return }
        if dragging { dragging = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.onDragEnd?() } }
    }
    override func rightMouseDown(with event: NSEvent) { dragging = false }
    override func rightMouseDragged(with event: NSEvent) {
        if !dragging { dragging = true; onDragStart?() }
        onPan?(event.deltaX, event.deltaY)
    }
    override func rightMouseUp(with event: NSEvent) { dragging = false }
    override func otherMouseDragged(with event: NSEvent) { onPan?(event.deltaX, event.deltaY) }
    override func scrollWheel(with event: NSEvent) {
        onScroll?()
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.12
        onZoom?(d, convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) { onZoom?(event.magnification * 2.5, convert(event.locationInWindow, from: nil)) }
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if drawing { onDrawMove?(lastDraw, event.modifierFlags) }   // ⇧ ned/upp mitt i ett streck
    }
    override func resetCursorRects() {
        if let c = cursorProvider?() { addCursorRect(bounds, cursor: c) } else { super.resetCursorRects() }
    }
    override func cursorUpdate(with event: NSEvent) {
        if let c = cursorProvider?(), arDirekt(event) { c.set() } else { super.cursorUpdate(with: event) }
    }
    func refreshCursor() {
        guard let w = window, bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        (cursorProvider?() ?? NSCursor.arrow).set()
    }
    /// Ligger pekaren direkt på 3D-vyn – inte på en knapp/panel ovanpå? (Spårningsytan täcker hela vyn, också under
    /// SwiftUI-panelerna; utan den här kollen skrev hover över knapparnas tooltips och satte pennmarkören på dem.)
    private var underPekaren = false
    private func arDirekt(_ event: NSEvent) -> Bool {
        guard let cv = window?.contentView else { return true }
        let p = cv.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
        return cv.hitTest(p) === self
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard arDirekt(event) else {
            if underPekaren { underPekaren = false; onHover?(nil); Tips.dolj(self) }
            return
        }
        underPekaren = true
        if let c = cursorProvider?() { c.set() }
        onHover?(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        underPekaren = false
        onHover?(nil)
        Tips.dolj(self)
    }
}

struct CadFace { let id: Int; let typ: String; let radie: Double?; let geometry: SCNGeometry; let edges: SCNGeometry? }

/// Läser modell-cad-ytor.json: en geometri per CAD-yta, med mjuka normaler inom ytan.
func loadFaces(_ url: URL) -> [CadFace]? {
    struct F: Decodable { let id: Int; let typ: String; let radie: Double?; let v: [Float]; let t: [Int32] }
    struct Root: Decodable { let ytor: [F] }
    guard let data = try? Data(contentsOf: url), let root = try? JSONDecoder().decode(Root.self, from: data) else { return nil }
    return root.ytor.compactMap { f in
        let n = f.v.count / 3
        guard n >= 3, f.t.count >= 3 else { return nil }
        let pts = (0..<n).map { SIMD3<Float>(f.v[3 * $0], f.v[3 * $0 + 1], f.v[3 * $0 + 2]) }
        var normals = [SIMD3<Float>](repeating: .zero, count: n)
        for k in stride(from: 0, to: f.t.count - 2, by: 3) {
            let a = Int(f.t[k]), b = Int(f.t[k + 1]), c = Int(f.t[k + 2])
            guard a < n, b < n, c < n else { continue }
            let nn = simd_cross(pts[b] - pts[a], pts[c] - pts[a])
            normals[a] += nn; normals[b] += nn; normals[c] += nn
        }
        let vsrc = SCNGeometrySource(vertices: pts.map { SCNVector3($0.x, $0.y, $0.z) })
        let nsrc = SCNGeometrySource(normals: normals.map { let u = simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 0, 1); return SCNVector3(u.x, u.y, u.z) })
        let el = SCNGeometryElement(indices: f.t, primitiveType: .triangles)
        // ytans kantlinjer = trianglarnas kanter som bara används en gång inom ytan
        var count: [UInt64: Int] = [:]
        for k in stride(from: 0, to: f.t.count - 2, by: 3) {
            for (a, b) in [(f.t[k], f.t[k + 1]), (f.t[k + 1], f.t[k + 2]), (f.t[k + 2], f.t[k])] {
                let key = UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b)))
                count[key, default: 0] += 1
            }
        }
        let lineIdx: [Int32] = count.filter { $0.value == 1 }.keys.flatMap { [Int32(truncatingIfNeeded: $0 >> 32), Int32(truncatingIfNeeded: $0 & 0xffffffff)] }
        let edges = lineIdx.isEmpty ? nil : SCNGeometry(sources: [vsrc], elements: [SCNGeometryElement(indices: lineIdx, primitiveType: .line)])
        return CadFace(id: f.id, typ: f.typ, radie: f.radie, geometry: SCNGeometry(sources: [vsrc, nsrc], elements: [el]), edges: edges)
    }
}


/// Världskoordinaternas omslutande låda för all geometri under en nod (räknas ur geometrin, inte ur nodens egen box).
func worldBounds(_ root: SCNNode) -> (SIMD3<Float>, SIMD3<Float>) {
    var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
    root.enumerateHierarchy { n, _ in
        guard let g = n.geometry else { return }
        let (a, b) = g.boundingBox
        for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
            let w = n.convertPosition(SCNVector3(x, y, z), to: root)
            let p = SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        } } }
    }
    return (lo, hi)
}


