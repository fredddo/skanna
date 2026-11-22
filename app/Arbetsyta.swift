// Arbetsytan (Modellera): 3D-vyn fyller fönstret, med svävande objektträd, verktygsrad och inspektör,
// och en högerpanel med Samtal (Claude, trådar) och Mått (parametrar).
import AppKit
import SwiftUI

struct Workspace: View {
    @ObservedObject var run: Runner
    @Binding var big: Bool
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.35
    @AppStorage("followPhotos") private var followPhotos = false
    @AppStorage("cadStyle") private var cadStyle = 2          // 0 fyllt, 1 kanter, 2 båda
    @AppStorage("shading") private var shading = 1
    @AppStorage("background") private var background = 0
    @AppStorage("hogerflik") private var rightTab = 0          // 0 samtal, 1 mått, 2 historik
    @AppStorage("visaObjektPanel") private var showTree = true
    @State private var importMal = false
    @State private var upTick = 0
    @State private var keyMonitor: Any?

    private var upKey: String { "upp:" + (run.output?.path ?? "") }
    private var upSign: Float {
        _ = upTick
        if let v = UserDefaults.standard.object(forKey: upKey) as? Int { return Float(v) }
        return run.model != nil ? -1 : 1
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if run.model == nil && run.imageCount > 0 {
                ReconstructCard(run: run).padding(16)
            } else {
                HStack(spacing: 0) {
                    canvas
                    Divider()
                    if !run.dolPaneler { RightPanel(run: run, tab: $rightTab).frame(width: 340) }
                }
            }
        }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
        .onChange(of: run.skrivFokus) { _, _ in rightTab = 0 }
        .onChange(of: run.mikHall) { _, h in if h { rightTab = 0 } }   // ett streck är ritat: beskriv det i Samtal
        .onChange(of: run.visaHistorik) { _, v in if v { run.visaHistorik = false; run.dolPaneler = false; rightTab = 2 } }   // ⌘Y
        .onChange(of: run.tool) { _, t in if t != .rita { run.mellanslag = false } }
    }

    // MARK: Toppraden

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { withAnimation { big.toggle() } } label: {
                Image(systemName: big ? "sidebar.left" : "rectangle.leadinghalf.inset.filled")
            }
            .buttonStyle(.borderless).keyboardShortcut("f", modifiers: [.command, .shift]).tips("Dölj/visa projektlistan (⇧⌘F)")
            VStack(alignment: .leading, spacing: 1) {
                Text(run.projectName).font(.title3.bold()).lineLimit(1)
                Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if run.rebuilding { ProgressView().controlSize(.small); Text("Bygger …").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 2) {
                Button { run.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!run.canUndo).tips(run.undoName.map { "Ångra \($0) (⌘Z)" } ?? "Inget att ångra (⌘Z)")
                Button { run.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!run.canRedo).tips(run.redoName.map { "Gör om \($0) (⇧⌘Z)" } ?? "Inget att göra om (⇧⌘Z)")
            }
            SkrivUtKnapp(run: run)
            Menu {
                Picker("Bakgrund", selection: $background) { Text("Vit").tag(0); Text("Grå").tag(1); Text("Mörk").tag(2) }
                Picker("Upp i 3D-vyn", selection: Binding(get: { Int(upSign) }, set: { UserDefaults.standard.set($0, forKey: upKey); upTick += 1 })) {
                    Text("+Z (som i Bambu Studio)").tag(1); Text("−Z (skalets öppning)").tag(-1)
                }
                Divider()
                Button("Bygg om delarna (⌘B)") { run.rebuild() }.disabled(!run.canEdit || run.rebuilding)
                Button("Visa projektet i Finder (⇧⌘R)") { run.revealProject() }
                Button("Kopiera uppdrag till Claude") { run.copyClaudeText() }
                if run.model != nil {
                    Button("Visa skanningen i Finder") { run.revealModel() }
                    Button("Kopiera skanningens sökväg") { run.copyModelPath() }
                }
                Button("Kortkommandon …") { run.showShortcuts = true }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).frame(width: 34).tips("Bakgrund, upp-riktning, uppdraget till Claude och kortkommandon (⌘/)")
        }
    }

    private var subtitle: String {
        var s: [String] = []
        if run.model != nil { s.append(run.dims ?? (run.model?.lastPathComponent == "modell-mm.obj" ? "mäter …" : "skala okänd")) }
        else { s.append("modellprojekt") }
        let d = run.parts.filter { $0.roll == "design" }.count
        if d > 0 { s.append("\(d) konstruktionsdel\(d == 1 ? "" : "ar")") }
        if let a = run.cad?.avvikelse { s.append("avvikelse \(a)") }
        return s.joined(separator: " · ")
    }

    // MARK: 3D-vyn med svävande paneler

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            viewer
            if let m = run.mattInmatning {
                MattRuta(run: run, m: m)
                    .fixedSize()
                    .position(x: m.punkt.x + 14 + 90, y: m.punkt.y)
                    .zIndex(5)
            }
            VStack(alignment: .leading, spacing: 8) {
                ToolBar(run: run, followPhotos: $followPhotos, cadStyle: $cadStyle, overlayOpacity: overlayOpacity)
                if !run.dolPaneler {
                    HStack(alignment: .top) {
                        if showTree {
                            ObjektPanel(run: run, hide: { withAnimation { showTree = false } })
                                .frame(width: 236)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        } else {
                            Button { withAnimation { showTree = true } } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.right").font(.caption.bold()).frame(width: 14).foregroundStyle(.secondary)
                                    Text("Objekt").font(.headline)
                                    Text("\(run.parts.count + (run.model != nil ? 1 : 0))").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).tips("Fäll ut objektträdet (O)")
                        }
                        Spacer()
                    }
                }
                Spacer(minLength: 0)
                if !run.dolPaneler {
                    HStack(alignment: .bottom) {
                        Inspector(run: run, toChat: { rightTab = 0 })
                        Spacer()
                    }
                }
            }
            .padding(10)
            if run.output != nil && (run.model != nil || !run.parts.isEmpty) {
                // sparade vyer: till vänster om vykuben (132 pt, 8 pt från hörnet), centrerat i höjd med den
                VyRad(run: run)
                    .padding(.top, 8 + (132 - VyRad.sida) / 2 - 4)
                    .padding(.trailing, 8 + 132 + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if run.snapped != nil {
                Button { run.request("lämna-foto"); followPhotos = false } label: { Label("Lämna fotoläget", systemImage: "xmark.circle.fill") }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var viewer: some View {
        ModelView(url: run.model, run: run, parts: run.partSpecs, hidden: run.hidden, scanStyle: min(shading, 3), background: background,
                  marks: run.tool == .valj ? run.focusMarks : (run.tool == .peka ? run.pins : run.focusMarks + run.pins),
                  selectedFace: run.pick.flatMap { p in p.yta.map { "\(p.del ?? ""):\($0)" } },
                  photos: run.reliablePhotos, photoFolder: run.output, followPhotos: followPhotos,
                  overlayOpacity: overlayOpacity, cadStyle: cadStyle, viewRequest: run.viewRequest,
                  upSign: upSign,
                  section: run.sectionOn && !run.snittPlaceras && run.snapped == nil,
                  partOpacity: run.partOpacity, photoOpacity: run.partOpacity["foto/fotot"] ?? 1, selectedPart: run.selectedPart,
                  sectionCoord: run.sectionCoord,
                  onSection: { l, v, r in DispatchQueue.main.async {
                      run.sectionLabel = l
                      if l == nil { run.sectionCoord = nil } else { run.sectionRange = r; if run.sectionCoord.map({ abs($0 - v) > 1e-3 }) ?? true { run.sectionCoord = v } }
                  } },
                  onSelectPart: { id in DispatchQueue.main.async { run.selectedPart = id } },
                  onSnap: { f in run.snapped = f },
                  onNote: { t in run.note = t },
                  onFollowChange: { on in DispatchQueue.main.async { followPhotos = on } },
                  onPick: { p, target, part, face, typ, foto, px in
                      let pp = Runner.PickPoint(pos: [Double(p.x), Double(p.y), Double(p.z)].map { ($0 * 10).rounded() / 10 },
                                                target: target, yta: face, ytatyp: typ, del: part, foto: foto, foto_px: px)
                      if run.tool == .peka { run.pekaKlick(pp) } else { run.pick = pp } })
            .overlay {
                if run.model == nil && run.parts.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("Tomt projekt").font(.headline).foregroundStyle(.secondary)
                        Text("Lägg till en del från en mall, importera en fil (STEP, STL, 3MF, OBJ – dra in den hit), eller beskriv för Claude vad du vill bygga (Samtal till höger).")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                        HStack {
                            Menu("Lägg till del från mall") {
                                ForEach(run.mallar) { m in Button(m.namn) { run.addPart(from: m) } }
                            }.fixedSize()
                            Button("Importera fil …") { run.valjImport() }
                        }
                    }
                }
            }
            .overlay {
                if importMal {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .overlay(Label("Släpp för att importera som del", systemImage: "square.and.arrow.down")
                            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)))
                        .padding(6).allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let f = urls.filter(Runner.kanImportera)
                guard !f.isEmpty, run.output != nil else { return false }
                run.importeraDelar(f); return true
            } isTargeted: { importMal = $0 }
    }

    // MARK: Snabbtangenter utan modifierare (bara när man inte skriver i ett textfält)

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { e in
            // Rita: ⌥ nedhållet = dra för att vrida (handverktyget); mellanslag är "håll och prata" i alla verktyg
            if e.type == .flagsChanged {
                run.mellanslag = run.screen == .projekt && run.tool == .rita && e.modifierFlags.contains(.option)
                return e
            }
            // Håll mellanslag = mikrofonen i chattrutan lyssnar tills det släpps (i skrivfältet sköter fältet det själv)
            if e.keyCode == 49 {
                if e.type == .keyUp { if run.mikHall { run.mikHall = false; return nil }; return e }
                if run.mikHall { return nil }
                if run.screen == .projekt, !((e.window ?? NSApp.keyWindow)?.firstResponder is NSTextView), (e.window ?? NSApp.keyWindow)?.attachedSheet == nil,
                   e.modifierFlags.intersection([.command, .control, .option]).isEmpty, !e.isARepeat {
                    run.dolPaneler = false
                    run.mikHall = true
                    return nil
                }
                return e
            }
            if e.type == .keyUp { return e }
            // ⇥: släck/tänd alla paneler; Esc tänder dem igen
            if run.screen == .projekt, e.keyCode == 48, e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               !(NSApp.keyWindow?.firstResponder is NSTextView), NSApp.keyWindow?.attachedSheet == nil {
                run.dolPaneler.toggle(); return nil
            }
            if run.screen == .projekt, e.keyCode == 53, run.dolPaneler, NSApp.keyWindow?.attachedSheet == nil {
                run.dolPaneler = false; return nil
            }
            guard run.screen == .projekt, e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView), NSApp.keyWindow?.attachedSheet == nil,
                  let c = e.charactersIgnoringModifiers?.lowercased() else { return e }
            switch c {
            case "v": run.tool = .valj
            case "m": run.tool = .mat; run.matning = nil
            case "d": run.tool = .rita
            case "g": run.tool = .flytta
            case "p": run.tool = .peka
            case "e": if run.spelar { run.spelar = false } else { withAnimation { run.explode = run.explode > 0 ? 0 : 1 } }
            case "a":
                if run.spelar { run.spelar = false } else if run.snapped == nil { if run.explode == 0 { run.explode = 1 }; run.spelar = true }
            case "x": run.sectionOn.toggle(); run.snittPlaceras = run.sectionOn
            case "r": run.resetLayout()
            case "o": withAnimation { showTree.toggle() }
            case "z": run.request("Valt")
            default:
                if e.keyCode == 53 {   // Esc: rensa val och mätning (fotoläget har egen Esc-knapp)
                    if run.spelar { run.spelar = false; return nil }
                    if run.tool == .rita, run.ritning != nil { run.kastaRitning(); return nil }
                    if run.tool == .peka, !run.pekpunkter.isEmpty { run.pekpunkter = []; run.traff = nil; run.info = nil; return nil }
                    if run.snapped != nil { return e }
                    if run.matning != nil || run.traff != nil || run.selectedPart != nil {
                        run.matning = nil; run.traff = nil; run.info = nil; run.selectedPart = nil; return nil
                    }
                }
                return e
            }
            return nil
        }
    }

    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }
}

