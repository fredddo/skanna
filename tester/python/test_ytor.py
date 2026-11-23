"""cad/ytor.py + cad/projekt.py: delar.json (skript, bambu med filament, föräldrar) och ytor-filerna."""
import json
import unittest

from hjalp import kopia, stada

import ytor


class Delar(unittest.TestCase):
    def setUp(self):
        self.t, self.p = kopia()
        self.cad = self.p / "cad"

    def tearDown(self):
        stada(self.t)

    def test_bygget_skriver_skript_och_forelder(self):
        d = {x["id"]: x for x in json.loads((self.cad / "delar.json").read_text())["delar"]}
        self.assertEqual(set(d), {"lada", "lock", "insats", "fotter"})
        self.assertEqual(d["lada"]["skript"], "10-lada.py")
        self.assertEqual(d["fotter"]["skript"], "20-fotter.py")
        self.assertEqual(d["insats"]["foralder"], "lada")
        self.assertIsNone(d["insats"]["export"])
        self.assertEqual(d["lada"]["bambu"], {"wall_loops": "3", "plast": "PETG"})

    def test_flera_kroppar(self):
        k = json.loads((self.cad / "fotter-ytor.json").read_text())["kroppar"]
        self.assertEqual(len(k), 4)

    def test_register_part_behaller_filament_dict(self):
        ytor.register_part(self.cad, "ny", "Ny", "ny-ytor.json", "design", "#000000",
                           bambu={"wall_loops": 2, "filament": {"nozzle_temperature": 240}}, skript="30-ny.py")
        d = {x["id"]: x for x in json.loads((self.cad / "delar.json").read_text())["delar"]}
        self.assertEqual(d["ny"]["bambu"], {"wall_loops": "2", "filament": {"nozzle_temperature": "240"}})
        self.assertEqual(d["ny"]["skript"], "30-ny.py")

    def test_geometri_har_parametrar(self):
        g = json.loads((self.cad / "geometri.json").read_text())
        namn = {p["namn"]: p for p in g["parametrar"]}
        self.assertEqual(namn["Låda: längd"]["varde"], 60.0)


if __name__ == "__main__":
    unittest.main()
