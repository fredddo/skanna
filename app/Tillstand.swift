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
        willSet { if newValue != output { flushUtskrift(); historikSpara(vanta: true) } }   // osparad historik till rätt projekt   // väntande utskriftsmeddelande till rätt projekt
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
    @Published var hidden: Set<String> = [] { didSet { if hidden != oldValue { noteChange("Visa/dölj"); saveObjektVisning() } } }
    @Published var objektOrdning: [String] = []          // användarens ordning i objektträdet (cad/objekt.json)
    @Published var fokusTrad: String?                   // tråden som "Claude väntar på ditt svar" öppnade (visas som aktiv tills du svarat)
    var fokusTradVantar = false                          // trådens svarsfält ska få fokus när tråden visas
    @Published var fokusTradTick = 0
    @Published var ortoVy: String?                      // rak vy med ortografisk projektion (lappen vid vykuben)
    @Published var utfallda: Set<String> = []           // delar vars kroppar är utfällda i objektträdet (sprängs då var för sig)
    @Published var borttagna: Set<String> = []          // raderade delar (cad/objekt.json)
    @Published var egnaNamn: [String: String] = [:]      // användarens namn på delar (cad/objekt.json)
    static let panelerByts = Notification.Name("skanna.panelerByts")
    @Published var dolPaneler = false { willSet { if newValue != dolPaneler { NotificationCenter.default.post(name: Runner.panelerByts, object: self) } } }                   // alla paneler släckta (⇥); Esc tänder igen
    @Published var claude: ClaudeInfo?
    @Published var focusQuestion: String?
    /// Peka: punkter som blir förankring för nästa meddelande (flera går; Esc eller annat verktyg tar bort dem).
    @Published var pekpunkter: [PickPoint] = []
    var pick: PickPoint? {
        get { pekpunkter.first }
        set { pekpunkter = newValue.map { [$0] } ?? [] }
    }
    @Published var photoIndex = 0
    @Published var toast: String?
    @Published var selectedPart: String?
    @Published var partOpacity: [String: Double] = [:]   // per del (och "skanning"), sparas per projekt
    @Published var sectionOn = false { didSet { if sectionOn != oldValue { if !sectionOn { aktivSnittvy = nil }; noteChange("Snitt") } } }
    @Published var sectionLabel: String?
    @Published var sectionCoord: Double?                 // planets läge (reglaget)

    // MARK: Verktyg och visning (Verktyg.swift) – ändrar aldrig modellen
    @Published var tool: Verktyg = .valj {
        didSet {
            guard tool != oldValue else { return }
            if oldValue == .peka { pekpunkter = [] }                  // pekpunkterna hör till Peka
            if tool == .valj || tool == .peka { matning = nil }      // Välj och Peka visar inga mått
            if tool == .valj { focusQuestion = nil }                 // … och Välj inga pratnålar eller Claudes markeringar
        }
    }
    @Published var traff: Traff?                         // vald del/yta/kant/punkt (verktyget Välj/Peka)
    @Published var info: Info?                           // mått på det valda (inspektören)
    @Published var matning: Matning?                     // verktyget Mät
    @Published var explode: Double = 0 { didSet { if explode != oldValue { noteChange("Sprängvy") }; if explode == 0 { spelar = false } } }   // 0 = ihop, 1 = helt isärdraget
    @Published var offsets: [String: SIMD3<Double>] = [:] { didSet { if offsets != oldValue { noteChange("Flytta") } } }
    /// Flytt gjord i sprängvyn: läggs till isärdragningen och skalas med reglaget, så den följer med ihop ↔ isär.
    @Published var sprangOffsets: [String: SIMD3<Double>] = [:] { didSet { if sprangOffsets != oldValue { noteChange("Flytta i sprängvyn") } } }
    @Published var spelar = false
    @Published var kanslighet: Kanslighet?               // vad som ändras när ett mått ändras (bakgrundsbygge)
    @Published var kanslighetKor = false
    @Published var mattInmatning: MattInmatning?          // inmatningsrutan vid ett måtthandtag
    @Published var relParam: String?                      // måttet musen står på i Mått-listan → visas i 3D
    var kanslighetProc: Process?                        // sprängvyn spelas upp (A): ihop ↔ isär i en loop  // tillfällig flytt per del-/objekt-id (mm)
    @Published var underObjekt: [String: [UnderObjekt]] = [:]  // sätts av 3D-vyn efter laddning
    // Snitt: klick placerar planet; sparade vyer i cad/snittvyer.json
    @Published var snittPlaceras = false { didSet { if snittPlaceras { aktivSnittvy = nil } } }  // nästa klick lägger snittplanet
    @Published var snittBegaran: SparadSnitt?            // 3D-vyn visar detta snitt (plan + kamera) och nollställer fältet
    @Published var snittvyer: [SparadSnitt] = []
    @Published var vyer: [SparadVy] = []                 // sparade vyer (miniatyrerna vid vykuben)
    @Published var vyBegaran: SparadVy?                  // 3D-vyn ställer in kameran för den här vyn och nollställer fältet
    var vyBilder: URL? { cadFolder?.appendingPathComponent("vyer", isDirectory: true) }
    @Published var aktivSnittvy: String?                 // id för den sparade snittvy som är tänd (nil = inget eller ett osparat snitt)
    @Published var fargschema: Fargschema = .hav {
        didSet { if let o = output, oldValue != fargschema { UserDefaults.standard.set(fargschema.rawValue, forKey: "farg:" + o.path); noteChange("Färgschema") } }
    }
    @Published var sectionRange: ClosedRange<Double> = 0...1
    // Rita (Rita.swift)
    @Published var ritning: Ritning?                     // väntande ritning (streck från samma vy, inte skickad än)
    @Published var visadRitning: Ritning?                // skickad ritning som visas i 3D-vyn
    @Published var ritBegaran: Ritning?                  // 3D-vyn flyger till ritningens vy och nollställer fältet
    @Published var mellanslag = false                    // ⌥ nedhållet i Rita: dra = vrid (namnet är historiskt)
    @Published var mikHall = false                       // mellanslag hålls utanför skrivfältet: chattrutans mikrofon lyssnar
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

    // MARK: Historik i git (Historik.swift)
    @Published var gitLage: GitLage = .okand
    @Published var historik: [HistorikPost] = []
    @Published var visaHistorik = false

    // MARK: Delning och kommentarer från delning (Dela.swift) – kommentarerna skickas aldrig till Claude
    @Published var visaDela = false
    @Published var delKommentarer: [DelKommentar] = []
    @Published var kommentarNal: String?                // kommentaren vars punkt visas som nål i 3D-vyn
    var historikNamn: [String] = []      // vad som ändrats sedan senaste commit (blir rubriken)
    var historikSenast: String?          // git status vid förra varvet – commit först när den legat still
    var historikUpptagen = false
    var claudeSett: String?              // senaste Claude-meddelandet som redan finns i en commit

    private var cadTimer: Timer?
    private var historikTimer: Timer?
    private var pendingRebuild = false
    private var byggBegaran = 0               // motorns löpnummer för senaste byggbegäran
    private var byggTimer: Timer?

    init() {
        cadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reloadCad(onlyIfChanged: true) }
        historikTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.historikTick() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.historikSpara(vanta: true)
            Motor.delad.stoppa()
        }
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
        let ov = loadObjektVisning()
        objektOrdning = ov.ordning; egnaNamn = ov.namn; borttagna = Set(ov.borttagna ?? []); fokusTrad = nil
        hidden = Set(ov.dolda); pick = nil; ritning = nil; visadRitning = nil; mellanslag = false; focusQuestion = nil; snapped = nil; note = nil; buildError = nil; buildLog = ""
        selectedPart = nil; sectionOn = false; sectionLabel = nil; sectionCoord = nil
        traff = nil; info = nil; matning = nil; explode = 0; offsets = [:]; sprangOffsets = [:]; spelar = false; underObjekt = [:]
        kanslighetProc?.terminate(); kanslighetProc = nil; kanslighet = nil; kanslighetKor = false; mattInmatning = nil; relParam = nil
        snittPlaceras = false; snittBegaran = nil; vyBegaran = nil
        vyer = cadFolder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("vyer.json")) }
            .flatMap { try? JSONDecoder().decode([SparadVy].self, from: $0) } ?? []
        snittvyer = cadFolder.flatMap { try? Data(contentsOf: $0.appendingPathComponent("snittvyer.json")) }
            .flatMap { try? JSONDecoder().decode([SparadSnitt].self, from: $0) } ?? []
        fargschema = output.flatMap { UserDefaults.standard.string(forKey: "farg:" + $0.path) }.flatMap(Fargschema.init(rawValue:))
            ?? Fargschema.standard(for: output?.path ?? "")
        partOpacity = output.flatMap { UserDefaults.standard.dictionary(forKey: "opacitet:" + $0.path) as? [String: Double] } ?? [:]
        cadStamp = .distantPast
        projekt = output.flatMap { try? Data(contentsOf: $0.appendingPathComponent("projekt.json")) }
            .flatMap { try? JSONDecoder().decode(ProjektFil.self, from: $0) }
        reloadCad()
        uppdateraGitLage()
        startKanslighet()
        kommentarerVidOppning()
    }

    // MARK: Lokalt tillstånd (användarens mått och stängda frågor)

    func loadLocalState() {
        // värde för värde: ett trasigt värde (t.ex. text) ska inte tömma alla andra mått
        let ov = overridesURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        overrides = ov.compactMapValues { ($0 as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } }
        closedQuestions = Set(closedURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    /// Ett tal som användaren skrivit: "−12,5", "12.5 mm", "22,5°" → Double. nil om texten inte är (bara) ett tal.
    static func tolkaTal(_ text: String, enhet: String? = nil) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "")
        for e in [enhet, "mm", "°", "st", "×", "x"].compactMap({ $0 }) where !e.isEmpty && t.lowercased().hasSuffix(e.lowercased()) {
            t = String(t.dropLast(e.count)); break
        }
        t = t.replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.allSatisfy({ "-+0123456789.eE".contains($0) }), let v = Double(t), v.isFinite else { return nil }
        return v
    }

    func setParam(_ name: String, _ text: String, unit: String? = nil) {
        guard let v = Runner.tolkaTal(text, enhet: unit), let project = output else { toast = "\"\(text)\" är inget tal"; return }
        if let nu = cad?.parametrar?.first(where: { $0.namn == name })?.varde, abs(nu - v) < 1e-9 { return }   // oförändrat
        noteChange("Ändra \(name)", immediate: true)
        do { try Motor.delad.anrop("POST", "/v1/parameter", kropp: ["projekt": project.path, "namn": name, "varde": v]) } catch {
            self.error = "Måttet kunde inte sparas: \(error)"; return
        }
        overrides[name] = v
        send(questionID: "parameter", question: name, text: String(format: "%@ = %g %@ (ändrat i appen)", name, v, unit ?? "mm"), attachment: nil)
        rebuild()
    }

    func resetParam(_ name: String) {
        guard let project = output else { return }
        noteChange("Återställ \(name)", immediate: true)
        do { try Motor.delad.anrop("POST", "/v1/parameter", kropp: ["projekt": project.path, "namn": name, "varde": NSNull()]) } catch {
            self.error = "Måttet kunde inte återställas: \(error)"; return
        }
        overrides[name] = nil
        rebuild()
    }

    /// Skriv (data) eller ta bort (nil) en delad fil i cad/ via motorn – för ångra/gör om.
    func motorFil(_ fil: String, _ data: Data?) {
        guard let project = output else { return }
        do {
            try Motor.delad.anrop("POST", "/v1/fil", kropp: ["projekt": project.path, "fil": fil,
                                                            "data": data.map { $0.base64EncodedString() } ?? NSNull()])
        } catch { self.error = "\(fil) kunde inte skrivas: \(error)" }
    }

    /// Bygg projektet i motorns byggkö (bygg_projekt.sh, ett bygge i taget per projekt). Fel visas i appen med loggen.
    /// Går motorn inte att nå körs bygg_projekt.sh direkt (det tar själv projektets bygglås).
    func rebuild() {
        guard canEdit, let project = output else { return }
        if let svar = try? Motor.delad.anrop("POST", "/v1/bygg", kropp: ["projekt": project.path]), let n = svar["begaran"] as? Int {
            kanslighetProc?.terminate(); kanslighetProc = nil
            buildError = nil
            rebuilding = true
            byggBegaran = max(byggBegaran, n)
            if byggTimer == nil {
                byggTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.byggKoll(project) }
            }
            return
        }
        rebuildLokalt(project)
    }

    private func byggKoll(_ project: URL) {
        guard output == project else { byggTimer?.invalidate(); byggTimer = nil; rebuilding = false; return }
        guard let s = try? Motor.delad.anrop("GET", "/v1/bygg", query: ["projekt": project.path], timeout: 5) else { return }
        guard let klar = s["klar_till"] as? Int, klar >= byggBegaran else { return }
        byggTimer?.invalidate(); byggTimer = nil
        rebuilding = false
        let text = s["logg"] as? String ?? ""
        let kod = s["kod"] as? Int ?? 1
        buildLog = text
        if kod != 0 {
            let last = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
            buildError = "Bygget misslyckades: " + last
        }
        reloadCad()
        refreshScans()
        if kod == 0 { startKanslighet() }
    }

    private func rebuildLokalt(_ project: URL) {
        if rebuilding { pendingRebuild = true; return }
        rebuilding = true
        kanslighetProc?.terminate(); kanslighetProc = nil
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
                else if proc.terminationStatus == 0 { self.startKanslighet() }
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
            let f = fargschema.farger.compactMap(NSColor.init(hex:))
            let i = parts.firstIndex(where: { $0.id == p.id }) ?? 0
            let palett = f.count > 1 ? (0..<f.count).map { f[(i + $0) % f.count] } : []
            return PartSpec(id: p.id, url: u, color: color(for: p), stamp: d, palett: palett, egna: fargschema == .egna)
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

    /// Raderna i objektträdet från toppen ner till det valda: delen (och dess föräldradelar), komponentgrupperna, kroppen.
    /// Nycklarna är samma som i utfallda (del-id, gruppNyckel) och sist kroppens id.
    func valdStig() -> [String] {
        guard let del = traff?.del ?? selectedPart else { return [] }
        let base = del.split(separator: "#").first.map(String.init) ?? del
        var delar = [base]
        var seen: Set<String> = [base]
        while let f = parts.first(where: { $0.id == delar[0] })?.foralder, !seen.contains(f), parts.contains(where: { $0.id == f }) {
            delar.insert(f, at: 0); seen.insert(f)
        }
        guard let obj = traff?.objekt, obj != base, let s = underObjekt[base]?.first(where: { $0.id == obj }), (underObjekt[base]?.count ?? 0) > 1
        else { return delar }
        let grupper = s.grupp.indices.map { UnderObjekt.gruppNyckel(base, Array(s.grupp.prefix($0 + 1))) }
        return delar + grupper + [obj]
    }

    /// Den rad i objektträdet som visar det valda just nu: den djupaste i valdStig som inte ligger under en ihopfälld nivå.
    func valdRad() -> String? {
        let stig = valdStig()
        guard var rad = stig.first else { return nil }
        for k in stig.dropFirst() {
            guard utfallda.contains(rad) else { break }
            rad = k
        }
        return rad
    }

    /// Fäll ut objektträdet ner till det valda (dubbelklick i 3D-vyn).
    func fallUtTillValt() {
        let stig = valdStig()
        for k in stig.dropLast() where !utfallda.contains(k) { utfallda.insert(k) }
    }

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
        _ = folder
        guard let project = output else { return }
        do { try Motor.delad.anrop("POST", "/v1/kantbehandling", kropp: ["projekt": project.path, "post": Motor.dict(k)]) } catch {
            self.error = "Kantbehandlingen kunde inte sparas: \(error)"; return
        }
        let what = k.typ == "fillet" ? String(format: "Fillet r = %g mm", k.matt) : String(format: "Fas %g mm", k.matt)
        send(questionID: "meddelande", question: "Kantbehandling", text: "\(what) på \(namn), kant \(k.kant.map(String.init) ?? "?")",
             attachment: nil, plats: PickPoint(pos: k.mitt, target: namn, del: k.del), kant: k.kant)
        if !scripts.isEmpty { rebuild() }
    }

    // MARK: Sparade vyer

    /// Anropas av 3D-vyn (begäran "spara-vy") med kameran, ev. snitt och en ögonblicksbild av canvasen.
    func saveVy(kamera: [Double], mal: [Double], snitt: SparadSnitt?, foto: String? = nil, bild: NSImage?) {
        guard let f = cadFolder else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        var id = "vy-" + fmt.string(from: Date()), n = 2
        while vyer.contains(where: { $0.id == id }) { id = "vy-\(fmt.string(from: Date()))-\(n)"; n += 1 }
        let v = SparadVy(id: id, namn: "Vy \(vyer.count + 1)", tid: isoNu(), kamera: kamera, mal: mal, dolda: hidden.sorted(),
                         flyttade: offsets.mapValues { [$0.x, $0.y, $0.z] }, explode: explode, opacitet: partOpacity,
                         fargschema: fargschema.rawValue, snitt: snitt, foto: foto,
                         sprangflyttade: sprangOffsets.isEmpty ? nil : sprangOffsets.mapValues { [$0.x, $0.y, $0.z] },
                         spelar: spelar && explode > 0 ? true : nil)
        if let bild, let dir = vyBilder, let png = Runner.miniatyr(bild) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: dir.appendingPathComponent(id + ".png"), options: .atomic)
        }
        vyer.append(v)
        writeVyer()
        _ = f
        toast = "\(v.namn) sparad\(foto != nil ? " (fotoläge)" : "") – klicka på miniatyren för att komma tillbaka hit"
    }

    /// Kvadratisk miniatyr (mitten av bilden), 192 px, PNG.
    static func miniatyr(_ img: NSImage) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let s = min(cg.width, cg.height)
        guard s > 0, let crop = cg.cropping(to: CGRect(x: (cg.width - s) / 2, y: (cg.height - s) / 2, width: s, height: s)) else { return nil }
        let side = 192
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    func vyBild(_ v: SparadVy) -> NSImage? { vyBilder.flatMap { NSImage(contentsOf: $0.appendingPathComponent(v.id + ".png")) } }

    /// Gå till en sparad vy: lager, flytt, explode, opacitet, färger och snitt här; kameran i 3D-vyn.
    func showVy(_ v: SparadVy) {
        noteChange("Visa \(v.namn)")
        hidden = Set(v.dolda)
        offsets = v.flyttade.compactMapValues { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
        explode = v.explode
        sprangOffsets = (v.sprangflyttade ?? [:]).compactMapValues { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil }
        spelar = v.spelar == true && v.explode > 0
        partOpacity = v.opacitet
        if let o = output { UserDefaults.standard.set(partOpacity, forKey: "opacitet:" + o.path) }
        if let fs = Fargschema(rawValue: v.fargschema) { fargschema = fs }
        if let s = v.snitt { showSection(s) } else { sectionOn = false; snittPlaceras = false }
        if v.foto == nil && snapped != nil { request("lämna-foto") }
        vyBegaran = v
    }
    func deleteVy(_ id: String) {
        vyer.removeAll { $0.id == id }
        if let dir = vyBilder { try? FileManager.default.removeItem(at: dir.appendingPathComponent(id + ".png")) }
        writeVyer()
    }
    func renameVy(_ id: String, _ namn: String) {
        guard let i = vyer.firstIndex(where: { $0.id == id }), !namn.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        vyer[i].namn = namn; writeVyer()
    }
    private func writeVyer() {
        guard let f = cadFolder else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let d = try? enc.encode(vyer) { try? d.write(to: f.appendingPathComponent("vyer.json"), options: .atomic) }
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
    func resetLayout() { offsets = [:]; sprangOffsets = [:]; explode = 0 }

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
        // tester (offscreen) öppnar aldrig Bambu Studio
        if ProcessInfo.processInfo.environment["SKANNA_ALDRIG_SLICER"] != nil { print("skulle öppna:", existing.map(\.path)); return }
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
    func isReceived(_ a: Svar) -> Bool { (claude?.mottaget).map { !tidEfter(a.tid, $0) } ?? false }
    func isRead(_ a: Svar) -> Bool { (cad?.last_svar).map { !tidEfter(a.tid, $0) } ?? false }

    static func pekBokstav(_ i: Int) -> String { i < 26 ? String(UnicodeScalar(65 + i)!) : "\(i + 1)" }

    /// Peka-klick: lägg till en punkt – eller ta bort den om man klickar nära en befintlig (inom 1,5 mm).
    func pekaKlick(_ p: PickPoint) {
        func d(_ a: [Double], _ b: [Double]) -> Double { sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)) }
        if let i = pekpunkter.firstIndex(where: { d($0.pos, p.pos) < 1.5 }) { pekpunkter.remove(at: i) } else { pekpunkter.append(p); skrivFokus += 1 }   // ny punkt: skriv (eller håll mellanslag och prata) direkt
    }

    var pins: [CadInfo.Markering] {
        var out: [CadInfo.Markering] = []
        // bara nålar från trådar som fortfarande är aktiva – avslutade trådars platser försvinner ur 3D-vyn
        let active = Set(chatThreads(closedLocal: loadClosedThreads()).threads.filter { $0.status != .klar }
            .flatMap { $0.entries.compactMap { $0.svar?.tid } })
        for (i, a) in answers.filter({ $0.plats != nil && active.contains($0.tid) }).enumerated() {
            out.append(.init(typ: "pin", fran: nil, till: nil, pos: a.plats, min: nil, max: nil, text: "\(i + 1)"))
            for f in a.fler ?? [] { out.append(.init(typ: "pin", fran: nil, till: nil, pos: f.plats, min: nil, max: nil, text: "\(i + 1)")) }
        }
        for (i, p) in pekpunkter.enumerated() {
            out.append(.init(typ: "pin_ny", fran: nil, till: nil, pos: p.pos, min: nil, max: nil, text: pekpunkter.count == 1 ? "här" : Runner.pekBokstav(i)))
        }
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
        loggaSkriptMatt(folder)
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
            parts = applyObjekt(partList)
        } else if let m = cadModel {
            parts = [PartInfo(id: "cad", namn: "CAD", fil: m.lastPathComponent, roll: "referens", farg: "#F28C26", export: nil, beskrivning: nil)]
        } else {
            parts = []
        }
        loadAnswers()
        loadKanslighet()
    }

    /// Mått som ändrats i skripten (av Claude) syns inte i svar.json. Jämför geometri.json med förra bygget
    /// (cad/visningar/parametrar-senast.json) och lägg ändrade standardvärden i cad/parameterlogg.json. Ändringar där
    /// användarens eget värde gäller (före eller efter) loggas redan av appen och hoppas över här.
    func loggaSkriptMatt(_ folder: URL) {
        guard let ps = cad?.parametrar else { return }
        let senast = folder.appendingPathComponent("visningar/parametrar-senast.json")
        var nu: [String: SkriptMatt] = [:]
        for p in ps { if let v = p.varde { nu[p.namn] = SkriptMatt(varde: v, kalla: p.kalla, enhet: p.enhet) } }
        let forra = (try? Data(contentsOf: senast)).flatMap { try? JSONDecoder().decode([String: SkriptMatt].self, from: $0) }
        if forra == nu { return }
        if let forra {
            var nya: [ParameterLogg.Andring] = []
            for (namn, n) in nu.sorted(by: { $0.key < $1.key }) {
                guard let f = forra[namn], abs(f.varde - n.varde) > 1e-9, f.kalla != "användare", n.kalla != "användare" else { continue }
                nya.append(.init(namn: namn, fran: f.varde, till: n.varde, enhet: n.enhet, tid: isoNu()))
            }
            if !nya.isEmpty {
                let u = folder.appendingPathComponent("parameterlogg.json")
                var logg = (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(ParameterLogg.self, from: $0) } ?? ParameterLogg(andringar: [])
                logg.andringar += nya
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                if let d = try? enc.encode(logg) { try? d.write(to: u, options: .atomic) }
            }
        }
        try? FileManager.default.createDirectory(at: senast.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(nu) { try? d.write(to: senast, options: .atomic) }
    }

    /// Claudes måttändringar som rader i "Ändrade mått".
    var skriptMattLogg: [Svar] {
        guard let u = cadFolder?.appendingPathComponent("parameterlogg.json"),
              let l = (try? Data(contentsOf: u)).flatMap({ try? JSONDecoder().decode(ParameterLogg.self, from: $0) }) else { return [] }
        return l.andringar.map { a in
            let txt = a.varfor.map { " – " + $0 } ?? ""
            return Svar(fraga_id: "parameter:" + a.namn, fraga: a.namn, svar: String(format: "%@ = %g → %g %@ (Claude)", a.namn, a.fran, a.till, a.enhet ?? "mm") + txt,
                        bilaga: nil, tid: a.tid)
        }
    }

    func loadKanslighet() {
        let u = cadFolder?.appendingPathComponent("visningar/kanslighet.json")
        let k = u.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Kanslighet.self, from: $0) }
        if k?.stampel != kanslighet?.stampel || (k == nil) != (kanslighet == nil) { kanslighet = k }
    }

    /// Räkna i bakgrunden ut vad varje mått påverkar (cad/kanslighet.py bygger om med måttet +1 i en tillfällig mapp).
    /// Gör inget om resultatet redan stämmer med skript och mått.
    func startKanslighet() {
        guard canEdit, !rebuilding, let project = output, let sk = scriptFolder,
              ((try? FileManager.default.contentsOfDirectory(atPath: sk.path)) ?? []).contains(where: { $0.hasSuffix(".py") }) else { return }
        kanslighetProc?.terminate()
        let p = Process()
        p.executableURL = Hem.url.appendingPathComponent(".venv/bin/python")
        p.arguments = [Hem.url.appendingPathComponent("cad/kanslighet.py").path, project.path]
        var env = ProcessInfo.processInfo.environment
        env["SKANNA_HEM"] = Hem.url.path
        p.environment = env
        p.qualityOfService = .background
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.kanslighetProc === proc else { return }
                self.kanslighetProc = nil; self.kanslighetKor = false
                self.loadKanslighet()
            }
        }
        do { try p.run(); kanslighetProc = p; kanslighetKor = true } catch { kanslighetKor = false }
    }

    /// Post för post: en post som inte går att läsa hoppas över i stället för att hela samtalet försvinner.
    func loadAnswers() {
        let rot = answersURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let poster = rot?["svar"] as? [Any] ?? []
        answers = poster.compactMap { p in
            (try? JSONSerialization.data(withJSONObject: p)).flatMap { try? JSONDecoder().decode(Svar.self, from: $0) }
        }
    }

    /// Spara ett svar (eller fritt meddelande) med ev. bilaga, som kopieras in i cad/bilagor/.
    func send(questionID: String, question: String, text: String, attachment: URL?, plats: PickPoint? = nil, trad: String? = nil, kant: Int? = nil,
              ritning: String? = nil, bilagaRel: String? = nil, fler: [PickPoint] = []) {
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
        let ny = Svar(fraga_id: questionID, fraga: question, svar: text, bilaga: bilaga, tid: isoNu(),
                      plats: plats?.pos, pa: plats?.target, yta: plats?.yta, ytatyp: plats?.ytatyp, del: plats?.del,
                      foto: plats?.foto, foto_px: plats?.foto_px, trad: trad, kant: kant, ritning: ritning,
                      fler: fler.isEmpty ? nil : fler.map { Svar.Plats(plats: $0.pos, pa: $0.target, yta: $0.yta, ytatyp: $0.ytatyp, del: $0.del,
                                                                        foto: $0.foto, foto_px: $0.foto_px) })
        var post = Motor.dict(ny)
        post.removeValue(forKey: "tid")          // motorn sätter en unik tid
        if let project = output, (try? Motor.delad.anrop("POST", "/v1/svar", kropp: ["projekt": project.path, "post": post])) != nil {
            loadAnswers()
            return
        }
        // reserv utan motor: lägg till posten i den befintliga filen (okända fält och poster bevaras), under projektets lås
        let projekt = folder.deletingLastPathComponent()
        let ok: Bool = ProjektLas.medLas(projekt) {
            var rot: [String: Any] = [:]
            if let d = try? Data(contentsOf: url) {
                guard let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }   // trasig: skriv inte över
                rot = r
            }
            var lista = rot["svar"] as? [Any] ?? []
            var p = Motor.dict(ny)
            let tider = lista.compactMap { ($0 as? [String: Any])?["tid"] as? String }
            p["tid"] = unikTid(efter: tider)
            lista.append(p)
            rot["svar"] = lista
            guard let data = try? JSONSerialization.data(withJSONObject: rot, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }
        if !ok { error = "Meddelandet kunde inte sparas: cad/svar.json går inte att läsa. Rätta filen (eller ta bort den) och skicka igen." }
        loadAnswers()
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
