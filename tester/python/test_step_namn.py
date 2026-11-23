"""STEP-import behåller kropparnas namn (t.ex. från Fusion) i stället för Kropp 1, 2 …"""
import sys, unittest, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "cad"))
import importera


class StepNamn(unittest.TestCase):
    def test_namn_foljer_med(self):
        from build123d import Box, Compound, Location, export_step
        a = Box(10, 10, 10); a.label = "Tallrik 1"
        b = Box(5, 5, 5).moved(Location((20, 0, 0))); b.label = "Gejder"
        c = Box(5, 5, 5).moved(Location((40, 0, 0))); c.label = "Gejder"
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.step"
            export_step(Compound(children=[a, b, c]), str(p))
            s, namn, _ = importera.las_step_med_namn(p)
        self.assertEqual(len(s.solids()), 3)
        self.assertEqual(namn, ["Tallrik 1", "Gejder (1)", "Gejder (2)"])
        self.assertAlmostEqual(s.bounding_box().max.X, 42.5, places=3)


    def test_farger_foljer_med(self):
        from build123d import Box, Color, Compound, Location, export_step
        a = Box(10, 10, 10); a.label = "Röd"; a.color = Color(1, 0, 0)
        b = Box(5, 5, 5).moved(Location((20, 0, 0))); b.label = "Utan färg"
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.step"
            export_step(Compound(children=[a, b]), str(p))
            _, _, farger = importera.las_step_med_namn(p)
        self.assertEqual(farger[0], "#FF0000")


if __name__ == "__main__":
    unittest.main()
