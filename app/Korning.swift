// Körning av CLI:t (skanna-cli i appen): video/foton → modell i mm, med förlopp.
import AppKit
import UniformTypeIdentifiers

extension Runner {
    var cli: URL {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/skanna-cli")
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
        let local = Hem.url.appendingPathComponent("skanna")
        if FileManager.default.isExecutableFile(atPath: local.path) { return local }
        return URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/skanna")
    }

    func add(_ urls: [URL]) {
        var rejected: [String] = []
        for u in urls {
            var dir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &dir)
            let isMovie = (UTType(filenameExtension: u.pathExtension)?.conforms(to: .movie)) ?? false
            if isMovie || dir.boolValue {
                if !clips.contains(u) { clips.append(u) }
            } else { rejected.append(u.lastPathComponent) }
        }
        if !rejected.isEmpty { toast = "Hoppade över \(rejected.joined(separator: ", ")) – bara videoklipp eller en mapp med foton" }
        let folders = clips.filter { u in var d: ObjCBool = false; FileManager.default.fileExists(atPath: u.path, isDirectory: &d); return d.boolValue }
        if !folders.isEmpty && clips.count > 1 {
            clips = [folders[0]]
            toast = "En fotomapp körs ensam – videoklippen togs bort ur listan"
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .folder]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Välj ett eller flera videoklipp (⌘-klicka för flera) – eller en mapp med foton"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Ny skanning från video/fotomapp: resultatet hamnar bredvid första klippet som <namn>.modell.
    func start() {
        guard !clips.isEmpty, !running else { return }
        let base = clips[0].deletingPathExtension()
        var out = base.appendingPathExtension("modell")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = base.appendingPathExtension("modell-\(n)"); n += 1 }
        var args = clips.map(\.path) + ["--ut", out.path, "--detalj", raw ? "raw" : "full"]
        let len = length.trimmingCharacters(in: .whitespaces)
        if !len.isEmpty { args += ["--langd", len] }
        runCLI(args, out: out)
    }

    /// Bygg 3D-modell av projektets egna bilder (guidad skanning/importerade foton) – modellen hamnar i projektet.
    func reconstructProject(turntable: Bool) {
        guard let project = output, !running else { return }
        var args = [project.appendingPathComponent("bilder").path, "--ut", project.path, "--detalj", raw ? "raw" : "full"]
        let len = length.trimmingCharacters(in: .whitespaces)
        if !len.isEmpty { args += ["--langd", len] }
        if turntable { args += ["--ordning", "sekventiell", "--maskning", "on"] }
        runCLI(args, out: project)
    }

    func runCLI(_ args: [String], out: URL) {
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            error = "Hittar inte skanna-programmet (\(cli.path)). Bygg om appen med bygg-beta.sh."
            return
        }
        log = ""; dims = nil; error = nil
        progress = 0; stageIndex = 0; pass = 0; buffer = ""
        passes = raw ? 1 : 2
        stage = "Startar …"
        running = true
        runningProject = out

        let p = Process()
        p.executableURL = cli
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["SKANNA_APP"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.finished(status: proc.terminationStatus, out: out)
            }
        }
        do { try p.run(); process = p } catch {
            running = false
            self.error = "Kunde inte starta skanna: \(error.localizedDescription)"
        }
    }

    func cancel() { process?.terminate() }

    private func ingest(_ s: String) {
        buffer += s
        while let r = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<r])
            buffer.removeSubrange(...r)
            handle(line)
        }
    }

    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("Warning") { return }
        if line.hasSuffix("%"), let p = Double(line.dropLast().trimmingCharacters(in: .whitespaces)) {
            let f = p / 100
            switch stageIndex {
            case 1: progress = 0.15 * f
            case 2: progress = 0.15 + 0.83 * min((Double(pass) + f) / passes, 1)
            default: break
            }
            return
        }
        log += line + "\n"
        if line.hasPrefix("1/3") { stageIndex = 1; stage = "Steg 1 av 3 · väljer de skarpaste bildrutorna ur videon" }
        else if line.hasPrefix("2/3") { stageIndex = 2; pass = 0; progress = max(progress, 0.15); stage = "Steg 2 av 3 · bygger 3D-modellen (tar några minuter)" }
        else if line.hasPrefix("3/3") { stageIndex = 3; progress = 0.98; stage = "Steg 3 av 3 · mäter och skalar" }
        else if line.hasPrefix("klar:") { pass += 1 }
        else if line.contains("pass 2") { pass = max(pass, 1) }
        else if line.hasPrefix("Mått:") { dims = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        else if line.hasPrefix("FEL:") { error = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
    }

    private func finished(status: Int32, out: URL) {
        running = false
        process = nil
        runningProject = nil
        guard status == 0 else {
            if error == nil { error = status == 15 ? "Avbrutet." : "skanna avslutades med fel (\(status)). Se loggen." }
            stage = "Stoppad"
            return
        }
        progress = 1
        stage = "Klar"
        refreshScans()
        select(out)
        NSSound(named: "Glass")?.play()
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Mått ur den skalade, uppräta modellen (modell-mm.obj): dess omslutande låda är måtten.
    func computeDims() {
        dims = nil
        guard let model, model.lastPathComponent == "modell-mm.obj" else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: model, options: .mappedIfSafe) else { return }
            var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
            // snabb genomläsning av "v x y z"-rader utan att dela upp hela filen i strängar
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let b = raw.bindMemory(to: UInt8.self)
                var i = 0
                let n = b.count
                while i < n {
                    if b[i] == UInt8(ascii: "v"), i + 1 < n, b[i + 1] == UInt8(ascii: " "), i == 0 || b[i - 1] == 10 {
                        var j = i + 2
                        var vals: [Double] = []
                        while vals.count < 3 && j < n && b[j] != 10 {
                            while j < n && b[j] == 32 { j += 1 }
                            let s = j
                            while j < n && b[j] != 32 && b[j] != 10 && b[j] != 13 { j += 1 }
                            if j > s, let v = Double(String(decoding: UnsafeBufferPointer(rebasing: b[s..<j]), as: UTF8.self)) { vals.append(v) }
                        }
                        if vals.count == 3 { for k in 0..<3 { lo[k] = min(lo[k], vals[k]); hi[k] = max(hi[k], vals[k]) } }
                        i = j
                    }
                    while i < n && b[i] != 10 { i += 1 }
                    i += 1
                }
            }
            guard lo[0].isFinite else { return }
            let s = (0..<3).map { String(format: "%.2f", hi[$0] - lo[$0]) }
            DispatchQueue.main.async {
                guard self?.model == model else { return }
                self?.dims = "\(s[0]) × \(s[1]) × \(s[2]) mm  (X × Y × Z)"
            }
        }
    }
}
