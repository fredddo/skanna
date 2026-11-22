// Huvudfönstret: projektlista till vänster, och till höger antingen välkomstsidan, en ny skanning,
// guidad skanning eller arbetsytan för valt projekt.
import AppKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var run: Runner
    @StateObject private var kamera = Kamera()
    @AppStorage("sidebarHidden") private var big = false

    var body: some View {
        HSplitView {
            if !big && !(run.dolPaneler && run.screen == .projekt) {
                Sidebar(run: run)
                    .frame(minWidth: 240, idealWidth: 270, maxWidth: 360)
            }
            detail
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) { ToastView(run: run) }
        .sheet(isPresented: $run.showNewProject) { NewProjectSheet(run: run) }
        .sheet(isPresented: $run.showShortcuts) { ShortcutsSheet() }
        .onAppear {
            run.refreshScans()
            if !UserDefaults.standard.bool(forKey: "harSettValkommen") {
                UserDefaults.standard.set(true, forKey: "harSettValkommen")
                run.screen = .valkommen
            } else {
                run.restoreLast()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch run.screen {
        case .valkommen: WelcomeView(run: run)
        case .nySkanning: NewScanView(run: run)
        case .guidad: GuidedCaptureView(run: run, kamera: kamera)
        case .projekt:
            if run.output != nil { Workspace(run: run, big: $big) } else { WelcomeView(run: run) }
        }
    }
}

// MARK: - Projektlistan

struct Sidebar: View {
    @ObservedObject var run: Runner
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; f.locale = Locale(identifier: "sv_SE"); return f
    }()

    @State private var slapp = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projekt").font(.headline)
                Spacer()
                Menu {
                    Button("Nytt modellprojekt …  ⌘N") { run.showNewProject = true }
                    Button("Ny skanning från video …  ⇧⌘N") { run.screen = .nySkanning }
                    Button("Guidad skanning (stativ + vridskiva) …  ⌥⌘N") { run.screen = .guidad }
                    Button("Importera foton …") { run.importPhotos() }
                    Divider()
                    Button("Öppna projekt …  ⌘O") { run.openOther() }
                } label: { Label("Nytt", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                .tips("Nytt projekt eller ny skanning")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            List {
                Button { run.screen = .valkommen } label: {
                    Label("Start", systemImage: "house").padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .listRowBackground(run.screen == .valkommen ? Color.accentColor.opacity(0.18) : Color.clear)
                if run.running, let p = run.runningProject {
                    Button { if run.scans.contains(where: { $0.id == p.standardizedFileURL }) && run.output == p.standardizedFileURL { run.screen = .projekt } else { run.screen = .nySkanning } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Bygger \(p.lastPathComponent)", systemImage: "gearshape.2").lineLimit(1)
                            ProgressView(value: run.progress).controlSize(.small)
                        }
                    }.buttonStyle(.plain)
                }
                Section("Senaste") {
                    ForEach(run.scans) { s in row(s) }
                }
                // modellprojekt utan skanning: ett klick ger ett nytt projekt med delen (alla mått går att ändra)
                if !run.mallar.isEmpty {
                    Section("Ny från mall") {
                        ForEach(run.mallar) { m in
                            Button { run.createModelProject(name: m.namn, template: m, message: "") } label: {
                                Label(m.namn, systemImage: "plus.square.on.square").foregroundStyle(.purple).padding(.vertical, 1)
                            }
                            .buttonStyle(.plain)
                            .tips("Nytt modellprojekt: \(m.beskrivning)\nHamnar i \(Hem.projektRot.path)")
                        }
                    }
                }
            }
            .overlay {
                if run.scans.isEmpty {
                    VStack(spacing: 6) {
                        Text("Inga projekt än").font(.callout)
                        Text("Skapa ett med + ovan.\nNya projekt hamnar i \(Hem.projektRot.path) (ändra i Inställningar, ⌘,).")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.caption)
                    }.padding()
                }
            }
            HStack {
                Button { run.screen = .valkommen } label: { Image(systemName: "questionmark.circle") }.tips("Start och guide")
                Button { run.openOther() } label: { Image(systemName: "folder") }
                    .tips("Öppna ett projekt (⌘O): vilken projektmapp som helst – skanning (*.modell) eller modellprojekt (mapp med projekt.json eller cad/skript)")
                Spacer()
                Button { run.refreshScans() } label: { Image(systemName: "arrow.clockwise") }.tips("Uppdatera listan")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        // dra in en projektmapp eller CAD-filer (STEP, STL, 3MF, OBJ → nytt modellprojekt)
        .dropDestination(for: URL.self) { urls, _ in run.oppnaFiler(urls); return true } isTargeted: { slapp = $0 }
        .overlay { if slapp { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(3).allowsHitTesting(false) } }
    }

    private func row(_ s: ProjektPost) -> some View {
        let selected = run.screen == .projekt && run.output?.standardizedFileURL == s.id
        let (icon, color, sub): (String, Color, String) = {
            switch s.typ {
            case .skanning: return ("cube.fill", .accentColor, s.model?.lastPathComponent == "modell-mm.obj" ? "skanning · mm" : "skanning · ej skalad")
            case .bilder: return ("photo.stack", .orange, "\(s.bildantal) bilder · ingen modell än")
            case .modell: return ("square.stack.3d.up.fill", .purple, "modellprojekt")
            case .tom: return ("square.dashed", .secondary, "tomt")
            }
        }()
        return Button { run.select(s.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).lineLimit(1)
                    Text("\(Sidebar.dateFormat.string(from: s.date)) · \(sub)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contextMenu {
            Button("Visa i Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.id]) }
            Button("Kopiera sökväg") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.id.path, forType: .string) }
            Divider()
            if s.id.deletingLastPathComponent().standardizedFileURL != Hem.projektRot.standardizedFileURL {
                Button("Flytta till projektmappen (\(Hem.projektRot.lastPathComponent))") { run.flyttaProjekt(s.id, till: Hem.projektRot) }
            }
            Button("Flytta till …") { run.valjOchFlytta(s.id) }
            Divider()
            Button("Ta bort ur listan") { run.removeFromList(s.id) }
        }
        .tips(s.id.path)
    }
}

// MARK: - Start

struct WelcomeView: View {
    @ObservedObject var run: Runner
    @State private var showGuide = false
    @State private var slapp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Välkommen till \(Hem.appNamn)").font(.largeTitle.bold())
                    Text("Skanna en del till en mm-exakt 3D-modell, låt Claude rita om den som ren CAD, ändra måtten och skriv ut – eller modellera nya delar direkt, utan skanning.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 14) {
                    card("Modellera", "square.stack.3d.up.fill", .purple,
                         "Ny del från en mall (låda, distans, fäste …) eller beskriv för Claude vad du vill ha. Alla mått går att ändra.",
                         "Nytt modellprojekt", "⌘N") { run.showNewProject = true }
                    card("Guidad skanning", "camera.aperture", .orange,
                         "iPhonen på stativ, delen på vridskiva, korspolariserat ljus. Appen tar stillbilderna och kontrollerar dem.",
                         "Starta", "⌥⌘N") { run.screen = .guidad }
                    card("Skanna från video", "film.stack", .blue,
                         "Gå runt delen och filma, eller välj en mapp med foton. Snabbast att komma igång.",
                         "Välj klipp", "⇧⌘N") { run.screen = .nySkanning }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        flow(1, "Skanna eller modellera", "Skanningen blir en mesh i mm. Modellprojekt börjar tomma eller från en mall.")
                        flow(2, "Claude ritar ren CAD", "Kopiera uppdraget till Claude (knappen i högerpanelen). Claude svarar och frågar här i appen.")
                        flow(3, "Peka, fråga, ändra", "Klicka i modellen för att peka ut en plats. Klicka på ett mått för att ändra det – delen byggs om direkt.")
                        flow(4, "Skriv ut", "Konstruktionsdelar öppnas i Bambu Studio i utskriftsläge (⌘E).")
                    }.padding(6)
                } label: { Text("Så hänger det ihop").font(.headline) }
                HStack {
                    Button { showGuide.toggle() } label: { Label(showGuide ? "Dölj skanningsguiden" : "Visa skanningsguiden", systemImage: "book") }
                    Button { run.showShortcuts = true } label: { Label("Kortkommandon", systemImage: "keyboard") }
                    Button { run.printSheet() } label: { Label("Referensark", systemImage: "printer") }
                    Spacer()
                    if !run.scans.isEmpty, let last = run.scans.first {
                        Button { run.select(last.id) } label: { Label("Fortsätt med \(last.name)", systemImage: "arrow.right.circle") }
                    }
                }
                if showGuide { Guide(printSheet: run.printSheet) }
                Label("Dra in en STEP-, STL-, 3MF- eller OBJ-fil här (eller ⌘O) så blir den ett nytt modellprojekt – mät, snitt och skriv ut.",
                      systemImage: "square.and.arrow.down").font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .dropDestination(for: URL.self) { urls, _ in run.oppnaFiler(urls); return true } isTargeted: { slapp = $0 }
        .overlay { if slapp { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false) } }
    }

    private func card(_ title: String, _ icon: String, _ color: Color, _ text: String, _ button: String, _ key: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(color)
            Text(title).font(.title3.bold())
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack {
                Button(button, action: action).controlSize(.large)
                Text(key).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25)))
    }

    private func flow(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.headline).frame(width: 24, height: 24).background(Circle().fill(Color.accentColor.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Ny skanning från video/foton

struct NewScanView: View {
    @ObservedObject var run: Runner
    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ny skanning från video").font(.title2.bold())
                Text("Gå långsamt tre varv runt delen (lågt, mellan, högt), vänd den och filma ett klipp till. Eller välj en mapp med foton.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundStyle(dropping ? Color.accentColor : Color.secondary.opacity(0.5))
                        .background(RoundedRectangle(cornerRadius: 10).fill(dropping ? Color.accentColor.opacity(0.08) : .clear))
                    if run.clips.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("Dra hit videoklippen (eller en fotomapp)").font(.headline)
                            Button("…eller välj filer") { run.choose() }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(run.clips, id: \.self) { c in
                                HStack {
                                    Image(systemName: c.pathExtension.isEmpty ? "folder" : "film")
                                    Text(c.lastPathComponent).lineLimit(1)
                                    Text(c.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button { run.clips.removeAll { $0 == c } } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(run.running)
                                }
                            }
                            Button("Lägg till fler klipp …") { run.choose() }.disabled(run.running).padding(.top, 4)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minHeight: 130)
                .dropDestination(for: URL.self) { urls, _ in run.add(urls); return true } isTargeted: { dropping = $0 }

                LengthRow(run: run)

                HStack {
                    Button { run.screen = .guidad } label: { Label("Har du stativ och vridskiva? Guidad skanning", systemImage: "camera.aperture") }
                        .buttonStyle(.link)
                    Spacer()
                    if run.running { Button("Avbryt", role: .cancel) { run.cancel() } }
                    Button { run.start() } label: { Label("Skanna", systemImage: "cube.transparent").frame(minWidth: 110) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(run.clips.isEmpty || run.running)
                }
                if run.running || run.progress > 0 || run.error != nil { ProgressCard(run: run) }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

/// Längsta mått + detaljnivå (delas av video-skanning och bygg-av-bilder).
struct LengthRow: View {
    @ObservedObject var run: Runner
    var body: some View {
        HStack(spacing: 10) {
            Text("Längsta mått")
            TextField("t.ex. 142,3", text: $run.length).frame(width: 110).textFieldStyle(.roundedBorder)
            Text("mm").foregroundStyle(.secondary)
            Text("(skjutmått; tomt = okänd skala)").foregroundStyle(.secondary).font(.caption)
            Spacer()
            Toggle("Max detalj (raw)", isOn: $run.raw).tips("Ingen ytförenkling. Större fil, ingen förhandsvisning i Finder.")
        }
        .disabled(run.running)
    }
}

struct ProgressCard: View {
    @ObservedObject var run: Runner
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if run.running { ProgressView().controlSize(.small) }
                    Text(run.stage).font(.callout)
                    Spacer()
                    Text("\(Int(run.progress * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: run.progress)
                if let e = run.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Text(ErrorHelp.hint(for: e)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Logg") {
                    ScrollView { Text(run.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 120)
                }.font(.caption)
            }
            .padding(6)
        } label: { Text("Förlopp").font(.headline) }
    }
}

/// Begripliga råd för vanliga fel från fotogrammetrin.
enum ErrorHelp {
    static func hint(for e: String) -> String {
        let l = e.lowercased()
        if l.contains("bara") && l.contains("bilder") { return "Object Capture behöver minst ~20 bilder, helst 60–150 med god överlappning." }
        if l.contains("finns redan") { return "Projektet har redan en modell. Ta bort mappen modell/ (eller välj en ny utmapp) och försök igen." }
        if l.contains("stöder inte") { return "Object Capture kräver en Mac med Apple-processor eller kraftigt grafikkort." }
        if l.contains("avbrutet") { return "Inget sparades. Starta om när du vill." }
        if l.contains("hittar inte") { return "Kontrollera att filerna inte flyttats, och att appen har åtkomst till mappen." }
        return "Vanliga orsaker: för få eller suddiga bilder, blank/svart yta (matta den eller korspolarisera), eller för lite överlappning mellan bilderna."
    }
}

// MARK: - Arbetsytan: se Arbetsyta.swift

/// Projekt med bilder men utan modell (guidad skanning eller importerade foton): kontrollera och bygg.
struct ReconstructCard: View {
    @ObservedObject var run: Runner
    @State private var turntable = true
    @State private var showCheck = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("\(run.imageCount) bilder i \(run.output?.lastPathComponent ?? "")/bilder", systemImage: "photo.stack").font(.headline)
                        Text("Nästa steg: bygg 3D-modellen med Object Capture. Kontrollera gärna bilderna först – suddiga eller överexponerade bilder gör modellen sämre.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        LengthRow(run: run)
                        Toggle("Tagna på vridskiva/stativ i ordning (stillbilder i följd, maskera bort bakgrunden)", isOn: $turntable)
                        HStack {
                            Button { showCheck = true } label: { Label("Kontrollera bilderna", systemImage: "checkmark.seal") }
                            Button { run.screen = .guidad } label: { Label("Ta fler bilder", systemImage: "camera") }
                            Button { run.openFolder() } label: { Label("Visa i Finder", systemImage: "folder") }
                            Spacer()
                            if run.running { Button("Avbryt", role: .cancel) { run.cancel() } }
                            Button { run.reconstructProject(turntable: turntable) } label: { Label("Bygg 3D-modell", systemImage: "cube.transparent") }
                                .controlSize(.large).keyboardShortcut(.defaultAction)
                                .disabled(run.running || run.imageCount < 20)
                        }
                        if run.imageCount < 20 { Text("Minst 20 bilder behövs (helst 60–150).").font(.caption).foregroundStyle(.orange) }
                    }.padding(6)
                } label: { Text("Bygg modell av bilderna").font(.headline) }
                if run.running || run.progress > 0 || run.error != nil { ProgressCard(run: run) }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear { turntable = run.projekt?.kalla != "video" }
        .sheet(isPresented: $showCheck) {
            if let o = run.output { ImageCheckSheet(folder: o.appendingPathComponent("bilder")) }
        }
    }
}

// MARK: - Nytt modellprojekt

struct NewProjectSheet: View {
    @ObservedObject var run: Runner
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var mall: Mall?
    @State private var message = ""
    @State private var rotUtanGit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nytt modellprojekt").font(.title2.bold())
            Text("Ett projekt utan skanning. Börja från en mall eller beskriv vad du vill bygga – Claude ritar det som ett build123d-skript och alla mått blir redigerbara.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Namn").frame(width: 70, alignment: .leading)
                TextField("t.ex. Distans HiKOKI", text: $name).textFieldStyle(.roundedBorder)
            }
            Text("Börja från").font(.headline)
            ScrollView {
                VStack(spacing: 6) {
                    option(nil, "Tomt – Claude ritar", "Beskriv delen nedan; Claude läser beskrivningen och ritar.", "sparkles")
                    ForEach(run.mallar) { m in option(m, m.namn, m.beskrivning, "square.grid.2x2") }
                }
            }
            .frame(minHeight: 160, maxHeight: 260)
            Text(mall == nil ? "Vad vill du bygga? (skickas till Claude)" : "Något mer Claude ska veta? (valfritt)").font(.headline)
            TextEditor(text: $message)
                .font(.callout)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            Text("Projektet sparas i \(Hem.projektRot.path) (ändra i Inställningar, ⌘,).").font(.caption).foregroundStyle(.secondary)
            if rotUtanGit {
                Varning(text: "Projektmappen är inget git-repo – projektet får ingen historik mellan omstarter. Starkt rekommenderat: gör den till ett git-repo i Inställningar (⌘,).")
            }
            HStack {
                Spacer()
                Button("Avbryt", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Skapa") {
                    let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? (mall?.namn ?? "Nytt projekt") : name
                    run.createModelProject(name: n, template: mall, message: message)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mall == nil && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            run.mallar = Mall.alla()
            let r = Hem.projektRot
            DispatchQueue.global().async {
                let utan = Git.finns && Git.rot(FileManager.default.fileExists(atPath: r.path) ? r : r.deletingLastPathComponent()) == nil
                DispatchQueue.main.async { rotUtanGit = utan }
            }
        }
    }

    private func option(_ m: Mall?, _ title: String, _ text: String, _ icon: String) -> some View {
        let on = mall == m
        return Button { mall = m } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.bold())
                    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.12) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Småbitar

struct ToastView: View {
    @ObservedObject var run: Runner
    var body: some View {
        if let t = run.toast {
            Text(t)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().stroke(Color.secondary.opacity(0.3)))
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { run.toast = nil }
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if run.toast == t { withAnimation { run.toast = nil } }
                }
        }
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private typealias Grupp = (titel: String, ikon: String, rader: [(String, String)])
    private let vanster: [Grupp] = [
        ("Verktyg", "cursorarrow", [
            ("V", "Välj – mått på det du klickar"), ("M", "Mät mellan två punkter"),
            ("P", "Peka – A, B, C … till nästa chattmeddelande"), ("D", "Rita i vyn (⌥ + dra = vrid)"), ("Mellanslag (håll)", "Prata in till chattrutan – släpp när du är klar"), ("G", "Flytta del tillfälligt (⇧: rakt längs X/Y/Z)"),
            ("Esc", "Avmarkera / rensa mätning och pekpunkter")]),
        ("Rita", "pencil.tip", [
            ("D, dra", "Rita – starten fäster mot kanter"), ("⇧", "Rak linje"), ("Mellanslag + dra", "Vrid vyn medan du ritar"),
            ("Esc", "Kasta ritningen")]),
        ("Vy", "cube", [
            ("⌘0 · dubbelklick", "Hela modellen"), ("⌘1 … ⌘6", "Topp, fram, höger, bak, vänster, botten"), ("⌘7", "Perspektiv"),
            ("Dra", "Vrid"), ("⌥-dra · högerdra", "Flytta vyn"), ("Nyp · skrolla", "Zooma mot pekaren"),
            ("X", "Snitt av/på"), ("⌘K", "Fotoläge av/på"), ("← →", "Föregående/nästa foto i fotoläget")]),
    ]
    private let hoger: [Grupp] = [
        ("Projekt", "folder", [
            ("⌘N", "Nytt modellprojekt"), ("⌘O", "Öppna projekt"), ("⇧⌘R", "Visa projektet i Finder"),
            ("⌘,", "Inställningar: projektmapp och git")]),
        ("Ändra och spara", "arrow.uturn.backward", [
            ("⌘Z", "Ångra"), ("⇧⌘Z", "Gör om"), ("⌘Y", "Historik (fliken i högerpanelen) – gå tillbaka till en tidigare version"),
            ("⌘B", "Bygg om delarna"), ("⌥⌘I", "Importera del från fil (STEP, STL, 3MF, OBJ)"), ("⌘E", "Skriv ut (Bambu Studio)"), ("⇧⌘C", "Kopiera uppdrag till Claude")]),
        ("Delar", "square.stack.3d.up", [
            ("E", "Sprängvy: dra isär synliga delar / ihop igen"), ("A", "Spela upp sprängvyn (ihop ↔ isär) / stoppa"), ("R", "Lägg tillbaka allt som flyttats")]),
        ("Paneler", "rectangle.dashed", [
            ("⇥", "Släck alla paneler"), ("Esc", "Tänd panelerna igen"), ("O", "Objektträdet"), ("⇧⌘F", "Projektlistan")]),
        ("Skanning", "camera", [
            ("⇧⌘N", "Ny skanning från video"), ("⌥⌘N", "Guidad skanning"),
            ("Mellanslag · ↩", "Ta bild (guidad)"), ("Volym upp", "Ta bild med Bluetooth-avtryckare")]),
    ]
    private func kolumn(_ g: [Grupp]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(g, id: \.titel) { grupp in
                VStack(alignment: .leading, spacing: 5) {
                    Label(grupp.titel, systemImage: grupp.ikon).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(grupp.rader, id: \.1) { k, t in
                            GridRow {
                                Text(k).font(.callout.monospaced()).foregroundStyle(.secondary).frame(width: 128, alignment: .trailing)
                                Text(t).font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Kortkommandon").font(.title2.bold()); Spacer(); Text("⌘/ visar den här listan").font(.caption).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 28) { kolumn(vanster); kolumn(hoger) }
            Text("Bokstavstangenterna fungerar när du inte skriver i ett textfält.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Stäng") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 860)
    }
}
