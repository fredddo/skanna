// Utskriftsinställningar per konstruktionsdel (Bambu Lab X2D): <projekt>/cad/utskrift.json, {"delar": {id: {nyckel: värde}}}.
// Nycklarna är Bambu Studios processnycklar plus "plast". Gällande värde: processprofilen < delens "bambu" i delar.json
// (del-skriptet) < utskrift.json. Appen och Claude skriver filen; cad/bambu.py läser den vid exporten och sätter plasten
// i objektnamnet ("Lock (PETG-CF)"). Ändringar går att ångra och Claude får ett meddelande (fraga_id "parameter").
import AppKit
import SwiftUI

/// Ett värde i en JSON-dict som kan vara sträng, tal eller bool (Claude skriver ibland tal) – lagras som Bambus sträng.
struct LosVarde: Decodable, Hashable {
    let s: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { s = v }
        else if let v = try? c.decode(Bool.self) { s = v ? "1" : "0" }
        else if let v = try? c.decode(Int.self) { s = String(v) }
        else if let v = try? c.decode(Double.self) { s = String(format: "%g", v) }
        else { s = "" }
    }
}

/// delar.json → "bambu": tålig avkodning (fel typ ger tom dict i stället för att hela dellistan faller).
struct BambuDict: Decodable, Hashable {
    var v: [String: String] = [:]
    init(_ v: [String: String]) { self.v = v }
    init(from decoder: Decoder) throws {
        let d = (try? decoder.singleValueContainer().decode([String: LosVarde].self)) ?? [:]
        v = d.mapValues(\.s)
    }
}

enum Utskrift {
    static let fil = "utskrift.json"
    static let grund = ["wall_loops", "sparse_infill_density", "top_shell_layers", "bottom_shell_layers", "enable_support", "support_type"]
    static let etikett: [String: String] = [
        "plast": "Plast", "wall_loops": "Vägglager", "sparse_infill_density": "Infill", "top_shell_layers": "Topplager",
        "bottom_shell_layers": "Bottenlager", "enable_support": "Support", "support_type": "Supporttyp",
    ]
    static let supporttyper: [(String, String)] = [("tree(auto)", "Träd (auto)"), ("normal(auto)", "Normal (auto)"),
                                                   ("tree(manual)", "Träd (manuell)"), ("normal(manual)", "Normal (manuell)")]
    static let standardPlast = "PLA"
    static let vanligaPlaster = ["PLA", "PLA Matte", "PLA-CF", "PETG", "PETG HF", "PETG-CF", "ABS", "ASA", "PC", "PA6-CF", "TPU 95A"]
    private static let profilSuffix = " @BBL X2D 0.4 nozzle.json"
    private static var profilMapp: URL { URL(fileURLWithPath: "/Applications/BambuStudio.app/Contents/Resources/profiles/BBL/filament") }

    /// Processprofilens värden (samma för alla plaster) ur bambu/x2d-PLA-project_settings.json.
    static let standard: [String: String] = {
        let u = Hem.url.appendingPathComponent("bambu/x2d-PLA-project_settings.json")
        guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return ["wall_loops": "2", "sparse_infill_density": "15%", "top_shell_layers": "5", "bottom_shell_layers": "3",
                    "enable_support": "0", "support_type": "tree(auto)"]
        }
        var out: [String: String] = [:]
        for k in grund { if let s = o[k] as? String { out[k] = s } }
        return out
    }()

    /// Kort namn per installerad X2D 0.4-filamentprofil ("PLA", "PETG-CF", "Generic PETG" …), som cad/bambu.py.
    static let installerade: [String] = {
        let namn = ((try? FileManager.default.contentsOfDirectory(atPath: profilMapp.path)) ?? [])
            .filter { $0.hasSuffix(profilSuffix) }.map { String($0.dropLast(profilSuffix.count)) }.sorted()
        return namn.map { n in
            var s = n.hasPrefix("Bambu ") ? String(n.dropFirst(6)) : n
            if s.hasSuffix(" Basic") { s = String(s.dropLast(6)) }
            return s
        }
    }()

    /// Finns en installerad profil för plasten (samma uppslag som cad/bambu.py: "Bambu X", "Bambu X Basic", "Generic X")?
    static func harProfil(_ plast: String) -> Bool {
        let p = plast.lowercased()
        return installerade.contains { $0.lowercased() == p || $0.lowercased() == "generic " + p }
    }

    static func varde(_ k: String, _ s: String) -> String {
        switch k {
        case "enable_support": return s == "1" ? "på" : "av"
        case "support_type": return supporttyper.first { $0.0 == s }?.1 ?? s
        default: return s
        }
    }

    /// Bambu vill ha strängar; infill med %, lager som heltal (som cad/utskrift.py).
    static func normalisera(_ k: String, _ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        if ["wall_loops", "top_shell_layers", "bottom_shell_layers"].contains(k),
           let d = Double(s.replacingOccurrences(of: ",", with: ".")) { s = String(Int(d.rounded())) }
        if k == "sparse_infill_density", let d = Double(s.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")) {
            s = String(format: "%g%%", d)
        }
        return s
    }
}

