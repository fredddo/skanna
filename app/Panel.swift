// Sidopanelerna i arbetsytan: objektträdet (vänster) och CAD/Claude-panelen (höger).
import AppKit
import SwiftUI

/// Objektträdet (svävande panel): skanning, referensdelar, konstruktionsdelar och deras under-objekt (kroppar).
/// Klick på raden väljer (opacitetsreglaget gäller vald), ögat tänder/släcker, pilen fäller ut kropparna.
struct ObjektPanel: View {
    @ObservedObject var run: Runner
    var hide: () -> Void
    @AppStorage("shading") private var scanStyle = 1
    @AppStorage("skanningOppen") private var scanOpen = true
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button(action: hide) { Image(systemName: "chevron.down").font(.caption.bold()).frame(width: 14) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).tips("Fäll ihop objektträdet (O)")
                Text("Objekt").font(.headline)
                Spacer()
                addMenu
            }
            .padding(.bottom, 4)
            ScrollIfNeeded(rows: run.parts.count + run.underObjekt.values.reduce(0) { $0 + $1.count } / 2 + (run.model != nil ? 1 : 0), limit: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    // delar med "foralder" visas under föräldern (inte på egen rad på toppnivå)
                    let ids = Set(run.parts.map(\.id))
                    let topp = run.parts.filter { $0.foralder.map { !ids.contains($0) } ?? true }
                    let refs = topp.filter { $0.roll != "design" }
                    let designs = topp.filter { $0.roll == "design" }
                    if run.model != nil {
                        // skanningen överst, och allt som kommer ur skanningen (referensdelar) under den
                        HStack(spacing: 2) {
                            if refs.isEmpty { Color.clear.frame(width: 12, height: 1) } else {
                                Button { scanOpen.toggle() } label: {
                                    Image(systemName: scanOpen ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                                }.buttonStyle(.plain).foregroundStyle(.secondary).tips(scanOpen ? "Fäll ihop skanningens lager" : "Visa skanningens lager")
                            }
                            row(id: "skanning", name: "Skanning",
                                sub: ["Textur", "Form", "Trådnät", "Genomskinlig"][min(max(scanStyle, 0), 3)] + (refs.isEmpty ? "" : " · \(refs.count) lager"),
                                color: .gray, icon: "camera.viewfinder", indent: 0) {
                                Menu {
                                    Picker("Visa skanningen som", selection: $scanStyle) {
                                        Text("Textur (foto)").tag(0); Text("Form (grå)").tag(1); Text("Trådnät").tag(2); Text("Genomskinlig").tag(3)
                                    }.pickerStyle(.inline)
                                } label: { Image(systemName: "slider.horizontal.3") }
                                .menuStyle(.borderlessButton).frame(width: 26).tips("Hur skanningen ritas")
                            }
                        }
                        if scanOpen { ForEach(refs) { partTree($0, indent: 14) } }
                    }
                    if !run.parts.isEmpty || run.model != nil { snittGroup }
                    if !refs.isEmpty && run.model == nil { header("Referens"); ForEach(refs) { partTree($0) } }
                    if !designs.isEmpty { header("Konstruktion"); ForEach(designs) { partTree($0) } }
                    if run.parts.isEmpty && run.model == nil {
                        Text("Inga delar än. Lägg till en från en mall (+) eller beskriv för Claude vad du vill bygga.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Visa alla") { run.hidden = [] }.disabled(run.hidden.isEmpty).tips("Tänd alla lager")
                if run.selectedPart != nil {
                    Button("Bara vald") { isolate(run.selectedPart!) }.tips("Släck allt utom den valda delen")
                }
                Spacer()
            }
            .buttonStyle(.link).font(.caption).padding(.top, 4)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }

    // Snitt: av/på, placera med klick, spara vyn, sparade vyer (cad/snittvyer.json)
    @AppStorage("snittOppen") private var snittOpen = true
    @State private var renaming: String?
    @State private var newName = ""

    @ViewBuilder private var snittGroup: some View {
        HStack(spacing: 2) {
            Button { snittOpen.toggle() } label: {
                Image(systemName: snittOpen ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "square.split.diagonal").foregroundStyle(.secondary).frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Snitt")
                    Text(run.sectionOn ? (run.snittPlaceras ? "klicka i modellen …" : (run.sectionLabel ?? "")) : "\(run.snittvyer.count) sparade")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if run.sectionOn {
                    Button { run.snittPlaceras = true } label: { Image(systemName: "scope") }
                        .buttonStyle(.borderless).tips("Flytta snittet: klicka i modellen där det ska gå (⌥-klick: lodrätt tvärs igenom)")
                    Button { run.request("spara-snitt") } label: { Image(systemName: "plus.square.on.square") }
                        .buttonStyle(.borderless).tips("Spara snittvyn (plan och kamera)")
                }
                Button { run.sectionOn.toggle(); run.snittPlaceras = run.sectionOn } label: {
                    Image(systemName: run.sectionOn ? "eye" : "eye.slash").frame(width: 18)
                }.buttonStyle(.plain).foregroundStyle(run.sectionOn ? Color.primary : Color.secondary).tips("Snitt av/på (X)")
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture { snittOpen.toggle() }
        }
        if snittOpen {
            ForEach(run.snittvyer) { v in
                let on = run.sectionOn && run.aktivSnittvy == v.id
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.split.2x1").foregroundStyle(.secondary).frame(width: 12)
                    if renaming == v.id {
                        TextField("", text: $newName).textFieldStyle(.roundedBorder).font(.caption)
                            .onSubmit { run.renameSection(v.id, newName); renaming = nil }
                    } else {
                        Text(v.namn).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { run.toggleSavedSection(v) } label: { Image(systemName: on ? "eye" : "eye.slash").frame(width: 18) }
                        .buttonStyle(.plain).foregroundStyle(on ? Color.primary : Color.secondary).tips(on ? "Släck snittet" : "Tänd snittet")
                }
                .padding(.vertical, 2).padding(.horizontal, 4).padding(.leading, 12)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture { run.showSection(v) }
                .tips("Visa snittet")
                .contextMenu {
                    Button("Visa") { run.showSection(v) }
                    Button("Byt namn …") { newName = v.namn; renaming = v.id }
                    Button("Ta bort") { run.deleteSection(v.id) }
                }
            }
            if run.snittvyer.isEmpty {
                Text(run.sectionOn ? "Spara vyn med knappen ovan." : "Slå på snittet (X) och klicka där det ska gå.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 16).padding(.bottom, 2)
            }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.secondary).padding(.top, 6).padding(.leading, 2)
    }

    private var addMenu: some View {
        Menu {
            Section("Ny del från mall") {
                ForEach(run.mallar) { m in Button(m.namn) { run.addPart(from: m) }.help(m.beskrivning) }
            }
            Button("Importera fil (STEP, STL, 3MF, OBJ) …  ⌥⌘I") { run.valjImport() }
            Divider()
            if !run.scripts.isEmpty {
                Menu("Öppna del-skript") { ForEach(run.scripts, id: \.self) { u in Button(u.lastPathComponent) { run.openScript(u) } } }
            }
            Button("Bygg om alla delar  ⌘B") { run.rebuild() }.disabled(!run.canEdit)
        } label: { Image(systemName: "plus") }
        .menuStyle(.borderlessButton).frame(width: 26).tips("Lägg till en del från en mall · bygg om (⌘B)")
    }

    private func isolate(_ id: String) {
        var all = Set(run.parts.map(\.id) + ["skanning"])
        for (_, subs) in run.underObjekt { all.formUnion(subs.map(\.id)) }
        let base = id.split(separator: "#").first.map(String.init) ?? id
        all.remove(id); all.remove(base)
        for c in run.parts where c.foralder == base { all.remove(c.id); for s in run.underObjekt[c.id] ?? [] { all.remove(s.id) } }
        if id == base { for s in run.underObjekt[base] ?? [] { all.remove(s.id) } }
        run.hidden = all
    }

    /// En del och dess barn (delar med "foralder" = delen), indragna under den. Ett barn har eget öga.
    @ViewBuilder private func partTree(_ p: PartInfo, indent: CGFloat = 0) -> some View {
        partRow(p, indent: indent)
        if run.utfallda.contains(p.id) {
            ForEach(run.parts.filter { $0.foralder == p.id && $0.id != p.id }) { c in
                partRow(c, indent: indent + 14)
            }
        }
    }

    @ViewBuilder private func partRow(_ p: PartInfo, indent: CGFloat = 0) -> some View {
        let subs = run.underObjekt[p.id] ?? []
        let barn = run.parts.filter { $0.foralder == p.id && $0.id != p.id }
        let color = Color(nsColor: run.color(for: p))
        HStack(spacing: 2) {
            if subs.count > 1 || !barn.isEmpty {
                Button { if run.utfallda.contains(p.id) { run.utfallda.remove(p.id) } else { run.utfallda.insert(p.id) } } label: {
                    Image(systemName: run.utfallda.contains(p.id) ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                .tips(run.utfallda.contains(p.id) ? "Fäll ihop – i sprängvyn hålls \(barn.isEmpty ? "kropparna" : "underdelarna") då ihop med delen"
                                                   : "Fäll ut \(barn.isEmpty ? "kropparna" : "underdelarna") – i sprängvyn dras de då isär var för sig")
            } else { Color.clear.frame(width: 12, height: 1) }
            // konstruktionsdelar: plasten först (samma som i Bambu Studio: "Lock (PETG-CF)")
            let sub = subs.count > 1 ? "\(subs.count) kroppar" : (!barn.isEmpty && !run.utfallda.contains(p.id)
                ? "+ " + barn.map(\.namn).joined(separator: ", ") : p.beskrivning)
            row(id: p.id, name: p.namn, sub: p.roll == "design" ? ([run.plast(p.id)] + [sub].compactMap { $0 }).joined(separator: " · ") : sub,
                color: color, icon: nil, indent: 0, renamable: true)
        }
        .padding(.leading, indent)
        .overlay(alignment: .top) { if dropTarget == p.id { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .draggable(p.id) { Text(p.namn).padding(4).background(RoundedRectangle(cornerRadius: 5).fill(.regularMaterial)) }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, run.parts.contains(where: { $0.id == s }) else { return false }
            withAnimation { run.movePart(s, to: p.id) }
            return true
        } isTargeted: { on in dropTarget = on ? p.id : (dropTarget == p.id ? nil : dropTarget) }
        .contextMenu {
            Button("Byt namn …") { newName = p.namn; renaming = p.id }
            if run.egnaNamn[p.id] != nil { Button("Tillbaka till Claudes namn") { run.renamePart(p.id, "") } }
            Divider()
            Button("Visa bara den här") { isolate(p.id) }
            Button("Visa alla") { run.hidden = [] }
            if p.export != nil { Button("Öppna i Bambu Studio") { run.export(p) } }
            if run.offsets[p.id] != nil { Button("Lägg tillbaka (flyttad)") { run.offsets[p.id] = nil } }
            Button("Visa filer i Finder") { if let f = run.cadFolder { NSWorkspace.shared.activateFileViewerSelecting([f.appendingPathComponent(p.fil)]) } }
            Divider()
            Button("Radera", role: .destructive) { run.raderaDel(p.id) }
        }
        if run.utfallda.contains(p.id) && subs.count > 1 {
            gruppTrad(p, subs: subs, sti: [], color: color, indent: 26 + indent)
        }
    }

    /// Kropparna i en del som ett träd efter komponenterna i den importerade filen (grupp = sti från yttersta).
    /// En grupp fälls ut/ihop, har ett öga för alla sina kroppar och "Visa bara den här".
    private func gruppTrad(_ p: PartInfo, subs: [UnderObjekt], sti: [String], color: Color, indent: CGFloat) -> AnyView {
        let d = sti.count
        let inom = subs.filter { $0.grupp.count >= d && Array($0.grupp.prefix(d)) == sti }
        var grenar: [String] = []
        for s in inom where s.grupp.count > d && !grenar.contains(s.grupp[d]) { grenar.append(s.grupp[d]) }
        let blad = inom.filter { $0.grupp.count == d }
        return AnyView(VStack(spacing: 0) {
            ForEach(grenar, id: \.self) { g in
                let gs = sti + [g]
                let nyckel = UnderObjekt.gruppNyckel(p.id, gs)
                let kroppar = subs.filter { $0.grupp.count > d && Array($0.grupp.prefix(d + 1)) == gs }.map(\.id)
                let ute = run.utfallda.contains(nyckel)
                let synlig = kroppar.contains { !run.hidden.contains($0) }
                HStack(spacing: 2) {
                    Button { if ute { run.utfallda.remove(nyckel) } else { run.utfallda.insert(nyckel) } } label: {
                        Image(systemName: ute ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .tips(ute ? "Fäll ihop – i sprängvyn hålls kropparna då ihop" : "Fäll ut – i sprängvyn dras kropparna då isär var för sig")
                    Image(systemName: "shippingbox").font(.caption2).foregroundStyle(.secondary).frame(width: 12)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(g).lineLimit(1)
                        Text("\(kroppar.count) kroppar").font(.caption2).foregroundStyle(.secondary)
                    }.opacity(synlig ? 1 : 0.45)
                    Spacer(minLength: 0)
                    Button { if synlig { run.hidden.formUnion(kroppar) } else { run.hidden.subtract(kroppar) } } label: {
                        Image(systemName: synlig ? "eye" : "eye.slash").frame(width: 18)
                    }.buttonStyle(.plain).foregroundStyle(synlig ? Color.primary : Color.secondary).tips(synlig ? "Släck gruppen" : "Tänd gruppen")
                }
                .padding(.vertical, 3).padding(.horizontal, 4).padding(.leading, indent)
                .contentShape(Rectangle())
                .onTapGesture { if ute { run.utfallda.remove(nyckel) } else { run.utfallda.insert(nyckel) } }
                .tips("\(g)\n\(kroppar.count) kroppar\n\nKlicka för att fälla ut/ihop · ögat tänder/släcker hela gruppen")
                .contextMenu {
                    Button("Visa bara den här") { isolera(p.id, kroppar) }
                    Button("Visa alla") { run.hidden = [] }
                }
                if ute { gruppTrad(p, subs: subs, sti: gs, color: color, indent: indent + 14) }
            }
            ForEach(blad) { s in
                row(id: s.id, name: s.namn, sub: nil, color: color.opacity(0.7), icon: nil, indent: indent)
                    .contextMenu { Button("Visa bara den här") { isolate(s.id) }; Button("Visa alla") { run.hidden = [] } }
            }
        })
    }

    private func isolera(_ del: String, _ kroppar: [String]) {
        var all = Set(run.parts.map(\.id) + ["skanning"])
        for (_, subs) in run.underObjekt { all.formUnion(subs.map(\.id)) }
        all.remove(del)
        all.subtract(kroppar)
        run.hidden = all
    }

    private func row(id: String, name: String, sub: String?, color: Color, icon: String?, indent: CGFloat, renamable: Bool = false) -> some View {
        row(id: id, name: name, sub: sub, color: color, icon: icon, indent: indent, renamable: renamable) { EmptyView() }
    }

    private func row<Extra: View>(id: String, name: String, sub: String?, color: Color, icon: String?, indent: CGFloat, renamable: Bool = false,
                                  @ViewBuilder extra: () -> Extra) -> some View {
        let on = !run.hidden.contains(id)
        let selected = run.selectedPart == id || run.traff?.objekt == id
        return HStack(spacing: 6) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 12) }
            else { Circle().fill(color).frame(width: 11, height: 11) }
            VStack(alignment: .leading, spacing: 0) {
                if renaming == id {
                    TextField("", text: $newName).textFieldStyle(.roundedBorder).font(.callout)
                        .onSubmit { run.renamePart(id, newName); renaming = nil }
                        .onExitCommand { renaming = nil }
                } else {
                    Text(name).lineLimit(1)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { if renamable { newName = name; renaming = id } })
                }
                // hela texten när raden är vald (annars en rad), och alltid i tooltipen
                if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(selected ? nil : 1)
                    .fixedSize(horizontal: false, vertical: selected) }
            }
            .opacity(on ? 1 : 0.45)
            Spacer(minLength: 0)
            if run.offsets[id] != nil { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.caption2).foregroundStyle(.orange).tips("Flyttad tillfälligt") }
            if let o = run.partOpacity[run.opacityKey(id)], o < 0.999 { Text("\(Int(o * 100)) %").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            extra()
            Button { run.toggle(id) } label: { Image(systemName: on ? "eye" : "eye.slash").frame(width: 18) }
                .buttonStyle(.plain).foregroundStyle(on ? Color.primary : Color.secondary).tips(on ? "Släck" : "Tänd")
        }
        .padding(.vertical, 3).padding(.horizontal, 4).padding(.leading, indent)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.2) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { run.selectPart(id) }
        .tips((sub.map { "\(name)\n\($0)\n\n" } ?? "")
              + (renamable ? "Klicka för att välja och se hela texten · dubbelklicka på namnet för att byta namn · dra för att flytta i listan · ögat tänder/släcker"
                           : "Klicka för att välja och se hela texten · ögat tänder/släcker"))
    }
}

