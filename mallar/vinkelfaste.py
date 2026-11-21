# mall: Vinkelfäste
# beskrivning: L-format fäste med skruvhål i båda skänklarna och en stödkil i mitten.
# id: vinkelfaste
"""Vinkelfäste. Körs: python vinkelfaste.py <projektmapp>. Ram: mm, Z upp; liggande skänkel i XY-planet,
stående skänkel i XZ-planet vid y = 0."""
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
from projekt import Projekt  # noqa: E402

from build123d import (Align, Axis, Box, BuildPart, BuildSketch, Cylinder, Locations, Mode, Plane, Polygon, Rot,
                       extrude, fillet)  # noqa: E402

prj = Projekt(sys.argv[1])
P = prj.parametrar("Vinkelfäste", {
    "bredd": (30.0, "mm"),
    "skänkel liggande": (40.0, "mm"),
    "skänkel stående": (40.0, "mm"),
    "tjocklek": (4.0, "mm"),
    "hål diameter": (4.5, "mm"),
    "hål per skänkel": (2, "st"),
    "stödkil": (1, "st"),
    "inre radie": (3.0, "mm"),
})
W, A, Bh, t, hd = P["bredd"], P["skänkel liggande"], P["skänkel stående"], P["tjocklek"], P["hål diameter"]
n = max(0, int(round(P["hål per skänkel"])))
with BuildPart() as b:
    Box(W, A, t, align=(Align.CENTER, Align.MIN, Align.MIN))
    Box(W, t, Bh, align=(Align.CENTER, Align.MIN, Align.MIN))
    if P["inre radie"] > 0:
        inner = b.edges().filter_by(Axis.X).filter_by_position(Axis.Y, t - 0.01, t + 0.01).filter_by_position(Axis.Z, t - 0.01, t + 0.01)
        fillet(inner, min(P["inre radie"], A - t - 1, Bh - t - 1))
    if int(round(P["stödkil"])):
        k = min(A, Bh) * 0.6
        with BuildSketch(Plane.YZ) as s:
            Polygon((t, t), (k, t), (t, k), align=None)
        extrude(s.sketch, amount=min(t, W / 4), both=True)
    xs = [(-W / 2 + W * (i + 0.5) / n) for i in range(n)] if n else []
    for x in xs:
        with Locations((x, t + (A - t) * 0.6, t / 2)):
            Cylinder(hd / 2, t + 1, mode=Mode.SUBTRACT)
        with Locations((x, t / 2, t + (Bh - t) * 0.6)):
            Cylinder(hd / 2, t + 1, rotation=(90, 0, 0), mode=Mode.SUBTRACT)
prj.del_("vinkelfaste", "Vinkelfäste", b.part, farg="#2E7DD7", beskrivning=f"{W:g} mm brett, {t:g} mm tjockt",
         utskrift_solid=lambda s: s.rotate(Axis.Y, 90),
         bambu={"wall_loops": 4, "sparse_infill_density": "30%", "enable_support": 0})
prj.mattlinje("bredd", (-W / 2, A, 0), (W / 2, A, 0), "vinkelfaste", faktor=2)
prj.mattlinje("skänkel liggande", (W / 2, 0, 0), (W / 2, A, 0), "vinkelfaste")
prj.mattlinje("skänkel stående", (W / 2, 0, 0), (W / 2, 0, Bh), "vinkelfaste")
prj.mattlinje("tjocklek", (-W / 2, A * 0.3, 0), (-W / 2, A * 0.3, t), "vinkelfaste")
prj.spara(beskrivning="Vinkelfäste från mall. Skriv ut liggande på sidan (ingen support, starkast i böjen).")
