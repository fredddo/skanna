// Datatyper för filprotokollet mellan appen, CLI:t och Claude (se AGENT.md).
import AppKit
import Foundation

/// Var Skanna Beta har sina skript, mallar och sin Python-miljö (Info.plist-nyckeln SkannaHem, annars standard).
enum Hem {
    static var url: URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "SkannaHem") as? String, !s.isEmpty { return URL(fileURLWithPath: s) }
        if let s = ProcessInfo.processInfo.environment["SKANNA_HEM"] { return URL(fileURLWithPath: s) }
        return URL(fileURLWithPath: NSHomeDirectory() + "/git/worldforge/local/skanna-v2")
    }
    static var byggSkript: URL { url.appendingPathComponent("bygg_projekt.sh") }
    static var mallar: URL { url.appendingPathComponent("mallar", isDirectory: true) }
    static var agentProtokoll: URL { url.appendingPathComponent("AGENT.md") }
    /// Nya projekt (modellprojekt och guidade skanningar) hamnar här.
    static var standardProjektRot: URL {
        let name = (Bundle.main.object(forInfoDictionaryKey: "SkannaProjektmapp") as? String) ?? "Skanna"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    }
    static var projektRot: URL {
        if let s = ProcessInfo.processInfo.environment["SKANNA_PROJEKTROT"] { return URL(fileURLWithPath: s, isDirectory: true) }
        if let s = UserDefaults.standard.string(forKey: "projektRot"), !s.isEmpty { return URL(fileURLWithPath: s, isDirectory: true) }
        let name = (Bundle.main.object(forInfoDictionaryKey: "SkannaProjektmapp") as? String) ?? "Skanna"
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    }
    static var appNamn: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Skanna" }
}

/// <projekt>/projekt.json – finns i alla projekt som appen skapar (äldre video-skanningar saknar den).
struct ProjektFil: Codable {
    var namn: String
    var typ: String                 // "modell" | "skanning"
    var skapad: String
    var kalla: String? = nil        // "video" | "guidad" | "foton" | "mall"
    var beskrivning: String? = nil
    var plan: Fotoplan? = nil       // guidad skanning: hur bilderna togs
}

/// Innehållet i <projekt>/cad/geometri.json.
struct CadInfo: Decodable {
    struct Param: Decodable, Identifiable {
        var id: String { namn }
        let namn: String
        let varde: Double?
        let text: String?
        let enhet: String?
        let kalla: String?        // "användare" | "uppmätt" | "skanning" | "standard" | "antagande" | "mall"
        let osakerhet: Double?
        let grupp: String?
    }
    struct Fraga: Decodable, Identifiable {
        let fid: String?
        let text: String
        let besvarad: Bool?
        let markering: [Markering]?
        var id: String { fid ?? text }
        enum CodingKeys: String, CodingKey { case fid = "id", text, besvarad, markering }
    }
    /// Vad frågan gäller, i modellens ram (mm): "matt" (fran→till), "punkt" (pos), "omrade" (min/max).
    struct Markering: Decodable, Hashable {
        let typ: String
        let fran: [Double]?
        let till: [Double]?
        let pos: [Double]?
        let min: [Double]?
        let max: [Double]?
        let text: String?
    }
    let status: String?           // "utkast" | "väntar på svar" | "klar"
    let beskrivning: String?
    let parametrar: [Param]?
    let fragor: [Fraga]?
    let avvikelse: String?
    let last_svar: String?
}

/// Claude → appen: <projekt>/cad/claude.json
struct ClaudeInfo: Decodable {
    struct Meddelande: Decodable, Identifiable, Hashable { var id: String { tid }; let tid: String; let text: String; let svar_pa: String? }
    let status: String?          // "arbetar" | "klar" | "väntar"
    let status_text: String?
    let mottaget: String?
    let meddelanden: [Meddelande]?
    /// Trådarnas läge, nyckel = trådens rot-tid: {"status": "arbetar" | "fraga" | "klar", "titel": "…"}
    let tradar: [String: TradStatus]?
    struct TradStatus: Decodable, Hashable { let status: String; let titel: String? }
}

