"""Rensad CAD-geometri för HiKOKI 18V 4,0 Ah nederskal, i samma ram som skanningens modell-mm.obj.

Ram: mm, X = längd, Y = bredd, Z = höjd. Öppningen vetter mot −Z (så låg delen i skanningen).
Kör:  .venv/bin/python cad/nederskal.py <skanningsmapp>
Skriver <skanningsmapp>/cad/{modell-cad.step, modell-cad.stl, geometri.json}.
"""
import json
import sys
from pathlib import Path

import numpy as np
import trimesh
from build123d import (Face, Wire, Rectangle, Align, Axis, Box, BuildPart, BuildSketch, Cylinder, Location, Locations, Mode, Plane,
                       RectangleRounded, export_step, export_stl, extrude)

scan = Path(sys.argv[1]).expanduser()
LAST_SVAR = "2026-11-17T20:21:11+01:00"   # senaste svar i cad/svar.json som är inarbetat
out = scan / "cad"
out.mkdir(exist_ok=True)

# ---- Parametrar: värde, källa ("uppmätt" | "skanning" | "antagande" | "standard"), osäkerhet --------------------
P = {
    "längd ytter":        (133.90, "uppmätt", 0.05),  # skjutmått strax under kanten (skanningen: 133,2)
    "bredd ytter":        (79.35, "uppmätt", 0.05),   # skjutmått strax under kanten (skanningen: 78,55)
    "mitt Y-förskjutning": (-2.17, "skanning", 0.2),
    "hörnradie ytter":    (None,  "skanning", 1.0),   # anpassas nedan
    "väggtjocklek":       (3.08,  "uppmätt", 0.05),   # skjutmått; skanningen sa 3,8
    "kantens topp Z":     (-10.0, "skanning", 0.2),
    "läpp bredd (ytter)": (2.0,   "uppmätt", 0.05),   # yttre delen av väggen står upp, läpp runt hela kanten
    "läpp höjd":          (1.91,  "uppmätt", 0.05),   # inre delen av väggen ligger så mycket lägre
    "underkant Z":        (13.5,  "antagande", 1.5),  # undersidan syntes inte (låg mot bordet)
    "cellradie":          (10.6,  "standard", 0.1),   # 21700: ⌀21,2 mm. Skanningen gav 10,60/10,91/10,66
    "celldelning":        (21.6,  "skanning", 0.3),   # båda skanningarna + krockkontroll; åsmåttet 67,5 togs troligen över ytterkanterna
    "cell 3 centrum X":   (-0.58, "skanning", 0.3),
    "cellcentrum Z":      (-3.0,  "skanning", 0.3),
    "åsarnas topp Z":     (3.0,   "skanning", 0.3),
    "ändblockens topp Z": (1.0,   "skanning", 0.6),
    "ändblock från |X|":  (54.0,  "skanning", 1.0),
    # urtag i gavlarnas kant (bekräftat av användaren, mått ur skanningen)
    "+X urtag bredd i botten": (52.4, "uppmätt", 0.05),
    "+X urtag mitt Y":    (0.0,   "antagande", 0.8),    # centrerat mellan tornen (skanningen: ~0,2)
    "+X urtag djup":      (2.35,  "uppmätt", 0.05),
    "urtagens fas (grader)": (45.0, "uppmätt", None),   # sidorna fasade 45° uppåt-utåt
    "−X grunt parti Y från": (-28.0, "skanning", 0.8),
    "−X grunt parti Y till": (23.5,  "skanning", 0.8),
    "−X grunt parti botten Z": (-8.2, "skanning", 0.3),
    "−X småurtag bredd i botten": (2.0, "antagande", 0.8),
    "−X småurtag djup":   (2.65,  "skanning", 0.3),
    # skruvtorn (användaren: 4 st; lägen ur skanningens hål)
    # hylsor: överskalets långa torn går ner i 6,9 mm-hål här; skruv underifrån genom ett mindre hål i botten
    "hylsa hål diameter": (6.9,   "uppmätt", 0.05),
    "hylsa ytterdiameter": (9.9,  "antagande", 1.0),   # hål + 2 × 1,5 mm gods
    "hylsa hålets djup":  (10.0,  "antagande", 2.0),   # överskalets torn går 7,5 (−X) / 6,6 (+X) mm ner i hylsan
    "skruvhål diameter":  (2.5,   "antagande", 0.5),   # skanningen såg ~2 mm i hylsornas botten
    "tornens topp Z":     (-8.4,  "skanning", 0.4),
    "klack X från":       (21.3,  "skanning", 0.4),
    "klack X till":       (32.3,  "skanning", 0.4),
    "klack tjocklek":     (3.3,   "skanning", 0.4),
    "klackens topp Z":    (-14.4, "skanning", 0.3),
}
sys.path.insert(0, str(Path(__file__).parent))
from ytor import apply_overrides  # noqa: E402
OVERRIDES = apply_overrides(out, P)   # dina värden från appen går före
v = lambda k: P[k][0]
TOWERS = [(-60.4, 14.4), (-60.9, -19.5), (57.2, 14.5), (57.2, -19.5)]  # hålcentrum X,Y absolut (sista: antagen symmetri)
SMALL_NOTCHES = [-25.3, -13.6, 8.0, 20.0]   # −X-gavelns småurtag, centrum Y (skanning; relativt mitten)

