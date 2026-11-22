// Ångra/gör om (⌘Z / ⇧⌘Z): ögonblicksbilder av det användaren kan ändra i appen – mått, kantbehandlingar, utskriftsinställningar, tillagda delar
// (filer i cad/) och visningen (synlighet, flytt, explode, opacitet, färgschema, snitt). Snabba ändringar i följd (ett drag,
// ett reglage) blir ett steg. Meddelanden till Claude ångras inte, men Claude får veta när en modelländring ångras.
import AppKit
import SwiftUI

struct Ogonblick: Equatable {
    var overrides: [String: Double]
    var kant: Data?                       // cad/kantbehandling.json
    var skript: [String: Data]            // cad/skript/*.py
    var hidden: Set<String>
    var offsets: [String: SIMD3<Double>]
    var sprangOffsets: [String: SIMD3<Double>] = [:]
    var explode: Double
    var partOpacity: [String: Double]
    var fargschema: Fargschema
    var sectionOn: Bool
    var ritning: Ritning?                 // väntande (inte skickad) ritning
    var utskrift: Data? = nil             // cad/utskrift.json (utskriftsinställningar per del)
    var borttagna: Set<String> = []       // raderade delar (cad/objekt.json)

    func sammaModell(_ o: Ogonblick) -> Bool { overrides == o.overrides && kant == o.kant && skript == o.skript }
}

extension Runner {
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoName: String? { undoStack.last?.namn }
    var redoName: String? { redoStack.last?.namn }

    func captureState() -> Ogonblick {
        let fm = FileManager.default
        var skript: [String: Data] = [:]
        if let d = scriptFolder {
            for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "py" {
                skript[u.lastPathComponent] = try? Data(contentsOf: u)
            }
        }
        return Ogonblick(overrides: overrides,
                         kant: cadFolder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("kantbehandling.json")) },
                         skript: skript, hidden: hidden, offsets: offsets, sprangOffsets: sprangOffsets, explode: explode, partOpacity: partOpacity,
                         fargschema: fargschema, sectionOn: sectionOn, ritning: ritning,
                         utskrift: utskriftURL.flatMap { try? Data(contentsOf: $0) }, borttagna: borttagna)
    }

    /// Anropas före (modelländringar, immediate) eller efter (visning, via didSet) en ändring.
    func noteChange(_ name: String, immediate: Bool = false) {
        guard !undoPaused, output != nil else { return }
        if immediate && undoBurst != nil { settleUndo() }
        if undoStable == nil { undoStable = captureState() }
        if undoBurst == nil {
            undoStack.append((name, undoStable!))
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack = []
            undoBurst = name
            historikNotera(name)
        }
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: immediate ? 0.05 : 0.7, repeats: false) { [weak self] _ in self?.settleUndo() }
    }

    func settleUndo() {
        undoTimer?.invalidate()
        undoBurst = nil
        undoStable = captureState()
    }

    func resetUndo() {
        undoTimer?.invalidate()
        undoStack = []; redoStack = []
        undoBurst = nil
        undoPaused = false
        undoStable = output == nil ? nil : captureState()
    }

    func undo() {
        if undoBurst != nil { settleUndo() }
        guard let last = undoStack.popLast() else { return }
        redoStack.append((last.namn, captureState()))
        restoreState(last.bild, message: "Ångrade: \(last.namn)")
    }

    func redo() {
        if undoBurst != nil { settleUndo() }
        guard let next = redoStack.popLast() else { return }
        undoStack.append((next.namn, captureState()))
        restoreState(next.bild, message: "Gjorde om: \(next.namn)")
    }

    private func restoreState(_ b: Ogonblick, message: String) {
        let current = captureState()
        undoPaused = true
        defer { undoPaused = false; undoStable = captureState(); undoBurst = nil }
        hidden = b.hidden
        offsets = b.offsets
        sprangOffsets = b.sprangOffsets
        explode = b.explode
        partOpacity = b.partOpacity
        if let o = output { UserDefaults.standard.set(partOpacity, forKey: "opacitet:" + o.path) }
        fargschema = b.fargschema
        ritning = b.ritning
        if sectionOn != b.sectionOn { sectionOn = b.sectionOn; if !b.sectionOn { snittPlaceras = false } }
        toast = message
        if b.borttagna != borttagna {
            borttagna = b.borttagna
            saveObjektVisning()
            reloadCad()
            if b.sammaModell(current) { send(questionID: "parameter", question: "Ångra", text: message + " (i appen, cad/objekt.json \"borttagna\")", attachment: nil) }
        }
        if b.utskrift != current.utskrift, let u = utskriftURL {
            // utskriftsinställningar: filen tillbaka, ingen ombyggnad behövs; Claude får veta (om inte modellen också ändras)
            utskriftTimer?.invalidate(); utskriftAndrade = [:]
            if let d = b.utskrift { try? d.write(to: u, options: .atomic) } else { try? FileManager.default.removeItem(at: u) }
            loadUtskrift()
            if b.sammaModell(current) {
                send(questionID: "parameter", question: "Ångra", text: message + " (utskriftsinställningar i appen, cad/utskrift.json)", attachment: nil)
            }
        }
        guard !b.sammaModell(current), let folder = cadFolder else { return }
        // modellen: mått, kantbehandlingar och del-skript tillbaka på disk, bygg om och berätta för Claude
        let fm = FileManager.default
        overrides = b.overrides
        let enc = JSONEncoder()
        if let d = try? enc.encode(b.overrides) { try? d.write(to: folder.appendingPathComponent("parametrar-anvandare.json"), options: .atomic) }
        let kantURL = folder.appendingPathComponent("kantbehandling.json")
        if let k = b.kant { try? k.write(to: kantURL, options: .atomic) } else { try? fm.removeItem(at: kantURL) }
        if let dir = scriptFolder {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, _) in current.skript where b.skript[name] == nil { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            for (name, data) in b.skript where current.skript[name] != data { try? data.write(to: dir.appendingPathComponent(name), options: .atomic) }
        }
        send(questionID: "parameter", question: "Ångra", text: message + " (i appen)", attachment: nil)
        if canEdit { rebuild() } else { reloadCad() }
    }

    /// ⌘Z/⇧⌘Z: i ett textfält gäller textens egen ångra, annars appens.
    func undoCommand(redo: Bool) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
        } else if redo { self.redo() } else { undo() }
    }
}
