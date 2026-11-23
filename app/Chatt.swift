// Chattpanelen med trådar: aktiva trådar överst, avslutade nedanför, skrivfält som startar en ny tråd.
// Trådarna beräknas ur cad/svar.json, cad/claude.json och cad/geometri.json (se PLAN-modellera.md och AGENT.md).
import AppKit
import SwiftUI

// MARK: - Trådmodell

enum ChatStatus: Equatable {
    case fraga, arbetar, vantar, klar
    var aktiv: Bool { self != .klar }
    var text: String { ["fraga": "Fråga till dig", "arbetar": "Claude arbetar", "vantar": "Väntar på Claude", "klar": "Klar"][key]! }
    var icon: String { ["fraga": "questionmark.circle.fill", "arbetar": "sparkles", "vantar": "hourglass", "klar": "checkmark.circle.fill"][key]! }
    var color: Color { [Color.orange, Color.purple, Color.secondary, Color.green][order] }
    private var key: String { ["fraga", "arbetar", "vantar", "klar"][order] }
    private var order: Int { switch self { case .fraga: return 0; case .arbetar: return 1; case .vantar: return 2; case .klar: return 3 } }
    static func parse(_ s: String?) -> ChatStatus? {
        switch s { case "fraga": return .fraga; case "arbetar": return .arbetar; case "vantar": return .vantar; case "klar": return .klar; default: return nil }
    }
}

struct ChatEntry: Identifiable {
    let id: String
    let tid: String
    let fromClaude: Bool
    let isQuestion: Bool
    let text: String
    let svar: Svar?
}

struct ChatThread: Identifiable {
    let id: String                  // rot-tid (meddelandetråd) eller fråge-id
    let isQuestion: Bool
    var title: String
    var status: ChatStatus
    var entries: [ChatEntry]
    var plats: Runner.PickPoint?
    var kant: Int?
    var markering: Bool             // frågan har en markering i 3D-vyn
    var closedByUser: Bool
    var lastTid: String
    var count: Int { entries.count }
    var canFocus: Bool { plats != nil || markering }
}

extension Runner {
    // MARK: Stängda trådar (lokalt, cad/stangda-tradar.json = lista med rot-id)

    private var closedThreadsURL: URL? { cadFolder?.appendingPathComponent("stangda-tradar.json") }