# ---- Hörnradie: anpassa rundad rektangel till ytterkonturen strax under kanten -----------------------------------
mesh = trimesh.load(scan / "modell" / "modell-mm.obj", force="mesh", process=False)
sec = mesh.section(plane_origin=[0, 0, -6], plane_normal=[0, 0, 1])
pts = np.vstack(sec.discrete)[:, :2] - [0, v("mitt Y-förskjutning")]
hx, hy = v("längd ytter") / 2, v("bredd ytter") / 2


def rr_dist(p, r):
    q = np.abs(p) - [hx - r, hy - r]
    return np.linalg.norm(np.maximum(q, 0), axis=1) + np.minimum(np.max(q, axis=1), 0) - r


outer = pts[rr_dist(pts, 6) > -1.5]  # bara ytterväggens punkter
corner = outer[(np.abs(outer[:, 0]) > hx - 18) & (np.abs(outer[:, 1]) > hy - 18)]  # bara hörnområdena
best = min(np.arange(2, 16, 0.25), key=lambda r: np.median(np.abs(rr_dist(corner, r))))
per_corner = []
for sx in (1, -1):
    for sy in (1, -1):
        c = corner[(np.sign(corner[:, 0]) == sx) & (np.sign(corner[:, 1]) == sy)]
        per_corner.append(min(np.arange(2, 16, 0.25), key=lambda r: np.median(np.abs(rr_dist(c, r)))) if len(c) > 20 else None)
print("hörnradier per hörn (+x+y, +x-y, -x+y, -x-y):", per_corner)
if "hörnradie ytter" not in OVERRIDES:
    P["hörnradie ytter"] = (float(best), "skanning", 1.0)