extension Runner {
    var utskriftURL: URL? { cadFolder?.appendingPathComponent(Utskrift.fil) }

    func loadUtskrift() {
        guard let u = utskriftURL, let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let delar = o["delar"] as? [String: Any] else { if !utskrift.isEmpty { utskrift = [:] }; return }
        var ny: [String: [String: String]] = [:]
        for (pid, v) in delar {
            guard let dict = v as? [String: Any] else { continue }
            var s: [String: String] = [:]
            for (k, x) in dict {
                if let t = x as? String { s[k] = t }
                else if let b = x as? Bool { s[k] = b ? "1" : "0" }
                else if let n = x as? NSNumber { s[k] = Utskrift.normalisera(k, n.stringValue) }
            }
            ny[pid] = s
        }
        if ny != utskrift { utskrift = ny }
    }

    private func writeUtskrift() {
        guard let u = utskriftURL else { return }
        var root = (try? Data(contentsOf: u)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["delar"] = utskrift.filter { !$0.value.isEmpty }
        if let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? d.write(to: u, options: .atomic)
        }
    }

    /// Delens gällande värde och varifrån det kommer: "app" (utskrift.json), "skript" (delar.json) eller "standard".
    func utskriftVarde(_ pid: String, _ k: String) -> (String, String) {
        if let v = utskrift[pid]?[k], !v.isEmpty { return (v, "app") }
        if let v = parts.first(where: { $0.id == pid })?.bambu?.v[k], !v.isEmpty { return (v, "skript") }
        if k == "plast" { return (Utskrift.standardPlast, "standard") }
        return (Utskrift.standard[k] ?? "", "standard")
    }

    func plast(_ pid: String) -> String { utskriftVarde(pid, "plast").0 }

    /// Övriga nycklar (utöver grundfälten) som skriptet eller Claude har satt för delen.
    func utskriftOvriga(_ pid: String) -> [(String, String, String)] {
        var keys = Set(utskrift[pid]?.keys.map { $0 } ?? [])
        keys.formUnion(parts.first { $0.id == pid }?.bambu?.v.keys.map { $0 } ?? [])
        keys.subtract(Utskrift.grund + ["plast"])
        return keys.sorted().map { k in let (v, kalla) = utskriftVarde(pid, k); return (k, v, kalla) }
    }