    func loadClosedThreads() -> Set<String> {
        Set(closedThreadsURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    func setThreadClosed(_ id: String, _ closed: Bool) {
        guard let url = closedThreadsURL else { return }
        var s = loadClosedThreads()
        if closed { s.insert(id) } else { s.remove(id) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s.sorted()) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Beräkning

    /// Alla trådar (aktiva och avslutade), Claudes fristående meddelanden och parameterloggen.
    func chatThreads(closedLocal: Set<String>) -> (threads: [ChatThread], loose: [ClaudeInfo.Meddelande], log: [Svar]) {
        let qs = cad?.fragor ?? []
        let qIDs = Set(qs.map(\.id))
        var userBy: [String: [Svar]] = [:]
        var tidKey: [String: String] = [:]
        var log: [Svar] = []
        for a in answers.sorted(by: { $0.tid < $1.tid }) {
            if a.fraga_id == "parameter" { log.append(a); continue }
            let key: String
            if qIDs.contains(a.fraga_id) {
                if a.svar.hasPrefix("(stängd av dig") { continue }
                key = a.fraga_id
            } else { key = a.trad ?? a.tid }
            userBy[key, default: []].append(a)
            if tidKey[a.tid] == nil { tidKey[a.tid] = key }
        }
        for q in qs { tidKey[q.id] = q.id }
        var claudeBy: [String: [ClaudeInfo.Meddelande]] = [:]
        var pending = (claude?.meddelanden ?? []).sorted { $0.tid < $1.tid }
        var changed = true
        while changed {
            changed = false
            pending.removeAll { m in
                guard let r = m.svar_pa, let k = tidKey[r] else { return false }
                claudeBy[k, default: []].append(m)
                if tidKey[m.tid] == nil { tidKey[m.tid] = k }
                changed = true
                return true
            }
        }
        var keys = Array(userBy.keys)
        for q in qs where userBy[q.id] == nil { keys.append(q.id) }
        let senasteClaude = (claude?.meddelanden ?? []).map(\.tid).max() ?? ""
        let claudeArbetarNu = claudeArbetar
        var out: [ChatThread] = []
        for key in keys {
            let q = qs.first { $0.id == key }
            var entries: [ChatEntry] = []
            if let q { entries.append(ChatEntry(id: "q" + q.id, tid: "", fromClaude: true, isQuestion: true, text: q.text, svar: nil)) }
            var rest: [ChatEntry] = (userBy[key] ?? []).map { ChatEntry(id: "u" + $0.id, tid: $0.tid, fromClaude: false, isQuestion: false, text: $0.svar, svar: $0) }
            rest += (claudeBy[key] ?? []).map { ChatEntry(id: "c" + $0.tid + String($0.text.hashValue), tid: $0.tid, fromClaude: true, isQuestion: false, text: $0.text, svar: nil) }
            rest.sort { $0.tid < $1.tid }
            entries += rest
            guard !entries.isEmpty else { continue }
            let isQ = q != nil
            let first = userBy[key]?.first
            var plats: PickPoint?
            var kant: Int?
            if let p = (userBy[key] ?? []).first(where: { $0.plats != nil }), let pos = p.plats {
                plats = PickPoint(pos: pos, target: p.pa ?? "skanning", yta: p.yta, ytatyp: p.ytatyp, del: p.del, foto: p.foto, foto_px: p.foto_px)
                kant = p.kant
            }
            let closedByUser = isQ ? closedQuestions.contains(key) : closedLocal.contains(key)
            let lastEntry = entries.last!
            // Status. Claude markerar trådar i claude.json, men glömmer ibland att släppa "arbetar" – och en äldre
            // "klar" får inte dölja ett nytt svar från dig. Därför vägs markeringen mot tiderna:
            //  · ditt meddelande sist, ej mottaget                 → väntar på Claude
            //  · ditt meddelande sist, mottaget, Claude har skrivit något senare (var som helst) och kallar tråden klar → klar
            //  · ditt meddelande sist, mottaget, Claude arbetar nu   → arbetar, annars → väntar
            //  · Claudes meddelande sist                           → klar, utom när Claude uttryckligen frågar (fraga)
            let explicit = ChatStatus.parse(claude?.tradar?[key]?.status)
            var status: ChatStatus
            if closedByUser { status = .klar }
            else if !lastEntry.fromClaude, let s = lastEntry.svar {
                if isRead(s) { status = .klar }
                else if !isReceived(s) { status = .vantar }
                else if explicit == .klar, senasteClaude > s.tid { status = .klar }
                else { status = claudeArbetarNu ? .arbetar : .vantar }
            } else if isQ, q?.besvarad != true, !entries.contains(where: { !$0.fromClaude }) { status = .fraga }
            else if explicit == .fraga { status = .fraga }
            else if isQ, q?.besvarad != true, explicit == nil { status = .fraga }
            else { status = .klar }
            var title = claude?.tradar?[key]?.titel ?? ""
            if title.isEmpty { title = q?.text ?? first?.svar ?? "" }
            if title.isEmpty { title = first?.fraga ?? "Tråd" }
            title = String(title.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
            if title.count > 48 { title = String(title.prefix(46)) + "…" }
            out.append(ChatThread(id: key, isQuestion: isQ, title: title, status: status, entries: entries, plats: plats, kant: kant,
                                  markering: !(q?.markering ?? []).isEmpty, closedByUser: closedByUser,
                                  lastTid: rest.last?.tid ?? ""))
        }
        // Claudes lösa meddelanden (inte svar på något) blir egna, avslutade trådar i historiken
        for m in pending {
            var t = String(m.text.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
            if t.count > 48 { t = String(t.prefix(46)) + "…" }
            out.append(ChatThread(id: "claude-" + m.tid, isQuestion: false, title: t, status: .klar,
                                  entries: [ChatEntry(id: "c" + m.tid, tid: m.tid, fromClaude: true, isQuestion: false, text: m.text, svar: nil)],
                                  plats: nil, kant: nil, markering: false, closedByUser: false, lastTid: m.tid))
        }
        out.sort { $0.lastTid > $1.lastTid }
        return (out, [], (log + skriptMattLogg).sorted { $0.tid < $1.tid })
    }

    /// Arbetar Claude just nu? claude.json säger "arbetar" och har ändrats den senaste halvtimmen
    /// (annars har Claude troligen avbrutits utan att städa – då visas det i stället för ett evigt "arbetar").
    var claudeArbetar: Bool { claude?.status == "arbetar" && !claudeTyst }
    var claudeTyst: Bool {
        guard claude?.status == "arbetar", let f = cadFolder?.appendingPathComponent("claude.json"),
              let d = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(d) > 30 * 60
    }
    var claudeSenast: Date? {
        cadFolder.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.appendingPathComponent("claude.json").path))?[.modificationDate] as? Date }
    }

    // MARK: Förankring och sändning

    /// Förankringen för nästa meddelande: Peka-nålen, annars det som är valt i 3D-vyn.
    var chatAnchor: (point: PickPoint, kant: Int?, text: String)? {
        func fmt(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−") }
        func punkt(_ p: [Double]) -> String { "punkt " + p.map(fmt).joined(separator: "; ") }
        func namn(_ del: String?) -> String { del.flatMap { d in parts.first { $0.id == d }?.namn } ?? del ?? "skanning" }
        if let p = pick {
            func txt(_ p: PickPoint) -> String { p.yta.map { "\(namn(p.del ?? p.target)) · yta \($0)" } ?? punkt(p.pos) }
            if pekpunkter.count == 1 { return (p, nil, txt(p)) }
            return (p, nil, pekpunkter.enumerated().map { "\(Runner.pekBokstav($0.offset)) \(txt($0.element))" }.joined(separator: "  ·  "))
        }
        guard let t = traff else { return nil }
        let pp = PickPoint(pos: [t.pos.x, t.pos.y, t.pos.z], target: t.del ?? "skanning", yta: t.yta, ytatyp: nil, del: t.del, foto: t.foto, foto_px: t.fotoPx)
        let text: String
        switch t.slag {
        case .yta: text = "\(namn(t.del)) · yta \(t.yta.map(String.init) ?? "?")"
        case .kant: text = "\(namn(t.del)) · kant \(t.kant.map(String.init) ?? "?")"
        case .objekt: text = namn(t.del)
        case .punkt: text = punkt(pp.pos)
        }
        return (pp, t.kant, text)
    }

    /// Samma funktion som skicka-knapparna anropar. thread = nil startar en ny tråd.
    func chatSend(thread: ChatThread?, text: String, attachment: URL? = nil, anchor: (point: PickPoint, kant: Int?, text: String)? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || attachment != nil || (thread == nil && ritning != nil) else { return }
        if let th = thread {
            let fler = anchor != nil && anchor?.point == pick ? Array(pekpunkter.dropFirst()) : []
            if th.isQuestion {
                send(questionID: th.id, question: th.title, text: t, attachment: attachment, plats: anchor?.point, kant: anchor?.kant, fler: fler)
                if closedQuestions.contains(th.id) { reopenQuestion(th.id) }
            } else {
                send(questionID: "meddelande", question: th.title, text: t, attachment: attachment, plats: anchor?.point, trad: th.id,
                     kant: anchor?.kant, fler: fler)
                if th.closedByUser { setThreadClosed(th.id, false) }
            }
        } else if let r = ritning {
            // ny tråd med ritningen som referens
            let (json, png, plats) = sparaRitning(r)
            send(questionID: "ritning", question: "Ritning i modellen", text: t.isEmpty ? "(se ritningen)" : t, attachment: attachment,
                 plats: plats ?? anchor?.point, ritning: json, bilagaRel: png)
            glomVantandeRitning()
            visadRitning = lasRitning(json)
        } else {
            send(questionID: anchor == nil ? "meddelande" : "plats", question: anchor == nil ? "Meddelande till Claude" : "Plats i modellen",
                 text: t, attachment: attachment, plats: anchor?.point, kant: anchor?.kant,
                 fler: anchor != nil && anchor?.point == pick ? Array(pekpunkter.dropFirst()) : [])
        }
        reloadCad()
    }

    func chatFocus(_ th: ChatThread) {
        if th.isQuestion { focusQuestion = (focusQuestion == th.id) ? nil : th.id; return }
        if let p = th.plats { tool = .peka; pick = p }
    }
}

// MARK: - Panelen

/// Chattens textstorlek (A− / A+ i panelens överkant), delas av alla chattvyer.
enum ChattText {
    static let nyckel = "chattTextstorlek"
    static let standard = 13.0
    static let spann = 11.0...20.0
}

/// "15:16" i dag, "i går 15:16", annars "17 nov 15:16".
func chattTid(_ iso: String) -> String {
    guard iso.count >= 16 else { return "" }
    let dag = String(iso.prefix(10)), klocka = String(iso.dropFirst(11).prefix(5))
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    let idag = f.string(from: Date()), igar = f.string(from: Date().addingTimeInterval(-86400))
    if dag == idag { return klocka }
    if dag == igar { return "i går " + klocka }
    guard let d = f.date(from: dag) else { return iso }
    let g = DateFormatter(); g.locale = Locale(identifier: "sv_SE"); g.dateFormat = "d MMM"
    return g.string(from: d) + " " + klocka
}

func chattDag(_ iso: String) -> String {
    guard iso.count >= 10 else { return "Utan datum" }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    let dag = String(iso.prefix(10))
    if dag == f.string(from: Date()) { return "I dag" }
    if dag == f.string(from: Date().addingTimeInterval(-86400)) { return "I går" }
    guard let d = f.date(from: dag) else { return dag }
    let g = DateFormatter(); g.locale = Locale(identifier: "sv_SE"); g.dateFormat = "EEEE d MMMM"
    return g.string(from: d).prefix(1).uppercased() + g.string(from: d).dropFirst()
}

struct ChattPanel: View {
    @ObservedObject var run: Runner
    @State private var closedLocal: Set<String> = []
    @AppStorage("chattHistorikOppen") private var showDone = true
    @State private var showLog = false
    @State private var sok = ""
    @AppStorage(ChattText.nyckel) private var storlek = ChattText.standard

    init(run: Runner, avslutadeOppna: Bool = false) {
        self.run = run
    }

    var body: some View {
        let data = run.chatThreads(closedLocal: closedLocal)
        let active = data.threads.filter { $0.status.aktiv }
        let done = data.threads.filter { !$0.status.aktiv }
        VStack(alignment: .leading, spacing: 8) {
            statusLine(active)
            // Allt i en rullning: aktiva trådar överst (hela texten), historiken under. Inga dolda höjdgränser.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if data.threads.isEmpty && data.log.isEmpty { emptyState }
                    ForEach(active) { th in
                        ChattTrad(run: run, thread: th, finished: false, onClose: { close(th) }, onReopen: {})
                            .transition(.opacity)
                    }
                    if !done.isEmpty { historik(done) }
                    if !data.log.isEmpty { logGroup(data.log) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
            }
            ChattSkrivfalt(run: run)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .animation(.easeInOut(duration: 0.25), value: data.threads.map { $0.id + ($0.status.aktiv ? "a" : "k") })
        .onAppear { closedLocal = run.loadClosedThreads() }
        .onChange(of: run.output) { _, _ in closedLocal = run.loadClosedThreads() }
        .onChange(of: run.cadStamp) { _, _ in closedLocal = run.loadClosedThreads() }
    }

    private func close(_ th: ChatThread) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if th.isQuestion { run.closeQuestion(th.id, th.title); run.reloadCad() }
            else { run.setThreadClosed(th.id, true); closedLocal = run.loadClosedThreads() }
        }
    }

    private var storleksKnappar: some View {
        HStack(spacing: 0) {
            Button { storlek = max(ChattText.spann.lowerBound, storlek - 1) } label: { Image(systemName: "textformat.size.smaller") }
                .tips("Mindre text i chatten")
            Button { storlek = min(ChattText.spann.upperBound, storlek + 1) } label: { Image(systemName: "textformat.size.larger") }
                .tips("Större text i chatten")
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    // Claudes övergripande status, tunn rad
    /// Trådar där ditt meddelande ligger sist utan svar, äldsta väntetid först.
    private func obesvarade(_ active: [ChatThread]) -> [ChatThread] {
        active.filter { $0.status == .vantar && $0.entries.last?.fromClaude == false }.sorted { $0.lastTid < $1.lastTid }
    }
    /// Claude har inte svarat på en tid och arbetar inte: troligen lyssnar ingen Claude-chatt just nu.
    private func tystClaude(_ active: [ChatThread]) -> [ChatThread] {
        guard run.claude?.status != "arbetar" || run.claudeTyst else { return [] }
        let o = obesvarade(active)
        let f = ISO8601DateFormatter()
        guard let forsta = o.first, let t = f.date(from: forsta.lastTid), Date().timeIntervalSince(t) > 180 else { return [] }
        return o
    }
    private func paminnelse(_ o: [ChatThread]) -> String {
        let lista = o.map { "• \(chattTid($0.lastTid)): \($0.title)" }.joined(separator: "\n")
        return """
        Påminnelse från \(Hem.appNamn): \(o.count) meddelande\(o.count == 1 ? "" : "n") i projektet \(run.output?.path ?? "") väntar på svar:
        \(lista)
        Läs cad/svar.json, svara i varje tråd (cad/meddela.py … --svar-pa <tid>) och bevaka sedan projektet med bevaka.sh, så att du ser nästa meddelande.
        """
    }

    @ViewBuilder private func statusLine(_ active: [ChatThread]) -> some View {
        let tyst = tystClaude(active)
        let fragaUtanTrad = run.claude?.status == "fraga" && !active.contains { $0.status == .fraga }
        HStack(spacing: 6) {
            if !tyst.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange).font(.caption)
                    Text("Inget svar på \(tyst.count) meddelande\(tyst.count == 1 ? "" : "n") sedan \(chattTid(tyst[0].lastTid)) – lyssnar Claude?")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Kopiera påminnelse") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paminnelse(tyst), forType: .string)
                        run.toast = "Påminnelsen är kopierad – klistra in den i chatten med Claude"
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                .tips("Claude körs i en egen chatt (Claude Code) och ser bara nya meddelanden när den bevakar projektet. Appen kan inte väcka den – klistra in påminnelsen där.")
            } else if fragaUtanTrad {
                Button { run.skrivFokus += 1 } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).font(.caption)
                        Text("Claude väntar på ditt svar: \(run.claude?.status_text ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text("Svara").font(.caption.bold()).foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tips("Claude frågar utan att frågan hör till en tråd. Klicka och skriv ditt svar i rutan längst ner – det blir en ny tråd som Claude läser.")
            } else if run.claude == nil {
                Button { run.copyClaudeText() } label: { Label("Kopiera uppdrag till Claude", systemImage: "doc.on.clipboard") }
                    .tips("Klistra in i chatten med Claude (Claude Code). Claude läser då AGENT.md och svarar här i appen.")
            } else if let st = run.claude?.status {
                HStack(spacing: 6) {
                    if run.claudeTyst {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        Text("Claude har inte hörts av sedan \(run.claudeSenast.map { chattTid(ISO8601DateFormatter().string(from: $0).replacingOccurrences(of: "Z", with: "")) } ?? "länge") – kör Claude fortfarande?")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        if st == "arbetar" { ProgressView().controlSize(.mini) }
                        else { Image(systemName: st == "klar" ? "checkmark.circle.fill" : "hourglass").foregroundStyle(st == "klar" ? .green : .orange).font(.caption) }
                        Text(run.claude?.status_text ?? st.capitalized).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.purple.opacity(0.08)))
                .tips(run.claude?.status_text ?? st)
            }
            Spacer(minLength: 0)
            storleksKnappar
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Prata med Claude", systemImage: "bubble.left.and.bubble.right").font(.system(size: storlek, weight: .bold))
            Text("Skriv nedan vad du vill ändra eller bygga. Varje meddelande blir en egen tråd som Claude svarar i.")
            Text("Peka (P) på ett eller flera ställen i 3D-vyn först, så följer platserna med och Claude vet exakt vad du menar.")
            Text("Aktiva trådar ligger överst. Klara trådar hamnar i Historik, sorterade per dag.")
        }
        .font(.system(size: storlek - 1)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    /// Historiken: alla avslutade trådar per dag, nyast först, med sökning i all text.
    private func historik(_ done: [ChatThread]) -> some View {
        let q = sok.trimmingCharacters(in: .whitespaces).lowercased()
        let traffar = q.isEmpty ? done : done.filter { th in
            th.title.lowercased().contains(q) || th.entries.contains { $0.text.lowercased().contains(q) }
        }
        var dagar: [(String, [ChatThread])] = []
        for th in traffar {
            let d = chattDag(th.lastTid)
            if dagar.last?.0 == d { dagar[dagar.count - 1].1.append(th) } else { dagar.append((d, [th])) }
        }
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showDone.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showDone ? 90 : 0)).font(.caption.bold())
                    Image(systemName: "clock")
                    Text("Historik").font(.system(size: storlek, weight: .bold))
                    Text("\(done.count) trådar").font(.system(size: storlek - 2)).foregroundStyle(.secondary)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .tips("Avslutade trådar och Claudes meddelanden, per dag. Klicka på en tråd för att läsa hela.")
            if showDone {
                TextField("Sök i historiken …", text: $sok).textFieldStyle(.roundedBorder).font(.system(size: storlek - 1))
                if traffar.isEmpty { Text("Inget hittades.").font(.system(size: storlek - 1)).foregroundStyle(.secondary) }
                ForEach(dagar, id: \.0) { dag, tradar in
                    Text(dag).font(.system(size: storlek - 2, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(tradar) { th in
                        ChattTrad(run: run, thread: th, finished: true, onClose: {},
                                  onReopen: { run.setThreadClosed(th.id, false); if th.isQuestion { run.reopenQuestion(th.id) }; closedLocal = run.loadClosedThreads() },
                                  startOppen: !q.isEmpty)
                    }
                }
            }
        }
    }

    private func logGroup(_ log: [Svar]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showLog ? 90 : 0)).font(.caption2.bold())
                    Image(systemName: "slider.horizontal.3").font(.caption)
                    Text("Ändrade mått (\(log.count))").font(.system(size: storlek - 1, weight: .bold))
                    Spacer()
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showLog {
                ForEach(log.reversed()) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(chattTid(a.tid)).font(.system(size: storlek - 3).monospacedDigit()).foregroundStyle(.tertiary)
                        Text(a.svar.replacingOccurrences(of: " (ändrat i appen)", with: ""))
                            .font(.system(size: storlek - 2).monospacedDigit()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Ett trådkort

struct ChattTrad: View {
    @ObservedObject var run: Runner
    let thread: ChatThread
    let finished: Bool
    let onClose: () -> Void
    let onReopen: () -> Void
    var startOppen = false
    @State private var expanded = false
    @State private var draft = ""
    @State private var attachment: URL?
    @FocusState private var focused: Bool
    @AppStorage(ChattText.nyckel) private var storlek = ChattText.standard

    private var color: Color { thread.isQuestion && thread.status == .fraga ? .orange : thread.status.color }
    private var selected: Bool { thread.isQuestion && run.focusQuestion == thread.id }
    private var oppen: Bool { expanded || startOppen }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if finished && !oppen {
                EmptyView()
            } else {
                let shown = shownEntries
                if !oppen && thread.entries.count > shown.count {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { expanded = true } } label: {
                        Text("Visa \(thread.entries.count - shown.count) tidigare meddelanden").font(.system(size: storlek - 2))
                    }.buttonStyle(.link)
                }
                ForEach(shown) { e in ChattBubbla(run: run, entry: e) }
                if !finished || expanded { replyField }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(finished ? Color.secondary.opacity(0.05) : color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.red : (finished ? Color.secondary.opacity(0.15) : color.opacity(0.35)), lineWidth: selected ? 1.5 : 1))
    }

    /// Aktiv och hopfälld: de två senaste meddelandena i sin helhet (frågetexten följer alltid med). Utfälld: alla.
    private var shownEntries: [ChatEntry] {
        if oppen { return thread.entries }
        var shown = Array(thread.entries.suffix(2))
        if thread.isQuestion, let q = thread.entries.first, shown.first?.id != q.id { shown = [q] + shown.suffix(1) }
        return shown
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if finished {
                Image(systemName: thread.closedByUser ? "xmark.circle.fill" : (thread.id.hasPrefix("claude-") ? "sparkles" : "checkmark"))
                    .foregroundStyle(thread.closedByUser ? Color.secondary : (thread.id.hasPrefix("claude-") ? Color.purple : Color.green))
                    .font(.system(size: storlek - 2, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title).font(.system(size: storlek - 1, weight: .semibold)).lineLimit(oppen ? nil : 1)
                    Text([chattTid(thread.lastTid), "\(thread.count) \(thread.count == 1 ? "meddelande" : "meddelanden")"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: storlek - 3)).foregroundStyle(.secondary)
                }
            } else {
                if thread.status == .arbetar { ProgressView().controlSize(.mini) }
                else { Image(systemName: thread.status.icon).foregroundStyle(color).font(.system(size: storlek - 1)) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title).font(.system(size: storlek, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    Text([thread.status.text, chattTid(thread.lastTid)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: storlek - 3)).foregroundStyle(color)
                }
            }
            Spacer(minLength: 0)
            if thread.canFocus { Image(systemName: "mappin.and.ellipse").font(.system(size: storlek - 2)).foregroundStyle(.red.opacity(0.7)) }
            if finished && oppen && !thread.id.hasPrefix("claude-") {
                Button("Öppna igen") { onReopen(); expanded = true }.buttonStyle(.link).font(.system(size: storlek - 2))
            }
            if !finished {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .tips("Avsluta tråden (den flyttas till Historik)")
            }
            Image(systemName: "chevron.down").rotationEffect(.degrees(oppen ? 180 : 0)).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            run.chatFocus(thread)
        }
        .tips(thread.canFocus ? "Klicka för att visa platsen i 3D-vyn och fälla ut/ihop tråden" : "Fäll ut/ihop tråden")
    }

    /// Svarsfältet: text, bilaga och – om du pekat (P) – platserna, precis som när en ny tråd startas.
    private var replyField: some View {
        let anchor = run.pekpunkter.isEmpty ? nil : run.chatAnchor
        return VStack(alignment: .leading, spacing: 3) {
            if let a = anchor, focused || !draft.isEmpty {
                Text("📍 " + a.text + " följer med svaret").font(.system(size: storlek - 3).monospacedDigit()).foregroundStyle(.red.opacity(0.8))
                    .lineLimit(3)
            }
            HStack(spacing: 4) {
                TextField(thread.isQuestion ? "Ditt svar …" : "Svara i tråden …", text: $draft, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder).font(.system(size: storlek - 1)).focused($focused).onSubmit { send(anchor) }
                Button { attachment = run.pickAttachment() } label: { Image(systemName: attachment == nil ? "paperclip" : "paperclip.circle.fill") }
                    .buttonStyle(.borderless).tips(attachment.map { "Bifogas: \($0.lastPathComponent) – klicka för att byta" } ?? "Bifoga foto eller fil till svaret")
                Button { send(anchor) } label: { Image(systemName: "paperplane.fill") }.buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && attachment == nil).tips("Skicka (↩), ny rad med ⇧↩")
            }
            if let a = attachment {
                HStack(spacing: 4) {
                    Text("Bifogas: \(a.lastPathComponent)").font(.system(size: storlek - 3)).foregroundStyle(.secondary)
                    Button { attachment = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: focused) { _, f in if f && thread.isQuestion { run.focusQuestion = thread.id } }
    }

    private func send(_ anchor: (point: Runner.PickPoint, kant: Int?, text: String)?) {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil else { return }
        run.chatSend(thread: thread, text: draft, attachment: attachment, anchor: anchor)
        if anchor != nil { run.pekpunkter = [] }
        draft = ""; attachment = nil
    }
}

struct ChattBubbla: View {
    @ObservedObject var run: Runner
    let entry: ChatEntry
    @AppStorage(ChattText.nyckel) private var storlek = ChattText.standard

    var body: some View {
        if entry.fromClaude {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: entry.isQuestion ? "questionmark.circle.fill" : "sparkles")
                    .foregroundStyle(entry.isQuestion ? Color.orange : Color.purple).font(.system(size: storlek - 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).font(.system(size: storlek)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if !entry.tid.isEmpty { Text("Claude · " + chattTid(entry.tid)).font(.system(size: storlek - 3)).foregroundStyle(.tertiary) }
                }
            }
            .padding(7).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill((entry.isQuestion ? Color.orange : Color.purple).opacity(0.11)))
            .padding(.trailing, 12)
        } else if let a = entry.svar {
            VStack(alignment: .trailing, spacing: 3) {
                if !a.svar.isEmpty { Text(a.svar).font(.system(size: storlek)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if let rel = a.ritning {
                    let shown = run.arVisad(rel)
                    Button { run.visaRitning(rel) } label: {
                        if let b = a.bilaga, let f = run.cadFolder, let img = NSImage(contentsOf: f.appendingPathComponent(b)) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(shown ? Color.pink : Color.secondary.opacity(0.3), lineWidth: 1.5))
                        } else { Label("Ritning", systemImage: "pencil.tip").font(.system(size: storlek - 2)) }
                    }.buttonStyle(.plain).tips("Tillbaka till vyn ritningen gjordes i, med strecken")
                    HStack(spacing: 8) {
                        Button { run.visaRitning(rel) } label: { Label("Visa i vyn", systemImage: "pencil.tip") }
                        if shown { Button { run.visadRitning = nil } label: { Label("Dölj", systemImage: "eye.slash") } }
                    }.buttonStyle(.plain).font(.system(size: storlek - 2)).foregroundStyle(.pink)
                } else if let b = a.bilaga { bilaga(b) }
                if a.plats != nil || a.yta != nil || a.kant != nil {
                    Label(Self.anchorText(a), systemImage: "mappin").font(.system(size: storlek - 2)).foregroundStyle(.orange)
                }
                HStack(spacing: 4) {
                    Text(chattTid(a.tid)).foregroundStyle(.tertiary)
                    Text(run.isRead(a) ? "✓✓ inarbetat" : (run.isReceived(a) ? "✓ mottaget" : "skickat"))
                        .foregroundStyle(run.isRead(a) ? Color.green : (run.isReceived(a) ? Color.blue : Color.secondary))
                }.font(.system(size: storlek - 3))
            }
            .padding(7).frame(maxWidth: .infinity, alignment: .trailing)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.13)))
            .padding(.leading, 12)
        }
    }

