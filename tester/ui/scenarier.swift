// UI-scenarierna. Varje scenario öppnar en färsk kopia av testprojektet (tester/fixtur/Testlåda: låda + lock +
// insats under lådan + fötter med fyra kroppar) och kontrollerar resultatet med kolla(…). Lägg till ett scenario per
// funktion som ska fortsätta fungera.
import AppKit
import SceneKit
import SwiftUI

enum Scenarier {
    static var projekt = URL(fileURLWithPath: "/")
    static func laddat() -> Bool {
        guard let (_, c) = vy() else { return false }
        return run.parts.count >= 4 && c.leaves.count >= 7 && !run.rebuilding
    }
    static func oppna(_ namn: String) -> [Steg] {
        [.gor { projekt = oppnaKopia(namn) }, .tills("projektet laddat (4 delar, 7 objekt i 3D-vyn)", 20) { laddat() }, .vanta(0.5)]
    }
    static func s(_ namn: String, _ steg: [Steg]) -> Scenario { Scenario(namn: namn, steg: oppna(namn) + steg) }

    static func alla() -> [Scenario] { [
        s("Öppna projekt", [.gor {
            kolla(Set(run.parts.map(\.id)) == ["lada", "lock", "insats", "fotter"], "delarna: \(run.parts.map(\.id))")
            kolla(run.parts.first { $0.id == "insats" }?.foralder == "lada", "insats ska ha föräldern lada")
            kolla(run.parts.first { $0.id == "lada" }?.skript == "10-lada.py", "lada ska veta sitt skript")
            kolla(run.underObjekt["fotter"]?.count == 4, "fötterna ska ha 4 kroppar, har \(run.underObjekt["fotter"]?.count ?? 0)")
            kolla((run.cad?.parametrar ?? []).contains { $0.namn == "Låda: längd" }, "måttet Låda: längd saknas")
            kolla(run.plast("lada") == "PETG", "lådans plast från skriptet ska vara PETG, är \(run.plast("lada"))")
        }]),

        s("Vridning utan stopp runt det valda", [.gor { run.selectedPart = "lada" }, .vanta(0.3), .gor {
            guard let (scn, c) = vy(), let (q, _) = c.valtCentrum() else { kolla(false, "inget valt centrum"); return }
            let p0 = proj(q)
            var vinkel: Float = 0, overToppen = false
            var forra = simd_normalize(scn.pointOfView!.simdWorldPosition - q)
            for _ in 0..<314 {
                c.orbit(0, -10)
                let d = simd_normalize(scn.pointOfView!.simdWorldPosition - q)
                vinkel += acos(max(-1, min(1, simd_dot(d, forra)))); forra = d
                if simd_dot(c.upp, c.U) < 0 { overToppen = true }
            }
            kolla(vinkel * 180 / .pi > 1700, "upp/ner ska kunna snurra flera varv, snurrade \(Int(vinkel * 180 / .pi))°")
            kolla(overToppen, "vyn ska kunna gå över toppen (upp och ner)")
            kolla(avst(proj(q), p0) < 0.5, "det valda ska stå still på skärmen, flyttade \(avst(proj(q), p0)) px")
            for _ in 0..<20 { c.orbit(15, 3) }
            kolla(avst(proj(q), p0) < 0.5, "det valda ska stå still vid sidledsvridning, flyttade \(avst(proj(q), p0)) px")
            kolla(skillnad(c.cubeCam.simdOrientation, scn.pointOfView!.simdWorldOrientation) < 1e-4, "vykuben ska följa kameran")
        }]),

        s("Raka vyer är ortografiska", [
            .gor { run.request("Topp") }, .vanta(0.6), .gor {
                guard let (scn, c) = vy(), let pov = scn.pointOfView else { return }
                kolla(simd_dot(pov.simdWorldFront, -c.U) > 0.9999, "Topp ska titta rakt ner")
                kolla(pov.camera?.usesOrthographicProjection == true, "Topp ska vara ortografisk")
                kolla(run.ortoVy == "Uppifrån", "lappen vid kuben ska säga Uppifrån, säger \(run.ortoVy ?? "inget")")
            },
            .gor { run.request("+X") }, .vanta(0.6), .gor {
                guard let (scn, c) = vy(), let pov = scn.pointOfView else { return }
                kolla(simd_dot(pov.simdWorldFront, -c.E1) > 0.9999, "+X ska titta längs −X")
                kolla(abs(simd_dot(pov.simdWorldUp, c.U) - 1) < 1e-4, "sidovyn ska vara exakt vågrät")
                kolla(pov.camera?.usesOrthographicProjection == true, "sidovyn ska vara ortografisk")
            },
            .gor { run.request("Botten") }, .vanta(0.6), .gor {
                guard let (scn, c) = vy(), let pov = scn.pointOfView else { return }
                kolla(simd_dot(pov.simdWorldFront, c.U) > 0.9999, "Botten ska titta rakt upp")
            },
            .gor { vy()?.1.orbit(10, 5) }, .vanta(0.3), .gor {
                kolla(vy()?.0.pointOfView?.camera?.usesOrthographicProjection == false, "vridning ska ge perspektiv")
                kolla(run.ortoVy == nil, "lappen ska försvinna vid vridning")
            },
            .gor { vy()?.1.orbit(0, -200) }, .gor { run.request("Hela") }, .vanta(0.6), .gor {
                guard let (_, c) = vy() else { return }
                kolla(abs(simd_dot(c.upp, c.U) - 1) < 1e-4, "⌘0 ska räta upp vyn")
            },
        ]),

        s("Z zoomar in på det valda", [.gor { run.selectedPart = "lock" }, .vanta(0.3), .gor { run.request("Valt") }, .vanta(0.8), .gor {
            guard let (scn, c) = vy(), let (q, _) = c.valtCentrum() else { kolla(false, "inget valt"); return }
            let mitt = CGPoint(x: scn.bounds.midX, y: scn.bounds.midY)
            kolla(avst(proj(q), mitt) < 3, "locket ska hamna mitt i vyn, är \(avst(proj(q), mitt)) px därifrån")
        }]),

        s("Sprängvy håller ihop hopfällda delar", [
            .gor { run.explode = 1 }, .vanta(0.8), .gor {
                guard let (_, c) = vy() else { return }
                let f = c.leaves.values.filter { $0.del == "fotter" }.map { $0.node.simdPosition }
                kolla(f.count == 4 && f.allSatisfy { simd_length($0 - f[0]) < 0.01 }, "hopfällda fötter ska flyttas som en enhet")
                kolla(simd_length(f[0]) > 1, "fötterna ska flyttas isär från mitten")
                let l = c.partNodes["lada"]?.simdPosition ?? .zero, i = c.partNodes["insats"]?.simdPosition ?? .one
                kolla(simd_length(l - i) < 0.01, "insatsen ska följa lådan när lådan är hopfälld")
            },
            .gor { run.utfallda = ["fotter", "lada"] }, .vanta(0.8), .gor {
                guard let (_, c) = vy() else { return }
                let f = c.leaves.values.filter { $0.del == "fotter" }.map { $0.node.simdPosition }
                kolla(f.contains { simd_length($0 - f[0]) > 1 }, "utfällda fötter ska dras isär var för sig")
                let l = c.partNodes["lada"]?.simdPosition ?? .zero, i = c.partNodes["insats"]?.simdPosition ?? .zero
                kolla(simd_length(l - i) > 1, "utfälld låda: insatsen ska sprängas för sig")
            },
            .gor { run.hidden = ["lada"] }, .vanta(0.4), .gor {
                kolla(vy()?.1.partNodes["insats"]?.isHidden == true, "döljs lådan ska insatsen också döljas")
            },
            .gor { run.hidden = []; run.explode = 0 }, .vanta(0.8), .gor {
                kolla(vy()?.1.partNodes["lada"].map { simd_length($0.simdPosition) < 0.01 } == true, "explode 0 ska lägga ihop delarna")
            },
        ]),

        s("Radera del och ångra", [
            .gor {
                run.raderaDel("fotter")
                let skript = projekt.appendingPathComponent("cad/skript/20-fotter.py")
                kolla(!run.parts.contains { $0.id == "fotter" }, "fötterna ska försvinna ur listan")
                kolla(!finns(skript), "fötternas eget skript ska tas bort")
                let b = json(projekt.appendingPathComponent("cad/objekt.json"))["borttagna"] as? [String] ?? []
                kolla(b.contains("fotter"), "objekt.json ska ha fötterna under borttagna")
            },
            .vanta(0.3), .gor { run.undo() }, .vanta(0.5), .gor {
                kolla(finns(projekt.appendingPathComponent("cad/skript/20-fotter.py")), "ångra ska lägga tillbaka skriptet")
                kolla(run.parts.contains { $0.id == "fotter" }, "ångra ska ta tillbaka fötterna")
                kolla(run.borttagna.isEmpty, "ångra ska tömma borttagna")
            },
            .tills("ombygget efter ångra blir klart", 90) { !run.rebuilding },
            .gor {
                run.raderaDel("lock")
                kolla(finns(projekt.appendingPathComponent("cad/skript/10-lada.py")), "skript som gör fler delar ska ligga kvar")
                kolla(!run.parts.contains { $0.id == "lock" } && run.parts.contains { $0.id == "lada" }, "bara locket ska försvinna")
            },
        ]),

        s("Utskriftsinställningar sparas och går att ångra", [
            .gor {
                run.setUtskrift("lock", "wall_loops", "4")
                run.setUtskrift("lock", "filament.nozzle_temperature", "240")
                let d = (json(projekt.appendingPathComponent("cad/utskrift.json"))["delar"] as? [String: Any])?["lock"] as? [String: Any] ?? [:]
                kolla(d["wall_loops"] as? String == "4", "wall_loops ska sparas: \(d)")
                kolla((d["filament"] as? [String: String])?["nozzle_temperature"] == "240", "filament ska sparas nästlat: \(d)")
                run.loadUtskrift()
                kolla(run.utskrift["lock"]?["filament.nozzle_temperature"] == "240", "filament ska läsas tillbaka")
                kolla(run.utskriftOvriga("lock").contains { $0.0 == "filament.nozzle_temperature" }, "filament ska synas bland tilläggen")
                kolla(run.utskriftVarde("lada", "plast") == ("PETG", "skript"), "lådans plast ska komma från skriptet")
                kolla(Utskrift.mening("filament.nozzle_temperature", "240") == "munstycke 240 °C", "löptexten för temperatur")
                kolla(Utskrift.mening("reduce_crossing_wall", "1") == "undvik att korsa väggar: på", "löptexten för på/av")
            },
            .vanta(1.0), .gor { run.undo() }, .vanta(0.5), .gor {
                kolla(run.utskrift["lock"] == nil, "ångra ska ta bort lockets ändringar, är \(run.utskrift["lock"] ?? [:])")
            },
        ]),

        s("Byt namn på projekt", [
            .gor { run.bytNamnPaProjekt(projekt, till: "Omdöpt låda") },
            .tills("mappen byter namn", 10) { finns(projekt.deletingLastPathComponent().appendingPathComponent("Omdöpt låda")) },
            .vanta(0.5), .gor {
                let ny = projekt.deletingLastPathComponent().appendingPathComponent("Omdöpt låda")
                kolla(!finns(projekt), "den gamla mappen ska vara borta")
                kolla(json(ny.appendingPathComponent("projekt.json"))["namn"] as? String == "Omdöpt låda", "projekt.json ska få det nya namnet")
                kolla(run.output?.lastPathComponent == "Omdöpt låda", "det öppna projektet ska följa med, är \(run.output?.lastPathComponent ?? "-")")
            },
        ]),

        s("Historik är en flik", [.gor { UserDefaults.standard.set(0, forKey: "hogerflik"); run.visaHistorik = true }, .vanta(0.4), .gor {
            kolla(UserDefaults.standard.integer(forKey: "hogerflik") == 2, "⌘Y ska öppna historikfliken")
            kolla(!run.visaHistorik, "inget eget historikfönster ska öppnas")
        }]),

        s("Peka ger skrivfokus", [.gor {
            run.tool = .peka
            let f = run.skrivFokus
            run.pekaKlick(Runner.PickPoint(pos: [1, 2, 3], target: "lada"))
            kolla(run.skrivFokus == f + 1, "en ny punkt ska ge chattrutan fokus")
            kolla(run.pekpunkter.count == 1, "punkten ska läggas till")
            run.pekaKlick(Runner.PickPoint(pos: [1, 2, 3.5], target: "lada"))
            kolla(run.pekpunkter.isEmpty, "klick på samma punkt ska ta bort den")
            run.tool = .valj
        }]),

        s("Håll mellanslag = prata", [
            .gor { win.makeKey(); run.tool = .rita; tangent(true, tecken: " ", kod: 49) }, .vanta(0.2),
            .gor { kolla(run.mikHall, "mellanslag nere i Rita ska starta mikrofonen") },
            .gor { tangent(false, tecken: " ", kod: 49) }, .vanta(0.2),
            .gor { kolla(!run.mikHall, "släppt mellanslag ska stoppa mikrofonen"); run.tool = .valj },
        ]),

        s("Chatten ser obesvarade meddelanden", [.gor {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            let tid = f.string(from: Date().addingTimeInterval(-600)), mott = f.string(from: Date().addingTimeInterval(-500))
            let cad = projekt.appendingPathComponent("cad")
            try? JSONSerialization.data(withJSONObject: ["svar": [["fraga_id": "meddelande", "fraga": "", "svar": "Hur högt är locket?", "tid": tid]]])
                .write(to: cad.appendingPathComponent("svar.json"))
            try? JSONSerialization.data(withJSONObject: ["status": "klar", "mottaget": mott, "meddelanden": [] as [Any]])
                .write(to: cad.appendingPathComponent("claude.json"))
            run.loadAnswers(); run.reloadCad()
        }, .vanta(0.5), .gor {
            let t = run.chatThreads(closedLocal: []).threads
            kolla(t.count == 1 && t.first?.status == .vantar, "meddelandet ska stå som Väntar på Claude: \(t.map { "\($0.title) \($0.status)" })")
        }]),

        s("Ändrat mått byggs om", [
            .gor { run.setParam("Låda: längd", "70") },
            .tills("ombygget startar", 10) { run.rebuilding }, .tills("ombygget blir klart", 120) { !run.rebuilding }, .vanta(1),
            .gor {
                let v = run.cad?.parametrar?.first { $0.namn == "Låda: längd" }?.varde
                kolla(v == 70, "Låda: längd ska vara 70 efter ombygget, är \(v.map { "\($0)" } ?? "-")")
                kolla(run.buildError == nil, "bygget ska gå utan fel: \(run.buildError ?? "")")
            },
        ]),

        Scenario(namn: "Vykubens sidor", steg: [.gor {
            kolla(ModelView.Coordinator.cubeMaterials(1).count == 6 && ModelView.Coordinator.cubeMaterials(-1).count == 6, "kuben ska ha sex sidor")
        }]),
    ] }
}
