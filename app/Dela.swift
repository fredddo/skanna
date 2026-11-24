// Dela modell (PLAN-webbvisare.md): skapa en hemlig länk till modellen via motorn (cad/dela.py), lista och återkalla
// projektets delningar, och ta emot besökarnas kommentarer (brevlådan eller en inklistrad svarslänk).
// Kommentarerna ligger i cad/kommentarer.json och visas under en egen rubrik i Samtal – de skickas aldrig till Claude
// och skrivs aldrig i svar.json.
import AppKit
import SwiftUI

// MARK: - Modeller

/// En kommentar från en besökare (cad/kommentarer.json, skriven av motorn/dela.py).
struct DelKommentar: Identifiable, Equatable {
    let id: String              // unik nyckel i appen (delning + kommentarens id)
    let kid: String?            // kommentarens eget id (från visaren)
    let tid: String?            // när besökaren skrev den
    let text: String
    let punkt: [Double]?        // modellens koordinater (mm), utan spräng-/flyttförskjutning
    let del: String?
    let kropp: Int?
    let delning: String?
    let fran: String?
    let mottagen: String?

    var visadTid: String? { tid ?? mottagen }

    /// Tåligt, post för post: en post som inte går att läsa (fel typ, ingen text) hoppas över.
    static func tolka(_ poster: [Any]) -> [DelKommentar] {
        var sedda: Set<String> = []
        var ut: [DelKommentar] = []
        for (i, p) in poster.enumerated() {
            guard let d = p as? [String: Any], let text = d["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            func str(_ k: String) -> String? { d[k] as? String }
            let kid = str("id"), delning = str("delning")
            var punkt: [Double]?
            if let a = d["punkt"] as? [Any] {
                let v = a.compactMap { x -> Double? in
                    guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
                    return n.doubleValue
                }
                punkt = (v.count == 3 && a.count == 3) ? v : nil
            }
            var kropp: Int?
            if let n = d["kropp"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { kropp = n.intValue }
            var nyckel = (delning ?? "") + "/" + (kid ?? "\(str("tid") ?? "")#\(i)")
            while sedda.contains(nyckel) { nyckel += "+" }
            sedda.insert(nyckel)
            ut.append(DelKommentar(id: nyckel, kid: kid, tid: str("tid"), text: text, punkt: punkt, del: str("del"), kropp: kropp,
                                   delning: delning, fran: str("fran"), mottagen: str("mottagen")))
        }
        // nyast först
        return ut.sorted { tidEfter($0.visadTid, $1.visadTid) }
    }
}

/// En post i <projekt>/cad/delningar.json (via GET /v1/delningar).
struct Delning: Identifiable, Equatable {
    let id: String
    let tid: String?
    let lank: String?
    let lokalLank: String?
    let med: [String]
    let aterkallad: Bool
    let brevlada: String?       // adressen till delningens brevlåda (nil = bara svarslänk)

    static func tolka(_ poster: [Any]) -> [Delning] {
        poster.compactMap { p in
            guard let d = p as? [String: Any], let id = d["id"] as? String, !id.isEmpty else { return nil }
            let a = d["aterkallad"]
            let atk: Bool
            if a == nil || a is NSNull { atk = false }
            else if let n = a as? NSNumber { atk = n.boolValue }
            else if let s = a as? String { atk = !s.isEmpty }
            else { atk = true }
            return Delning(id: id, tid: d["tid"] as? String, lank: d["lank"] as? String, lokalLank: d["lokal_lank"] as? String,
                           med: (d["med"] as? [Any])?.compactMap { $0 as? String } ?? [], aterkallad: atk,
                           brevlada: (d["brevlada"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        .sorted { tidEfter($0.tid, $1.tid) }
    }
}

/// Svaret från POST /v1/dela: {id, lank, lokal_lank, publicerad}.
struct DelningSkapad: Equatable {
    let id: String
    let lank: String?
    let lokalLank: String?
    var publicerad = false          // motorn publicerade direkt (publicera_automatiskt i delning.json)

    /// Ingen publiceringsplats inställd: motorn ger då bara en lokal länk (lank saknas, är samma som lokal_lank eller
    /// pekar på den egna datorn).
    var baraLokal: Bool { Delning.arLokal(lank) || lank == lokalLank }
    /// Länken som kopieras: den publika om den finns, annars den lokala.
    var kopieras: String? { (lank?.isEmpty == false ? lank : nil) ?? lokalLank }
}

extension Delning {
    static func arLokal(_ lank: String?) -> Bool {
        guard let l = lank, !l.isEmpty, let h = URL(string: l)?.host?.lowercased() else { return true }
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }
}

// MARK: - Runner: delning och kommentarer

extension Runner {
    var kommentarerURL: URL? { cadFolder?.appendingPathComponent("kommentarer.json") }
    var harDelningar: Bool { cadFolder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("delningar.json").path) } ?? false }

    /// Skanningen och nätdelarna (fil .stl/.obj/.3mf) – delas bara när de kryssas i.
    var natdelar: [PartInfo] { parts.filter { ["stl", "obj", "3mf"].contains(($0.fil as NSString).pathExtension.lowercased()) } }
    var cadDelar: [PartInfo] { let n = Set(natdelar.map(\.id)); return parts.filter { !n.contains($0.id) } }

    /// Ett motoranrop i bakgrunden; svaret (eller felet) kommer på huvudtråden.
    func motorBakgrund(_ metod: String, _ sokvag: String, query: [String: String] = [:], kropp: [String: Any]? = nil,
                       timeout: TimeInterval = 60, klar: @escaping (Result<[String: Any], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Motor.delad.anrop(metod, sokvag, query: query, kropp: kropp, timeout: timeout) }
            DispatchQueue.main.async { klar(r) }
        }
    }

    static func felText(_ e: Error) -> String { (e as? Motor.Fel)?.description ?? e.localizedDescription }

    // Dela

    /// Publicera delat-mappen (användarens uttryckliga val – knappen "Publicera nu").
    func publiceraDelningar(klar: @escaping (Result<String, Error>) -> Void) {
        motorBakgrund("POST", "/v1/dela/publicera", kropp: [:], timeout: 120) { r in klar(r.map { $0["resultat"] as? String ?? "" }) }
    }

    func skapaDelning(med: [String], fran: String?, klar: @escaping (Result<DelningSkapad, Error>) -> Void) {
        guard let p = output else { klar(.failure(Motor.Fel(description: "Inget projekt är öppet"))); return }
        let f = fran?.trimmingCharacters(in: .whitespacesAndNewlines)
        motorBakgrund("POST", "/v1/dela", kropp: ["projekt": p.path, "med": med, "fran": (f?.isEmpty == false ? f! : NSNull()) as Any],
                      timeout: 120) { r in
            klar(r.flatMap { s in
                guard let id = s["id"] as? String else { return .failure(Motor.Fel(description: "motorn svarade utan id")) }
                return .success(DelningSkapad(id: id, lank: s["lank"] as? String, lokalLank: s["lokal_lank"] as? String,
                                              publicerad: s["publicerad"] as? Bool ?? false))
            })
        }
    }

    func hamtaDelningar(klar: @escaping (Result<[Delning], Error>) -> Void) {
        guard let p = output else { klar(.success([])); return }
        motorBakgrund("GET", "/v1/delningar", query: ["projekt": p.path], timeout: 15) { r in
            klar(r.map { Delning.tolka($0["delningar"] as? [Any] ?? []) })
        }
    }

    /// Sluta dela → motorns ev. varning (t.ex. att brevlådan inte gick att stänga).
    func aterkallaDelning(_ id: String, klar: @escaping (Result<String?, Error>) -> Void) {
        guard let p = output else { return }
        motorBakgrund("POST", "/v1/dela/aterkalla", kropp: ["projekt": p.path, "id": id]) { r in klar(r.map { $0["varning"] as? String }) }
    }

    func kopieraLank(_ lank: String, toast t: String = "Länken är kopierad") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lank, forType: .string)
        toast = t
    }

    func oppnaLank(_ lank: String) {
        guard let u = URL(string: lank) else { return }
        if ProcessInfo.processInfo.environment["SKANNA_TESTFIXTUR"] != nil { print("skulle öppna:", lank); return }   // UI-testerna
        NSWorkspace.shared.open(u)
    }

    // Kommentarer

    static func kommentarerFranFil(_ projekt: URL) -> [DelKommentar] {
        let u = projekt.appendingPathComponent("cad/kommentarer.json")
        let rot = (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return DelKommentar.tolka(rot?["kommentarer"] as? [Any] ?? [])
    }

    static func kommentarerFranMotor(_ projekt: URL) throws -> [DelKommentar] {
        let s = try Motor.delad.anrop("GET", "/v1/kommentarer", query: ["projekt": projekt.path])
        guard let poster = s["kommentarer"] as? [Any] else { throw Motor.Fel(description: "motorn svarade utan kommentarer") }
        return DelKommentar.tolka(poster)
    }

    /// Läs kommentarerna (motorn, reserv: filen direkt). Ingen fil = inga kommentarer, utan att motorn behöver startas.
    func laddaKommentarer(klar: (() -> Void)? = nil) {
        guard let p = output, let fil = kommentarerURL, FileManager.default.fileExists(atPath: fil.path) else {
            delKommentarer = []; kommentarNal = nil; klar?(); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let lista = (try? Runner.kommentarerFranMotor(p)) ?? Runner.kommentarerFranFil(p)
            DispatchQueue.main.async {
                if self.output == p {
                    self.delKommentarer = lista
                    if let n = self.kommentarNal, !lista.contains(where: { $0.id == n }) { self.kommentarNal = nil }
                }
                klar?()
            }
        }
    }

    /// Projektet öppnades: visa kommentarerna och hämta nya ur brevlådan – tyst (ingen brevlåda, ingen motor = inget fel).
    func kommentarerVidOppning() {
        delKommentarer = []; kommentarNal = nil
        laddaKommentarer()
        guard let p = output, harDelningar else { return }
        motorBakgrund("POST", "/v1/kommentarer/hamta", kropp: ["projekt": p.path], timeout: 30) { [weak self] r in
            guard let self, self.output == p, case .success(let s) = r, let n = s["nya"] as? Int, n > 0 else { return }
            self.laddaKommentarer()
            self.toast = n == 1 ? "1 ny kommentar från delning (Samtal)" : "\(n) nya kommentarer från delning (Samtal)"
        }
    }

    /// Knappen "Hämta kommentarer": som vid öppning, men säger vad som hände (också när ingen brevlåda är inställd).
    func hamtaKommentarer(klar: (() -> Void)? = nil) {
        guard let p = output else { return }
        motorBakgrund("POST", "/v1/kommentarer/hamta", kropp: ["projekt": p.path], timeout: 30) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let s):
                // {nya, trasiga, fel: [...]}
                let n = s["nya"] as? Int ?? 0, trasiga = s["trasiga"] as? Int ?? 0
                let fel = (s["fel"] as? [Any])?.compactMap { $0 as? String } ?? []
                var t = n == 0 ? "Inga nya kommentarer" : (n == 1 ? "1 ny kommentar" : "\(n) nya kommentarer")
                if trasiga > 0 { t += " (\(trasiga) brev gick inte att läsa)" }
                if let f = fel.first { t += " – \(f)" }
                self.toast = t
                if n == 0 && fel.isEmpty {
                    // ingen delning med brevlåda: säg det, i stället för bara "inga nya"
                    self.hamtaDelningar { r in
                        if case .success(let l) = r, !l.contains(where: { !$0.aterkallad && $0.brevlada != nil }), self.output == p {
                            self.toast = "Ingen brevlåda är inställd för projektets delningar – be om en svarslänk och använd Ta emot svarslänk …"
                        }
                    }
                }
            case .failure(let e):
                self.toast = "Kommentarerna kunde inte hämtas: \(Runner.felText(e))"
            }
            self.laddaKommentarer(klar: klar)
        }
    }

    /// En inklistrad svarslänk (…#d=…&k=…&c=…) → kommentarerna läggs i cad/kommentarer.json av motorn.
    func taEmotSvarslank(_ lank: String, klar: ((Result<Int?, Error>) -> Void)? = nil) {
        let l = lank.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = output, !l.isEmpty else { return }
        motorBakgrund("POST", "/v1/kommentarer", kropp: ["projekt": p.path, "lank": l]) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let s):
                let n = s["nya"] as? Int
                self.toast = n.map { $0 == 0 ? "Inga nya kommentarer i länken (redan mottagna)" : ($0 == 1 ? "1 kommentar mottagen" : "\($0) kommentarer mottagna") }
                    ?? "Kommentarerna är mottagna"
                self.laddaKommentarer { klar?(.success(n)) }
            case .failure(let e):
                self.toast = "Svarslänken kunde inte läsas: \(Runner.felText(e))"
                klar?(.failure(e))
            }
        }
    }

    /// Fråga efter en svarslänk (klistra in) och ta emot den.
    func taEmotSvarslankDialog() {
        guard output != nil else { return }
        let a = NSAlert()
        a.messageText = "Ta emot svarslänk"
        a.informativeText = "Klistra in länken som besökaren skickade (den slutar på &c=…). Kommentarerna visas i Samtal under "
            + "\"Kommentarer från delning\" – de skickas inte till Claude."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        f.placeholderString = "https://…/visare/#d=…&k=…&c=…"
        if let s = NSPasteboard.general.string(forType: .string), s.contains("&c=") { f.stringValue = s }
        a.accessoryView = f
        a.addButton(withTitle: "Ta emot")
        a.addButton(withTitle: "Avbryt")
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { taEmotSvarslank(f.stringValue) }
    }

    /// Klick på en kommentar: välj delen, flyg dit och visa punkten som en nål. Klick igen tar bort nålen.
    func visaKommentar(_ k: DelKommentar) {
        if kommentarNal == k.id { kommentarNal = nil; return }
        kommentarNal = k.id
        if let d = k.del, parts.contains(where: { $0.id == d }) {
            if hidden.contains(d) { hidden.remove(d) }
            selectedPart = d
            request("Valt")
        }
    }

    /// Nålen för den kommentar som visas (läggs till de andra markeringarna i 3D-vyn).
    var kommentarMarks: [CadInfo.Markering] {
        guard let id = kommentarNal, let k = delKommentarer.first(where: { $0.id == id }), let p = k.punkt else { return [] }
        let namn = k.fran.flatMap { $0.isEmpty ? nil : $0 } ?? "Kommentar"
        return [.init(typ: "pin_ny", fran: nil, till: nil, pos: p, min: nil, max: nil, text: namn)]
    }
}