    /// Bilaga: bilder visas som miniatyr, andra filer som namn. Klick öppnar filen.
    @ViewBuilder private func bilaga(_ rel: String) -> some View {
        let url = run.cadFolder?.appendingPathComponent(rel)
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            if let url, let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 110).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Label((rel as NSString).lastPathComponent, systemImage: "paperclip").font(.system(size: storlek - 2))
            }
        }.buttonStyle(.plain).tips("Öppna bilagan")
    }

    static func anchorText(_ a: Svar) -> String {
        let f = a.fler?.count ?? 0
        return enAnchorText(a) + (f > 0 ? " + \(f) punkt\(f == 1 ? "" : "er") till" : "")
    }
    static func enAnchorText(_ a: Svar) -> String {
        let d = a.del ?? a.pa ?? "skanning"
        if let k = a.kant { return "\(d) · kant \(k)" }
        if let y = a.yta { return "\(d) · yta \(y)" }
        if let p = a.plats { return "punkt " + p.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") }.joined(separator: "; ") }
        return d
    }
}

// MARK: - Skrivfältet (ny tråd)

struct ChattSkrivfalt: View {
    @ObservedObject var run: Runner
    @State private var draft = ""
    @State private var attachment: URL?
    @State private var ignored: Traff?
    @FocusState private var focused: Bool
    @AppStorage(ChattText.nyckel) private var storlek = ChattText.standard
    @StateObject private var dikt = Diktering()
    @State private var mellanslagsVakt: Any?
    @State private var haller: DispatchWorkItem?
    @State private var vaxel = false          // startad med klick/kort tryck (Rita): ett nytt tryck stänger