# ---- Geometri --------------------------------------------------------------------------------------------------------
L, W, R, t = v("längd ytter"), v("bredd ytter"), v("hörnradie ytter"), v("väggtjocklek")
cy, ztop, zbot = v("mitt Y-förskjutning"), v("kantens topp Z"), v("underkant Z")
floor_z = v("åsarnas topp Z")
with BuildPart() as part:
    # skal
    with BuildSketch(Plane.XY.offset(ztop)) as s:
        with Locations((0, cy)):
            RectangleRounded(L, W, R)
    extrude(amount=zbot - ztop)
    with BuildSketch(Plane.XY.offset(ztop)):
        with Locations((0, cy)):
            RectangleRounded(L - 2 * t, W - 2 * t, max(R - t, 0.5))
    extrude(amount=floor_z - ztop, mode=Mode.SUBTRACT)
    # läpp: väggens inre del ett trappsteg lägre än den yttre
    lip_w, lip_h = v("läpp bredd (ytter)"), v("läpp höjd")
    with BuildSketch(Plane.XY.offset(ztop)):
        with Locations((0, cy)):
            RectangleRounded(L - 2 * lip_w, W - 2 * lip_w, max(R - lip_w, 0.5))
    extrude(amount=lip_h, mode=Mode.SUBTRACT)
    # ändblock (högre platåer vid kortsidorna)
    xe, ze = v("ändblock från |X|"), v("ändblockens topp Z")
    # klipps efter skalets inre (rundade) kontur så att inga hörn sticker ut genom ytterväggen
    with BuildSketch(Plane.XY.offset(ze)):
        with Locations((0, cy)):
            RectangleRounded(L - 2 * (t - 0.3), W - 2 * (t - 0.3), max(R - (t - 0.3), 0.5))
            Rectangle(2 * xe, W + 10, mode=Mode.SUBTRACT)
    extrude(amount=floor_z - ze)
    # cellbäddar: 5 st 21700 tvärs (axel längs Y)
    for k in range(-2, 3):
        x = v("cell 3 centrum X") + k * v("celldelning")
        with Locations(Location((x, cy, v("cellcentrum Z")), (90, 0, 0))):
            Cylinder(v("cellradie"), W - 2 * t + 0.02, mode=Mode.SUBTRACT)
    # klackar på långsidornas kant
    for sgn in (1, -1):
        y_in = cy + sgn * (W / 2 - t)
        kt_ = min(v("klack tjocklek"), t)                # jäms med ytterväggen, aldrig utanför
        y_c = y_in + sgn * kt_ / 2
        x_c = (v("klack X från") + v("klack X till")) / 2
        h = ztop + lip_h - v("klackens topp Z")          # från trappsteget upp till klackens topp
        with Locations(Location((x_c, y_c, v("klackens topp Z") + h / 2))):
            Box(v("klack X till") - v("klack X från"), kt_, h + 0.01)

    # urtag i gavlarna: trapets genom väggen – plan botten, sidor fasade (45°) uppåt-utåt till över kanten
    import math
    slope = 1 / math.tan(math.radians(v("urtagens fas (grader)")))

    def cut(gable, yc_rel, bottom_w, depth):
        x0 = (L / 2 - t - 0.6) if gable > 0 else (-L / 2 - 0.6)
        zb, zt = ztop + depth, ztop - 1.0
        spread = (zb - zt) * slope
        y = cy + yc_rel
        pts = [(x0, y - bottom_w / 2, zb), (x0, y + bottom_w / 2, zb),
               (x0, y + bottom_w / 2 + spread, zt), (x0, y - bottom_w / 2 - spread, zt)]
        extrude(Face(Wire.make_polygon(pts, close=True)), amount=t + 1.2, dir=(1, 0, 0), mode=Mode.SUBTRACT)

    def cut_box(gable, y0, y1, zb):
        with Locations(Location((gable * (L / 2 - t / 2), cy + (y0 + y1) / 2, (ztop - 1 + zb) / 2))):
            Box(t + 1.2, abs(y1 - y0), zb - (ztop - 1), mode=Mode.SUBTRACT)

    # hylsor: cylinder från topp till botten med brygga ut till gaveln; 6,9 mm-hål för överskalets torn,
    # och ett mindre genomgående skruvhål i botten
    for tx, ty in TOWERS:
        top = v("tornens topp Z")
        h_t = zbot - top
        zc_t = top + h_t / 2
        with Locations(Location((tx, ty, zc_t))):
            Cylinder(v("hylsa ytterdiameter") / 2, h_t)
        wall_x = (L / 2 - t + 0.3) * (1 if tx > 0 else -1)
        with Locations(Location(((tx + wall_x) / 2, ty, zc_t))):
            Box(abs(wall_x - tx), v("hylsa ytterdiameter"), h_t)
        dep = v("hylsa hålets djup")
        with Locations(Location((tx, ty, top - 1 + (dep + 1) / 2))):
            Cylinder(v("hylsa hål diameter") / 2, dep + 1, mode=Mode.SUBTRACT)
        with Locations(Location((tx, ty, zc_t))):
            Cylinder(v("skruvhål diameter") / 2, h_t + 2, mode=Mode.SUBTRACT)

    cut(+1, v("+X urtag mitt Y"), v("+X urtag bredd i botten"), v("+X urtag djup"))
    cut_box(-1, v("−X grunt parti Y från"), v("−X grunt parti Y till"), v("−X grunt parti botten Z"))
    for yc_ in SMALL_NOTCHES:
        cut(-1, yc_, v("−X småurtag bredd i botten"), v("−X småurtag djup"))

solid = part.part
export_step(solid, str(out / "modell-cad.step"))
export_stl(solid, str(out / "modell-cad.stl"), tolerance=0.02, angular_tolerance=0.1)
from ytor import export_faces, register_part  # noqa: E402  (ligger bredvid det här skriptet)
print("ytor:", export_faces(solid, out / "modell-cad-ytor.json"))
register_part(out, "nederskal", "Nederskal", "modell-cad-ytor.json", "referens", "#F28C26",
              beskrivning="Rekonstruerat ur skanningen")

# ---- Avvikelse: skanningens ytpunkter (ovanifrån synliga delar) mot CAD-ytan -----------------------------------------
cad = trimesh.load(out / "modell-cad.stl", force="mesh")
vs = mesh.vertices
vis = vs[vs[:, 2] < zbot - 4]  # undersidan är inte observerad
rng = np.random.default_rng(0)
sample = vis[rng.choice(len(vis), size=min(20000, len(vis)), replace=False)]
_, d, _ = trimesh.proximity.closest_point(cad, sample)
avv = f"median {np.median(d):.2f} mm, 90 % < {np.percentile(d, 90):.2f} mm"

