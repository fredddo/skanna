// Appens tillstånd: valt projekt, CAD-filerna från Claude/del-skripten, svar till Claude, och skanningskörningen.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Skarm: Equatable { case valkommen, nySkanning, guidad, projekt }

final class Runner: ObservableObject {
    // MARK: Navigering
    @Published var screen: Skarm = .valkommen
    @Published var showNewProject = false
    @Published var showShortcuts = false
    @Published var viewRequest: ViewRequest?

    // MARK: Skanningskörning (CLI)
    @Published var clips: [URL] = []
    @Published var length = ""
    @Published var raw = false
    @Published var running = false
    @Published var runningProject: URL?
    @Published var stage = ""
    @Published var progress = 0.0
    @Published var log = ""
    @Published var dims: String?
    @Published var error: String?
    var process: Process?
    var buffer = ""
    var stageIndex = 0
    var pass = 0
    var passes = 2.0

    // MARK: Valt projekt
    @Published var output: URL? {
        willSet { if newValue != output { flushUtskrift() } }   // väntande utskriftsmeddelande till rätt projekt
        didSet { if output != oldValue { projectChanged() } }
    }
    @Published var model: URL?
    @Published var projekt: ProjektFil?
    @Published var scans: [ProjektPost] = []
    @Published var mallar: [Mall] = []

    // MARK: CAD-steget (<projekt>/cad/)
    @Published var cad: CadInfo?
    @Published var cadModel: URL?
    @Published var cadStamp = Date.distantPast
    @Published var answers: [Svar] = []
    @Published var parts: [PartInfo] = []
    @Published var photos: [FotoInfo] = []
    @Published var snapped: FotoInfo?
    @Published var note: String?
    @Published var rebuilding = false
    @Published var buildError: String?
    @Published var buildLog = ""
    @Published var closedQuestions: Set<String> = []
    @Published var overrides: [String: Double] = [:]
    @Published var utskrift: [String: [String: String]] = [:]   // cad/utskrift.json (Utskrift.swift)
    var utskriftAndrade: [String: [String]] = [:]                // ändrade nycklar per del, ej skickade till Claude än
    var utskriftTimer: Timer?
    @Published var hidden: Set<String> = [] { didSet { if hidden != oldValue { noteChange("Visa/dölj") } } }
    @Published var claude: ClaudeInfo?
    @Published var focusQuestion: String?
    @Published var pick: PickPoint?
    @Published var photoIndex = 0
    @Published var toast: String?
    @Published var selectedPart: String?
    @Published var partOpacity: [String: Double] = [:]   // per del (och "skanning"), sparas per projekt
    @Published var sectionOn = false { didSet { if sectionOn != oldValue { if !sectionOn { aktivSnittvy = nil }; noteChange("Snitt") } } }
    @Published var sectionLabel: String?
    @Published var sectionCoord: Double?                 // planets läge (reglaget)

    // MARK: Verktyg och visning (Verktyg.swift) – ändrar aldrig modellen
    @Published var tool: Verktyg = .valj
    @Published var traff: Traff?                         // vald del/yta/kant/punkt (verktyget Välj/Peka)
    @Published var info: Info?                           // mått på det valda (inspektören)
    @Published var matning: Matning?                     // verktyget Mät
    @Published var explode: Double = 0 { didSet { if explode != oldValue { noteChange("Explode") } } }   // 0 = ihop, 1 = helt isärdraget
    @Published var offsets: [String: SIMD3<Double>] = [:] { didSet { if offsets != oldValue { noteChange("Flytta") } } }  // tillfällig flytt per del-/objekt-id (mm)
    @Published var underObjekt: [String: [UnderObjekt]] = [:]  // sätts av 3D-vyn efter laddning
    // Snitt: klick placerar planet; sparade vyer i cad/snittvyer.json
    @Published var snittPlaceras = false { didSet { if snittPlaceras { aktivSnittvy = nil } } }  // nästa klick lägger snittplanet
    @Published var snittBegaran: SparadSnitt?            // 3D-vyn visar detta snitt (plan + kamera) och nollställer fältet
    @Published var snittvyer: [SparadSnitt] = []
    @Published var aktivSnittvy: String?                 // id för den sparade snittvy som är tänd (nil = inget eller ett osparat snitt)
    @Published var fargschema: Fargschema = .hav {
        didSet { if let o = output, oldValue != fargschema { UserDefaults.standard.set(fargschema.rawValue, forKey: "farg:" + o.path); noteChange("Färgschema") } }
    }
    @Published var sectionRange: ClosedRange<Double> = 0...1
    // Rita (Rita.swift)
    @Published var ritning: Ritning?                     // väntande ritning (streck från samma vy, inte skickad än)
    @Published var visadRitning: Ritning?                // skickad ritning som visas i 3D-vyn
    @Published var ritBegaran: Ritning?                  // 3D-vyn flyger till ritningens vy och nollställer fältet
    @Published var mellanslag = false                    // mellanslag nedhållet i Rita: dra = vrid
    @Published var skrivFokus = 0                        // ökas när ett streck är klart: skrivfältet i Samtal får fokus
    var ritBilder: [String: Data] = [:]                  // "<ritning>#<antal streck>" → PNG av vyn
    var ritBildSkala: [String: Double] = [:]

