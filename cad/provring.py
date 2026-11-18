"""Provring: en låg ring som sätter sig på nederskalets kant – för att prova passningen innan hela distansen skrivs ut.

Läser nederskalets mått ur <skanning>/cad/geometri.json (kör nederskal.py först), ritar ringen i samma ram,
exporterar provring.step, provring-ytor.json (för appen) och provring.3mf/.stl i utskriftsläge (platt sida ner),
registrerar delen i delar.json och lägger till ringens mått och frågor i geometri.json.

Antagande: överskalet griper som ringen – yttre väggen vilar på nederskalets läpp, en tunga går ner innanför läppen
och vilar på trappsteget, och klackarna går upp i fickor.
"""
import json
import sys
from pathlib import Path

from build123d import (Box, BuildPart, Cylinder, Location, Locations, Mesher, Mode, Plane, Pos, RectangleRounded,
                       export_step, export_stl, extrude)

sys.path.insert(0, str(Path(__file__).parent))
from ytor import export_faces, register_part  # noqa: E402

scan = Path(sys.argv[1]).expanduser()
cad = scan / "cad"
geo = json.loads((cad / "geometri.json").read_text())
skal = {p["namn"]: p["varde"] for p in geo["parametrar"]}
s = lambda k: float(skal[k])

# ---- Ringens egna parametrar ---------------------------------------------------------------------------------------
R_ = {
    "Provring: höjd över kanten": (7.0, "antagande", None),
    "Provring: spel mot läppen": (0.20, "antagande", None),     # per sida, mellan tungan och läppens insida
    "Provring: tungans spel mot steget": (0.20, "antagande", None),  # tungan når inte riktigt ner till steget
    "Provring: spel kring klackarna": (0.30, "antagande", None),
    "Provring: brygga över klackfickan": (2.0, "antagande", None),
}
from ytor import apply_overrides  # noqa: E402
apply_overrides(cad, R_)
r = lambda k: R_[k][0]

L, W, R, t = s("längd ytter"), s("bredd ytter"), s("hörnradie ytter"), s("väggtjocklek")
cy, ztop = s("mitt Y-förskjutning"), s("kantens topp Z")
lip_w, lip_h = s("läpp bredd (ytter)"), s("läpp höjd")
kx0, kx1, kt, ktop = s("klack X från"), s("klack X till"), s("klack tjocklek"), s("klackens topp Z")
H = max(r("Provring: höjd över kanten"), (ztop - ktop) + r("Provring: spel kring klackarna") + r("Provring: brygga över klackfickan"))
R_["Provring: höjd över kanten"] = (H, "antagande", None)
gap, gz, gk = r("Provring: spel mot läppen"), r("Provring: tungans spel mot steget"), r("Provring: spel kring klackarna")

def rr(z, inset):
    """Rundad rektangel (ytterkonturen minus inset) som yta i planet z."""
    return Plane.XY.offset(z) * Pos(0, cy) * RectangleRounded(L - 2 * inset, W - 2 * inset, max(R - inset, 0.5))


# skisser skapas utanför BuildPart (annars tolkas de som del-operationer)
wall_out, wall_in = rr(ztop - H, 0), rr(ztop - H, t)
tongue_out, tongue_in = rr(ztop, lip_w + gap), rr(ztop, t)

with BuildPart() as ring:
    # ringens vägg ovanför kanten (öppningen mot −Z, så "uppåt" är mot −Z)
    extrude(wall_out, amount=H)
    extrude(wall_in, amount=H, mode=Mode.SUBTRACT)
    # tungan: innanför läppen, ner mot trappsteget
    extrude(tongue_out, amount=lip_h - gz)
    extrude(tongue_in, amount=lip_h - gz, mode=Mode.SUBTRACT)
    # fickor för klackarna (genom väggen, upp till klackens topp + spel)
    pocket_h = (ztop - ktop) + gk + lip_h
    for sgn in (1, -1):
        with Locations(Location(((kx0 + kx1) / 2, cy + sgn * (W / 2 - t / 2), ztop + lip_h - pocket_h / 2))):
            Box(kx1 - kx0 + 2 * gk, t + 2, pocket_h, mode=Mode.SUBTRACT)

    # urtag för nederskalets skruvtorn där tungan annars tar i
    for tx, ty in geo.get("torn", []):
        with Locations(Location((tx, ty, ztop + lip_h / 2))):
            Cylinder(s("hylsa ytterdiameter") / 2 + gk, lip_h + 1.0, mode=Mode.SUBTRACT)

solid = ring.part
export_step(solid, str(cad / "provring.step"))
n = export_faces(solid, cad / "provring-ytor.json")
# utskriftsläge: platt ovansida (minsta z) mot plattan
bb = solid.bounding_box()
printed = solid.moved(Location((-(bb.min.X + bb.max.X) / 2, -(bb.min.Y + bb.max.Y) / 2, -bb.min.Z)))
export_stl(printed, str(cad / "provring.stl"), tolerance=0.01, angular_tolerance=0.1)
mesher = Mesher()
mesher.add_shape(printed)
mesher.write(str(cad / "provring.3mf"))
register_part(cad, "provring", "Provring", "provring-ytor.json", "design", "#2E7DD7", export="provring.3mf",
              beskrivning="Låg ring som provar passningen mot nederskalets kant")

# ---- Lägg ringens mått och frågor i geometri.json ------------------------------------------------------------------
geo["parametrar"] = [p for p in geo["parametrar"] if not p["namn"].startswith("Provring: ")] + [
    {"namn": k, "varde": round(v, 2), "enhet": "mm", "kalla": src, "osakerhet": unc} for k, (v, src, unc) in R_.items()]
geo["fragor"] = [f for f in geo["fragor"] if not f["id"].startswith("provring-")] + [
    {"id": "provring-passning",
     "text": "Skriv ut provringen (objektträdet → Provring → Exportera, öppnas i Bambu Studio; platt sida ner, inga stöd). "
             "Sätt den på nederskalets kant: sitter den? För trång, glapp, eller tar den i någonstans? Hamnar klackarna i fickorna? "
             "Klicka gärna på stället i modellen där det tar i.",
     "markering": [{"typ": "omrade", "min": [-L / 2, cy - W / 2, ztop - H], "max": [L / 2, cy + W / 2, ztop + lip_h],
                    "text": "provring"}]},
    {"id": "provring-overskal", "besvarad": True,
     "text": "Hur möter överskalet nederskalet i dag – går en tunga på överskalet ner innanför läppen (som ringen antar), "
             "eller tvärtom?",
     "markering": [{"typ": "matt", "fran": [-30, cy + W / 2 - lip_w - gap, ztop], "till": [-30, cy + W / 2 - t, ztop],
                    "text": "tunga?"}]},
]
(cad / "geometri.json").write_text(json.dumps(geo, ensure_ascii=False, indent=2))
print(f"provring: {L:.1f} × {W:.1f}, höjd {H:.1f} mm, {n} ytor → {cad}")