    var body: some View {
        let anchor = (run.pick == nil && run.traff != nil && run.traff == ignored) ? nil : run.chatAnchor
        VStack(alignment: .leading, spacing: 4) {
            if let r = run.ritning {
                HStack(spacing: 6) {
                    if let d = run.ritBild(r), let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Text("✏️ Ritning · \(r.streck.count) streck").font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { run.visaVantandeRitning() } label: { Image(systemName: "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).tips("Tillbaka till ritvyn")
                    Button { run.kastaRitning() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).tips("Kasta ritningen (Esc, går att ångra)")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.pink.opacity(0.10)))
            } else if let a = anchor {
                HStack(spacing: 4) {
                    Text("📍 " + a.text).font(.system(size: storlek - 2).monospacedDigit()).lineLimit(run.pekpunkter.count > 1 ? 4 : 1).truncationMode(.middle)
                    Button { dropAnchor() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).tips("Släpp förankringen")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.10)))
            }
            HStack(spacing: 4) {
                TextField(dikt.lyssnar ? "Lyssnar …" : run.ritning == nil ? "Skriv till Claude – ny tråd …" : "Beskriv vad ritningen ska bli …", text: $draft, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder).font(.system(size: storlek)).focused($focused).onSubmit { send(anchor) }
                Button { if dikt.lyssnar { dikt.stoppa() } else { focused = true; vaxel = true; startaDiktat() } } label: {
                    Image(systemName: dikt.lyssnar ? "mic.fill" : "mic").foregroundStyle(dikt.lyssnar ? Color.red : Color.secondary)
                        .symbolEffect(.pulse, isActive: dikt.lyssnar)
                }
                .buttonStyle(.borderless)
                .tips(dikt.lyssnar ? vaxel ? "Lyssnar – tryck mellanslag (space) eller klicka för att sluta" : "Lyssnar – släpp mellanslag (space) när du är klar" : "Prata in texten – håll mellanslag (space) eller klicka")
                Button { attachment = run.pickAttachment() } label: { Image(systemName: attachment == nil ? "paperclip" : "paperclip.circle.fill") }
                    .buttonStyle(.borderless).tips(attachment?.lastPathComponent ?? "Bifoga foto eller fil")
                Button { send(anchor) } label: { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && attachment == nil && run.ritning == nil)
                    .tips("Skicka (↩), ny rad med ⇧↩ – håll mellanslag för att prata in texten")
            }
            if let a = attachment { Text("Bifogas: \(a.lastPathComponent)").font(.caption2).foregroundStyle(.secondary) }
            if let f = dikt.fel { Text(f).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .onChange(of: run.skrivFokus) { _, _ in DispatchQueue.main.async { focused = true } }
        .onAppear { vaktaMellanslag(); if run.mikHall && !dikt.lyssnar { startaDiktat() } }
        .onChange(of: run.mikHall) { _, h in if h { if !dikt.lyssnar { vaxel = false; startaDiktat() } } else if dikt.lyssnar { dikt.stoppa() } }
        .onChange(of: dikt.lyssnar) { _, l in if !l { vaxel = false; run.mikHall = false } }
        .onDisappear {
            if let m = mellanslagsVakt { NSEvent.removeMonitor(m) }
            mellanslagsVakt = nil
            dikt.stoppa()
        }
    }

    /// Börja lyssna; den tolkade texten läggs efter det som redan står i fältet.
    private func startaDiktat() {
        let bas = draft
        let mellan = bas.isEmpty || bas.hasSuffix(" ") || bas.hasSuffix("\n") ? "" : " "
        dikt.starta { t in draft = bas + mellan + t }
    }

    /// Mellanslag i skrivfältet: ett tryck skriver ett mellanslag som vanligt; hålls det kvar (0,35 s) tas mellanslaget
    /// bort och mikrofonen lyssnar tills det släpps. Den tolkade texten läggs efter det som redan står i fältet.
    private func vaktaMellanslag() {
        guard mellanslagsVakt == nil else { return }
        mellanslagsVakt = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.keyCode == 49 else {
                if e.type == .keyDown, let h = haller { h.cancel(); haller = nil }   // skriver vidare: det var ett vanligt mellanslag
                return e
            }
            if vaxel {                                                             // på/av-läge: ett tryck i fältet stänger
                guard focused else { return e }                                    // utanför fältet sköter Rita det
                if e.type == .keyUp { dikt.stoppa() }
                return nil
            }
            if e.type == .keyUp {
                if let h = haller { h.cancel(); haller = nil; return e }
                if dikt.lyssnar { dikt.stoppa(); return nil }
                return e
            }
            if dikt.lyssnar || haller != nil { return nil }                       // upprepningar medan det hålls
            guard focused, !e.isARepeat,
                  e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return e }
            let jobb = DispatchWorkItem {
                haller = nil
                if draft.hasSuffix(" ") { draft.removeLast() }
                startaDiktat()
            }
            haller = jobb
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: jobb)
            return e
        }
    }

    private func dropAnchor() {
        if run.pick != nil { run.pick = nil } else { ignored = run.traff }
    }

    private func send(_ anchor: (point: Runner.PickPoint, kant: Int?, text: String)?) {
        let hadDrawing = run.ritning != nil
        run.chatSend(thread: nil, text: draft, attachment: attachment, anchor: hadDrawing ? nil : anchor)
        if hadDrawing { draft = ""; attachment = nil; return }
        if run.pick != nil { run.pick = nil } else if anchor != nil { ignored = run.traff }
        draft = ""; attachment = nil
    }
}
