"""cad/projekt.py och ytor.register_part: mått i geometri.json och delarnas poster i delar.json."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from hjalp import HEM, stada

SKRIPT = """
import sys
sys.path.insert(0, %r)
from projekt import Projekt
prj = Projekt(sys.argv[1])
prj.parametrar("A", {"a": (1.0, "mm")})
prj.parametrar("B", {"b": (22.5, "°")})
prj.spara(fragor=[{"id": "f1", "text": "?"}])
"""


class Spara(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="skanna-projekt-"))

    def tearDown(self):
        stada(self.t)

    def kor(self):
        s = self.t / "s.py"
        s.write_text(SKRIPT % str(HEM / "cad"))
        subprocess.run([sys.executable, str(s), str(self.t)], check=True, env=dict(os.environ, PYTHONUTF8="1"))
        return json.loads((self.t / "cad" / "geometri.json").read_text())

    def test_flera_grupper_dupliceras_inte(self):
        (self.t / "cad").mkdir()
        (self.t / "cad" / "geometri.json").write_text(json.dumps({"parametrar": [
            {"namn": "Annan: x", "varde": 5, "grupp": "Annan"}], "fragor": [{"id": "annan", "grupp": "Annan"}]}))
        for _ in range(3):
            geo = self.kor()
        namn = [(p["namn"], p["grupp"]) for p in geo["parametrar"]]
        self.assertEqual(sorted(namn), [("A: a", "A"), ("Annan: x", "Annan"), ("B: b", "B")])
        self.assertEqual(next(p for p in geo["parametrar"] if p["namn"] == "B: b")["varde"], 22.5)
        self.assertEqual(sorted(f["id"] for f in geo["fragor"]), ["annan", "f1"])

    def test_trasig_geometri_skrivs_inte_over(self):
        (self.t / "cad").mkdir()
        (self.t / "cad" / "geometri.json").write_text('{"parametrar": [')
        s = self.t / "s.py"
        s.write_text(SKRIPT % str(HEM / "cad"))
        r = subprocess.run([sys.executable, str(s), str(self.t)], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("trasig", r.stderr)
        self.assertEqual((self.t / "cad" / "geometri.json").read_text(), '{"parametrar": [')

    def test_anvandarvarde_med_komma_och_minus(self):
        (self.t / "cad").mkdir()
        (self.t / "cad" / "parametrar-anvandare.json").write_text(json.dumps({"A: a": "−3,5"}))
        geo = self.kor()
        self.assertEqual(next(p for p in geo["parametrar"] if p["namn"] == "A: a")["varde"], -3.5)


class Delar(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="skanna-delar-"))
        sys.path.insert(0, str(HEM / "cad"))

    def tearDown(self):
        stada(self.t)

    def test_foralder_och_egna_falt_bevaras_vid_ombygge(self):
        from ytor import register_part
        cad = self.t / "cad"
        cad.mkdir()
        register_part(cad, "cell", "Cellbädd", "cell-ytor.json", "design", "#fff", foralder="ring")
        d = json.loads((cad / "delar.json").read_text())
        d["delar"][0]["egen"] = "behåll"
        (cad / "delar.json").write_text(json.dumps(d))
        register_part(cad, "cell", "Cellbädd 2", "cell-ytor.json", "design", "#fff")   # skriptet nämner inte föräldern
        post = json.loads((cad / "delar.json").read_text())["delar"][0]
        self.assertEqual((post["namn"], post["foralder"], post["egen"]), ("Cellbädd 2", "ring", "behåll"))
        register_part(cad, "cell", "Cellbädd", "cell-ytor.json", "design", "#fff", foralder="")
        self.assertNotIn("foralder", json.loads((cad / "delar.json").read_text())["delar"][0])


if __name__ == "__main__":
    unittest.main()
