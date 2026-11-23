// Kontrakt mellan arbetsytan (UI), 3D-vyn och chatten: verktyg, mätning, info, tillfällig flytt, färger, objekt.
// Inget här ändrar modellen eller skripten – allt är visningstillstånd (utom kantbehandling, som går via skript/agent).
import AppKit
import SwiftUI

/// Aktivt verktyg i 3D-vyn.
enum Verktyg: String, CaseIterable, Identifiable {
    case valj       // klick = välj objekt/yta/kant och visa mått i inspektören; klick i tomrummet avmarkerar
    case mat        // klick 1 och 2 = mät mellan punkter/ytor/kanter (fäster mot hörn, kantmitt, ytcentrum)
    case rita       // rita streck i vyn som på en utskrift (Rita.swift); start fäster mot kanter/hörn, ⇧ = rak linje
    case flytta     // dra i ett objekt = flytta det tillfälligt (bara visning); dubbelklick = tillbaka
    case peka       // klick = lägg en nål och börja en ny chattråd om just den platsen
    var id: String { rawValue }
    var namn: String { ["valj": "Välj", "mat": "Mät", "rita": "Rita", "flytta": "Flytta", "peka": "Peka"][rawValue]! }
    var ikon: String { ["valj": "cursorarrow", "mat": "ruler", "rita": "pencil.tip", "flytta": "arrow.up.and.down.and.arrow.left.and.right", "peka": "mappin.and.ellipse"][rawValue]! }
    var tangent: KeyEquivalent { ["valj": "v", "mat": "m", "rita": "d", "flytta": "g", "peka": "p"][rawValue]! }
    var hjalp: String {
        switch self {
        case .valj: return "Klicka på en del, yta eller kant för att se dess mått (V)"
        case .mat: return "Klicka två punkter, ytor eller kanter för att mäta avståndet (M)"
        case .rita: return "Rita i vyn som på en utskrift och beskriv för Claude – starten fäster mot kanter. ⇧ = rak linje, ⌥ + dra = vrid, håll mellanslag = prata (D)"
        case .flytta: return "Dra en del för att flytta den tillfälligt – modellen ändras inte (G). Håll ⇧ för att dra rakt längs X, Y eller Z; i sprängvyn blir flytten en del av isärdragningen"
        case .peka: return "Klicka där något ska ändras (fler klick = B, C …) – skriv direkt i chattrutan, eller håll mellanslag och prata. Esc rensar punkterna (P)"
        }
    }
}

/// Det som är markerat/träffat i 3D-vyn.
struct Traff: Equatable {
    enum Slag: Equatable { case objekt, yta, kant, punkt }
    var slag: Slag
    var del: String?                 // del-id i delar.json ("skanning" för skanningen)
    var objekt: String?              // under-objekt-id ("<del>#<n>") när delen består av flera sammanhängande kroppar
    var yta: Int? = nil              // ytans id i <del>-ytor.json
    var kant: Int? = nil             // kantens id i <del>-ytor.json ("kanter")
    var pos: SIMD3<Double>           // träffpunkt i modellens ram (mm)
    var normal: SIMD3<Double>? = nil
    var foto: String? = nil          // bildruta om fotoläget var på
    var fotoPx: [Double]? = nil
}

/// Mått på det som valts (inspektören).
struct Info: Equatable {
    var rubrik: String               // t.ex. "Lock · yta 12 (plan)"
    var rader: [(String, String)]    // ("Längd × bredd × höjd", "80,0 × 50,0 × 30,0 mm"), ("Ø", "5,30 mm"), ("Tjocklek", "1,60 mm") …
    static func == (a: Info, b: Info) -> Bool { a.rubrik == b.rubrik && a.rader.map { $0.0 + $0.1 } == b.rader.map { $0.0 + $0.1 } }
}

/// Resultat av mätverktyget.
struct Matning: Equatable {
    var a: Traff
    var b: Traff?
    var avstand: Double?             // kortaste avstånd (mm) – mellan parallella plan: vinkelrätt avstånd
    var dx: Double?, dy: Double?, dz: Double?
    var vinkel: Double?              // grader mellan ytnormaler/kanter om relevant
    var text: String                 // färdig sammanfattning, t.ex. "43,70 mm (Δx 0,0 · Δy 43,7 · Δz 0,0)"
}