// MARK: - Verktygsraden (svävande)

struct ToolBar: View {
    @ObservedObject var run: Runner
    @Binding var followPhotos: Bool
    @Binding var cadStyle: Int
    let overlayOpacity: Double

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Verktyg.allCases) { t in
                Button { run.tool = t; if t == .mat { run.matning = nil } } label: {
                    Image(systemName: t.ikon).frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(run.tool == t ? Color.accentColor.opacity(0.22) : .clear))
                .foregroundStyle(run.tool == t ? Color.accentColor : Color.primary)
                .tips("\(t.namn): \(t.hjalp)")
            }
            sep
            Button { run.spelar = false; withAnimation(.easeInOut(duration: 0.3)) { run.explode = run.explode > 0 ? 0 : 1 } } label: {
                Image(systemName: run.explode > 0 ? "burst.fill" : "burst")
                    .foregroundStyle(run.explode > 0 ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .tips(run.explode > 0 ? "Sprängvy på (E) – klicka för ihop. Delar som är hopfällda i objektträdet hålls ihop med sina kroppar; fäll ut en del (▸) så dras dess kroppar isär var för sig. Flytta (G) i sprängvyn placerar delarna isär; det följer med reglaget och sparade vyer"
                                  : "Sprängvy (E): dra isär de synliga delarna – bara visning. Delar som är hopfällda i objektträdet sprängs som en enhet; fäll ut en del (▸) så dras dess kroppar isär var för sig")
            if run.explode > 0 {
                Slider(value: $run.explode, in: 0...1).frame(width: 80).tips("Hur långt isär")
                Button { run.spelar.toggle() } label: { Image(systemName: run.spelar ? "stop.fill" : "play.fill") }
                    .buttonStyle(.borderless).disabled(run.snapped != nil)
                    .tips(run.spelar ? "Stoppa (A, Esc)" : "Spela upp (A): ihop ↔ isär i en loop tills du stoppar")
            }
            if !run.offsets.isEmpty || !run.sprangOffsets.isEmpty || run.explode > 0 {
                Button { withAnimation { run.resetLayout() } } label: { Image(systemName: "arrow.down.forward.and.arrow.up.backward") }
                    .buttonStyle(.borderless).tips("Lägg tillbaka allt (R)")
            }
            sep
            Toggle(isOn: Binding(get: { run.sectionOn }, set: { run.sectionOn = $0; run.snittPlaceras = $0 })) { Image(systemName: "square.split.diagonal") }
                .toggleStyle(.button).buttonStyle(.borderless).disabled(run.snapped != nil)
                .tips("Snitt (X): klicka sedan i modellen där snittet ska gå – planet vänds mot dig (⌥-klick: lodrätt)")
            if run.sectionOn, let l = run.sectionLabel {
                Text(l.replacingOccurrences(of: "Snitt: ", with: "")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Slider(value: Binding(get: { run.sectionCoord ?? run.sectionRange.lowerBound },
                                      set: { v in if UserInput.isNow { run.sectionCoord = v } }),   // SwiftUI skriver annars tillbaka värden när intervallet ändras
                       in: run.sectionRange).frame(width: 90).tips("Flytta snittplanet")
            }
            if !run.reliablePhotos.isEmpty {
                Toggle(isOn: $followPhotos) { Image(systemName: "camera") }
                    .toggleStyle(.button).buttonStyle(.borderless)
                    .tips("Foto (⌘K): delarna ovanpå bilderna i kamerans exakta perspektiv")
            }
            sep
            Menu {
                Picker("Delarna ritas", selection: $cadStyle) { Text("Fyllda").tag(0); Text("Bara kanter").tag(1); Text("Fyllda med kanter").tag(2) }
                    .pickerStyle(.inline)
            } label: { Image(systemName: "cube") }
            .menuStyle(.borderlessButton).fixedSize().tips("Hur delarna ritas: fyllda, bara kanter eller båda")
            Menu {
                Picker("Färgschema", selection: $run.fargschema) {
                    ForEach(Fargschema.allCases) { f in Text(f.namn).tag(f) }
                }.pickerStyle(.inline)
            } label: { Image(systemName: "paintpalette") }
            .menuStyle(.borderlessButton).fixedSize().tips("Färgschema för delarna (olika projekt får olika scheman)")
            opacityControl
            sep
            Button { run.dolPaneler.toggle() } label: {
                Image(systemName: run.dolPaneler ? "rectangle.inset.filled" : "rectangle.dashed")
            }
            .buttonStyle(.borderless)
            .tips(run.dolPaneler ? "Tänd panelerna igen (⇥ eller Esc)" : "Släck alla paneler – bara modellen (⇥, Esc tänder igen)")
            if run.snapped != nil { photoNav }
            if let t = run.note { Label(t, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }

    private var sep: some View { Divider().frame(height: 16).padding(.horizontal, 2) }

    @ViewBuilder private var opacityControl: some View {
        if let id = run.selectedPart {
            let name = id == "skanning" ? "Skanning" : (run.parts.first { $0.id == id }?.namn ?? id)
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).tips("Opacitet: \(name)")
            Slider(value: Binding(get: { run.partOpacity[run.opacityKey(id)] ?? (run.snapped != nil ? overlayOpacity : 1) },
                                  set: { run.setOpacity(run.opacityKey(id), $0) }), in: 0.05...1)
                .frame(width: 80).tips("Opacitet: \(name)")
        } else if run.snapped != nil {
            Image(systemName: "photo").foregroundStyle(.secondary).tips("Opacitet: foto")
            Slider(value: Binding(get: { run.partOpacity["foto/fotot"] ?? 1 }, set: { run.setOpacity("foto/fotot", $0) }), in: 0.05...1)
                .frame(width: 80).tips("Opacitet: foto")
        }
    }

    private var photoNav: some View {
        let r = run.reliablePhotos
        return HStack(spacing: 4) {
            sep
            Button { step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).keyboardShortcut(.leftArrow, modifiers: []).tips("Föregående bild (←)")
            if let f = run.snapped, let i = r.firstIndex(of: f) { Text("\(i + 1)/\(r.count)").font(.caption.monospacedDigit()) }
            Button { step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).keyboardShortcut(.rightArrow, modifiers: []).tips("Nästa bild (→)")
        }
    }

    private func step(_ d: Int) {
        let r = run.reliablePhotos
        guard let f = run.snapped, let i = r.firstIndex(of: f), !r.isEmpty else { return }
        run.request("foto:" + r[(i + d + r.count) % r.count].bild)
    }
}

// MARK: - Skriv ut: knappen och rutan under pilen (utskriftsalternativ + inställningar per del)

struct SkrivUtKnapp: View {
    @ObservedObject var run: Runner
    @State var visa = false                // (testriggen öppnar rutan direkt)
    @State private var del: String?

    private var kanSkriva: Bool { run.parts.contains { $0.export != nil } }
    private var designdelar: [PartInfo] { run.parts.filter { $0.roll == "design" && ($0.export != nil || $0.foralder != nil) } }
    /// Delen vars inställningar visas: den man valt i rutan, annars den valda i vyn, annars den första.
    private var aktuell: String? {
        let ids = designdelar.map(\.id)
        if let d = del, ids.contains(d) { return d }
        if let s = run.selectedPart ?? run.traff?.del {
            let id = s.split(separator: "#").first.map(String.init) ?? s
            if ids.contains(id) { return id }
        }
        return ids.first
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { run.exportBambuProject() } label: { Label("Skriv ut", systemImage: "printer") }
                .buttonStyle(.borderless).padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 4)
                .disabled(!kanSkriva)
                .tips(run.sectionOn && run.snapped == nil
                      ? "Skriv ut snittet: de synliga delarna avskurna där snittet går, snittytan mot plattan (⌘E)"
                      : "Öppna synliga konstruktionsdelar som ett färdigt Bambu Studio-projekt (⌘E)")
            Divider().frame(height: 16)
            Button { del = nil; visa.toggle() } label: { Image(systemName: "chevron.down").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless).padding(.horizontal, 7).padding(.vertical, 4)
                .tips("Utskriftsalternativ och inställningar per del (plast, väggar, infill …)")
                .popover(isPresented: $visa, arrowEdge: .bottom) { ruta }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private var ruta: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if run.sectionOn && run.snapped == nil {
                    rad("Bara snittet (det som syns, avskuret vid planet)", "square.split.diagonal") { run.exportBambuProject() }
                    rad("Hela delarna (utan snitt)", "cube") { run.exportBambuProject(heladelar: true) }
                } else {
                    rad("Bambu Studio-projekt (alla synliga delar, inställningar satta)", "printer") { run.exportBambuProject() }
                }
                rad("Öppna delarnas 3MF-filer var för sig", "doc.on.doc") { run.exportAll() }
            }
            .disabled(!kanSkriva)
            Divider()
            if let pid = aktuell {
                if designdelar.count > 1 {
                    Picker("Inställningar för", selection: Binding(get: { pid }, set: { del = $0 })) {
                        ForEach(designdelar) { Text($0.namn).tag($0.id) }
                    }
                    .pickerStyle(.menu).controlSize(.small)
                }
                ScrollView { UtskriftKort(run: run, pid: pid, alltidOppen: true).padding(.trailing, 6) }
                    .frame(maxHeight: 520)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Inga konstruktionsdelar att skriva ut än.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private func rad(_ t: String, _ ikon: String, _ gor: @escaping () -> Void) -> some View {
        Button { visa = false; gor() } label: {
            Label(t, systemImage: ikon).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.vertical, 4).padding(.horizontal, 4)
    }
}

// MARK: - Inspektören (mått på det valda, mätning, kantbehandling, utskriftsinställningar)

struct Inspector: View {
    @ObservedObject var run: Runner
    var toChat: () -> Void
    @State private var filletText = "1"
    @State private var fasText = "0,5"


    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            main
        }
    }

    @ViewBuilder private var main: some View {
        if run.tool == .rita {
            hintCard(ritText)
        } else if run.tool == .mat || run.matning != nil {
            card { measure }
        } else if let info = run.info {
            card { infoView(info) }
        } else if run.snittPlaceras && run.sectionOn {
            hintCard("Klicka i modellen där snittet ska gå – planet vänds mot dig genom punkten (⌥-klick: lodrätt tvärs igenom)")
        } else if run.tool != .valj {
            hintCard(run.tool.hjalp)
        }
    }

    private var ritText: String {
        guard let r = run.ritning else { return Verktyg.rita.hjalp }
        let n = r.streck.count
        return "Ritning: \(n) streck – beskriv i Samtal och skicka. Fler streck från samma vy hamnar i samma ritning. ⌘Z tar bort senaste strecket, Esc kastar ritningen."
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6, content: c)
            .padding(10)
            .frame(width: 290, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }

    private func hintCard(_ t: String) -> some View {
        Text(t).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
    }

    @ViewBuilder private var measure: some View {
        HStack {
            Label("Mät", systemImage: "ruler").font(.headline)
            Spacer()
            if run.matning != nil { Button { run.matning = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
        }
        if let m = run.matning {
            if m.b == nil {
                Text("Klicka den andra punkten, ytan eller kanten.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(m.avstand.map { Fmt.mm($0) } ?? "–").font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .textSelection(.enabled)
                Text(m.text).font(.caption.monospacedDigit()).foregroundStyle(.secondary).textSelection(.enabled)
                if let v = m.vinkel { Text(String(format: "Vinkel %.1f°", v).replacingOccurrences(of: ".", with: ",")).font(.caption) }
                HStack {
                    Button("Kopiera") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.avstand.map { Fmt.mm($0) } ?? m.text, forType: .string) }
                    Button("Fråga Claude om det här") {
                        run.send(questionID: "meddelande", question: "Mätning", text: "Jag mätte \(m.text). ", attachment: nil,
                                 plats: Runner.PickPoint(pos: [m.a.pos.x, m.a.pos.y, m.a.pos.z], target: m.a.del ?? "modellen", del: m.a.del))
                        toChat()
                    }
                }.controlSize(.small)
            }
        } else {
            Text(Verktyg.mat.hjalp + ". Punkterna fäster mot hörn, kantmitt och ytcentrum.").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func infoView(_ info: Info) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(info.rubrik).font(.headline).lineLimit(2)
            Spacer()
            Button { run.info = nil; run.traff = nil; run.selectedPart = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).tips("Avmarkera (Esc)")
        }
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(Array(info.rader.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).font(.caption).foregroundStyle(.secondary)
                    Text(r.1).font(.callout.monospacedDigit()).textSelection(.enabled)
                }
            }
        }
        if let t = run.traff, t.slag == .kant, let del = t.del {
            Divider()
            HStack(spacing: 6) {
                Text("Fillet").font(.caption)
                TextField("r", text: $filletText).frame(width: 44).textFieldStyle(.roundedBorder)
                Button("Runda") { treat(t, del: del, typ: "fillet", text: filletText) }
                Text("Fas").font(.caption).padding(.leading, 4)
                TextField("mm", text: $fasText).frame(width: 44).textFieldStyle(.roundedBorder)
                Button("Fasa") { treat(t, del: del, typ: "fas", text: fasText) }
            }.controlSize(.small)
            Text(run.scripts.isEmpty ? "Delen saknar del-skript – Claude gör ändringen." : "Byggs om direkt via del-skriptet. Claude får också veta.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if let t = run.traff, let o = t.objekt ?? t.del, run.offsets[o] != nil {
            Button("Lägg tillbaka (flyttad tillfälligt)") { run.offsets[o] = nil }.controlSize(.small)
        }
        Button { run.pick = t2pick(run.traff); toChat() } label: { Label("Säg något om det här …", systemImage: "bubble.left") }
            .controlSize(.small).disabled(run.traff == nil)
    }

    private func t2pick(_ t: Traff?) -> Runner.PickPoint? {
        guard let t else { return run.pick }
        let name = t.del.flatMap { d in run.parts.first { $0.id == d }?.namn } ?? (t.del == "skanning" ? "skanning" : "modellen")
        return Runner.PickPoint(pos: [t.pos.x, t.pos.y, t.pos.z].map { ($0 * 10).rounded() / 10 }, target: name, yta: t.yta, ytatyp: nil, del: t.del, foto: t.foto, foto_px: t.fotoPx)
    }

    private func treat(_ t: Traff, del: String, typ: String, text: String) {
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }), v > 0 else {
            run.toast = "Skriv ett mått i mm"; return
        }
        let name = run.parts.first { $0.id == del }?.namn ?? del
        // projekt.py hittar kanten igen via dess mittpunkt (kanter[].mitt i ytor.json), inte via klickpunkten
        let mitt = t.kant.flatMap { run.edgeMid(del: del, kant: $0) } ?? [t.pos.x, t.pos.y, t.pos.z]
        run.kantbehandla(Kantbehandling(del: del, kant: t.kant, mitt: mitt, typ: typ, matt: v, tid: isoNu()), namn: name)
    }
}