// MARK: - Dela-bladet (Arkiv → Dela modell …)

struct DelaVy: View {
    @ObservedObject var run: Runner
    @Environment(\.dismiss) private var dismiss
    @AppStorage("delaFran") private var fran = ""
    @State private var med: Set<String> = []          // avstängda från början: skanningsdata delas bara uttryckligen
    @State private var arbetar = false
    @State private var skapad: DelningSkapad?
    @State private var fel: String?
    @State private var delningar: [Delning] = []
    @State private var listFel: String?
    @State private var aterkalla: Delning?
    @State private var publicerar = false
    @State private var publiceringsText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dela modell").font(.title2.bold())
            Text("En hemlig länk som öppnar modellen i en webbläsare utan inloggning. Den som har länken kan vrida, spränga isär, mäta och kommentera – men aldrig ändra något i projektet.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            vadDelas
            HStack {
                Text("Från")
                TextField("Ditt namn (valfritt, visas för mottagaren)", text: $fran).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button { skapa() } label: { Label("Skapa länk", systemImage: "link") }
                    .buttonStyle(.borderedProminent).disabled(arbetar || run.output == nil || run.parts.isEmpty)
                if arbetar { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let fel { Label(fel, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let skapad { resultat(skapad) }
            Divider()
            lista
            Divider()
            HStack {
                Button("Hämta kommentarer") { run.hamtaKommentarer() }
                    .tips("Hämta besökarnas kommentarer ur brevlådan. De visas i Samtal under \"Kommentarer från delning\".")
                Button("Ta emot svarslänk …") { run.taEmotSvarslankDialog() }
                    .tips("Klistra in en svarslänk som besökaren skickat (när ingen brevlåda finns).")
                Spacer()
                Button("Klar") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { laddaLista() }
        .confirmationDialog("Sluta dela?", isPresented: Binding(get: { aterkalla != nil }, set: { if !$0 { aterkalla = nil } }), presenting: aterkalla) { d in
            Button("Sluta dela", role: .destructive) { slutaDela(d) }
            Button("Avbryt", role: .cancel) {}
        } message: { _ in
            Text("Paketet tas bort ur delat-mappen och länken slutar fungera när mappen publiceras igen. Den som redan öppnat länken kan ha kvar en kopia.")
        }
    }

    private var vadDelas: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Det här delas").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                Text("CAD-delarna (\(run.cadDelar.count)): " + (run.cadDelar.isEmpty ? "inga" : run.cadDelar.map(\.namn).joined(separator: ", ")))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tips("Delarnas ytor, färger och namn, och vilka som är släckta. Inga skript, mått, chatt, foton eller sökvägar.")
            if run.model != nil { kryss("skanning", "Skanningen (råa skanningsnätet)") }
            ForEach(run.natdelar) { p in kryss(p.id, "\(p.namn) (nät, \((p.fil as NSString).pathExtension.uppercased()))") }
            Label("Skanningsdata lämnar aldrig datorn om du inte kryssar i den här.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private func kryss(_ id: String, _ text: String) -> some View {
        Toggle(text, isOn: Binding(get: { med.contains(id) }, set: { if $0 { med.insert(id) } else { med.remove(id) } }))
            .toggleStyle(.checkbox)
    }

    @ViewBuilder private func resultat(_ s: DelningSkapad) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if s.baraLokal {
                Label("Ingen publiceringsplats är inställd – länken nedan är en lokal förhandsvisning som bara fungerar på den här datorn.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Ställ in mapp och bas-URL i ~/.config/skanna/delning.json och publicera (dela.py --publicera) för att dela med andra.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Länken är kopierad.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                if s.publicerad {
                    Text("Publicerad. Det kan ta någon minut innan länken fungerar för andra.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(publiceringsText ?? "Länken fungerar för andra först när delningen är publicerad.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(publicerar ? "Publicerar …" : "Publicera nu") {
                        publicerar = true
                        run.publiceraDelningar { r in
                            publicerar = false
                            switch r {
                            case .success: publiceringsText = "Publicerad. Det kan ta någon minut innan länken fungerar för andra."
                            case .failure(let e): publiceringsText = "Kunde inte publicera: " + Runner.felText(e)
                            }
                        }
                    }
                    .disabled(publicerar)
                    .tips("Lägger upp de krypterade delningarna och visaren på din publiceringsplats (git push i delat-mappen).")
                }
            }
            if let l = s.kopieras {
                Text(l).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                HStack {
                    Button("Kopiera länk") { run.kopieraLank(l) }
                    Button("Öppna") { run.oppnaLank(l) }
                    if !s.baraLokal, let lok = s.lokalLank, !lok.isEmpty {
                        Button("Förhandsvisa lokalt") { run.oppnaLank(lok) }
                            .tips("Öppna delningen från motorn på den här datorn (fungerar innan du publicerat).")
                    }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    private var lista: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Projektets delningar").font(.headline)
            if let listFel { Text(listFel).font(.caption).foregroundStyle(.secondary) }
            else if delningar.isEmpty { Text("Inga delningar än.").font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(delningar) { d in rad(d) }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func medText(_ d: Delning) -> String {
        let extra = d.med.map { m in m == "skanning" ? "skanningen" : (run.parts.first { $0.id == m }?.namn ?? m) }
        return "CAD-delarna" + (extra.isEmpty ? "" : " + " + extra.joined(separator: ", "))
    }

    private func rad(_ d: Delning) -> some View {
        let l = (d.lank?.isEmpty == false ? d.lank : nil) ?? d.lokalLank
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(d.tid.map(chattTid) ?? "–").font(.callout.monospacedDigit())
                Text(medText(d) + (d.aterkallad ? " · slutat delas" : "") + (Delning.arLokal(d.lank) ? " · bara lokal" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !d.aterkallad, let l {
                Button("Kopiera länk") { run.kopieraLank(l) }.controlSize(.small)
                Button("Öppna") { run.oppnaLank(l) }.controlSize(.small)
                Button("Sluta dela") { aterkalla = d }.controlSize(.small)
            }
        }
        .opacity(d.aterkallad ? 0.55 : 1)
    }

    private func skapa() {
        arbetar = true; fel = nil; skapad = nil
        let valda = (run.model != nil && med.contains("skanning") ? ["skanning"] : []) + run.natdelar.map(\.id).filter { med.contains($0) }
        run.skapaDelning(med: valda, fran: fran) { r in
            arbetar = false
            switch r {
            case .success(let s):
                skapad = s
                if let l = s.kopieras { run.kopieraLank(l, toast: s.baraLokal ? "Lokal länk kopierad (ingen publiceringsplats inställd)" : "Länken är kopierad") }
                laddaLista()
            case .failure(let e):
                fel = "Delningen kunde inte skapas: \(Runner.felText(e))"
            }
        }
    }

    private func laddaLista() {
        run.hamtaDelningar { r in
            switch r {
            case .success(let l): delningar = l; listFel = nil
            case .failure(let e): listFel = "Delningarna kunde inte läsas: \(Runner.felText(e))"
            }
        }
    }

    private func slutaDela(_ d: Delning) {
        run.aterkallaDelning(d.id) { r in
            switch r {
            case .success(let varning):
                // "Sluta dela" ska göra att länken slutar fungera: ta bort filen också på publiceringsplatsen
                let extra = varning.map { " (\($0))" } ?? ""
                if Delning.arLokal(d.lank) {
                    run.toast = "Delningen är borttagen" + extra
                } else {
                    run.publiceraDelningar { p in
                        switch p {
                        case .success: run.toast = "Delningen är borttagen – länken slutar fungera inom någon minut" + extra
                        case .failure(let e): run.toast = "Delningen är borttagen här, men inte på webbplatsen: \(Runner.felText(e))" + extra
                        }
                    }
                }
            case .failure(let e): run.toast = "Delningen kunde inte tas bort: \(Runner.felText(e))"
            }
            laddaLista()
        }
    }
}

// MARK: - Samtal: Kommentarer från delning

struct KommentarerFranDelning: View {
    @ObservedObject var run: Runner
    @AppStorage("kommentarerOppna") private var oppen = true
    @AppStorage(ChattText.nyckel) private var storlek = ChattText.standard

    var body: some View {
        if !run.delKommentarer.isEmpty || run.harDelningar {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { oppen.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(oppen ? 90 : 0)).font(.caption.bold())
                            Image(systemName: "text.bubble")
                            Text("Kommentarer från delning").font(.system(size: storlek, weight: .bold))
                            Text("\(run.delKommentarer.count)").font(.system(size: storlek - 2)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Spacer()
                    Menu {
                        Button("Hämta kommentarer") { run.hamtaKommentarer() }
                        Button("Ta emot svarslänk …") { run.taEmotSvarslankDialog() }
                        Button("Dela modell …") { run.visaDela = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .tips("Kommentarer från dem du delat modellen med. De skickas inte till Claude. Klicka på en kommentar för att se platsen.")
                if oppen {
                    if run.delKommentarer.isEmpty {
                        Text("Inga kommentarer än.").font(.system(size: storlek - 1)).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(run.delKommentarer) { k in rad(k) }
                        }
                    }
                    .frame(maxHeight: 200)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08)))
            .padding(.horizontal, 8).padding(.top, 8)
        }
    }

    private func rad(_ k: DelKommentar) -> some View {
        let vald = run.kommentarNal == k.id
        let del = k.del.flatMap { d in run.parts.first { $0.id == d }?.namn }
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: k.punkt != nil ? "mappin.circle.fill" : "text.bubble").foregroundStyle(vald ? .red : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(k.fran.flatMap { $0.isEmpty ? nil : $0 } ?? "Okänd").font(.system(size: storlek - 2, weight: .semibold))
                    if let t = k.visadTid { Text(chattTid(t)).font(.system(size: storlek - 3).monospacedDigit()).foregroundStyle(.tertiary) }
                    if let del { Text("· " + del).font(.system(size: storlek - 3)).foregroundStyle(.secondary) }
                }
                Text(k.text).font(.system(size: storlek - 1)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(vald ? Color.red.opacity(0.1) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { run.visaKommentar(k) }
    }
}
