// Historik i git: varaktig versionshistorik för projektets cad/ och projekt.json, vid sidan av Ångra.
// Ångra (Angra.swift) är snabb och finkornig men lever bara i minnet. Här görs en commit när en ändring är klar
// (Claude har byggt färdigt, ett mått har satt sig, projektbyte, appen stängs) – inte för varje klick.
// Skanningens råa evidens (bilder/, modell/, video) är stor och ändras inte: den hålls utanför git via projektets .gitignore.
import AppKit
import SwiftUI

enum GitLage: Equatable {
    case okand
    case ingenGit                 // git saknas på datorn (Command Line Tools)
    case ingetRepo
    case ignoreras(rot: URL)      // projektet ligger i ett repo men ignoreras av dess .gitignore
    case avstangd(rot: URL)
    case aktiv(rot: URL)

    var rot: URL? {
        switch self { case .ignoreras(let r), .avstangd(let r), .aktiv(let r): return r; default: return nil }
    }
}

struct HistorikPost: Identifiable, Hashable {
    let id: String        // sha
    let datum: Date
    let rubrik: String
    let text: String
    var kort: String { String(id.prefix(7)) }
}

enum Git {
    /// Finns git utan att macOS frågar om att installera Command Line Tools?
    static let finns: Bool = {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    @discardableResult
    static func kor(_ args: [String], i dir: URL) -> (ok: Bool, ut: String) {
        guard finns else { return (false, "git saknas") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_OPTIONAL_LOCKS"] = "0"; env["LC_ALL"] = "C"
        p.environment = env
        let ut = Pipe()
        p.standardOutput = ut; p.standardError = ut
        guard (try? p.run()) != nil else { return (false, "kunde inte starta git") }
        let data = ut.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// Repots rot för en mapp, eller nil om mappen inte ligger i ett git-repo.
    static func rot(_ dir: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let r = kor(["rev-parse", "--show-toplevel"], i: dir)
        let s = r.ut.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !s.isEmpty ? URL(fileURLWithPath: s, isDirectory: true) : nil
    }

    static func lage(_ projekt: URL) -> GitLage {
        guard finns else { return .ingenGit }
        guard let r = rot(projekt) else { return .ingetRepo }
        if kor(["check-ignore", "-q", "--no-index", "cad/parametrar-anvandare.json"], i: projekt).ok { return .ignoreras(rot: r) }
        return UserDefaults.standard.bool(forKey: "historikAv:" + projekt.path) ? .avstangd(rot: r) : .aktiv(rot: r)
    }

    /// Committa allt under `projekt` (och bara det – annat i repot rörs inte). Returnerar sha eller nil om inget ändrats.
    @discardableResult
    static func commit(_ projekt: URL, rubrik: String, text: String) -> String? {
        guard !kor(["status", "--porcelain", "-uall", "--", "."], i: projekt).ut.isEmpty else { return nil }
        guard kor(["add", "-A", "--", "."], i: projekt).ok else { return nil }
        var args: [String] = []
        if kor(["config", "user.email"], i: projekt).ut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-c", "user.name=Skanna", "-c", "user.email=skanna@lokal"]
        }
        args += ["commit", "-q", "--no-verify", "-m", rubrik]
        if !text.isEmpty { args += ["-m", text] }
        args += ["--", "."]
        guard kor(args, i: projekt).ok else { return nil }
        return kor(["rev-parse", "HEAD"], i: projekt).ut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func logg(_ projekt: URL) -> [HistorikPost] {
        let r = kor(["log", "-n", "300", "--format=%H%x1f%aI%x1f%s%x1f%b%x1e", "--", "."], i: projekt)
        guard r.ok else { return [] }
        let iso = ISO8601DateFormatter()
        return r.ut.split(separator: "\u{1e}").compactMap { rec in
            let f = rec.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard f.count >= 3, f[0].count == 40 else { return nil }
            return HistorikPost(id: f[0], datum: iso.date(from: f[1]) ?? .distantPast, rubrik: f[2],
                                text: f.count > 3 ? f[3].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
    }

    /// Projektets .gitignore: bara cad/ och projekt.json versioneras. I projekt med del-skript är STEP/STL/3MF/ytor
    /// byggresultat (bygg_projekt.sh gör om dem) och hålls utanför; i äldre skanningar utan skript är de källan och följer med.
    static func skrivIgnore(_ projekt: URL, byggs: Bool) {
        let u = projekt.appendingPathComponent(".gitignore")
        guard !FileManager.default.fileExists(atPath: u.path) else { return }
        var s = """
        # Skanna: bara cad/ och projekt.json versioneras. Skanningens bilder, video och mesh är rå evidens –
        # stora filer som inte ändras – och hålls utanför git.
        /*
        !/.gitignore
        !/projekt.json
        !/cad/
        /cad/visningar/
        /cad/poser-modell/
        .DS_Store

        """
        if byggs {
            s += """
            # Byggresultat (görs om av bygg_projekt.sh från cad/skript/)
            /cad/*.stl
            /cad/*.step
            /cad/*.3mf
            /cad/*-ytor.json
            /cad/bambu/

            """
        }
        try? s.write(to: u, atomically: true, encoding: .utf8)
    }
}

extension Runner {
    private static let gitKo = DispatchQueue(label: "skanna.historik")

    var historikPa: Bool { if case .aktiv = gitLage { return true }; return false }

    /// Kollas vid projektbyte och när inställningarna ändras.
    func uppdateraGitLage() {
        guard let projekt = output else { gitLage = .okand; historik = []; return }
        let byggs = canEdit && !scripts.isEmpty
        Runner.gitKo.async { [weak self] in
            let lage = Git.lage(projekt)
            if case .aktiv = lage { Git.skrivIgnore(projekt, byggs: byggs) }
            let logg = lage.rot == nil ? [] : Git.logg(projekt)
            DispatchQueue.main.async {
                guard let self, self.output == projekt else { return }
                self.gitLage = lage
                self.historik = logg
                self.historikSenast = nil
                self.claudeSett = self.claude?.meddelanden?.last?.tid
            }
        }
    }

    /// En sak som ändrats – blir en del av nästa commit-rubrik.
    func historikNotera(_ s: String) {
        guard !s.isEmpty, historikNamn.last != s else { return }
        historikNamn.append(s)
        if historikNamn.count > 30 { historikNamn.removeFirst() }
    }

    private func historikRubrik(filer: [String]) -> (String, String) {
        var delar: [String] = []
        var seen = Set<String>()
        for n in historikNamn where seen.insert(n).inserted { delar.append(n) }
        if filer.contains(where: { $0.hasSuffix("cad/svar.json") }), let a = answers.last, a.fraga_id != "parameter" {
            let rad = a.svar.split(whereSeparator: \.isNewline).first.map(String.init) ?? a.svar
            delar.append("Till Claude: " + (rad.isEmpty ? (a.ritning != nil ? "ritning" : "bilaga") : rad))
        }
        if let m = claude?.meddelanden?.last, m.tid != claudeSett {
            let rad = m.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? m.text
            delar.append("Claude: " + rad)
        }
        if historik.isEmpty { delar.insert("Första version i historiken", at: 0) }
        var rubrik = delar.joined(separator: " · ")
        if rubrik.isEmpty {
            let namn = filer.map { ($0 as NSString).lastPathComponent }
            rubrik = "Ändrade " + namn.prefix(3).joined(separator: ", ") + (namn.count > 3 ? " m.fl." : "")
        }
        if rubrik.count > 90 { rubrik = String(rubrik.prefix(89)) + "…" }
        let text = (delar.count > 1 || rubrik.hasSuffix("…") ? delar.map { "- " + $0 }.joined(separator: "\n") + "\n\n" : "")
            + "Filer:\n" + filer.prefix(40).map { "  " + $0 }.joined(separator: "\n") + (filer.count > 40 ? "\n  …" : "")
            + "\n\n(automatisk commit från \(Hem.appNamn))"
        return (rubrik, text)
    }

    /// Var 5:e sekund: committa när ändringarna har legat still ett varv och inget pågår (bygge, ett drag, Claude arbetar).
    func historikTick() {
        guard let projekt = output, historikPa, !historikUpptagen, !rebuilding, undoBurst == nil, claude?.status != "arbetar" else { return }
        historikUpptagen = true
        Runner.gitKo.async { [weak self] in
            let status = Git.kor(["status", "--porcelain", "-uall", "--", "."], i: projekt).ut
            DispatchQueue.main.async {
                guard let self else { return }
                self.historikUpptagen = false
                guard self.output == projekt else { return }
                if status.isEmpty { self.historikSenast = nil; self.historikNamn = []; self.claudeSett = self.claude?.meddelanden?.last?.tid; return }
                if status != self.historikSenast { self.historikSenast = status; return }
                self.historikSpara(projekt, status: status)
            }
        }
    }

    private func filLista(_ status: String) -> [String] {
        status.split(whereSeparator: \.isNewline).map { String($0.dropFirst(3)) }
    }

    /// Committa nu. `vanta`: synkront (projektbyte, appen stängs, före återgång).
    func historikSpara(_ projekt: URL? = nil, status: String? = nil, vanta: Bool = false, rubrik egen: String? = nil) {
        guard let projekt = projekt ?? output else { return }
        if projekt == output { guard historikPa else { return } } else if case .aktiv = Git.lage(projekt) {} else { return }
        let st = status ?? Git.kor(["status", "--porcelain", "-uall", "--", "."], i: projekt).ut
        guard !st.isEmpty else { return }
        var (rubrik, text) = historikRubrik(filer: filLista(st))
        if let egen { rubrik = egen }
        historikNamn = []; historikSenast = nil
        claudeSett = claude?.meddelanden?.last?.tid
        let jobb = { [weak self] in
            Git.commit(projekt, rubrik: rubrik, text: text)
            let logg = Git.logg(projekt)
            DispatchQueue.main.async { if self?.output == projekt { self?.historik = logg } }
        }
        if vanta { Runner.gitKo.sync(execute: jobb) } else { Runner.gitKo.async(execute: jobb) }
    }

    /// Gå tillbaka till en version: cad/ (utom samtalet med Claude) blir som då. Det blir en ny commit, så inget skrivs över.
    func historikTillbaka(_ post: HistorikPost) {
        guard let projekt = output, historikPa else { return }
        historikSpara(vanta: true, rubrik: "Innan återgång till \(post.kort)")
        let behall = ["cad/svar.json", "cad/claude.json", "cad/stangda-fragor.json", "cad/bilagor", "cad/ritningar"].map { ":(exclude)" + $0 }
        let r = Runner.gitKo.sync { Git.kor(["restore", "--source=" + post.id, "--worktree", "--", "."] + behall, i: projekt) }
        guard r.ok else { error = "Kunde inte gå tillbaka: " + r.ut.trimmingCharacters(in: .whitespacesAndNewlines); return }
        let datum = post.datum.formatted(date: .abbreviated, time: .shortened)
        // läs om allt från disk som om projektet öppnades igen, och bygg om delarna
        let ov = loadObjektVisning()
        undoPaused = true
        objektOrdning = ov.ordning; egnaNamn = ov.namn; hidden = Set(ov.dolda)
        cadStamp = .distantPast
        reloadCad()
        resetUndo()
        send(questionID: "parameter", question: "Historik",
             text: "Gick tillbaka till version \(post.kort) från \(datum) (\"\(post.rubrik)\") i appens historik. Filerna i cad/ är som då, utom samtalet (svar.json, claude.json, bilagor, ritningar). Läs om skripten innan du fortsätter.",
             attachment: nil)
        historikSpara(vanta: true, rubrik: "Tillbaka till \(post.kort) (\(datum)): \(post.rubrik)")
        if canEdit { rebuild() }
        toast = "Tillbaka till \(datum)"
    }

    /// Gör en mapp till git-repo (git init). Returnerar felet om det inte gick.
    func gorTillRepo(_ dir: URL) -> String? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = Git.kor(["init", "-q"], i: dir)
        uppdateraGitLage()
        return r.ok ? nil : r.ut
    }

    func satHistorik(pa: Bool) {
        guard let o = output else { return }
        UserDefaults.standard.set(!pa, forKey: "historikAv:" + o.path)
        uppdateraGitLage()
    }
}

// MARK: Historikvyn

struct HistorikVy: View {
    @ObservedObject var run: Runner
    @Environment(\.dismiss) private var dismiss
    @State private var valj: HistorikPost?
    @State private var fel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Historik").font(.title2.bold())
                Spacer()
                Button("Klar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            lageRuta
            if run.historik.isEmpty {
                Text(run.historikPa ? "Inga versioner än – första commit görs när en ändring har satt sig." : "Ingen historik.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(run.historik) { p in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.rubrik).lineLimit(2)
                            Text("\(p.datum.formatted(date: .abbreviated, time: .shortened)) · \(p.kort)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.id != run.historik.first?.id {
                            Button("Gå tillbaka hit") { valj = p }.controlSize(.small)
                        } else {
                            Text("nu").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(p.text)
                }
                .frame(minHeight: 280)
            }
            Text("⌘Z ångrar enskilda steg medan appen är öppen. Historiken här finns kvar mellan omstarter och omfattar även Claudes ändringar. Att gå tillbaka blir en ny version – inget skrivs över, och samtalet med Claude ligger kvar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 580)
        .onAppear { run.uppdateraGitLage() }
        .confirmationDialog("Gå tillbaka till \(valj?.kort ?? "")?", isPresented: Binding(get: { valj != nil }, set: { if !$0 { valj = nil } })) {
            Button("Gå tillbaka") { if let v = valj { run.historikTillbaka(v); dismiss() } }
        } message: {
            Text("Delarnas skript, mått och inställningar blir som \(valj?.datum.formatted(date: .abbreviated, time: .shortened) ?? ""). Nuvarande läge sparas först som en egen version, så du kan komma tillbaka hit.")
        }
    }

    @ViewBuilder private var lageRuta: some View {
        switch run.gitLage {
        case .aktiv(let rot):
            Label("Sparas automatiskt i git-repot \(rot.path)", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout)
            Toggle("Spara historik för det här projektet", isOn: Binding(get: { true }, set: { run.satHistorik(pa: $0) })).font(.callout)
        case .avstangd:
            Toggle("Spara historik för det här projektet", isOn: Binding(get: { false }, set: { run.satHistorik(pa: $0) })).font(.callout)
        case .ignoreras(let rot):
            Varning(text: "Projektet ligger i git-repot \(rot.path), men repots .gitignore utesluter det. Ingen historik sparas.")
        case .ingetRepo:
            VStack(alignment: .leading, spacing: 8) {
                Varning(text: "Projektet ligger inte i ett git-repo, så det finns ingen varaktig historik – bara ⌘Z medan appen är öppen. Starkt rekommenderat: gör projektmappen till ett git-repo.")
                HStack {
                    if let o = run.output {
                        Button("Gör projektet till git-repo") { fel = run.gorTillRepo(o) }
                    }
                    Text("Bilder och mesh hålls utanför git.").font(.caption).foregroundStyle(.secondary)
                }
                if let fel { Text(fel).font(.caption).foregroundStyle(.red) }
            }
        case .ingenGit:
            Varning(text: "git finns inte på datorn. Installera Command Line Tools (xcode-select --install) för att få historik.")
        case .okand:
            ProgressView().controlSize(.small)
        }
    }
}

struct Varning: View {
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: Inställningar (⌘,)

struct InstallningarVy: View {
    @ObservedObject var run: Runner
    @AppStorage("projektRot") private var rotStig = ""
    @AppStorage("skanningarIProjektmappen") private var skanningarIRot = true
    @State private var rotLage: GitLage = .okand
    @State private var fel: String?

    private var rot: URL { Hem.projektRot }

    var body: some View {
        Form {
            Section {
                LabeledContent("Projektmapp") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(rot.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        HStack {
                            if !rotStig.isEmpty { Button("Standard") { rotStig = ""; kolla() } }
                            Button("Välj …") { valjRot() }
                        }
                    }
                }
                Toggle("Lägg nya videoskanningar i projektmappen (annars bredvid klippet)", isOn: $skanningarIRot)
                Text("Nya modellprojekt, guidade skanningar och – om rutan är ikryssad – videoskanningar hamnar här. Befintliga projekt ligger kvar där de är.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Var filerna sparas") }

            Section {
                switch rotLage {
                case .aktiv(let r), .avstangd(let r):
                    Label("Projektmappen ligger i git-repot \(r.path). Varje projekt får automatisk historik.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .ignoreras(let r):
                    Varning(text: "Projektmappen ligger i git-repot \(r.path) men ignoreras av dess .gitignore. Välj en annan mapp eller ändra .gitignore.")
                case .ingetRepo:
                    Varning(text: "Projektmappen är inget git-repo. Starkt rekommenderat: utan git finns ingen historik mellan omstarter, och Claudes ändringar går bara att ångra medan appen är öppen.")
                    Button("Gör projektmappen till git-repo") { fel = run.gorTillRepo(rot); kolla() }
                case .ingenGit:
                    Varning(text: "git finns inte på datorn. Installera Command Line Tools (xcode-select --install).")
                case .okand:
                    ProgressView().controlSize(.small)
                }
                if let fel { Text(fel).font(.caption).foregroundStyle(.red) }
                Text("Appen gör en commit när en ändring har satt sig – Claude har byggt färdigt, ett mått är ändrat, du byter projekt eller stänger appen. Bara cad/ och projekt.json versioneras; bilder, video och mesh (hundratals MB) hålls utanför via projektets .gitignore. Appen pushar aldrig.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text("Historik (git)") }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onAppear(perform: kolla)
    }

    private func kolla() {
        let r = rot
        rotLage = .okand
        DispatchQueue.global().async {
            try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            let l: GitLage = !Git.finns ? .ingenGit : (Git.rot(r).map { root in
                Git.kor(["check-ignore", "-q", "--no-index", "x/cad/parametrar-anvandare.json"], i: r).ok ? .ignoreras(rot: root) : .aktiv(rot: root)
            } ?? .ingetRepo)
            DispatchQueue.main.async { rotLage = l }
        }
    }

    private func valjRot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = rot
        panel.prompt = "Välj"
        panel.message = "Välj var nya projekt ska sparas – helst i ett git-repo"
        if panel.runModal() == .OK, let u = panel.url {
            rotStig = u.path
            run.refreshScans()
            kolla()
        }
    }
}