/// Sant medan en mus- eller tangenthändelse hanteras (skiljer användarens reglagedrag från SwiftUI:s egna tillbakaskrivningar).
enum UserInput {
    static var isNow: Bool {
        guard let t = NSApp.currentEvent?.type else { return false }
        return [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .scrollWheel, .gesture, .swipe].contains(t)
    }
}

enum Fmt {
    static func mm(_ v: Double, _ d: Int = 2) -> String {
        String(format: "%.\(d)f mm", v).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
    }
}

// MARK: - Högerpanelen: Samtal och Mått

struct RightPanel: View {
    @ObservedObject var run: Runner
    @Binding var tab: Int

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(chatTitle).tag(0)
                Text("Mått" + ((run.cad?.parametrar?.count).map { " (\($0))" } ?? "")).tag(1)
                Text("Historik").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            .tips(tab == 2 ? "" : run.historikPa ? "Historik (⌘Y): \(run.historik.count) versioner i git" : "Historik (⌘Y): projektet sparas inte i git")
            Divider()
            switch tab {
            case 1: MattPanel(run: run)
            case 2: HistorikVy(run: run, iPanel: true)
            default: SamtalVy(run: run)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var chatTitle: String {
        let open = (run.cad?.fragor ?? []).filter { $0.besvarad != true && !run.closedQuestions.contains($0.id) }.count
        return open > 0 ? "Samtal · \(open) fråga\(open == 1 ? "" : "or")" : "Samtal"
    }
}

/// Parametrarna (redigerbara mått), beskrivning och avvikelse.
struct MattPanel: View {
    @ObservedObject var run: Runner
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let e = run.buildError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let b = run.cad?.beskrivning { Text(b).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let a = run.cad?.avvikelse { Label("Avvikelse mot skanning: \(a)", systemImage: "scope").font(.caption) }
                if let ps = run.cad?.parametrar, !ps.isEmpty {
                    if run.canEdit {
                        Text("Klicka på ett värde för att ändra det – delen byggs om direkt.").font(.caption2).foregroundStyle(.secondary)
                    }
                    let groups = ParamGroups.grouped(ps)
                    ForEach(groups, id: \.0) { g, items in
                        Text(g.isEmpty ? "Övrigt" : g).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(items) { p in
                            ParamRow(run: run, p: p, label: ParamGroups.shortName(p, group: g), valueText: ParamGroups.value(p),
                                     icon: ParamStyle.icon(p.kalla), color: ParamStyle.color(p.kalla))
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(Array(Set(ps.compactMap(\.kalla))).sorted(), id: \.self) { k in
                            Label(k, systemImage: ParamStyle.icon(k)).foregroundStyle(ParamStyle.color(k))
                        }
                    }.font(.caption2).padding(.top, 6)
                } else {
                    Text("Inga mått än. När en del ritas med ett del-skript (mall eller Claude) hamnar dess mått här och kan ändras.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum ParamGroups {
    static func grouped(_ ps: [CadInfo.Param]) -> [(String, [CadInfo.Param])] {
        var order: [String] = []
        var map: [String: [CadInfo.Param]] = [:]
        for p in ps {
            let g = p.grupp ?? (p.namn.contains(": ") ? String(p.namn.split(separator: ":", maxSplits: 1)[0]) : "")
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(p)
        }
        return order.map { ($0, map[$0]!) }
    }
    static func shortName(_ p: CadInfo.Param, group: String) -> String {
        guard !group.isEmpty, p.namn.hasPrefix(group + ": ") else { return p.namn }
        return String(p.namn.dropFirst(group.count + 2))
    }
    static func value(_ p: CadInfo.Param) -> String {
        if let t = p.text { return t }
        guard let v = p.varde else { return "?" }
        var s = ParamStyle.format(v, unit: p.enhet)
        if let u = p.enhet { s += " \(u)" }
        if let o = p.osakerhet { s += String(format: " ±%.2f", o) }
        return s
    }
}

// MARK: - Bambu Studio-projekt

extension Runner {
    /// Kantens mittpunkt ("mitt") ur <del>-ytor.json.
    func edgeMid(del: String, kant: Int) -> [Double]? {
        guard let folder = cadFolder, let p = parts.first(where: { $0.id == del }),
              let data = try? Data(contentsOf: folder.appendingPathComponent(p.fil)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kanter = root["kanter"] as? [[String: Any]],
              let k = kanter.first(where: { ($0["id"] as? Int) == kant }) else { return nil }
        if let m = k["mitt"] as? [Double], m.count == 3 { return m }
        if let p = k["p"] as? [Double], p.count >= 6 {   // mitten av polylinjen
            let n = p.count / 3, i = n / 2
            return [p[3 * i], p[3 * i + 1], p[3 * i + 2]]
        }
        return nil
    }

    /// cad/bambu.py → projekt-3MF (X2D, inställningar per del ur cad/utskrift.json, plasten i objektnamnet) med synliga
    /// konstruktionsdelar, öppnas i Bambu Studio.
    /// Konstruktionsdelar med utskriftsfil som syns – eller vars barn syns (barnet skrivs ut ihop med föräldern).
    var synligaUtskriftsdelar: [String] {
        parts.filter { p in
            p.roll == "design" && p.export != nil
                && (!hidden.contains(p.id) || parts.contains { $0.foralder == p.id && !hidden.contains($0.id) })
        }.map(\.id)
    }

    /// Skriv ut (⌘E): ett Bambu Studio-projekt av de synliga delarna. Är snittet på blir det bara snittet (3D-vyn ger
    /// planet via begäran "skriv-ut-snitt" → skrivUtSnitt), om inte heladelar.
    func exportBambuProject(heladelar: Bool = false) {
        if sectionOn && snapped == nil && !heladelar { request("skriv-ut-snitt"); return }
        korBambu(extra: [], tillagg: nil)
    }

    /// Snittet som syns: cad/snitt_utskrift.py skär de synliga delarna vid planet (kamerans sida bort, snittytan nedåt),
    /// sedan bambu.py med de avskurna filerna.
    func skrivUtSnitt(_ s: SparadSnitt) {
        guard let project = output, let cad = cadFolder else { return }
        let ids = synligaUtskriftsdelar
        guard !ids.isEmpty else { toast = "Inga synliga konstruktionsdelar att skriva ut"; return }
        toast = "Skär delarna vid \(s.namn) …"
        let mapp = cad.appendingPathComponent("visningar/snitt")   // mellanfiler: visningar/ hålls utanför git
        let p = Process()
        p.executableURL = Hem.url.appendingPathComponent(".venv/bin/python")
        p.arguments = [Hem.url.appendingPathComponent("cad/snitt_utskrift.py").path, project.path,
                       "--axel", String(s.axel), "--lage", String(s.lage), "--tecken", String(s.tecken),
                       "--delar", ids.joined(separator: ","), "--ut", mapp.path]
        var env = ProcessInfo.processInfo.environment
        env["SKANNA_HEM"] = Hem.url.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { [weak self] proc in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                if proc.terminationStatus == 0 {
                    let namn = s.namn.replacingOccurrences(of: ",", with: "_").filter { $0.isLetter || $0.isNumber || "-_".contains($0) }
                    self.korBambu(extra: ["--stl-mapp", mapp.path, "--namn-tillagg", " – \(s.namn)",
                                          "--ut", cad.appendingPathComponent("\(project.lastPathComponent)-\(namn)-bambu.3mf").path],
                                  tillagg: s.namn)
                } else {
                    self.buildLog = out
                    let last = out.split(separator: "\n").last.map(String.init) ?? ""
                    self.buildError = "Snittet gick inte att skära: " + last
                }
            }
        }
        do { try p.run() } catch { toast = "Kunde inte starta snittet: \(error.localizedDescription)" }
    }

    private func korBambu(extra: [String], tillagg: String?) {
        guard let project = output else { return }
        flushUtskrift()
        let script = Hem.url.appendingPathComponent("cad/bambu.py")
        guard FileManager.default.fileExists(atPath: script.path) else { exportAll(); return }
        let ids = synligaUtskriftsdelar
        guard !ids.isEmpty else { toast = "Inga synliga konstruktionsdelar att skriva ut"; return }
        toast = tillagg.map { "Gör Bambu Studio-projekt av \($0) …" } ?? "Gör Bambu Studio-projekt …"
        let p = Process()
        p.executableURL = Hem.url.appendingPathComponent(".venv/bin/python")
        p.arguments = [script.path, project.path, "--delar", ids.joined(separator: ",")] + extra
        var env = ProcessInfo.processInfo.environment
        env["SKANNA_HEM"] = Hem.url.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        p.terminationHandler = { [weak self] proc in
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let last = out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            let varningar = out.split(separator: "\n").filter { $0.hasPrefix("varning: ") }.map { String($0.dropFirst(9)) }
            DispatchQueue.main.async {
                guard let self else { return }
                if proc.terminationStatus == 0, last.hasSuffix(".3mf"), FileManager.default.fileExists(atPath: last) {
                    self.openInSlicer([URL(fileURLWithPath: last)])
                    self.toast = "Öppnar \((last as NSString).lastPathComponent) i Bambu Studio" + (varningar.first.map { " – \($0)" } ?? "")
                } else {
                    self.buildLog = out
                    self.buildError = "Bambu-exporten misslyckades: " + last
                }
            }
        }
        do { try p.run() } catch { toast = "Kunde inte starta exporten: \(error.localizedDescription)" }
    }
}