/// ScrollView bara när innehållet är långt – annars blir panelen precis så hög som innehållet.
struct ScrollIfNeeded<C: View>: View {
    let rows: Int
    let limit: Int
    @ViewBuilder var content: () -> C
    var body: some View {
        if rows > limit { TunnRullning(hojd: 420) { content() } } else { content() }
    }
}

/// Rullning med en tunn linje längs högerkanten i stället för macOS-rullningslisten (som lägger sig över ögonen).
struct TunnRullning<C: View>: View {
    let hojd: CGFloat
    @ViewBuilder var content: () -> C
    @State private var geo = CGRect.zero          // y = hur långt ner, height = innehållets höjd
    var body: some View {
        ScrollView { content().padding(.trailing, 5) }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: CGRect.self) { g in
                CGRect(x: 0, y: g.contentOffset.y, width: 0, height: g.contentSize.height)
            } action: { _, ny in geo = ny }
            .frame(height: hojd)
            .overlay(alignment: .topTrailing) {
                if geo.height > hojd {
                    let del = hojd / geo.height
                    let h = max(24, hojd * del)
                    let y = min(hojd - h, max(0, geo.minY / max(1, geo.height - hojd) * (hojd - h)))
                    Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 2, height: h)
                        .offset(x: -1, y: y).allowsHitTesting(false)
                }
            }
    }
}

