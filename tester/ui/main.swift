// UI-testerna: appen körs osynligt (fönster utanför skärmen) och varje scenario kontrollerar sig självt.
// (main.swift) Byggs och körs av tester/testa.sh: swiftc app/*.swift (utom SkannaApp.swift) + tester/ui/*.swift.
//   SKANNA_TESTFIXTUR = det byggda testprojektet (kopieras färskt per scenario)
//   SKANNA_TESTFILTER = kör bara scenarier vars namn innehåller texten
//   SKANNA_TESTBILDER = mapp för en skärmbild efter varje scenario (valfritt)
import AppKit
import SceneKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
UserDefaults.standard.set(true, forKey: "harSettValkommen")
let env = ProcessInfo.processInfo.environment
let FIXTUR = URL(fileURLWithPath: env["SKANNA_TESTFIXTUR"]!)
let TMP = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("skanna-ui-\(getpid())")
try? FileManager.default.createDirectory(at: TMP, withIntermediateDirectories: true)
let run = Runner()
let win = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1440, height: 880), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
win.contentView = NSHostingView(rootView: ContentView(run: run).frame(width: 1440, height: 880))
win.orderFrontRegardless()

// MARK: Hjälp

func findSCN(_ v: NSView) -> SCNView? { if let s = v as? SCNView, s.frame.width > 300 { return s }; for c in v.subviews { if let s = findSCN(c) { return s } }; return nil }
func vy() -> (SCNView, ModelView.Coordinator)? {
    guard let scn = findSCN(win.contentView!), let c = scn.delegate as? ModelView.Coordinator else { return nil }
    return (scn, c)
}
func proj(_ w: V3) -> CGPoint { guard let (scn, _) = vy() else { return .zero }; let p = scn.projectPoint(SCNVector3(w.x, w.y, w.z)); return CGPoint(x: p.x, y: p.y) }
func avst(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
/// En färsk kopia av testprojektet, öppnad i appen.
func oppnaKopia(_ namn: String) -> URL {
    let dir = TMP.appendingPathComponent(namn.replacingOccurrences(of: " ", with: "-"), isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let p = dir.appendingPathComponent("Testlåda")
    try! FileManager.default.copyItem(at: FIXTUR, to: p)
    run.selectedPart = nil; run.explode = 0; run.utfallda = []; run.hidden = []; run.tool = .valj
    win.makeFirstResponder(nil)                 // inget textfält har fokus från förra scenariot
    run.select(p)
    return p
}
func json(_ u: URL) -> [String: Any] { (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
func finns(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
func skillnad(_ a: simd_quatf, _ b: simd_quatf) -> Float { min(simd_length(a.vector - b.vector), simd_length(a.vector + b.vector)) }
func tangent(_ ner: Bool, tecken: String, kod: UInt16) {
    let e = NSEvent.keyEvent(with: ner ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: win.windowNumber, context: nil, characters: tecken, charactersIgnoringModifiers: tecken,
                             isARepeat: false, keyCode: kod)!
    NSApp.sendEvent(e)
}

// MARK: Scenarier och kontroller

enum Steg {
    case gor(() -> Void)
    case vanta(Double)
    case tills(String, Double, () -> Bool)     // vänta tills villkoret gäller (max sekunder), annars fel
}
struct Scenario { let namn: String; let steg: [Steg] }
var fel: [String: [String]] = [:]
var antal: [String: Int] = [:]
var aktuellt = ""
func kolla(_ ok: Bool, _ text: @autoclosure () -> String) {
    antal[aktuellt, default: 0] += 1
    if !ok { fel[aktuellt, default: []].append(text()) }
}

let filter = env["SKANNA_TESTFILTER"].flatMap { $0.isEmpty ? nil : $0 }
let alla = Scenarier.alla().filter { s in filter.map { s.namn.localizedCaseInsensitiveContains($0) } ?? true }
var si = 0, sti = 0
var start = Date()

func bild(_ namn: String) {
    guard let mapp = env["SKANNA_TESTBILDER"], let cv = win.contentView else { return }
    let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds)!
    cv.cacheDisplay(in: cv.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: mapp).appendingPathComponent(namn + ".png"))
}

func nasta() {
    guard si < alla.count else { avsluta(); return }
    let s = alla[si]
    if sti == 0 { aktuellt = s.namn; start = Date() }
    guard sti < s.steg.count else {
        bild(s.namn)
        let f = fel[s.namn] ?? []
        print(f.isEmpty ? "  ✓ \(s.namn) (\(antal[s.namn] ?? 0) kontroller)" : "  ✗ \(s.namn)\n" + f.map { "      – \($0)" }.joined(separator: "\n"))
        fflush(stdout)
        si += 1; sti = 0
        DispatchQueue.main.async { nasta() }
        return
    }
    let st = s.steg[sti]; sti += 1
    switch st {
    case .gor(let f): f(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nasta() }
    case .vanta(let t): DispatchQueue.main.asyncAfter(deadline: .now() + t) { nasta() }
    case .tills(let text, let max, let villkor):
        let t0 = Date()
        func prova() {
            if villkor() { nasta(); return }
            if Date().timeIntervalSince(t0) > max { kolla(false, "väntade förgäves (\(Int(max)) s): \(text)"); nasta(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { prova() }
        }
        prova()
    }
}

func avsluta() {
    let underkanda = alla.filter { !(fel[$0.namn] ?? []).isEmpty }
    let n = antal.values.reduce(0, +)
    if alla.isEmpty { print("UI: inga scenarier matchar filtret \(filter ?? "")"); exit(1) }
    print(underkanda.isEmpty ? "UI: alla \(alla.count) scenarier godkända (\(n) kontroller)"
                             : "UI: \(underkanda.count) av \(alla.count) scenarier underkända")
    try? FileManager.default.removeItem(at: TMP)
    exit(underkanda.isEmpty ? 0 : 1)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1) { nasta() }
app.run()

extension NSColor {
    var hexText: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
