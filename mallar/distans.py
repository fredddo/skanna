# mall: Distans / bricka
# beskrivning: Rund distans eller bricka med hål – ytter-, innerdiameter, höjd och fas.
# id: distans
"""Distans/bricka. Körs: python distans.py <projektmapp>. Ram: mm, Z upp, botten i z = 0."""
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
from projekt import Projekt  # noqa: E402

from build123d import Axis, BuildPart, Cylinder, Mode, Align, chamfer  # noqa: E402

prj = Projekt(sys.argv[1])
P = prj.parametrar("Distans", {
    "ytterdiameter": (12.0, "mm"),
    "hål diameter": (5.3, "mm"),         # M5 frigång
    "höjd": (10.0, "mm"),
    "fas": (0.5, "mm"),
})
D, d, h, f = P["ytterdiameter"], P["hål diameter"], P["höjd"], P["fas"]
if d >= D - 0.8:
    raise SystemExit(f"Hålet ({d} mm) är för stort för ytterdiametern ({D} mm)")
with BuildPart() as b:
    Cylinder(D / 2, h, align=(Align.CENTER, Align.CENTER, Align.MIN))
    if d > 0:
        Cylinder(d / 2, h, align=(Align.CENTER, Align.CENTER, Align.MIN), mode=Mode.SUBTRACT)
    if f > 0:
        chamfer(b.edges().filter_by(Axis.Z, reverse=True), min(f, (D - d) / 4 - 0.05, h / 3))
prj.del_("distans", "Distans", b.part, farg="#2E7DD7", beskrivning=f"⌀{D:g}/⌀{d:g} × {h:g} mm",
         bambu={"wall_loops": 4, "sparse_infill_density": "50%", "enable_support": 0})
prj.spara(beskrivning="Distans från mall.")