hx_, hy_ = L / 2, W / 2
crest = [v("cell 3 centrum X") + (k + 0.5) * v("celldelning") for k in range(-3, 3)]
info = {
    "status": "väntar på svar",
    "beskrivning": "Nederskalet: rundad låda (vägg 3,08 mm uppmätt), 5 cellbäddar för 21700 tvärs, ändplatåer, "
                   "två klackar och urtagen i gavlarnas kant. Ram som skanningen (öppningen mot −Z). "
                   "Läppen runt kanten (yttre del högre) är med. Fyra hylsor (Ø6,9) för överskalets torn är med; ribbornas kam är förenklad till en hel bädd.",
    "avvikelse": avv,
    "last_svar": LAST_SVAR,
    "torn": [[tx, ty] for tx, ty in TOWERS],
    "parametrar": [
        {"namn": k, "varde": round(val, 2) if val is not None else None, "enhet": "°" if "grader" in k else "mm",
         "kalla": src, "osakerhet": unc}
        for k, (val, src, unc) in P.items()
    ],
    "fragor": [
        {"id": "vaggtjocklek", "text": "Väggtjocklek", "besvarad": True},
        {"id": "kanthojd", "text": "Kortsidornas kant", "besvarad": True},
        {"id": "bredd", "text": "Ytterbredd", "besvarad": True},
        {"id": "lapp", "text": "Läppen", "besvarad": True},
        {"id": "langd", "text": "Ytterlängd", "besvarad": True},
        {"id": "urtag", "text": "Urtagen", "besvarad": True},
        {"id": "smaurtag", "text": "De fyra små urtagen i −X-gaveln (bredvid tornhålen): hur breda är de i botten och hur djupa från "
                                  "kanten? Jag antar 2,0 mm i botten, 2,65 mm djupa, 45° fas. (Bara viktigt om distansen ska fylla dem.)",
         "markering": [{"typ": "omrade", "min": [-hx_ - 0.5, cy + yc_ - 1.0, ztop], "max": [-hx_ + t + 0.5, cy + yc_ + 1.0, ztop + v("−X småurtag djup")],
                        "text": ""} for yc_ in SMALL_NOTCHES] + [{"typ": "punkt", "pos": [-hx_, cy, ztop - 3], "text": "4 småurtag"}]},
        {"id": "asdelning", "text": "Åsarnas delning", "besvarad": True},
        {"id": "asdelning2", "text": "Åsarna", "besvarad": True},
        {"id": "bottenkant", "text": "Ytterkanten mot botten (undersidan låg mot bordet och syns inte i skanningen): är den rundad? "
                                    "Ungefär vilken radie – och är botten plan? Jag har den nu skarp och plan.",
         "markering": [{"typ": "matt", "fran": [-20, cy + W / 2, zbot - 4], "till": [-20, cy + W / 2 - 4, zbot], "text": "rundning?"}]},
        {"id": "foto-ovanifran", "text": "Lägg skalet med öppningen nedåt mitt på referensarket och ta ETT foto rakt ovanifrån "
                                        "(telefonen parallell med bordet, ~40 cm upp). Bifoga med gemet. Det ger ytterkonturen och "
                                        "hörnradierna exakt (skanningen: 13–16 mm, ett hörn osäkert).",
         "markering": [{"typ": "omrade", "min": [-hx_, cy - hy_, ztop], "max": [hx_, cy + hy_, zbot], "text": "hela konturen"}]},
        {"id": "skruvtorn", "text": "Skruvtornen", "besvarad": True},
        {"id": "torn-hal", "text": "Tornen", "besvarad": True},
        {"id": "hylsor", "text": "Hylsorna (6,9 mm hål) är inlagda. Hur djupa är hålen ungefär, och sitter det ett mindre skruvhål i botten "
                                "(skruv underifrån upp i överskalets torn)? Annars får vi det ur skanningen av överskalet. "
                                "Jag antar 10 mm djup, Ø2,5 skruvhål.",
         "markering": [{"typ": "punkt", "pos": [tx, ty, v("tornens topp Z")], "text": "hylsa %d" % (i + 1)} for i, (tx, ty) in enumerate(TOWERS)]},
        {"id": "upplagg", "text": "Upplägg", "besvarad": True},
    ],
}
(out / "geometri.json").write_text(json.dumps(info, ensure_ascii=False, indent=2))
print("hörnradie", best, "| avvikelse", avv)
print("skrev", out)