    /// Ändra en inställning (nil = tillbaka till skriptets/profilens värde). Snabba ändringar i följd blir ett ångra-steg
    /// och ett meddelande till Claude.
    func setUtskrift(_ pid: String, _ k: String, _ value: String?) {
        guard utskriftURL != nil else { return }
        let v = value.map { Utskrift.normalisera(k, $0) }
        if let v, v.isEmpty { return }
        if utskrift[pid]?[k] == v { return }
        if let v, value != nil, utskrift[pid]?[k] == nil, utskriftVarde(pid, k).0 == v { return }   // samma som redan gäller
        let namn = parts.first { $0.id == pid }?.namn ?? pid
        noteChange("Utskrift: \(namn)")
        var s = utskrift[pid] ?? [:]
        s[k] = v
        utskrift[pid] = s.isEmpty ? nil : s
        writeUtskrift()
        utskriftAndrade[pid, default: []].removeAll { $0 == k }
        utskriftAndrade[pid, default: []].append(k)
        utskriftTimer?.invalidate()
        utskriftTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.flushUtskrift() }
    }

    func resetUtskrift(_ pid: String) {
        guard let s = utskrift[pid], !s.isEmpty else { return }
        let namn = parts.first { $0.id == pid }?.namn ?? pid
        noteChange("Utskrift: \(namn)", immediate: true)
        utskrift[pid] = nil
        writeUtskrift()
        utskriftTimer?.invalidate()
        utskriftAndrade[pid] = nil
        flushUtskrift()
        send(questionID: "parameter", question: "Utskrift: \(namn)",
             text: "Utskrift för \(namn) (\(pid)) återställd till del-skriptets värden (i appen, cad/utskrift.json)", attachment: nil)
    }

    /// Skicka väntande ändringar som ett meddelande per del.
    func flushUtskrift() {
        utskriftTimer?.invalidate(); utskriftTimer = nil
        let pending = utskriftAndrade
        utskriftAndrade = [:]
        for (pid, keys) in pending.sorted(by: { $0.key < $1.key }) where !keys.isEmpty {
            let namn = parts.first { $0.id == pid }?.namn ?? pid
            let lista = keys.map { k -> String in
                let (v, kalla) = utskriftVarde(pid, k)
                let lbl = Utskrift.etikett[k] ?? k
                return kalla == "app" ? "\(lbl) (\(k)) = \(v)" : "\(lbl) (\(k)) tillbaka till \(v)"
            }.joined(separator: ", ")
            send(questionID: "parameter", question: "Utskrift: \(namn)",
                 text: "Utskrift för \(namn) (\(pid)): \(lista) (ändrat i appen, cad/utskrift.json)", attachment: nil)
        }
    }
}

// MARK: - Kortet i inspektören

/// Utskriftsinställningar för vald konstruktionsdel. Fälten skriver cad/utskrift.json direkt (ingen ombyggnad behövs).
struct UtskriftKort: View {
    @ObservedObject var run: Runner
    let pid: String
    @AppStorage("utskriftOppen") private var open = true
    @State private var plastText = ""
    @FocusState private var plastFokus: Bool