/// Färgscheman för delarna. Varje projekt får ett eget schema (utifrån sökvägen) om inget är valt.
enum Fargschema: String, CaseIterable, Identifiable {
    case hav, solnedgang, skog, pastell, kontrast, egna, gra
    var id: String { rawValue }
    var namn: String { ["hav": "Hav", "solnedgang": "Solnedgång", "skog": "Skog", "pastell": "Pastell", "kontrast": "Kontrast", "egna": "Delarnas egna färger", "gra": "Allt grått"][rawValue]! }
    var farger: [String] {
        switch self {
        case .hav: return ["#2E7DD7", "#19A7A0", "#5B6CF0", "#2BB673", "#7E57C2", "#00A3E0", "#3D5A80", "#48C9B0"]
        case .solnedgang: return ["#E8743B", "#D9534F", "#F2B134", "#C2185B", "#8E44AD", "#FF8A65", "#B5651D", "#F06292"]
        case .skog: return ["#3E8E41", "#8BAA36", "#2F6B4F", "#C9A227", "#6D8B74", "#A0522D", "#4CAF50", "#7C9A92"]
        case .pastell: return ["#7FB3D5", "#F5B7B1", "#A9DFBF", "#F9E79F", "#D2B4DE", "#F8C471", "#AED6F1", "#A3E4D7"]
        case .kontrast: return ["#0072B2", "#E69F00", "#009E73", "#D55E00", "#CC79A7", "#56B4E9", "#F0E442", "#000000"]
        case .gra: return ["#A7ADB4"]
        case .egna: return []
        }
    }
    /// Standardschema för ett projekt: olika projekt får olika scheman.
    static func standard(for path: String) -> Fargschema {
        let all: [Fargschema] = [.hav, .solnedgang, .skog, .pastell, .kontrast]
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return all[Int(h % UInt64(all.count))]
    }
}

/// Ett under-objekt (sammanhängande kropp) i en del – t.ex. en av fem celler i "Celler 5 × 21700".
struct UnderObjekt: Identifiable, Equatable {
    let id: String          // "<del>#<n>"
    let del: String
    let namn: String        // "Kropp 1" eller namn från ytor.json ("kroppar")
    let ytor: [Int]         // ytornas id
    var grupp: [String] = []  // komponentträdet ovanför kroppen (importerad sammanställning)
    /// Nyckel i run.utfallda för gruppen sti (i delen del). Namnen kan innehålla "/", så avgränsaren är \u{1F}.
    static func gruppNyckel(_ del: String, _ sti: [String]) -> String { del + "\u{1F}" + sti.joined(separator: "\u{1F}") }
}

/// En begärd kantbehandling (cad/kantbehandling.json) – utförs av projekt.py vid nästa bygge, eller av Claude.
struct Kantbehandling: Codable, Equatable {
    var del: String
    var kant: Int?                  // id i <del>-ytor.json
    var mitt: [Double]              // kantens mittpunkt (mm), för att hitta kanten igen efter ombyggnad
    var typ: String                 // "fillet" | "fas"
    var matt: Double                // radie resp. fasens bredd (mm)
    var tid: String
}

/// En sparad vy (cad/vyer.json + cad/vyer/<id>.png): hela viewporten som den var – kamera, vilka objekt som syns,
/// flytt/explode, opacitet, färgschema och ev. snitt.
struct SparadVy: Codable, Identifiable, Equatable {
    var id: String                  // filnamnssäkert, t.ex. "vy-20261120-101530"
    var namn: String
    var tid: String
    var kamera: [Double]            // 4×4 kolumnvis
    var mal: [Double]               // orbit-målet
    var dolda: [String]
    var flyttade: [String: [Double]]
    var explode: Double
    var opacitet: [String: Double]
    var fargschema: String
    var snitt: SparadSnitt?
    var foto: String? = nil         // bildrutan om vyn sparades i fotoläget
    var sprangflyttade: [String: [Double]]? = nil   // egna flyttar i sprängvyn (skalas med explode)
    var spelar: Bool? = nil         // sprängvyn spelades upp (ihop ↔ isär) när vyn sparades
}

/// En sparad snittvy (cad/snittvyer.json): planet och kamerans läge, så att samma snitt kan visas igen.
struct SparadSnitt: Codable, Identifiable, Equatable {
    var id: String                  // tid när den sparades
    var namn: String                // t.ex. "Snitt Y = −2,2" (kan döpas om)
    var axel: Int                   // 0 = X, 1 = Y, 2 = Z
    var lage: Double                // planets läge längs axeln (mm)
    var tecken: Double              // +1/−1: vilken sida som klipps bort (normalen pekar mot den bortklippta sidan)
    var kamera: [Double]?           // kamerans 4×4-transform (kolumnvis, 16 tal), nil = behåll nuvarande vy
    var mal: [Double]?              // orbit-målet (x, y, z)
}