/// Användaren → Claude: <projekt>/cad/svar.json
struct Svar: Codable, Identifiable, Hashable {
    var id: String { tid + fraga_id }
    let fraga_id: String
    let fraga: String
    let svar: String
    let bilaga: String?
    let tid: String
    var plats: [Double]? = nil
    var pa: String? = nil
    var yta: Int? = nil
    var ytatyp: String? = nil
    var del: String? = nil
    var foto: String? = nil
    var foto_px: [Double]? = nil
    var trad: String? = nil      // svar i en befintlig tråd: trådens rot (tid för första meddelandet); nil = ny tråd
    var kant: Int? = nil         // vald CAD-kant (id i <del>-ytor.json "kanter")
    var ritning: String? = nil   // ritning i 3D-vyn: "ritningar/<id>.json" (bilden ligger i bilaga)
}
struct SvarFil: Codable { var svar: [Svar] }

/// <projekt>/cad/foton.json: bildrutor med kamerans läge i modellens ram (mm) och intrinsics.
struct FotoInfo: Decodable, Hashable {
    let bild: String
    let kamera_till_modell: [[Double]]
    let K: [[Double]]?
    let bredd: Double
    let hojd: Double
    let vy: String?
    let vinkel: Double?
    let palitlig: Bool?
}
struct FotonFil: Decodable { let foton: [FotoInfo] }

/// <projekt>/cad/delar.json
struct PartInfo: Decodable, Identifiable, Hashable {
    let id: String
    var namn: String          // användarens namn (cad/objekt.json) om det finns, annars Claudes
    let fil: String
    let roll: String        // "referens" | "design"
    let farg: String
    let export: String?
    let beskrivning: String?
    var bambu: BambuDict? = nil   // del-skriptets Bambu-inställningar (prj.del_(…, bambu={…})); cad/utskrift.json går före
}
struct PartsFile: Decodable { let delar: [PartInfo] }

/// En mall i <SkannaHem>/mallar/*.py (headerrader "# mall:", "# beskrivning:", "# id:").
struct Mall: Identifiable, Hashable {
    let id: String
    let namn: String
    let beskrivning: String
    let fil: URL

    static func alla() -> [Mall] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Hem.mallar, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "py" }
        return files.compactMap { u in
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            var meta: [String: String] = [:]
            for line in text.split(separator: "\n").prefix(12) where line.hasPrefix("# ") {
                let s = line.dropFirst(2)
                if let i = s.firstIndex(of: ":") {
                    meta[String(s[..<i]).trimmingCharacters(in: .whitespaces)] = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            guard let namn = meta["mall"] else { return nil }
            return Mall(id: meta["id"] ?? u.deletingPathExtension().lastPathComponent, namn: namn, beskrivning: meta["beskrivning"] ?? "", fil: u)
        }.sorted { $0.namn < $1.namn }
    }
}

/// En rad i projektlistan.
struct ProjektPost: Identifiable, Hashable {
    enum Typ { case skanning, modell, bilder, tom }
    let id: URL
    let name: String
    let date: Date
    let model: URL?
    let typ: Typ
    let bildantal: Int
}

/// En del i 3D-vyn: CAD-ytor (json) eller STL, med färg.
struct PartSpec: Equatable { let id: String; let url: URL; let color: NSColor; let stamp: Date }

struct ViewRequest: Equatable { let name: String; let id = UUID() }

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(calibratedRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

let bildandelser: Set<String> = ["heic", "jpg", "jpeg", "png", "tif", "tiff", "dng"]

func isoNu() -> String {
    let iso = ISO8601DateFormatter()
    iso.timeZone = .current
    return iso.string(from: Date())
}