    private var del: PartInfo? { run.parts.first { $0.id == pid } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { open.toggle() } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Label("Utskrift", systemImage: "printer").font(.headline)
                Text(del?.namn ?? pid).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if !(run.utskrift[pid]?.isEmpty ?? true) {
                    Button("Återställ") { run.resetUtskrift(pid) }.controlSize(.small).buttonStyle(.link)
                        .help("Tillbaka till del-skriptets inställningar")
                }
            }
            if open { falt } else {
                Text(sammanfattning).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .contentShape(Rectangle()).onTapGesture { open = true }
            }
        }
        .onAppear { plastText = run.plast(pid) }
        .onChange(of: pid) { _, _ in plastText = run.plast(pid) }
        .onChange(of: run.plast(pid)) { _, v in if !plastFokus { plastText = v } }
    }

    private var sammanfattning: String {
        let v = { (k: String) in run.utskriftVarde(pid, k).0 }
        let sup = v("enable_support") == "1" ? "support \(Utskrift.varde("support_type", v("support_type")).lowercased())" : "utan support"
        return "\(v("plast")) · \(v("wall_loops")) väggar · \(v("sparse_infill_density")) infill · \(v("top_shell_layers"))/\(v("bottom_shell_layers")) lager · \(sup)"
    }

    @ViewBuilder private var falt: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            GridRow {
                etikett("plast")
                HStack(spacing: 4) {
                    TextField("PLA", text: $plastText).textFieldStyle(.roundedBorder).frame(width: 110)
                        .focused($plastFokus)
                        .onSubmit { run.setUtskrift(pid, "plast", plastText) }
                        .onChange(of: plastFokus) { _, f in if !f && plastText != run.plast(pid) && !plastText.isEmpty { run.setUtskrift(pid, "plast", plastText) } }
                    Menu {
                        ForEach(Utskrift.vanligaPlaster.filter { Utskrift.installerade.isEmpty || Utskrift.harProfil($0) }, id: \.self) { p in
                            Button(p) { plastText = p; run.setUtskrift(pid, "plast", p) }
                        }
                        if !Utskrift.installerade.isEmpty {
                            Menu("Alla installerade profiler") {
                                ForEach(Utskrift.installerade, id: \.self) { p in Button(p) { plastText = p; run.setUtskrift(pid, "plast", p) } }
                            }
                        }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).help("Välj plast")
                }
            }
            if !Utskrift.installerade.isEmpty && !Utskrift.harProfil(run.plast(pid)) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("Ingen installerad profil för \(run.plast(pid)) – exporten använder närmaste (se varning).")
                        .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            heltal("wall_loops", 0...20, steg: 1)
            heltal("sparse_infill_density", 0...100, steg: 5, procent: true)
            heltal("top_shell_layers", 0...30, steg: 1)
            heltal("bottom_shell_layers", 0...30, steg: 1)
            GridRow {
                etikett("enable_support")
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(get: { run.utskriftVarde(pid, "enable_support").0 == "1" },
                                             set: { run.setUtskrift(pid, "enable_support", $0 ? "1" : "0") }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Picker("", selection: Binding(get: { run.utskriftVarde(pid, "support_type").0 },
                                                  set: { run.setUtskrift(pid, "support_type", $0) })) {
                        ForEach(typer, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 140)
                    .disabled(run.utskriftVarde(pid, "enable_support").0 != "1")
                    .help("Supporttyp")
                }
            }
        }
        .controlSize(.small)
        let ovriga = run.utskriftOvriga(pid)
        if !ovriga.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fler inställningar (från Claude/skriptet)").font(.caption2).foregroundStyle(.secondary)
                ForEach(ovriga, id: \.0) { k, v, kalla in
                    HStack(spacing: 4) {
                        Text("\(k) = \(v)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(kalla == "app" ? Color.pink : Color.primary)
                        Spacer(minLength: 0)
                        if kalla == "app" {
                            Button { run.setUtskrift(pid, k, nil) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Ta bort (tillbaka till skriptets värde)")
                        }
                    }
                }
            }
        }
        Text("Sparas i cad/utskrift.json och gäller vid Skriv ut. Rosa = ändrat här eller av Claude; Claude får veta.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var typer: [(String, String)] {
        let v = run.utskriftVarde(pid, "support_type").0
        return Utskrift.supporttyper.contains { $0.0 == v } || v.isEmpty ? Utskrift.supporttyper : Utskrift.supporttyper + [(v, v)]
    }

    private func etikett(_ k: String) -> some View {
        let kalla = run.utskriftVarde(pid, k).1
        return Text(Utskrift.etikett[k] ?? k).font(.caption)
            .foregroundStyle(kalla == "app" ? Color.pink : Color.secondary)
            .help(kalla == "app" ? "Ändrat (cad/utskrift.json) – högerklicka för att återställa"
                  : kalla == "skript" ? "Från del-skriptet" : "Profilens standardvärde")
            .contextMenu {
                if kalla == "app" { Button("Återställ till skriptets värde") { run.setUtskrift(pid, k, nil) } }
            }
    }

    /// Heltalsfält med pilar (infill i procent).
    private func heltal(_ k: String, _ r: ClosedRange<Int>, steg: Int, procent: Bool = false) -> some View {
        let b = Binding<Int>(
            get: { Int(Double(run.utskriftVarde(pid, k).0.replacingOccurrences(of: "%", with: "")) ?? 0) },
            set: { run.setUtskrift(pid, k, procent ? "\(min(max($0, r.lowerBound), r.upperBound))%" : String(min(max($0, r.lowerBound), r.upperBound))) })
        return GridRow {
            etikett(k)
            HStack(spacing: 2) {
                TextField("", value: b, format: .number).textFieldStyle(.roundedBorder).frame(width: 44)
                    .multilineTextAlignment(.trailing)
                if procent { Text("%").font(.caption) }
                Stepper("", value: b, in: r, step: steg).labelsHidden()
            }
        }
    }
}