    struct PickPoint: Equatable { let pos: [Double]; let target: String; var yta: Int? = nil; var ytatyp: String? = nil; var del: String? = nil; var foto: String? = nil; var foto_px: [Double]? = nil }

    // MARK: Ångra/gör om (Angra.swift)
    @Published var undoStack: [(namn: String, bild: Ogonblick)] = []
    @Published var redoStack: [(namn: String, bild: Ogonblick)] = []
    var undoStable: Ogonblick?
    var undoBurst: String?
    var undoTimer: Timer?
    var undoPaused = true          // av medan ett projekt laddas och medan ett läge återställs

    private var cadTimer: Timer?
    private var pendingRebuild = false

    init() {
        cadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reloadCad(onlyIfChanged: true) }
        mallar = Mall.alla()
    }

    var cadFolder: URL? { output?.appendingPathComponent("cad", isDirectory: true) }
    var scriptFolder: URL? { cadFolder?.appendingPathComponent("skript", isDirectory: true) }
    private var overridesURL: URL? { cadFolder?.appendingPathComponent("parametrar-anvandare.json") }
    private var closedURL: URL? { cadFolder?.appendingPathComponent("stangda-fragor.json") }
    private var answersURL: URL? { cadFolder?.appendingPathComponent("svar.json") }

    var projectName: String {
        if let n = projekt?.namn { return n }
        return output.map { $0.lastPathComponent } ?? ""
    }

    /// Del-skript i projektet (cad/skript/*.py).
    var scripts: [URL] {
        guard let d = scriptFolder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "py" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Kan måtten ändras och delarna byggas om? Ja om projektet har del-skript, eller (äldre skanningar) en egen CAD-modell.
    var canEdit: Bool {
        guard let f = cadFolder, FileManager.default.isExecutableFile(atPath: Hem.byggSkript.path) else { return false }
        return !scripts.isEmpty || FileManager.default.fileExists(atPath: f.appendingPathComponent("modell-cad.step").path)
    }

    /// Bilder i <projekt>/bilder (guidad skanning eller importerade foton) som ännu inte blivit en modell.
    var imageCount: Int {
        guard let o = output else { return 0 }
        let d = o.appendingPathComponent("bilder")
        return ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [])
            .filter { bildandelser.contains(($0 as NSString).pathExtension.lowercased()) }.count
    }

    private func projectChanged() {
        undoPaused = true
        defer { resetUndo() }
        hidden = []; pick = nil; ritning = nil; visadRitning = nil; mellanslag = false; focusQuestion = nil; snapped = nil; note = nil; buildError = nil; buildLog = ""
        selectedPart = nil; sectionOn = false; sectionLabel = nil; sectionCoord = nil
        traff = nil; info = nil; matning = nil; explode = 0; offsets = [:]; underObjekt = [:]
        snittPlaceras = false; snittBegaran = nil
        snittvyer = cadFolder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("snittvyer.json")) }
            .flatMap { try? JSONDecoder().decode([SparadSnitt].self, from: $0) } ?? []
        fargschema = output.flatMap { UserDefaults.standard.string(forKey: "farg:" + $0.path) }.flatMap(Fargschema.init(rawValue:))
            ?? Fargschema.standard(for: output?.path ?? "")
        partOpacity = output.flatMap { UserDefaults.standard.dictionary(forKey: "opacitet:" + $0.path) as? [String: Double] } ?? [:]
        cadStamp = .distantPast
        projekt = output.flatMap { try? Data(contentsOf: $0.appendingPathComponent("projekt.json")) }
            .flatMap { try? JSONDecoder().decode(ProjektFil.self, from: $0) }
        reloadCad()
    }

    // MARK: Lokalt tillstånd (användarens mått och stängda frågor)

    func loadLocalState() {
        overrides = overridesURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        closedQuestions = Set(closedURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    func setParam(_ name: String, _ text: String, unit: String? = nil) {
        let t = text.replacingOccurrences(of: ",", with: ".").filter { "-0123456789.".contains($0) }
        guard let v = Double(t), let url = overridesURL else { toast = "\"\(text)\" är inget tal"; return }
        noteChange("Ändra \(name)", immediate: true)
        overrides[name] = v
        if let d = try? JSONEncoder().encode(overrides) { try? d.write(to: url, options: .atomic) }
        send(questionID: "parameter", question: name, text: String(format: "%@ = %g %@ (ändrat i appen)", name, v, unit ?? "mm"), attachment: nil)
        rebuild()
    }

    func resetParam(_ name: String) {
        guard let url = overridesURL else { return }
        noteChange("Återställ \(name)", immediate: true)
        overrides[name] = nil
        if let d = try? JSONEncoder().encode(overrides) { try? d.write(to: url, options: .atomic) }
        rebuild()
    }

    /// Kör <SkannaHem>/bygg_projekt.sh <projekt>. Fel visas i appen med loggen.
    func rebuild() {
        guard canEdit, let project = output else { return }
        if rebuilding { pendingRebuild = true; return }
        rebuilding = true
        buildError = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [Hem.byggSkript.path, project.path]
        var env = ProcessInfo.processInfo.environment
        env["SKANNA_HEM"] = Hem.url.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        var collected = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); collected.append(d); lock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let text = String(decoding: collected, as: UTF8.self); lock.unlock()
            DispatchQueue.main.async {
                guard let self else { return }
                self.rebuilding = false
                self.buildLog = text
                if proc.terminationStatus != 0 {
                    let last = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
                    self.buildError = "Bygget misslyckades: " + last
                }
                self.reloadCad()
                self.refreshScans()
                if self.pendingRebuild { self.pendingRebuild = false; self.rebuild() }
            }
        }
        do { try p.run() } catch { rebuilding = false; buildError = "Kunde inte starta bygget: \(error.localizedDescription)" }
    }

    func closeQuestion(_ id: String, _ text: String) {
        closedQuestions.insert(id)
        if let url = closedURL, let d = try? JSONEncoder().encode(Array(closedQuestions)) { try? d.write(to: url, options: .atomic) }
        send(questionID: id, question: text, text: "(stängd av dig – ingen åtgärd)", attachment: nil)
    }

    func reopenQuestion(_ id: String) {
        closedQuestions.remove(id)
        if let url = closedURL, let d = try? JSONEncoder().encode(Array(closedQuestions)) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Foton med kamerans läge

    var reliablePhotos: [FotoInfo] { photos.filter { $0.palitlig != false && $0.K != nil } }

    // MARK: Delar

    var partSpecs: [PartSpec] {
        guard let folder = cadFolder else { return [] }
        return parts.compactMap { p in
            let u = folder.appendingPathComponent(p.fil)
            guard let d = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return nil }
            return PartSpec(id: p.id, url: u, color: color(for: p), stamp: d)
        }
    }

    /// Opaciteten sparas per läge: "3d/<del>", "foto/<del>" och "foto/fotot".
    func opacityKey(_ id: String) -> String { (snapped != nil ? "foto/" : "3d/") + id }

    func setOpacity(_ key: String, _ v: Double) {
        noteChange("Opacitet")
        partOpacity[key] = v
        if let o = output { UserDefaults.standard.set(partOpacity, forKey: "opacitet:" + o.path) }
    }

    func selectPart(_ id: String?) { selectedPart = (id == selectedPart) ? nil : id }

    /// Delens färg enligt valt färgschema (index i delar.json), eller skriptets egen färg.
    func color(for p: PartInfo) -> NSColor {
        let own = NSColor(hex: p.farg) ?? .systemOrange
        let f = fargschema.farger
        guard !f.isEmpty, let i = parts.firstIndex(where: { $0.id == p.id }) else { return own }
        return NSColor(hex: f[i % f.count]) ?? own
    }

    /// Begär fillet/fas på en kant: sparas i cad/kantbehandling.json (utförs av del-skriptet via projekt.py vid nästa bygge)
    /// och skickas som meddelande till Claude, som tar hand om delar utan del-skript.
    func kantbehandla(_ k: Kantbehandling, namn: String) {
        guard let folder = cadFolder else { return }
        noteChange(k.typ == "fillet" ? "Fillet" : "Fas", immediate: true)
        let url = folder.appendingPathComponent("kantbehandling.json")
        var list = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Kantbehandling].self, from: $0) } ?? []
        list.removeAll { $0.del == k.del && $0.kant == k.kant }
        list.append(k)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(list) { try? d.write(to: url, options: .atomic) }
        let what = k.typ == "fillet" ? String(format: "Fillet r = %g mm", k.matt) : String(format: "Fas %g mm", k.matt)
        send(questionID: "meddelande", question: "Kantbehandling", text: "\(what) på \(namn), kant \(k.kant.map(String.init) ?? "?")",
             attachment: nil, plats: PickPoint(pos: k.mitt, target: namn, del: k.del), kant: k.kant)
        if !scripts.isEmpty { rebuild() }
    }

    /// Spara en snittvy (anropas av 3D-vyn med aktuellt plan och kamera när arbetsytan begär "spara-snitt").
    func saveSection(_ v: SparadSnitt) {
        snittvyer.append(v)
        writeSections()
        toast = "Snittvyn sparad under Snitt i objektträdet"
    }
    func deleteSection(_ id: String) { snittvyer.removeAll { $0.id == id }; writeSections() }
    func renameSection(_ id: String, _ namn: String) {
        guard let i = snittvyer.firstIndex(where: { $0.id == id }) else { return }
        snittvyer[i].namn = namn; writeSections()
    }
    func showSection(_ v: SparadSnitt) { sectionOn = true; snittPlaceras = false; snittBegaran = v; aktivSnittvy = v.id }
    /// Ögat på en sparad snittvy: tänd den (släcker andra) eller släck den.
    func toggleSavedSection(_ v: SparadSnitt) {
        if aktivSnittvy == v.id && sectionOn { sectionOn = false; aktivSnittvy = nil } else { showSection(v) }
    }
    private func writeSections() {
        guard let f = cadFolder else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(snittvyer) { try? d.write(to: f.appendingPathComponent("snittvyer.json"), options: .atomic) }
    }

    /// Nollställ tillfällig flytt och isärdragning.
    func resetLayout() { offsets = [:]; explode = 0 }

    func toggle(_ id: String) { if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) } }

    func export(_ p: PartInfo) {
        guard let folder = cadFolder, let e = p.export else { return }
        openInSlicer([folder.appendingPathComponent(e)])
    }

    /// Alla designdelar med utskriftsfil i ett svep.
    func exportAll() {
        guard let folder = cadFolder else { return }
        let files = parts.filter { $0.roll == "design" && $0.export != nil && !hidden.contains($0.id) }.map { folder.appendingPathComponent($0.export!) }
        guard !files.isEmpty else { toast = "Inga synliga delar att skriva ut"; return }
        openInSlicer(files)
    }

    /// Vridskivans färdiga utskriftsfiler (vridskiva/ i Skanna-hemmet).
    func printTurntable() {
        let d = Hem.url.appendingPathComponent("vridskiva")
        openInSlicer(["bas.3mf", "topp.3mf"].map { d.appendingPathComponent($0) })
    }

    /// Vridskivan som eget modellprojekt, så att måtten går att ändra innan utskrift.
    func customizeTurntable() {
        guard let m = mallar.first(where: { $0.id == "vridskiva" }) ?? Mall.alla().first(where: { $0.id == "vridskiva" }) else {
            toast = "Mallen Vridskiva saknas i \(Hem.mallar.path)"; return
        }
        createModelProject(name: "Vridskiva", template: m, message: "")
    }

    func openInSlicer(_ files: [URL]) {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { toast = "Utskriftsfilen saknas – bygg om delen (⌘B)"; return }
        let candidates = ["/Applications/BambuStudio.app", "/Applications/Bambu Studio.app", NSHomeDirectory() + "/Applications/BambuStudio.app"]
        if let bambu = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(existing, withApplicationAt: URL(fileURLWithPath: bambu), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
            toast = "Bambu Studio hittades inte – filerna visas i Finder"
        }
    }

    // MARK: Claude

    func replies(to a: Svar) -> [ClaudeInfo.Meddelande] { claude?.meddelanden?.filter { $0.svar_pa == a.tid } ?? [] }
    func isReceived(_ a: Svar) -> Bool { (claude?.mottaget).map { $0 >= a.tid } ?? false }
    func isRead(_ a: Svar) -> Bool { (cad?.last_svar).map { $0 >= a.tid } ?? false }

    /// Meddelanden från Claude som inte är svar på något användarmeddelande (t.ex. första hälsningen).
    var looseReplies: [ClaudeInfo.Meddelande] {
        let tids = Set(answers.map(\.tid))
        return claude?.meddelanden?.filter { $0.svar_pa == nil || !tids.contains($0.svar_pa!) } ?? []
    }

    var pins: [CadInfo.Markering] {
        var out: [CadInfo.Markering] = []
        // bara nålar från trådar som fortfarande är aktiva – avslutade trådars platser försvinner ur 3D-vyn
        let active = Set(chatThreads(closedLocal: loadClosedThreads()).threads.filter { $0.status != .klar }
            .flatMap { $0.entries.compactMap { $0.svar?.tid } })
        for (i, a) in answers.filter({ $0.plats != nil && active.contains($0.tid) }).enumerated() {
            out.append(.init(typ: "pin", fran: nil, till: nil, pos: a.plats, min: nil, max: nil, text: "\(i + 1)"))
        }
        if let p = pick { out.append(.init(typ: "pin_ny", fran: nil, till: nil, pos: p.pos, min: nil, max: nil, text: "här")) }
        return out
    }

    var focusMarks: [CadInfo.Markering] {
        guard let f = focusQuestion else { return [] }
        return cad?.fragor?.first { $0.id == f }?.markering ?? []
    }

    func reloadCad(onlyIfChanged: Bool = false) {
        guard let folder = cadFolder else { cad = nil; cadModel = nil; parts = []; claude = nil; answers = []; photos = []; return }
        let json = folder.appendingPathComponent("geometri.json")
        let stl = folder.appendingPathComponent("modell-cad.stl")
        let faces = folder.appendingPathComponent("modell-cad-ytor.json")
        let claudeURL = folder.appendingPathComponent("claude.json")
        let partsURL = folder.appendingPathComponent("delar.json")
        let photosURL = folder.appendingPathComponent("foton.json")
        let svarURL = folder.appendingPathComponent("svar.json")
        let utskriftFil = folder.appendingPathComponent(Utskrift.fil)
        let fm = FileManager.default
        let partList = (try? Data(contentsOf: partsURL)).flatMap { try? JSONDecoder().decode(PartsFile.self, from: $0) }?.delar
        let partFiles = (partList ?? []).map { folder.appendingPathComponent($0.fil) }
        let watched = [json, stl, faces, claudeURL, partsURL, photosURL, svarURL, utskriftFil] + partFiles
        let stamp = watched.compactMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max() ?? .distantPast
        if onlyIfChanged && stamp == cadStamp { return }
        cadStamp = stamp
        cad = (try? Data(contentsOf: json)).flatMap { try? JSONDecoder().decode(CadInfo.self, from: $0) }
        claude = (try? Data(contentsOf: claudeURL)).flatMap { try? JSONDecoder().decode(ClaudeInfo.self, from: $0) }
        loadLocalState()
        loadUtskrift()
        cadModel = fm.fileExists(atPath: faces.path) ? faces : (fm.fileExists(atPath: stl.path) ? stl : nil)
        let newPhotos = (try? Data(contentsOf: photosURL)).flatMap { try? JSONDecoder().decode(FotonFil.self, from: $0) }?.foton
            .sorted { $0.bild < $1.bild } ?? []
        if newPhotos.map(\.bild) != photos.map(\.bild) {
            photos = newPhotos
            photoIndex = reliablePhotos.firstIndex { $0.vy == "ovanifrån" } ?? 0
        } else { photos = newPhotos }
        if let partList {
            parts = partList
        } else if let m = cadModel {
            parts = [PartInfo(id: "cad", namn: "CAD", fil: m.lastPathComponent, roll: "referens", farg: "#F28C26", export: nil, beskrivning: nil)]
        } else {
            parts = []
        }
        loadAnswers()
    }

    func loadAnswers() {
        answers = answersURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(SvarFil.self, from: $0) }?.svar ?? []
    }

    /// Spara ett svar (eller fritt meddelande) med ev. bilaga, som kopieras in i cad/bilagor/.
    func send(questionID: String, question: String, text: String, attachment: URL?, plats: PickPoint? = nil, trad: String? = nil, kant: Int? = nil,
              ritning: String? = nil, bilagaRel: String? = nil) {
        guard let folder = cadFolder, let url = answersURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var bilaga: String? = bilagaRel
        if let attachment {
            let dir = folder.appendingPathComponent("bilagor", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(attachment.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(attachment.deletingPathExtension().lastPathComponent)-\(n).\(attachment.pathExtension)"); n += 1
            }
            if (try? fm.copyItem(at: attachment, to: dest)) != nil { bilaga = "bilagor/" + dest.lastPathComponent }
        }
        loadAnswers()
        answers.append(Svar(fraga_id: questionID, fraga: question, svar: text, bilaga: bilaga, tid: isoNu(),
                            plats: plats?.pos, pa: plats?.target, yta: plats?.yta, ytatyp: plats?.ytatyp, del: plats?.del,
                            foto: plats?.foto, foto_px: plats?.foto_px, trad: trad, kant: kant, ritning: ritning))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(SvarFil(svar: answers)) { try? data.write(to: url, options: .atomic) }
    }

    func pickAttachment() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Välj foto eller fil att skicka till Claude"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Text att klistra in i chatten med Claude för att koppla upp den mot projektet.
    func askClaudeText() -> String {
        let path = output?.path ?? "?"
        let protocolPath = Hem.agentProtokoll.path
        if model != nil {
            return "Koppla upp mot \(Hem.appNamn): projektet \(path) har en färdig skanning. Läs \(protocolPath) och ta fram rensad CAD-geometri (cad/) – fråga mig i appen om det som är oklart."
        }
        return "Koppla upp mot \(Hem.appNamn): modellprojektet \(path) (ingen skanning). Läs \(protocolPath), läs mina meddelanden i cad/svar.json och rita delarna som del-skript i cad/skript/ – fråga mig i appen om det som är oklart."
    }

    func copyClaudeText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(askClaudeText(), forType: .string)
        toast = "Uppdraget är kopierat – klistra in i chatten med Claude"
    }

    func openFolder() { if let output { NSWorkspace.shared.open(output) } }
    func revealProject() { if let output { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
    func revealModel() { if let model { NSWorkspace.shared.activateFileViewerSelecting([model]) } }
    func copyModelPath() {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.path, forType: .string)
    }
    func printSheet() {
        if let url = Bundle.main.url(forResource: "referensark", withExtension: "pdf") { NSWorkspace.shared.open(url) }
        else { toast = "Referensarket saknas i appen" }
    }
    func request(_ view: String) { viewRequest = ViewRequest(name: view) }
}
