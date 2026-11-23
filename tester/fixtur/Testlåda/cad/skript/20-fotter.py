"""Testprojektets fötter: en del med fyra kroppar (fyra separata cylindrar), ensam i sitt skript."""
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
from projekt import Projekt  # noqa: E402

from build123d import Align, BuildPart, Cylinder, Locations  # noqa: E402

prj = Projekt(sys.argv[1])
with BuildPart() as f:
    with Locations((-25, -15, -6), (25, -15, -6), (-25, 15, -6), (25, 15, -6)):
        Cylinder(3, 5, align=(Align.CENTER, Align.CENTER, Align.MIN))
prj.del_("fotter", "Fötter", f.part, farg="#8E44AD", beskrivning="Fyra fötter")
prj.spara(beskrivning="Testprojekt för tester/testa.sh")
