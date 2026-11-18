// Guidad skanning enligt OpenScan: iPhonen på stativ (Continuity Camera), korspolariserat ljus,
// delen på en manuell vridskiva, stillbilder i N lägen × M kamerahöjder, ev. en omgång till med delen vänd.
import AppKit
import AVFoundation
import SwiftUI

/// Hur bilderna tas – sparas i projekt.json.
struct Fotoplan: Codable, Equatable {
    var lagen = 24                  // lägen per varv (vridskivans snäpp)
    var hojder = 3                  // kamerahöjder per omgång
    var vand = true                 // andra omgång med delen vänd upp och ner

    var omgangar: Int { vand ? 2 : 1 }
    var totalt: Int { lagen * hojder * omgangar }
    var steg: Double { 360.0 / Double(lagen) }

    struct Bild: Equatable { let omgang: Int; let hojd: Int; let lage: Int; let vinkel: Double
        var namn: String { String(format: "o%d_h%d_v%03d", omgang, hojd, Int(vinkel.rounded())) }
    }
    var alla: [Bild] {
        var out: [Bild] = []
        for o in 1...omgangar { for h in 1...hojder { for i in 0..<lagen { out.append(Bild(omgang: o, hojd: h, lage: i, vinkel: Double(i) * steg)) } } }
        return out
    }
    static func hojdText(_ h: Int, av n: Int) -> String {
        let vinklar: [Int: [String]] = [1: ["≈ 25° snett ovanifrån"], 2: ["≈ 15° (lågt)", "≈ 45° (högt)"],
                                        3: ["≈ 10° (lågt, nästan i höjd med skivan)", "≈ 30° (mellan)", "≈ 55° (högt)"],
                                        4: ["≈ 5° (i höjd med skivan)", "≈ 25°", "≈ 45°", "≈ 65° (nästan ovanifrån)"]]
        return vinklar[n]?[h - 1] ?? "höjd \(h)"
    }
}

struct GuidedCaptureView: View {
    @ObservedObject var run: Runner
    @ObservedObject var kamera: Kamera
    @State private var name = ""
    @State private var plan = Fotoplan()
    @State private var project: URL?
    @State private var tagna: Set<String> = []
    @State private var problem: [String: [String]] = [:]
    @State private var index = 0
    @State private var paus: String?                // t.ex. "Flytta kameran till höjd 2"
    @State private var autofoto = false
    @State private var vakt = Rorelse.Vakt()
    @State private var fel: String?
    @State private var monitors: [Any] = []
    @AppStorage("guidadChecklista") private var visaChecklista = true

    var body: some View {
        Group {
            if project == nil { setup } else { capture }
        }
        .onAppear(perform: resumeIfPossible)
        .onDisappear { removeMonitors() }
    }

