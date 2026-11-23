"""Importerad STEP med ytor som inte går att triangulera får inte fälla hela bygget."""
import sys, unittest, zipfile, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "cad"))
import ytor, projekt


class TrasigYta:
    def tessellate(self, *a):
        raise AttributeError("'NoneType' object has no attribute 'NbNodes'")
    wrapped = None


class ImportTrasig(unittest.TestCase):
    def test_yta_utan_triangulering_hoppas_over(self):
        self.assertEqual(ytor._tessellera(TrasigYta(), 0.02, 0.15), ([], []))

    def test_reserv_3mf(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a.3mf"
            projekt._skriv_3mf([(0, 0, 0), (1, 0, 0), (0, 1, 0)], [(0, 1, 2)], p)
            with zipfile.ZipFile(p) as z:
                m = z.read("3D/3dmodel.model").decode()
            self.assertIn('unit="millimeter"', m)
            self.assertIn('<triangle v1="0" v2="1" v3="2"/>', m)


if __name__ == "__main__":
    unittest.main()
