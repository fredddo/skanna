"""cad/utskrift.py: läsa/skriva utskriftsinställningar, normalisering, filament-dicten och CLI:t."""
import json
import subprocess
import sys
import unittest

from hjalp import HEM, kopia, stada

import utskrift


class Normalisera(unittest.TestCase):
    def test_infill_far_procent(self):
        self.assertEqual(utskrift.normalisera("sparse_infill_density", "25"), "25%")
        self.assertEqual(utskrift.normalisera("sparse_infill_density", "12,5"), "12.5%")
        self.assertEqual(utskrift.normalisera("sparse_infill_density", "30%"), "30%")

    def test_lager_blir_heltal(self):
        self.assertEqual(utskrift.normalisera("wall_loops", "3.6"), "4")
        self.assertEqual(utskrift.normalisera("top_shell_layers", 5), "5")

    def test_support_pa_av(self):
        self.assertEqual(utskrift.normalisera("enable_support", "på"), "1")
        self.assertEqual(utskrift.normalisera("enable_support", False), "0")


class Filament(unittest.TestCase):
    def setUp(self):
        self.t, self.p = kopia()
        self.cad = self.p / "cad"

    def tearDown(self):
        stada(self.t)

    def test_las_skriv_med_filament(self):
        utskrift.skriv(self.cad, {"lada": {"plast": "PETG", "filament": {"nozzle_temperature": 240}}})
        d = utskrift.las(self.cad)
        self.assertEqual(d["lada"]["filament"], {"nozzle_temperature": "240"})
        self.assertEqual(d["lada"]["plast"], "PETG")

    def test_gallande_lyfter_ut_plast_och_filament(self):
        fil = {"lada": {"wall_loops": "4", "filament": {"nozzle_temperature": "240"}}}
        plast, s = utskrift.gallande("lada", {"plast": "PETG", "wall_loops": 3, "filament": {"x": 1}}, fil)
        self.assertEqual(plast, "PETG")
        self.assertEqual(s, {"wall_loops": "4"})               # filament och plast är inte objektinställningar
        f = utskrift.filament_gallande("lada", {"filament": {"nozzle_temperature": 230, "fan_min_speed": 20}}, fil)
        self.assertEqual(f, {"nozzle_temperature": "240", "fan_min_speed": "20"})   # utskrift.json går före skriptet

    def test_cli_satter_och_tar_bort_filament(self):
        py = sys.executable
        subprocess.run([py, str(HEM / "cad/utskrift.py"), str(self.p), "lock", "filament.nozzle_temperature=235",
                        "wall_loops=5"], check=True, capture_output=True)
        d = json.loads((self.cad / "utskrift.json").read_text())["delar"]["lock"]
        self.assertEqual(d["filament"], {"nozzle_temperature": "235"})
        self.assertEqual(d["wall_loops"], "5")
        subprocess.run([py, str(HEM / "cad/utskrift.py"), str(self.p), "lock", "--ta-bort", "filament.nozzle_temperature"],
                       check=True, capture_output=True)
        d = json.loads((self.cad / "utskrift.json").read_text())["delar"]["lock"]
        self.assertNotIn("filament", d)
        self.assertEqual(d["wall_loops"], "5")

    def test_trasig_fil_ger_tomt(self):
        (self.cad / "utskrift.json").write_text("{inte json")
        self.assertEqual(utskrift.las(self.cad), {})


if __name__ == "__main__":
    unittest.main()
