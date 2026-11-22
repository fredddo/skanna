// Projektlistan, nya projekt (med eller utan skanning) och delar från mallar.
import AppKit
import UniformTypeIdentifiers

extension Runner {
    private var extraFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraScanFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraScanFolders") }
    }

    /// Projekt = *.modell*-mappar (video-skanningar) i Hämtade filer/Skrivbord/Dokument, plus alla mappar med projekt.json i projektmappen.
    ///
    /// Hämtade filer, Skrivbordet och Dokument är skyddade i macOS: varje mapp appen läser ger en fråga om åtkomst. De gås
    /// därför bara igenom en gång; efter det läses bara de mappar som faktiskt hade skanningar ("modellPlatser"), plus
    /// klippens mappar och projektmappen. En skanning på ett nytt ställe hittas via ⌘O (den läggs då i listan).
    func refreshScans() {
        let fm = FileManager.default
        let standard = [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        let sparade = UserDefaults.standard.stringArray(forKey: "modellPlatser")
        var places = sparade.map { $0.map { URL(fileURLWithPath: $0, isDirectory: true) } } ?? standard
        places += clips.map { $0.deletingLastPathComponent() }
        var found = Set<URL>()
        var medSkanningar = Set<String>()
        for place in Set(places) {
            let items = (try? fm.contentsOfDirectory(at: place, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for u in items where u.lastPathComponent.contains(".modell") {
                var dir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue {
                    found.insert(u.standardizedFileURL)
                    medSkanningar.insert(place.standardizedFileURL.path)
                }
            }
        }
        if sparade == nil {   // första gången: kom ihåg vilka av standardmapparna som har skanningar
            let std = Set(standard.map(\.standardizedFileURL.path))
            UserDefaults.standard.set(medSkanningar.filter(std.contains).sorted(), forKey: "modellPlatser")
        }
        for u in (try? fm.contentsOfDirectory(at: Hem.projektRot, includingPropertiesForKeys: nil)) ?? []
        where fm.fileExists(atPath: u.appendingPathComponent("projekt.json").path) || u.lastPathComponent.contains(".modell")
            || fm.fileExists(atPath: u.appendingPathComponent("cad/skript").path) {
            found.insert(u.standardizedFileURL)
        }
        for p in extraFolders where fm.fileExists(atPath: p) { found.insert(URL(fileURLWithPath: p).standardizedFileURL) }
        scans = found.map { u in
            let model = Runner.findModel(in: u)
            let images = ((try? fm.contentsOfDirectory(atPath: u.appendingPathComponent("bilder").path)) ?? [])
                .filter { bildandelser.contains(($0 as NSString).pathExtension.lowercased()) }.count
            let hasParts = fm.fileExists(atPath: u.appendingPathComponent("cad/delar.json").path)
            let typ: ProjektPost.Typ = model != nil ? .skanning : (images > 0 ? .bilder : (hasParts ? .modell : .tom))
            let stamp = [u, u.appendingPathComponent("cad")].compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            }.max() ?? .distantPast
            let name = (try? Data(contentsOf: u.appendingPathComponent("projekt.json")))
                .flatMap { try? JSONDecoder().decode(ProjektFil.self, from: $0) }?.namn ?? u.lastPathComponent
            return ProjektPost(id: u, name: name, date: stamp, model: model, typ: typ, bildantal: images)
        }.sorted { $0.date > $1.date }
        mallar = Mall.alla()
    }

    static func findModel(in folder: URL) -> URL? {
        let fm = FileManager.default
        let sub = folder.appendingPathComponent("modell")
        let scaled = sub.appendingPathComponent("modell-mm.obj")
        if fm.fileExists(atPath: scaled.path) { return scaled }
        let usdz = folder.appendingPathComponent("modell.usdz")
        if fm.fileExists(atPath: usdz.path) { return usdz }
        let objs = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
        return objs.first { $0.pathExtension.lowercased() == "obj" }
    }

    func select(_ folder: URL) {
        output = folder.standardizedFileURL
        model = Runner.findModel(in: folder)
        error = nil
        screen = .projekt
        computeDims()
        UserDefaults.standard.set(folder.path, forKey: "senasteProjekt")
    }

    func restoreLast() {
        guard let p = UserDefaults.standard.string(forKey: "senasteProjekt"), FileManager.default.fileExists(atPath: p) else { return }
        select(URL(fileURLWithPath: p))
    }

    func openOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.usdz, .folder] + Runner.importAndelser.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Välj en projektmapp (skanning *.modell eller modellprojekt) – eller CAD-filer (STEP, STL, 3MF, OBJ): de blir delar i ett nytt modellprojekt"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if panel.urls.count == 1, panel.urls[0].pathExtension.lowercased() == "usdz" { oppnaModellfil(panel.urls[0]); return }
        oppnaFiler(panel.urls)
    }

    /// Öppna (⌘O) eller dra in i projektlistan/startsidan: en projektmapp öppnas; CAD-filer (STEP, STL, 3MF, OBJ) blir delar
    /// (cad/importera.py: ytor, kanter, kroppar – mät, snitt och utskrift fungerar) i ett nytt modellprojekt med filens namn.
    /// (Dras filen in i 3D-vyn hamnar den i det öppna projektet i stället.)
    func oppnaFiler(_ urls: [URL]) {
        let fm = FileManager.default
        var mappar: [URL] = [], filer: [URL] = []
        for u in urls {
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &dir) else { continue }
            if dir.boolValue { mappar.append(u) } else if Runner.kanImportera(u) { filer.append(u) }
        }
        if let m = mappar.first, filer.isEmpty { oppnaMapp(m); return }
        guard !filer.isEmpty else { toast = "Välj en projektmapp eller STEP-, STL-, 3MF- eller OBJ-filer"; return }
        let namn = filer.count == 1 ? filer[0].deletingPathExtension().lastPathComponent : "Importerade delar"
        guard createModelProject(name: namn, template: nil, message: "") != nil else { return }
        importeraDelar(filer)
    }

    private func oppnaModellfil(_ u: URL) {
        output = u.deletingLastPathComponent()
        model = u
        screen = .projekt
        computeDims()
    }

    private func oppnaMapp(_ u: URL) {
        if !extraFolders.contains(u.path) { extraFolders.append(u.path) }
        refreshScans()
        select(u)
    }

    func removeFromList(_ u: URL) {
        extraFolders.removeAll { $0 == u.path }
        refreshScans()
    }

    /// Unik mapp under projektmappen för ett nytt namn.
    func newProjectFolder(_ name: String) -> URL {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let base = clean.isEmpty ? "Nytt projekt" : clean
        let fm = FileManager.default
        try? fm.createDirectory(at: Hem.projektRot, withIntermediateDirectories: true)
        var u = Hem.projektRot.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: u.path) { u = Hem.projektRot.appendingPathComponent("\(base) \(n)", isDirectory: true); n += 1 }
        return u
    }

    func writeProjectFile(_ p: ProjektFil, in folder: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        if let d = try? enc.encode(p) { try? d.write(to: folder.appendingPathComponent("projekt.json"), options: .atomic) }
    }

    /// Nytt modellprojekt (utan skanning): ev. en del från mall, och ev. ett första meddelande till Claude.
    @discardableResult
    func createModelProject(name: String, template: Mall?, message: String) -> URL? {
        let folder = newProjectFolder(name)
        do {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("cad/skript"), withIntermediateDirectories: true)
        } catch { self.error = "Kunde inte skapa \(folder.path): \(error.localizedDescription)"; return nil }
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        writeProjectFile(ProjektFil(namn: folder.lastPathComponent, typ: "modell", skapad: isoNu(), kalla: template == nil ? nil : "mall",
                                    beskrivning: msg.isEmpty ? nil : msg), in: folder)
        refreshScans()
        select(folder)
        if !msg.isEmpty { send(questionID: "meddelande", question: "Meddelande till Claude", text: msg, attachment: nil) }
        if let template { addPart(from: template) }
        return folder
    }

    /// Kopiera en mall till projektets cad/skript/ och bygg. Fungerar även i skanningsprojekt.
    func addPart(from mall: Mall) {
        guard let dir = scriptFolder else { return }
        noteChange("Lägg till \(mall.namn)", immediate: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = "50-\(mall.id).py"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) { name = "50-\(mall.id)-\(n).py"; n += 1 }
        do { try fm.copyItem(at: mall.fil, to: dir.appendingPathComponent(name)) } catch {
            toast = "Kunde inte kopiera mallen: \(error.localizedDescription)"; return
        }
        toast = "\(mall.namn) lagd till – bygger …"
        rebuild()
    }

    // MARK: Importera delar från andra CAD-program (cad/importera.py)

    static let importAndelser = ["step", "stp", "stl", "3mf", "obj"]
    static func kanImportera(_ u: URL) -> Bool { importAndelser.contains(u.pathExtension.lowercased()) }

    /// Välj STEP/STL/3MF/OBJ-filer och lägg in dem som delar.
    func valjImport() {
        guard output != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Runner.importAndelser.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Välj filer att importera som delar. STEP ger riktiga ytor och kanter; STL, 3MF och OBJ är trianglar."
        panel.prompt = "Importera"
        let ref = NSButton(checkboxWithTitle: "Som referens (visas och går att mäta mot, men skrivs inte ut)", target: nil, action: nil)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 34))
        ref.frame.origin = NSPoint(x: 12, y: 8)
        ref.sizeToFit()
        box.addSubview(ref)
        panel.accessoryView = box
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return }
        importeraDelar(panel.urls, referens: ref.state == .on)
    }

    /// Kopiera filerna till cad/import/ och skriv ett del-skript per fil (cad/skript/50-import-<id>.py), bygg sedan.
    @discardableResult
    func importeraDelar(_ urls: [URL], referens: Bool = false) -> [String] {
        let filer = urls.filter(Runner.kanImportera)
        guard !filer.isEmpty, let cad = cadFolder, let dir = scriptFolder else {
            if !urls.isEmpty { toast = "Bara STEP, STL, 3MF och OBJ går att importera" }
            return []
        }
        let fm = FileManager.default
        let importDir = cad.appendingPathComponent("import", isDirectory: true)
        do {
            try fm.createDirectory(at: importDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { toast = "Kunde inte skapa \(importDir.path): \(error.localizedDescription)"; return [] }
        noteChange(filer.count == 1 ? "Importera \(filer[0].lastPathComponent)" : "Importera \(filer.count) filer", immediate: true)
        var ids = Set(parts.map(\.id))
        var klara: [String] = []
        for src in filer {
            let namn = src.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping   // macOS-filnamn är NFD
            let bas = "import-" + Runner.slug(namn)
            var id = bas, n = 2
            while ids.contains(id) || fm.fileExists(atPath: dir.appendingPathComponent("50-\(id).py").path) { id = "\(bas)-\(n)"; n += 1 }
            ids.insert(id)
            let ext = src.pathExtension.lowercased()
            var fil = src.lastPathComponent.precomposedStringWithCanonicalMapping   // originalnamnet behålls
            if !src.standardizedFileURL.path.hasPrefix(importDir.standardizedFileURL.path + "/") {
                var k = 2
                while fm.fileExists(atPath: importDir.appendingPathComponent(fil).path) { fil = "\(namn) \(k).\(src.pathExtension)"; k += 1 }
                let dst = importDir.appendingPathComponent(fil)
                do { try fm.copyItem(at: src, to: dst) } catch {
                    toast = "Kunde inte kopiera \(src.lastPathComponent): \(error.localizedDescription)"; continue
                }
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
            func lit(_ s: String) -> String { String(decoding: (try? enc.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self) }
            let skript = """
            # Importerad del: \(src.lastPathComponent) (\(ext == "step" || ext == "stp" ? "STEP, ytor och kanter" : "trianglar")), \
            importerad \(isoNu()) av \(Hem.appNamn).
            # Originalfilen ligger i cad/import/. Placeringen ändras med måtten "\(namn): flytta x" osv. i appen.
            # Byt fil: ersätt filen i cad/import/ (samma namn) och bygg om. Se cad/importera.py i Skanna-hemmet.
            import os, sys
            sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
            from projekt import Projekt
            from importera import importera

            prj = Projekt(sys.argv[1])
            importera(prj, \(lit(id)), \(lit(namn)), \(lit("import/" + fil)), roll=\(lit(referens ? "referens" : "design")), farg="#8E8E93")

            """
            do { try skript.write(to: dir.appendingPathComponent("50-\(id).py"), atomically: true, encoding: .utf8) } catch {
                toast = "Kunde inte skriva del-skriptet: \(error.localizedDescription)"; continue
            }
            klara.append(namn)
        }
        guard !klara.isEmpty else { return [] }
        let hoppade = urls.count - filer.count
        toast = (klara.count == 1 ? "\(klara[0]) importerad" : "\(klara.count) filer importerade") + " – bygger …"
            + (hoppade > 0 ? " (\(hoppade) fil\(hoppade == 1 ? "" : "er") hoppades över: bara STEP, STL, 3MF och OBJ)" : "")
        rebuild()
        return klara
    }

    /// "Fäste v2 (å)" → "faste-v2-a"
    static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "sv_SE")).lowercased()
        var out = ""
        for c in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(c) && c.isASCII { out.unicodeScalars.append(c) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        let t = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return t.isEmpty ? "del" : String(t.prefix(40))
    }

    func openScript(_ u: URL) { NSWorkspace.shared.open(u) }

    /// Nytt guidat skanningsprojekt: tom bildmapp + projekt.json, och sedan fotoläget.
    func createCaptureProject(name: String, plan: Fotoplan) -> URL? {
        let folder = newProjectFolder(name)
        do { try FileManager.default.createDirectory(at: folder.appendingPathComponent("bilder"), withIntermediateDirectories: true) }
        catch { self.error = "Kunde inte skapa \(folder.path): \(error.localizedDescription)"; return nil }
        writeProjectFile(ProjektFil(namn: folder.lastPathComponent, typ: "skanning", skapad: isoNu(), kalla: "guidad", plan: plan), in: folder)
        refreshScans()
        output = folder.standardizedFileURL
        model = nil
        return folder
    }

    /// Importera foton (t.ex. tagna med iPhonens kameraapp) till ett nytt skanningsprojekt.
    func importPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .folder]
        panel.message = "Välj foton (eller en mapp med foton) från vridskivan/stativet"
        guard panel.runModal() == .OK else { return }
        var files: [URL] = []
        for u in panel.urls {
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &d)
            if d.boolValue {
                files += ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                    .filter { bildandelser.contains($0.pathExtension.lowercased()) }
            } else if bildandelser.contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        guard !files.isEmpty else { toast = "Inga bilder valda"; return }
        let name = panel.urls[0].deletingPathExtension().lastPathComponent
        let folder = newProjectFolder(name)
        let bilder = folder.appendingPathComponent("bilder")
        try? FileManager.default.createDirectory(at: bilder, withIntermediateDirectories: true)
        for f in files { try? FileManager.default.copyItem(at: f, to: bilder.appendingPathComponent(f.lastPathComponent)) }
        writeProjectFile(ProjektFil(namn: folder.lastPathComponent, typ: "skanning", skapad: isoNu(), kalla: "foton"), in: folder)
        refreshScans()
        select(folder)
    }
}
