"""Överskal (+ cellerna) i NEDERSKALETS ram, så att delarna passar ihop direkt.

Läser nederskalets mått (geometri.json, kör nederskal.py först) och överskalets egna mått/antaganden nedan.
Överskalet sitter ovanpå nederskalet (mot −Z): kantytan vilar på nederskalets läpp (z = kantens topp Z), en tunga
går ner innanför läppen, fyra torn går ner i nederskalets hylsor.

  .venv/bin/python cad/overskal.py <nederskalets skanning>      (t.ex. ~/Downloads/IMG_9071.modell)
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
N = {p["namn"]: p["varde"] for p in geo["parametrar"]}
n = lambda k: float(N[k])

# ---- Överskalets parametrar (källa, osäkerhet) -----------------------------------------------------------------------
U = {
    "Överskal: längd vid kanten": (134.1, "uppmätt", 0.05),
    "Överskal: bredd vid kanten": (81.56, "uppmätt", 0.05),
    "Överskal: hörnradie": (17.7, "skanning", 1.5),          # kantkonturen passad mot skanningen (median 0,37 mm)
    "Överskal: höjd från kanten": (26.6, "skanning", 1.0),
    "Överskal: tunga höjd": (1.65, "uppmätt", 0.05),
    "Överskal: tunga tjocklek": (1.3, "uppmätt", 0.05),
    "Överskal: spel tunga–läpp": (0.10, "antagande", None),
    "Överskal: tak tjocklek": (2.5, "antagande", None),
    "Överskal: spel kring klackar": (0.3, "antagande", None),
    "Överskal: torn ytterdiameter": (6.3, "uppmätt", 0.05),     # går i nederskalets Ø6,9-hål
    "Överskal: torn skruvhål": (2.55, "uppmätt", 0.05),
    "Överskal: torn höjd över kanten, +X (breda urtaget)": (8.25, "uppmätt", 0.05),
    "Överskal: torn höjd över kanten, −X": (9.1, "uppmätt", 0.05),
    "Isärdragning (distansens höjd)": (30.0, "antagande", None),  # användaren: dra isär ~30 mm så distansen får plats
    "Celler: diameter": (21.2, "standard", 0.1),
    "Celler: längd": (70.0, "standard", 0.2),
}
from ytor import apply_overrides  # noqa: E402
apply_overrides(cad, U)
u = lambda k: U[k][0]

L, W, R = u("Överskal: längd vid kanten"), u("Överskal: bredd vid kanten"), u("Överskal: hörnradie")
cy, ztop = n("mitt Y-förskjutning"), n("kantens topp Z")
# tungan: ytterytan mot nederskalets läpps insida
Ll, Wl, Rl, lip_w = n("längd ytter"), n("bredd ytter"), n("hörnradie ytter"), n("läpp bredd (ytter)")
gap, th, tt = u("Överskal: spel tunga–läpp"), u("Överskal: tunga tjocklek"), u("Överskal: tunga höjd")
tongue_out = (Ll - 2 * (lip_w + gap), Wl - 2 * (lip_w + gap), max(Rl - lip_w - gap, 0.5))
tongue_in = (tongue_out[0] - 2 * th, tongue_out[1] - 2 * th, max(tongue_out[2] - th, 0.5))
H, roof = u("Överskal: höjd från kanten"), u("Överskal: tak tjocklek")


def rr(z, dims):
    return Plane.XY.offset(z) * Pos(0, cy) * RectangleRounded(*dims)


outer = rr(ztop - H, (L, W, R))
inner = rr(ztop - H + roof, tongue_in)
t_out, t_in = rr(ztop, tongue_out), rr(ztop, tongue_in)

with BuildPart() as shell:
    extrude(outer, amount=H)                         # från toppen (−Z) ner till kantytan
    extrude(inner, amount=H - roof, mode=Mode.SUBTRACT)
    extrude(t_out, amount=tt)                        # tungan ner innanför nederskalets läpp
    extrude(t_in, amount=tt, mode=Mode.SUBTRACT)
    # torn: från taket ner genom kanten, in i nederskalets hylsor
    z0 = ztop - H + roof
    for tx, ty in geo.get("torn", []):
        tl = u("Överskal: torn höjd över kanten, +X (breda urtaget)") if tx > 0 else u("Överskal: torn höjd över kanten, −X")
        z1 = ztop + tl
        with Locations(Location((tx, ty, (z0 + z1) / 2))):
            Cylinder(u("Överskal: torn ytterdiameter") / 2, z1 - z0)
        with Locations(Location((tx, ty, (z0 + z1) / 2))):
            Cylinder(u("Överskal: torn skruvhål") / 2, z1 - z0 + 0.2, mode=Mode.SUBTRACT)
    # fickor för nederskalets klackar (de sticker upp från trappsteget in i överskalet)
    gk = u("Överskal: spel kring klackar")
    kx0, kx1, ktop = n("klack X från"), n("klack X till"), n("klackens topp Z")
    lip_h = n("läpp höjd")
    pocket_top = ktop - gk
    pocket_bot = ztop + lip_h + 0.5
    # fickan går från insidan ut till nederskalets ytteryta + spel – överskalets ytterhud (bredare skal) lämnas hel
    y_in, y_out = Wl / 2 - n("väggtjocklek") - 1.0, Wl / 2 + gk
    for sgn in (1, -1):
        with Locations(Location(((kx0 + kx1) / 2, cy + sgn * (y_in + y_out) / 2, (pocket_top + pocket_bot) / 2))):
            Box(kx1 - kx0 + 2 * gk, y_out - y_in, pocket_bot - pocket_top, mode=Mode.SUBTRACT)
solid_mated = shell.part                                   # sammansatt läge (för kontroll/foto i överdelens skanning)
GAP = u("Isärdragning (distansens höjd)")
solid = solid_mated.moved(Location((0, 0, -GAP)))         # isärdraget: överskalet lyft från nederskalet (mot −Z)
export_step(solid, str(cad / "overskal.step"))
print("överskal ytor:", export_faces(solid, cad / "overskal-ytor.json"))
register_part(cad, "overskal", "Överskal", "overskal-ytor.json", "referens", "#8E6CC9",
              beskrivning="Rekonstruerat ur IMG_9072, i nederskalets ram")

# ---- cellerna (referens): på nederskalets cellbäddar ----------------------------------------------------------------
with BuildPart() as cells:
    for k in range(-2, 3):
        x = n("cell 3 centrum X") + k * n("celldelning")
        with Locations(Location((x, cy, n("cellcentrum Z")), (90, 0, 0))):
            Cylinder(u("Celler: diameter") / 2, u("Celler: längd"))
cells_part = cells.part.moved(Location((0, 0, -GAP)))       # cellerna sitter i överdelens hållare och följer med upp
export_step(cells_part, str(cad / "celler.step"))
print("celler ytor:", export_faces(cells_part, cad / "celler-ytor.json"))
register_part(cad, "celler", "Celler 5 × 21700", "celler-ytor.json", "referens", "#D9443A",
              beskrivning="Standardmått, på nederskalets bäddar")

# ---- mått i geometri.json --------------------------------------------------------------------------------------------
geo["parametrar"] = [p for p in geo["parametrar"] if not (p["namn"].startswith("Överskal: ") or p["namn"].startswith("Celler: "))] + [
    {"namn": k, "varde": v, "enhet": "mm", "kalla": s, "osakerhet": o} for k, (v, s, o) in U.items()]
geo["fragor"] = [f for f in geo["fragor"] if f["id"] != "distans-hojd"] + [
    {"id": "distans-hojd",
     "text": "Distansen: delarna är nu isärdragna %.0f mm. Räcker det för elektroniken? Hur stor är den ungefär (L × B × H), "
             "och ska den ligga i nederdelen under cellerna (där bäddarna blir tomma)?" % GAP,
     "markering": [{"typ": "matt", "fran": [0, cy + W / 2 + 4, ztop], "till": [0, cy + W / 2 + 4, ztop - GAP],
                    "text": "%.0f mm isär" % GAP}]}]
(cad / "geometri.json").write_text(json.dumps(geo, ensure_ascii=False, indent=2))
print("klart")

# ---- samma delar i överdelens egen skanning (för foto-kontroll där), via inpassningens invers ------------------------
fit = cad / "overdel-inpassning.json"
if fit.exists():
    import numpy as np
    info = json.loads(fit.read_text())
    Ainv = np.linalg.inv(np.array(info["matris"]))
    other = scan.parent / Path(info["fran"]).parts[0] / "cad"
    other.mkdir(exist_ok=True)
    # överdelens skanning i nederdelens ram, isärdragen lika mycket
    import trimesh
    up = trimesh.load(scan.parent / info["fran"], force="mesh", process=False)
    up = trimesh.Trimesh(up.vertices, up.faces, process=False); up.remove_unreferenced_vertices()
    up.apply_transform(np.array(info["matris"])); up.apply_translation([0, 0, -GAP])
    up.export(cad / "overdel-skanning.stl")
    export_faces(solid_mated, cad / "_overskal-sammansatt.json")
    for src, pid, name, color in [("_overskal-sammansatt.json", "overskal", "Överskal (från nederdelens ram)", "#8E6CC9")]:
        data = json.loads((cad / src).read_text())
        for y in data["ytor"]:
            v = np.array(y["v"]).reshape(-1, 3)
            v = (np.c_[v, np.ones(len(v))] @ Ainv.T)[:, :3]
            y["v"] = [round(float(x), 4) for x in v.ravel()]
            y["centrum"] = None
            y["normal"] = None
        (other / "overskal-ytor.json").write_text(json.dumps(data, separators=(",", ":")))
        register_part(other, pid, name, "overskal-ytor.json", "referens", color, beskrivning="Ritad i nederdelens ram, transformerad hit")
    print("även i", other)