/// Samtalsfliken: byggfel överst, sedan den trådade chatten (Chatt.swift).
struct SamtalVy: View {
    @ObservedObject var run: Runner
    @State private var showLog = false
    var body: some View {
        VStack(spacing: 0) {
            if let e = run.buildError {
                VStack(alignment: .leading, spacing: 4) {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(4)
                    HStack {
                        Button("Visa logg") { showLog = true }.buttonStyle(.link).font(.caption)
                        Button("Skicka till Claude") {
                            run.send(questionID: "meddelande", question: "Byggfel", text: "Bygget misslyckades:\n" + String(run.buildLog.suffix(1500)), attachment: nil)
                            run.buildError = nil
                        }.buttonStyle(.link).font(.caption)
                        Spacer()
                        Button { run.buildError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08))).padding(8)
                .popover(isPresented: $showLog) {
                    ScrollView { Text(run.buildLog).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
                        .frame(width: 560, height: 360)
                }
            }
            ChattPanel(run: run)
        }
    }
}

enum ParamStyle {
    static func icon(_ k: String?) -> String {
        switch k {
        case "användare": return "pencil.circle.fill"
        case "uppmätt": return "ruler.fill"
        case "skanning": return "cube.transparent"
        case "standard": return "book.closed"
        case "mall": return "square.grid.2x2"
        default: return "questionmark.diamond"
        }
    }
    static func color(_ k: String?) -> Color {
        switch k {
        case "användare": return .pink
        case "uppmätt": return .green
        case "skanning": return .blue
        case "standard": return .purple
        case "mall": return .gray
        default: return .orange
        }
    }
    /// Visning och förifyllning av ett mått. Aldrig avrundat så att en inmatningsruta som bara bekräftas ändrar värdet:
    /// 22,5° visas "22,5" (inte "23"), 0,125 mm "0,125"; hela tal utan decimaler i st/° och från 100 uppåt.
    static func format(_ v: Double, unit: String?) -> String {
        func kort(_ d: Int) -> String {
            var s = String(format: "%.\(d)f", v)
            if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
            return s
        }
        let s: String
        if v == v.rounded() && (unit == "st" || unit == "°" || abs(v) >= 100) { s = String(format: "%.0f", v) }
        else if unit == "st" || unit == "°" || abs(v) >= 100 { s = kort(4) }
        else if abs(v * 100 - (v * 100).rounded()) < 1e-6 { s = String(format: "%.2f", v) }
        else { s = kort(4) }
        return s.replacingOccurrences(of: ".", with: ",")
    }
}

/// Ett mått i listan; redigerbart när projektet har del-skript (eller en egen CAD-modell).
/// Inmatningsrutan vid ett måtthandtag i 3D-vyn: skriv ett värde och tryck Enter (Esc stänger).
struct MattRuta: View {
    @ObservedObject var run: Runner
    let m: MattInmatning
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(m.kort).font(.callout).foregroundStyle(.secondary)
            TextField("", text: $draft).frame(width: 70).textFieldStyle(.roundedBorder).font(.callout.monospacedDigit())
                .focused($focused)
                .onSubmit { run.setParam(m.namn, draft, unit: m.enhet); run.mattInmatning = nil }
                .onExitCommand { run.mattInmatning = nil }
            if let e = m.enhet { Text(e).font(.callout).foregroundStyle(.secondary) }
            Button { run.mattInmatning = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor.opacity(0.5)))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .onAppear { draft = ParamStyle.format(m.varde, unit: m.enhet); DispatchQueue.main.async { focused = true } }
    }
}

