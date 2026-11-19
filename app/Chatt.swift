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
            var derived = ChatStatus.klar
            if !lastEntry.fromClaude, let s = lastEntry.svar { derived = isRead(s) ? .klar : (isReceived(s) ? .arbetar : .vantar) }
            let explicit = ChatStatus.parse(claude?.tradar?[key]?.status)
            var status: ChatStatus
            if closedByUser { status = .klar }
            else if derived != .klar, explicit != .arbetar { status = derived }
            else if let e = explicit { status = e }
            else if isQ { status = q?.besvarad == true ? .klar : (entries.contains { !$0.fromClaude } ? .arbetar : .fraga) }   // besvarad av dig men inte avbockad av Claude än
            else { status = derived }
            var title = claude?.tradar?[key]?.titel ?? ""
            if title.isEmpty { title = q?.text ?? first?.svar ?? "" }
            if title.isEmpty { title = first?.fraga ?? "Tråd" }
            title = String(title.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces)
            if title.count > 48 { title = String(title.prefix(46)) + "…" }
            out.append(ChatThread(id: key, isQuestion: isQ, title: title, status: status, entries: entries, plats: plats, kant: kant,
                                  markering: !(q?.markering ?? []).isEmpty, closedByUser: closedByUser,
                                  lastTid: rest.last?.tid ?? ""))
        }
        out.sort { $0.lastTid > $1.lastTid }
        return (out, pending, log)
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
            if th.isQuestion {
                send(questionID: th.id, question: th.title, text: t, attachment: attachment)
                if closedQuestions.contains(th.id) { reopenQuestion(th.id) }
            } else {
                send(questionID: "meddelande", question: th.title, text: t, attachment: attachment, trad: th.id)
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

private struct HojdNyckel: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ChattPanel: View {
    @ObservedObject var run: Runner
    @State private var closedLocal: Set<String> = []
    @State private var showDone: Bool
    @State private var showLog = false
    @State private var activeHeight: CGFloat = 0

    init(run: Runner, avslutadeOppna: Bool = false) {
        self.run = run
        _showDone = State(initialValue: avslutadeOppna)
    }

    var body: some View {
        let data = run.chatThreads(closedLocal: closedLocal)
        let active = data.threads.filter { $0.status.aktiv }
        let done = data.threads.filter { !$0.status.aktiv }
        VStack(alignment: .leading, spacing: 8) {
            statusLine
            if !active.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(active) { th in
                            ChattTrad(run: run, thread: th, finished: false, onClose: { close(th) }, onReopen: {})
                                .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .bottom).combined(with: .opacity)))
                        }
                    }
                    .background(GeometryReader { Color.clear.preference(key: HojdNyckel.self, value: $0.size.height) })
                }
                .frame(height: min(max(activeHeight, 40), 300))
                .onPreferenceChange(HojdNyckel.self) { activeHeight = $0 }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if data.threads.isEmpty && data.loose.isEmpty && data.log.isEmpty { emptyState }
                    ForEach(data.loose) { r in ClaudeBubble(text: r.text) }
                    if !done.isEmpty { finishedGroup(done) }
                    if !data.log.isEmpty { logGroup(data.log) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ChattSkrivfalt(run: run)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .animation(.easeInOut(duration: 0.3), value: data.threads.map { $0.id + ($0.status.aktiv ? "a" : "k") })
        .onAppear { closedLocal = run.loadClosedThreads() }
        .onChange(of: run.output) { _, _ in closedLocal = run.loadClosedThreads() }
        .onChange(of: run.cadStamp) { _, _ in closedLocal = run.loadClosedThreads() }
    }

    private func close(_ th: ChatThread) {
        withAnimation(.easeInOut(duration: 0.3)) {
            if th.isQuestion { run.closeQuestion(th.id, th.title); run.reloadCad() }
            else { run.setThreadClosed(th.id, true); closedLocal = run.loadClosedThreads() }
        }
    }

    // Claudes övergripande status, tunn rad
    @ViewBuilder private var statusLine: some View {
        if run.claude == nil {
            Button { run.copyClaudeText() } label: { Label("Kopiera uppdrag till Claude", systemImage: "doc.on.clipboard") }
                .tips("Klistra in i chatten med Claude (Claude Code). Claude läser då AGENT.md och svarar här i appen.")
        } else if let st = run.claude?.status {
            HStack(spacing: 6) {
                if st == "arbetar" { ProgressView().controlSize(.mini) }
                else { Image(systemName: st == "klar" ? "checkmark.circle.fill" : "hourglass").foregroundStyle(st == "klar" ? .green : .orange).font(.caption) }
                Text(run.claude?.status_text ?? st.capitalized).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.purple.opacity(0.08)))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Prata med Claude", systemImage: "bubble.left.and.bubble.right").font(.callout.bold())
            Text("Skriv nedan vad du vill ändra eller bygga. Varje meddelande blir en egen tråd som Claude svarar i.")
            Text("Peka eller markera något i 3D-vyn först, så följer platsen med och Claude vet exakt vad du menar.")
            Text("Flera trådar kan pågå samtidigt. Aktiva ligger överst; klara fälls ihop här.")
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    private func finishedGroup(_ done: [ChatThread]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showDone.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showDone ? 90 : 0)).font(.caption2.bold())
                    Text("Avslutade (\(done.count))").font(.subheadline.bold())
                    Spacer()
                }.foregroundStyle(.green).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showDone {
                ForEach(done) { th in
                    ChattTrad(run: run, thread: th, finished: true, onClose: {},
                              onReopen: { run.setThreadClosed(th.id, false); if th.isQuestion { run.reopenQuestion(th.id) }; closedLocal = run.loadClosedThreads() })
                        .transition(.opacity)
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
                    Text("Ändrade mått (\(log.count))").font(.caption.bold())
                    Spacer()
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showLog {
                ForEach(log.reversed()) { a in
                    Text("Ändrat: " + a.svar.replacingOccurrences(of: " (ändrat i appen)", with: ""))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    @State private var expanded = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var color: Color { thread.isQuestion && thread.status == .fraga ? .orange : thread.status.color }
    private var selected: Bool { thread.isQuestion && run.focusQuestion == thread.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if finished && !expanded {
                EmptyView()
            } else {
                let shown = shownEntries
                if !expanded && thread.entries.count > shown.count {
                    Text("… \(thread.entries.count - shown.count) tidigare").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(shown) { e in ChattBubbla(run: run, entry: e, full: expanded) }
                replyField
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(finished ? Color.green.opacity(0.05) : color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.red : (finished ? Color.clear : color.opacity(0.35)), lineWidth: selected ? 1.5 : 1))
    }

    /// Hopfälld: de två senaste meddelandena (frågetexten följer alltid med); utfälld: alla.
    private var shownEntries: [ChatEntry] {
        if expanded { return thread.entries }
        var shown = Array(thread.entries.suffix(2))
        if thread.isQuestion, let q = thread.entries.first, shown.first?.id != q.id { shown = [q] + shown.suffix(1) }
        return shown
    }

    private var header: some View {
        HStack(spacing: 5) {
            if finished {
                Image(systemName: thread.closedByUser ? "xmark.circle.fill" : "checkmark").foregroundStyle(thread.closedByUser ? Color.secondary : Color.green).font(.caption.bold())
                Text(thread.title).font(.caption.bold()).lineLimit(1)
                Text("· \(thread.count) \(thread.count == 1 ? "meddelande" : "meddelanden")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                if thread.status == .arbetar { ProgressView().controlSize(.mini) }
                else { Image(systemName: thread.status.icon).foregroundStyle(color).font(.caption) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.title).font(.callout.bold()).lineLimit(expanded ? 3 : 1)
                    Text(thread.status.text).font(.caption2).foregroundStyle(color)
                }
            }
            Spacer(minLength: 0)
            if thread.canFocus { Image(systemName: "mappin.and.ellipse").font(.caption2).foregroundStyle(.red.opacity(0.7)) }
            if finished && expanded {
                Button("Öppna igen") { onReopen(); expanded = true }.buttonStyle(.link).font(.caption)
            }
            if !finished {
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                    .tips("Avsluta tråden")
            }
            Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0)).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            run.chatFocus(thread)
        }
        .tips(thread.canFocus ? "Klicka för att visa platsen i 3D-vyn och fälla ut tråden" : "Fäll ut tråden")
    }

    private var replyField: some View {
        HStack(spacing: 4) {
            TextField(thread.isQuestion ? "Ditt svar …" : "Svara …", text: $draft, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.roundedBorder).font(.caption).focused($focused).onSubmit(send)
            Button(action: send) { Image(systemName: "paperplane.fill") }.buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty).tips("Skicka (↩)")
        }
        .onChange(of: focused) { _, f in if f && thread.isQuestion { run.focusQuestion = thread.id } }
    }

    private func send() {
        run.chatSend(thread: thread, text: draft)
        draft = ""
    }
}

struct ChattBubbla: View {
    @ObservedObject var run: Runner
    let entry: ChatEntry
    let full: Bool

    var body: some View {
        if entry.fromClaude {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: entry.isQuestion ? "questionmark.circle.fill" : "sparkles")
                    .foregroundStyle(entry.isQuestion ? Color.orange : Color.purple).font(.caption)
                Text(entry.text).font(.caption).lineLimit(full ? nil : 4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill((entry.isQuestion ? Color.orange : Color.purple).opacity(0.12)))
            .padding(.trailing, 14)
        } else if let a = entry.svar {
            VStack(alignment: .trailing, spacing: 2) {
                if !a.svar.isEmpty { Text(a.svar).font(.caption).lineLimit(full ? nil : 4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if let rel = a.ritning {
                    let shown = run.arVisad(rel)
                    Button { run.visaRitning(rel) } label: {
                        if let b = a.bilaga, let f = run.cadFolder, let img = NSImage(contentsOf: f.appendingPathComponent(b)) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(shown ? Color.pink : Color.secondary.opacity(0.3), lineWidth: 1.5))
                        } else { Label("Ritning", systemImage: "pencil.tip").font(.caption2) }
                    }.buttonStyle(.plain).tips("Tillbaka till vyn ritningen gjordes i, med strecken")
                    HStack(spacing: 8) {
                        Button { run.visaRitning(rel) } label: { Label("Visa i vyn", systemImage: "pencil.tip") }
                        if shown { Button { run.visadRitning = nil } label: { Label("Dölj", systemImage: "eye.slash") } }
                    }.buttonStyle(.plain).font(.caption2).foregroundStyle(.pink)
                } else if let b = a.bilaga { Label(b, systemImage: "paperclip").font(.caption2) }
                if a.plats != nil || a.yta != nil || a.kant != nil {
                    Label(Self.anchorText(a), systemImage: "mappin").font(.caption2).foregroundStyle(.orange)
                }
                Text(run.isRead(a) ? "✓✓ inarbetat" : (run.isReceived(a) ? "✓ mottaget" : "skickat"))
                    .font(.caption2).foregroundStyle(run.isRead(a) ? Color.green : (run.isReceived(a) ? Color.blue : Color.secondary))
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .trailing)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14)))
            .padding(.leading, 14)
        }
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
                    Text("📍 " + a.text).font(.caption.monospacedDigit()).lineLimit(run.pekpunkter.count > 1 ? 4 : 1).truncationMode(.middle)
                    Button { dropAnchor() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).tips("Släpp förankringen")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.10)))
            }
            HStack(spacing: 4) {
                TextField(run.ritning == nil ? "Skriv till Claude – ny tråd …" : "Beskriv vad ritningen ska bli …", text: $draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder).focused($focused).onSubmit { send(anchor) }
                Button { attachment = run.pickAttachment() } label: { Image(systemName: attachment == nil ? "paperclip" : "paperclip.circle.fill") }
                    .buttonStyle(.borderless).tips(attachment?.lastPathComponent ?? "Bifoga foto eller fil")
                Button { send(anchor) } label: { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && attachment == nil && run.ritning == nil)
                    .tips("Skicka (↩), ny rad med ⇧↩")
            }
            if let a = attachment { Text("Bifogas: \(a.lastPathComponent)").font(.caption2).foregroundStyle(.secondary) }
        }
        .onChange(of: run.skrivFokus) { _, _ in DispatchQueue.main.async { focused = true } }
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
