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
/// Den nästlade "filament"-dicten plattas till "filament.<nyckel>" (som i appen och cad/utskrift.py).
struct BambuDict: Decodable, Hashable {
    var v: [String: String] = [:]
    init(_ v: [String: String]) { self.v = v }
    private struct Nyckel: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Nyckel.self) else { return }
        for k in c.allKeys {
            if k.stringValue == Utskrift.filamentNyckel {
                for (fk, fv) in (try? c.decode([String: LosVarde].self, forKey: k)) ?? [:] where !fv.s.isEmpty {
                    v[Utskrift.filamentPrefix + fk] = fv.s
                }
            } else if let x = try? c.decode(LosVarde.self, forKey: k) { v[k.stringValue] = x.s }
        }
    }
}

enum Utskrift {
    static let fil = "utskrift.json"
    /// Filamentinställningar per del: {"filament": {nyckel: värde}} i filen, "filament.<nyckel>" i appen.
    static let filamentNyckel = "filament"
    static let filamentPrefix = "filament."
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

    /// Svenska namn och enheter för vanliga tillägg (Bambu Studios nycklar); okända visas som nyckeln med mellanslag.
    static let tillagg: [String: (String, String)] = [
        "nozzle_temperature": ("munstycke", "°C"), "nozzle_temperature_initial_layer": ("första lagret", "°C"),
        "hot_plate_temp": ("bädd", "°C"), "hot_plate_temp_initial_layer": ("bädd första lagret", "°C"),
        "textured_plate_temp": ("texturplatta", "°C"), "textured_plate_temp_initial_layer": ("texturplatta första lagret", "°C"),
        "cool_plate_temp": ("kall platta", "°C"), "eng_plate_temp": ("engineeringplatta", "°C"),
        "filament_retraction_length": ("retraktion", "mm"), "filament_retraction_speed": ("retraktionsfart", "mm/s"),
        "filament_deretraction_speed": ("återmatning", "mm/s"), "filament_z_hop": ("z-lyft", "mm"),
        "filament_retraction_minimum_travel": ("retraktion från", "mm förflyttning"), "filament_wipe": ("torka av", ""),
        "filament_max_volumetric_speed": ("max flöde", "mm³/s"), "filament_flow_ratio": ("flödesfaktor", ""),
        "fan_min_speed": ("fläkt min", "%"), "fan_max_speed": ("fläkt max", "%"), "overhang_fan_speed": ("fläkt överhäng", "%"),
        "close_fan_the_first_x_layers": ("fläkt av första", "lager"), "slow_down_layer_time": ("sakta ner under", "s/lager"),
        "reduce_crossing_wall": ("undvik att korsa väggar", ""), "brim_type": ("brätte", ""), "brim_width": ("brätte", "mm"),
        "sparse_infill_pattern": ("infillmönster", ""), "layer_height": ("lagerhöjd", "mm"),
        "initial_layer_print_height": ("första lagrets höjd", "mm"), "seam_position": ("söm", ""),
        "ironing_type": ("strykning", ""), "only_one_wall_top": ("en vägg på toppen", ""),
        "wall_generator": ("väggar", ""), "outer_wall_speed": ("yttervägg", "mm/s"), "inner_wall_speed": ("innervägg", "mm/s"),
        "travel_speed": ("förflyttning", "mm/s"), "support_threshold_angle": ("support från", "°"),
        "support_on_build_plate_only": ("support bara från plattan", ""), "elefant_foot_compensation": ("elefantfot", "mm"),
        "xy_contour_compensation": ("xy-kompensation yttre", "mm"), "xy_hole_compensation": ("xy-kompensation hål", "mm"),
    ]
    static let tillaggVarden: [String: String] = [
        "no_brim": "inget", "auto_brim": "auto", "outer_only": "bara utsida", "inner_only": "bara insida",
        "outer_and_inner": "ut- och insida", "brim_ears": "öron", "aligned": "i linje", "nearest": "närmast", "back": "bak",
        "random": "slumpad", "no ironing": "ingen", "top": "toppytan", "topmost": "översta ytan", "solid": "alla massiva",
        "gyroid": "gyroid", "grid": "rutnät", "cubic": "kubisk", "honeycomb": "bikaka", "rectilinear": "raka linjer",
        "zig-zag": "sicksack", "line": "linjer", "triangles": "trianglar", "arachne": "Arachne", "classic": "klassisk",
    ]
    /// Läsordning för tilläggen: temperaturer, retraktion, fläkt, flöde – sedan övriga i bokstavsordning.
    static let tillaggOrdning = ["nozzle_temperature", "nozzle_temperature_initial_layer", "hot_plate_temp", "hot_plate_temp_initial_layer",
                                 "textured_plate_temp", "textured_plate_temp_initial_layer", "cool_plate_temp", "eng_plate_temp",
                                 "filament_retraction_length", "filament_retraction_speed", "filament_deretraction_speed",
                                 "filament_z_hop", "filament_retraction_minimum_travel", "filament_wipe", "fan_min_speed", "fan_max_speed",
                                 "overhang_fan_speed", "filament_max_volumetric_speed", "filament_flow_ratio"]
    static func sortera(_ rader: [(String, String, String)]) -> [(String, String, String)] {
        func rang(_ k: String) -> Int {
            let n = k.hasPrefix(filamentPrefix) ? String(k.dropFirst(filamentPrefix.count)) : k
            return tillaggOrdning.firstIndex(of: n) ?? (tillagg[n] != nil ? 500 : 1000)
        }
        return rader.sorted { (rang($0.0), $0.0) < (rang($1.0), $1.0) }
    }
    static func namn(_ k: String) -> String {
        let n = k.hasPrefix(filamentPrefix) ? String(k.dropFirst(filamentPrefix.count)) : k
        return tillagg[n]?.0 ?? n.replacingOccurrences(of: "_", with: " ")
    }
    /// "munstycke 240 °C", "undvik att korsa väggar: på", "brätte inget".
    static func mening(_ k: String, _ v: String) -> String {
        let n = k.hasPrefix(filamentPrefix) ? String(k.dropFirst(filamentPrefix.count)) : k
        let (namn, enhet) = tillagg[n] ?? (n.replacingOccurrences(of: "_", with: " "), "")
        let tal = Double(v) != nil
        if enhet.isEmpty && (v == "0" || v == "1") { return "\(namn): \(v == "1" ? "på" : "av")" }
        var x = tal ? v.replacingOccurrences(of: ".", with: ",") : (tillaggVarden[v] ?? v)
        if !enhet.isEmpty { x += (enhet == "%" || enhet == "°" ? "" : " ") + enhet }
        return "\(namn) \(x)"
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
                if k == Utskrift.filamentNyckel, let f = x as? [String: Any] {
                    for (fk, fx) in f {
                        if let t = fx as? String { if !t.isEmpty { s[Utskrift.filamentPrefix + fk] = t } }
                        else if let n = fx as? NSNumber { s[Utskrift.filamentPrefix + fk] = n.stringValue }
                    }
                    continue
                }
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
        root["delar"] = utskrift.filter { !$0.value.isEmpty }.mapValues { s -> [String: Any] in
            var ut: [String: Any] = [:]
            var fil: [String: String] = [:]
            for (k, v) in s {
                if k.hasPrefix(Utskrift.filamentPrefix) { fil[String(k.dropFirst(Utskrift.filamentPrefix.count))] = v }
                else { ut[k] = v }
            }
            if !fil.isEmpty { ut[Utskrift.filamentNyckel] = fil }
            return ut
        }
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

// MARK: - Kortet (rutan under pilen vid Skriv ut)

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
                        .tips("Tillbaka till del-skriptets inställningar")
                }
            }
            if open { falt } else {
                Text(sammanfattning).font(.caption).foregroundStyle(.secondary).lineLimit(4)
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
        let extra = Utskrift.sortera(run.utskriftOvriga(pid)).map { Utskrift.mening($0.0, $0.1) }
        return "\(v("plast")) · \(v("wall_loops")) väggar · \(v("sparse_infill_density")) infill · \(v("top_shell_layers"))/\(v("bottom_shell_layers")) lager · \(sup)"
            + (extra.isEmpty ? "" : " · " + extra.joined(separator: ", "))
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
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).tips("Välj plast")
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
                    .tips("Supporttyp")
                }
            }
        }
        .controlSize(.small)
        let ovriga = Utskrift.sortera(run.utskriftOvriga(pid))
        if !ovriga.isEmpty {
            let fil = ovriga.filter { $0.0.hasPrefix(Utskrift.filamentPrefix) }
            let ovr = ovriga.filter { !$0.0.hasPrefix(Utskrift.filamentPrefix) }
            VStack(alignment: .leading, spacing: 4) {
                if !fil.isEmpty { stycke("Filament (\(run.plast(pid)))", fil) }
                if !ovr.isEmpty { stycke(fil.isEmpty ? "Dessutom" : "Övrigt", ovr) }
            }
            .padding(.top, 2)
        }
        Text("Sparas i cad/utskrift.json och gäller vid Skriv ut. Rosa = ändrat här eller av Claude; Claude får veta. Högerklicka ett tillägg för att ta bort det.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// Tillägg som löptext: "Filament (PETG): munstycke 240 °C, första lagret 245 °C, retraktion 0,8 mm."
    /// Rosa = ändrat i appen eller av Claude; högerklick tar bort ett värde.
    private func stycke(_ rubrik: String, _ rader: [(String, String, String)]) -> some View {
        var t = AttributedString(rubrik + ": ")
        t.font = .caption.bold()
        for (i, (k, v, kalla)) in rader.enumerated() {
            var del = AttributedString(Utskrift.mening(k, v) + (i == rader.count - 1 ? "." : ", "))
            del.font = .caption
            if kalla == "app" { del.foregroundColor = .pink }
            t += del
        }
        return Text(t).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .tips(rader.map { "\($0.0) = \($0.1)" }.joined(separator: "\n"))
            .contextMenu {
                ForEach(rader.filter { $0.2 == "app" }, id: \.0) { k, _, _ in
                    Button("Ta bort \(Utskrift.namn(k))") { run.setUtskrift(pid, k, nil) }
                }
            }
    }

    private var typer: [(String, String)] {
        let v = run.utskriftVarde(pid, "support_type").0
        return Utskrift.supporttyper.contains { $0.0 == v } || v.isEmpty ? Utskrift.supporttyper : Utskrift.supporttyper + [(v, v)]
    }

    private func etikett(_ k: String) -> some View {
        let kalla = run.utskriftVarde(pid, k).1
        return Text(Utskrift.etikett[k] ?? k).font(.caption)
            .foregroundStyle(kalla == "app" ? Color.pink : Color.secondary)
            .tips(kalla == "app" ? "Ändrat (cad/utskrift.json) – högerklicka för att återställa"
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