struct ParamRow: View {
    @ObservedObject var run: Runner
    let p: CadInfo.Param
    let label: String
    let valueText: String
    let icon: String
    let color: Color
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if editing {
                TextField("", text: $draft).frame(width: 80).textFieldStyle(.roundedBorder).font(.callout.monospacedDigit())
                    .focused($focused)
                    .onSubmit { run.setParam(p.namn, draft, unit: p.enhet); editing = false }
                    .onExitCommand { editing = false }
                Button { editing = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Text(valueText).font(.callout.monospacedDigit())
                    .underline(run.canEdit && p.varde != nil, color: .secondary.opacity(0.4))
                    .onTapGesture { startEdit() }
                    .tips(run.canEdit ? "Klicka för att ändra" : "Måttet kan inte ändras här (inget del-skript)")
            }
            Image(systemName: icon).foregroundStyle(color).tips(p.kalla ?? "")
        }
        .onHover { inne in
            if inne { run.relParam = p.namn } else if run.relParam == p.namn { run.relParam = nil }
        }
        .contextMenu {
            if run.canEdit && p.varde != nil { Button("Ändra …") { startEdit() } }
            if run.overrides[p.namn] != nil { Button("Återställ till skriptets värde") { run.resetParam(p.namn) } }
            Button("Kopiera värde") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(valueText, forType: .string)
            }
        }
    }

    private func startEdit() {
        guard run.canEdit, let v = p.varde else { return }
        draft = ParamStyle.format(v, unit: p.enhet)
        editing = true
        DispatchQueue.main.async { focused = true }
    }
}

struct ClaudeBubble: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "sparkles").foregroundStyle(.purple).font(.caption)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.10)))
    }
}