    // MARK: Förberedelse

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Guidad skanning").font(.title2.bold())
                Text("Stillbilder från iPhonen på stativ medan delen vrids på vridskivan. Appen säger vilken vinkel som är nästa, tar bilden och kontrollerar skärpa, ljus och reflexer.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        check("Stativ", "iPhonen fast på stativet, liggande, ca 25–40 cm från delen. Delen ska fylla större delen av bilden men alltid synas helt.")
                        check("Korspolarisering", "Polfilm framför lampan, DSLR-polfiltret framför iPhonens lins. Vrid filtret tills de blanka reflexerna på delen försvinner (bilden blir mörkare – det är rätt).")
                        check("Ljus", "En eller två lampor med polfilm, ingen blixt, inget fönsterljus som ändras. Samma ljus under hela skanningen.")
                        check("Vridskiva och bakgrund", "Delen mitt på vridskivan, gärna på referensarket (eller ett mönstrat papper som följer med runt). Bakgrunden matt och enfärgad (svart kartong) – inget mönster som står still bakom.")
                        check("Blank/svart plast", "Korspolarisering räcker ofta. Annars ett tunt lager torrschampo eller skanningsspray.")
                        check("Mät", "Mät delens längsta mått med skjutmått – det ger skalan.")
                    }.padding(6)
                } label: { Text("Ställ upp").font(.headline) }

                GroupBox {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "circle.circle").font(.system(size: 30)).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ingen vridskiva än?").font(.callout.bold())
                            Text("Två utskrivna delar (bas + topp), Ø 160 mm, 24 snäpplägen, inga köpdelar. Skriv ut i matt svart PLA, inga stöd.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button { run.printTurntable() } label: { Label("Skriv ut vridskivan", systemImage: "printer") }
                        Button("Ändra måtten …") { run.customizeTurntable() }
                            .help("Skapar ett modellprojekt från mallen Vridskiva där alla mått går att ändra")
                    }.padding(6)
                } label: { Text("Vridskiva").font(.headline) }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Namn").frame(width: 120, alignment: .leading); TextField("t.ex. Överskal HiKOKI", text: $name).textFieldStyle(.roundedBorder) }
                        HStack {
                            Text("Lägen per varv").frame(width: 120, alignment: .leading)
                            Picker("", selection: $plan.lagen) { ForEach([12, 18, 24, 36], id: \.self) { Text("\($0)  (var \(360 / $0)°)").tag($0) } }
                                .labelsHidden().frame(width: 160)
                            Text("24 matchar vridskivans snäpplägen").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Kamerahöjder").frame(width: 120, alignment: .leading)
                            Picker("", selection: $plan.hojder) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 160)
                        }
                        Toggle("Andra omgång med delen vänd upp och ner (ger undersidan)", isOn: $plan.vand)
                        Text("Totalt \(plan.totalt) bilder · ca \(plan.totalt * 6 / 60) min").font(.callout).foregroundStyle(.secondary)
                    }.padding(6)
                } label: { Text("Bildplan").font(.headline) }

                HStack {
                    Button { run.importPhotos() } label: { Label("Har redan foton? Importera", systemImage: "square.and.arrow.down") }.buttonStyle(.link)
                    Spacer()
                    Button { create() } label: { Label("Skapa projekt och anslut kameran", systemImage: "camera") }
                        .controlSize(.large).keyboardShortcut(.defaultAction)
                }
                Text("Första gången frågar macOS om kameratillstånd. iPhonen syns som kamera när den är låst, nära Macen, med samma Apple-konto och wifi/Bluetooth på (eller inkopplad med sladd).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func check(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.bold())
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Skanning \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))" : name
        guard let p = run.createCaptureProject(name: n, plan: plan) else { return }
        project = p
        tagna = []; index = 0; paus = nil
        kamera.anslut()
    }

    /// "Ta fler bilder" från ett befintligt guidat projekt: fortsätt där det slutade.
    private func resumeIfPossible() {
        installMonitors()
        guard project == nil, let o = run.output, let p = run.projekt, p.kalla == "guidad", run.model == nil else { return }
        plan = p.plan ?? Fotoplan()
        project = o
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: o.appendingPathComponent("bilder").path)) ?? [])
        tagna = Set(files.map { ($0 as NSString).deletingPathExtension })
        index = plan.alla.firstIndex { !tagna.contains($0.namn) } ?? plan.alla.count
        if kamera.status == .av { kamera.anslut() }
    }

    // MARK: Fotografering

    private var current: Fotoplan.Bild? { index < plan.alla.count ? plan.alla[index] : nil }

    private var capture: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                ZStack {
                    if kamera.status == .redo || kamera.status == .fotar {
                        KameraForhandsvisning(session: kamera.session)
                    } else {
                        Rectangle().fill(Color.black)
                        cameraState
                    }
                    if let b = current, paus == nil, kamera.status == .redo {
                        VStack {
                            Spacer()
                            Text(String(format: "Vrid till %.0f°", b.vinkel))
                                .font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .padding(.bottom, 14)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                cameraBar
            }
            sidePanel.frame(width: 320)
        }
        .padding(16)
        .onReceive(kamera.$rorelse) { v in
            guard autofoto, paus == nil, current != nil, kamera.status == .redo else { return }
            if vakt.mata(v) { shoot() }
        }
    }

    @ViewBuilder private var cameraState: some View {
        VStack(spacing: 10) {
            switch kamera.status {
            case .av:
                Image(systemName: "camera").font(.system(size: 36)).foregroundStyle(.secondary)
                Button("Anslut kamera") { kamera.anslut() }.controlSize(.large)
            case .soker:
                ProgressView().controlSize(.large)
                Text("Letar efter kameran …").foregroundStyle(.secondary)
            case .behorighetNekad:
                Image(systemName: "lock.fill").font(.system(size: 30)).foregroundStyle(.orange)
                Text("Appen får inte använda kameran.").foregroundStyle(.white)
                Button("Öppna Systeminställningar → Integritet → Kamera") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            case .fel(let t):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(.orange)
                Text(t).foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Försök igen") { kamera.anslut() }
            default: EmptyView()
            }
        }
    }

    private var cameraBar: some View {
        HStack(spacing: 10) {
            if !kamera.enheter.isEmpty {
                Picker("Kamera", selection: Binding(get: { kamera.valdId ?? "" }, set: { kamera.valj($0) })) {
                    ForEach(kamera.enheter, id: \.uniqueID) { d in
                        Text((d.isContinuityCamera ? "📱 " : "") + d.localizedName).tag(d.uniqueID)
                    }
                }.frame(maxWidth: 280)
            }
            if !kamera.upplosning.isEmpty { Text(kamera.upplosning).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if kamera.kanLasa {
                Toggle(isOn: Binding(get: { kamera.lasta }, set: { kamera.lasInstallningar($0) })) {
                    Label("Lås fokus/exponering", systemImage: kamera.lasta ? "lock.fill" : "lock.open")
                }.toggleStyle(.button).help("Ställ in skärpan på delen först, lås sedan – då blir alla bilder lika")
            }
            Spacer()
            Toggle(isOn: $autofoto) { Label("Autofoto", systemImage: "wand.and.stars") }
                .toggleStyle(.button)
                .help("Tar bilden automatiskt när du har vridit skivan och bilden stått still i knappt en sekund")
                .onChange(of: autofoto) { _, _ in vakt.aterstall() }
            if autofoto {
                ProgressView(value: min(kamera.rorelse / 0.04, 1)).frame(width: 60).help("Rörelse i bilden")
            }
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(run.projectName).font(.headline).lineLimit(1)
            ProgressView(value: Double(tagna.count), total: Double(max(plan.totalt, 1)))
            Text("\(tagna.count) av \(plan.totalt) bilder").font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            if let p = paus {
                VStack(alignment: .leading, spacing: 8) {
                    Label(p, systemImage: "arrow.up.and.down.circle").font(.callout.bold()).fixedSize(horizontal: false, vertical: true)
                    Button("Klart – fortsätt") { paus = nil; vakt.aterstall() }.keyboardShortcut(.defaultAction).controlSize(.large)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            } else if let b = current {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Omgång \(b.omgang) av \(plan.omgangar)" + (b.omgang == 2 ? " · delen vänd" : "")).font(.callout)
                    Text("Höjd \(b.hojd) av \(plan.hojder): \(Fotoplan.hojdText(b.hojd, av: plan.hojder))").font(.callout)
                    Text(String(format: "Läge %d av %d · %.0f°", b.lage + 1, plan.lagen, b.vinkel)).font(.title3.bold().monospacedDigit())
                }
                Button { shoot() } label: { Label("Ta bild", systemImage: "camera.shutter.button").frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(kamera.status != .redo)
                Text("Mellanslag, ↩ eller en Bluetooth-avtryckare (volym upp) tar också bilden.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Hoppa över") { advance() }.font(.caption)
                    Button("Ångra senaste") { undo() }.font(.caption).disabled(index == 0)
                }
            } else {
                Label("Alla bilder tagna!", systemImage: "checkmark.seal.fill").font(.title3.bold()).foregroundStyle(.green)
                Button { finish() } label: { Label("Vidare: bygg 3D-modell", systemImage: "cube.transparent").frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            if let fel { Label(fel, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red) }

            if let (u, q) = kamera.senaste {
                Divider()
                Text("Senaste bilden").font(.caption.bold())
                HStack(alignment: .top) {
                    Thumb(url: u).frame(width: 96, height: 72)
                    VStack(alignment: .leading, spacing: 2) {
                        let med = Kvalitet.median(Array(skarpor.values))
                        let p = q.problem(medianSkarpa: skarpor.count >= 5 ? med : nil)
                        if p.isEmpty { Label("Bra", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption) }
                        ForEach(p, id: \.self) { Text("⚠︎ " + $0).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        Text("skärpa \(Int(q.skarpa)) · ljus \(Int(q.ljus * 100)) %").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if !problem.isEmpty {
                Text("\(problem.count) bilder med anmärkning").font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Button("Avsluta") { finish() }.help("Spara det som är taget och gå till projektet")
                Spacer()
                Button { kamera.stang() } label: { Image(systemName: "power") }.help("Stäng av kameran")
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @State private var skarpor: [String: Double] = [:]

    private func shoot() {
        guard let b = current, let project, paus == nil, kamera.status == .redo else { return }
        fel = nil
        let base = project.appendingPathComponent("bilder").appendingPathComponent(b.namn)
        kamera.fota(till: base) { r in
            switch r {
            case .success(let (_, q)):
                tagna.insert(b.namn)
                skarpor[b.namn] = q.skarpa
                let med = skarpor.count >= 5 ? Kvalitet.median(Array(skarpor.values)) : nil
                let p = q.problem(medianSkarpa: med)
                if p.isEmpty { problem[b.namn] = nil } else { problem[b.namn] = p }
                NSSound(named: "Tink")?.play()
                advance()
            case .failure(let e):
                fel = "Bilden kunde inte tas: \(e.localizedDescription)"
                NSSound(named: "Basso")?.play()
            }
        }
    }

    private func advance() {
        let prev = current
        index += 1
        vakt.aterstall()
        guard let next = current, let prev else { return }
        if next.omgang != prev.omgang {
            paus = "Vänd delen upp och ner och lägg den mitt på skivan. Vrid skivan till 0°. Ställ kameran på höjd 1: \(Fotoplan.hojdText(1, av: plan.hojder))."
        } else if next.hojd != prev.hojd {
            paus = "Flytta kameran till höjd \(next.hojd): \(Fotoplan.hojdText(next.hojd, av: plan.hojder)). Rikta om så att delen är mitt i bild, vrid skivan till 0°."
        }
    }

    private func undo() {
        guard index > 0, let project else { return }
        index -= 1
        let b = plan.alla[index]
        let dir = project.appendingPathComponent("bilder")
        for ext in ["heic", "jpg"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(b.namn + "." + ext)) }
        tagna.remove(b.namn); problem[b.namn] = nil; skarpor[b.namn] = nil
        paus = nil
    }

    private func finish() {
        kamera.stang()
        removeMonitors()
        if let project { run.refreshScans(); run.select(project) }
        project = nil
    }

    // MARK: Avtryckare: mellanslag/↩ och Bluetooth-avtryckare (skickar volym upp)

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard project != nil, run.screen == .guidad,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return e }
            if e.keyCode == 49 || e.keyCode == 36 || e.keyCode == 76 {   // mellanslag, ↩, enter
                if paus != nil { paus = nil; vakt.aterstall() } else if current == nil { finish() } else { shoot() }
                return nil
            }
            return e
        }
        let media = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { e in
            guard project != nil, run.screen == .guidad, e.subtype.rawValue == 8 else { return e }
            let code = (e.data1 & 0xFFFF0000) >> 16
            let down = ((e.data1 & 0xFF00) >> 8) == 0xA
            // 0 = volym upp, 1 = volym ner, 16 = spela/paus
            if down && (code == 0 || code == 1 || code == 16) { shoot(); return nil }
            return e
        }
        monitors = [keys as Any, media as Any].compactMap { $0 }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}
