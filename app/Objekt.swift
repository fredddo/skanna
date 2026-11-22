// Objektträdets eget tillstånd per projekt (cad/objekt.json): vilka lager som är släckta, ordningen och användarens namn.
// Sparas när det ändras och läses när projektet öppnas – också efter att Claude byggt om något.
import Foundation

struct ObjektVisning: Codable {
    var dolda: [String] = []
    var ordning: [String] = []
    var namn: [String: String] = [:]
    var borttagna: [String]? = nil        // raderade delar (Radera i objektträdet): visas inte, skrivs inte ut
}

extension Runner {
    private var objektURL: URL? { cadFolder?.appendingPathComponent("objekt.json") }

    func loadObjektVisning() -> ObjektVisning {
        objektURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ObjektVisning.self, from: $0) } ?? ObjektVisning()
    }

    func saveObjektVisning() {
        guard let u = objektURL, FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path) else { return }
        let v = ObjektVisning(dolda: hidden.sorted(), ordning: objektOrdning, namn: egnaNamn,
                              borttagna: borttagna.isEmpty ? nil : borttagna.sorted())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(v), d != (try? Data(contentsOf: u)) { try? d.write(to: u, options: .atomic) }
    }

    /// Delarna med användarens namn och i användarens ordning (nya delar sist, i Claudes ordning).
    func applyObjekt(_ list: [PartInfo]) -> [PartInfo] {
        let rank = Dictionary(objektOrdning.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.filter { !borttagna.contains($0.id) }.enumerated().map { (i, p) -> (Int, PartInfo) in
            var q = p
            if let n = egnaNamn[p.id], !n.isEmpty { q.namn = n }
            return (rank[p.id] ?? (100_000 + i), q)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func renamePart(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = parts.first { $0.id == id }?.namn ?? id
        guard n != old else { return }
        if n.isEmpty { egnaNamn[id] = nil } else { egnaNamn[id] = n }
        historikNotera("Bytte namn: \(old) → \(n.isEmpty ? "Claudes namn" : n)")
        saveObjektVisning()
        reloadCad()
        send(questionID: "parameter", question: "Namn", text: "Bytte namn på delen \(id): \(old) → \(n.isEmpty ? "(Claudes namn)" : n) (i appen)", attachment: nil)
        reloadCad()
    }

    /// Radera en del: den försvinner direkt (cad/objekt.json "borttagna"), och gör dess del-skript bara den delen läggs
    /// skriptet undan, så att den inte kommer tillbaka vid nästa bygge. Går att ångra (⌘Z); Claude får veta.
    func raderaDel(_ id: String) {
        guard let p = parts.first(where: { $0.id == id }) else { return }
        noteChange("Radera \(p.namn)", immediate: true)
        let barn = parts.filter { $0.foralder == id }.map(\.id)
        var skriptBort: String?
        if let s = p.skript, let dir = scriptFolder,
           !parts.contains(where: { $0.skript == s && $0.id != id && !barn.contains($0.id) }),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent(s).path) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(s))   // ögonblicksbilden har innehållet (⌘Z)
            skriptBort = s
        }
        borttagna.formUnion([id] + barn)
        if selectedPart.map({ $0 == id || barn.contains($0) }) == true { selectedPart = nil }
        saveObjektVisning()
        parts = applyObjekt(parts)
        settleUndo()
        historikNotera("Raderade \(p.namn)")
        toast = "\(p.namn) raderad – ⌘Z ångrar"
        let skriptText = skriptBort.map { " Del-skriptet cad/skript/\($0) är borttaget (gjorde bara den delen)." }
            ?? " Delens skript ligger kvar (det gör fler delar, eller är okänt) – delen är bara dold via cad/objekt.json \"borttagna\"; ta bort den ur skriptet om användaren vill."
        send(questionID: "parameter", question: "Radera", text: "Användaren raderade delen \(p.namn) (\(id))\(barn.isEmpty ? "" : " med \(barn.joined(separator: ", "))") i appen.\(skriptText)", attachment: nil)
    }

    /// Dra-och-släpp i objektträdet: lägg `id` där `target` ligger (före om man drar uppåt, efter om man drar nedåt).
    func movePart(_ id: String, to target: String) {
        guard id != target else { return }
        var order = parts.map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        let t = order.firstIndex(of: target)!
        order.insert(id, at: from < to ? t + 1 : t)
        objektOrdning = order
        historikNotera("Ändrad ordning i objektlistan")
        saveObjektVisning()
        parts = applyObjekt(parts)
    }
}
