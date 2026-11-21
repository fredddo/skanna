# mall: Låda med lock
# beskrivning: Rektangulär låda med rundade hörn och ett lock som sätts på med en läpp; väggar, spel och fack går att ändra.
# id: lada
"""Låda med lock. Körs: python lada.py <projektmapp>. Ram: mm, Z upp, lådans botten i z = 0, centrerad i X/Y.
Locket ritas ovanpå lådan (på plats) och skrivs ut med ovansidan nedåt."""
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
from projekt import Projekt  # noqa: E402

from build123d import Axis, Box, Plane, Pos, RectangleRounded, extrude  # noqa: E402

prj = Projekt(sys.argv[1])
P = prj.parametrar("Låda", {
    "längd (inv)": (80.0, "mm"),
    "bredd (inv)": (50.0, "mm"),
    "höjd (inv)": (30.0, "mm"),
    "väggtjocklek": (1.6, "mm"),
    "bottentjocklek": (1.2, "mm"),
    "hörnradie (inv)": (4.0, "mm"),
    "antal fack": (1, "st"),
    "lock höjd": (8.0, "mm"),
    "lockläpp höjd": (4.0, "mm"),
    "spel lock": (0.2, "mm"),
})
L, B, H = P["längd (inv)"], P["bredd (inv)"], P["höjd (inv)"]
t, tb = P["väggtjocklek"], P["bottentjocklek"]
r = min(max(P["hörnradie (inv)"], 0.3), min(L, B) / 2 - 0.3)   # radien får aldrig bli större än halva bredden
n = max(1, int(round(P["antal fack"])))
LH, lip, gap = P["lock höjd"], P["lockläpp höjd"], P["spel lock"]


def rr(z, l, b, rad):
    return Plane.XY.offset(z) * RectangleRounded(l, b, max(rad, 0.2))


# algebra-läge: skisser och extruderingar utanför BuildPart
lada = extrude(rr(0, L + 2 * t, B + 2 * t, r + t), amount=H + tb) - extrude(rr(tb, L, B, r), amount=H)
for i in range(1, n):   # mellanväggar
    x = -L / 2 + i * L / n
    lada += Pos(x, 0, tb + (H - 1.0) / 2) * Box(t, B, H - 1.0)

ztop = H + tb
lock = extrude(rr(ztop + LH - t, L + 2 * t, B + 2 * t, r + t), amount=t)                      # lockets tak
lock += extrude(rr(ztop, L + 2 * t, B + 2 * t, r + t), amount=LH - t) - extrude(rr(ztop, L, B, r), amount=LH - t)  # kant
# läpp som går ner innanför lådans vägg
# läppen går från ztop − lip ända upp till taket, så att den sitter ihop med locket (en kropp)
lip_h = lip + LH - t
lock += extrude(rr(ztop - lip, L - 2 * gap, B - 2 * gap, r - gap), amount=lip_h) \
    - extrude(rr(ztop - lip, L - 2 * gap - 2 * t, B - 2 * gap - 2 * t, r - gap - t), amount=lip_h)

prj.del_("lada", "Låda", lada, farg="#2E7DD7", beskrivning=f"{L:.0f} × {B:.0f} × {H:.0f} mm invändigt, {n} fack",
         bambu={"wall_loops": 3, "sparse_infill_density": "15%", "enable_support": 0})
prj.del_("lock", "Lock", lock, farg="#E0A030", beskrivning="Läppen går ner innanför lådan",
         utskrift_solid=lambda s: s.rotate(Axis.X, 180),   # ovansidan nedåt; tillämpas på den kantbehandlade soliden
         bambu={"wall_loops": 3, "sparse_infill_density": "15%", "enable_support": 0, "top_shell_layers": 4})
# måttlinjer = handtag i appen (dra eller klicka). Symmetriska mått: faktor 2 (handtaget sitter på ena sidan).
prj.mattlinje("längd (inv)", (-L / 2, -B / 2, ztop), (L / 2, -B / 2, ztop), "lada", faktor=2)
prj.mattlinje("bredd (inv)", (L / 2, -B / 2, ztop), (L / 2, B / 2, ztop), "lada", faktor=2)
prj.mattlinje("höjd (inv)", (L / 2 + t, 0, tb), (L / 2 + t, 0, ztop), "lada")
prj.mattlinje("väggtjocklek", (L / 2, B / 4, ztop), (L / 2 + t, B / 4, ztop), "lada")
prj.mattlinje("bottentjocklek", (-L / 4, 0, 0), (-L / 4, 0, tb), "lada")
prj.mattlinje("lock höjd", (-L / 2 - t, 0, ztop), (-L / 2 - t, 0, ztop + LH), "lock")
prj.spara(beskrivning="Låda med lock från mall. Ändra måtten i listan – eller be Claude anpassa formen.")
