// Objektträdets eget tillstånd per projekt (cad/objekt.json): vilka lager som är släckta, ordningen och användarens namn.
// Sparas när det ändras och läses när projektet öppnas – också efter att Claude byggt om något.
import Foundation

struct ObjektVisning: Codable {
    var dolda: [String] = []
    var ordning: [String] = []
    var namn: [String: String] = [:]
}

extension Runner {
    private var objektURL: URL? { cadFolder?.appendingPathComponent("objekt.json") }

    func loadObjektVisning() -> ObjektVisning {
        objektURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(ObjektVisning.self, from: $0) } ?? ObjektVisning()
    }

    func saveObjektVisning() {
        guard let u = objektURL, FileManager.default.fileExists(atPath: u.deletingLastPathComponent().path) else { return }
        let v = ObjektVisning(dolda: hidden.sorted(), ordning: objektOrdning, namn: egnaNamn)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(v), d != (try? Data(contentsOf: u)) { try? d.write(to: u, options: .atomic) }
    }

    /// Delarna med användarens namn och i användarens ordning (nya delar sist, i Claudes ordning).
    func applyObjekt(_ list: [PartInfo]) -> [PartInfo] {
        let rank = Dictionary(objektOrdning.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.enumerated().map { (i, p) -> (Int, PartInfo) in
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
        saveObjektVisning()
        reloadCad()
        send(questionID: "parameter", question: "Namn", text: "Bytte namn på delen \(id): \(old) → \(n.isEmpty ? "(Claudes namn)" : n) (i appen)", attachment: nil)
        reloadCad()
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
        saveObjektVisning()
        parts = applyObjekt(parts)
    }
}
