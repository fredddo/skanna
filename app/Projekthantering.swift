// Projektlistan, nya projekt (med eller utan skanning) och delar från mallar.
import AppKit
import UniformTypeIdentifiers

extension Runner {
    private var extraFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraScanFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraScanFolders") }
    }

    /// Projekt = *.modell*-mappar (video-skanningar) i Hämtade filer/Skrivbord/Dokument, plus alla mappar med projekt.json i projektmappen.
    func refreshScans() {
        let fm = FileManager.default
        var places = [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        places += clips.map { $0.deletingLastPathComponent() }
        var found = Set<URL>()
        for place in Set(places) {
            let items = (try? fm.contentsOfDirectory(at: place, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for u in items where u.lastPathComponent.contains(".modell") {
                var dir: ObjCBool = false
                if fm.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue { found.insert(u.standardizedFileURL) }
            }
        }
        for u in (try? fm.contentsOfDirectory(at: Hem.projektRot, includingPropertiesForKeys: nil)) ?? []
        where fm.fileExists(atPath: u.appendingPathComponent("projekt.json").path) || u.lastPathComponent.contains(".modell") {
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
        panel.allowedContentTypes = [UTType(filenameExtension: "obj")!, .usdz, .folder]
        panel.message = "Välj en projektmapp (*.modell eller en mapp med projekt.json) eller en modellfil (.obj/.usdz)"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        var dir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &dir)
        if dir.boolValue {
            if !extraFolders.contains(u.path) { extraFolders.append(u.path) }
            refreshScans()
            select(u)
        } else {
            output = u.deletingLastPathComponent()
            model = u
            screen = .projekt
            computeDims()
        }
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
