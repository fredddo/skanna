"""cad/bambu.py: projekt-3MF för Bambu Studio – mallar, flera plaster, filamentvärden, raderade delar."""
import json
import unittest
import zipfile

from hjalp import kopia, stada

import bambu
import utskrift


def las_3mf(f):
    z = zipfile.ZipFile(f)
    return z, json.loads(z.read("Metadata/project_settings.config")), z.read("Metadata/model_settings.config").decode()


class Mallar(unittest.TestCase):
    def test_tva_plaster_ger_dubbla_filamentlistor(self):
        ref = json.loads(bambu.SKELETT.read_text())
        en = bambu.kombinera([bambu.profil_for("PLA")[0]])
        tva = bambu.kombinera([bambu.profil_for("PLA")[0], bambu.profil_for("PETG")[0]])
        self.assertEqual(len(tva["filament_settings_id"]), 2)
        for k in ("nozzle_temperature", "filament_retraction_length", "filament_self_index"):
            self.assertEqual(len(tva[k]), 2 * len(en[k]), k)
            self.assertEqual(len(tva[k]), len(ref[k]), k)      # skelettet har två filament
        self.assertEqual(len(tva["different_settings_to_system"]), 4)

    def test_satt_filament_ror_bara_sin_plats_och_inte_nil(self):
        inst = bambu.kombinera([bambu.profil_for("PLA")[0], bambu.profil_for("PETG")[0]])
        fore = list(inst["filament_retraction_length"])
        fel = bambu.satt_filament(inst, 1, {"nozzle_temperature": "240", "filament_retraction_length": "0.8",
                                            "retraction_length": "9", "bogus": "1"}, 2)
        self.assertEqual(sorted(fel), ["bogus", "retraction_length"])     # maskinnyckel och okänd nyckel vägras
        per = len(inst["nozzle_temperature"]) // 2
        self.assertEqual(inst["nozzle_temperature"][per:], ["240"] * per)
        self.assertNotIn("240", inst["nozzle_temperature"][:per])          # PLA-platsen orörd
        rl = inst["filament_retraction_length"]
        for j in range(per):
            self.assertEqual(rl[per + j], "nil" if fore[per + j] == "nil" else "0.8")
        self.assertIn("nozzle_temperature", inst["different_settings_to_system"][2])


class Export(unittest.TestCase):
    def setUp(self):
        self.t, self.p = kopia()

    def tearDown(self):
        stada(self.t)

    def test_export_med_plaster_filament_och_raderad_del(self):
        cad = self.p / "cad"
        utskrift.skriv(cad, {"lada": {"plast": "PETG", "filament": {"nozzle_temperature": "238"}},
                             "lock": {"plast": "PLA", "wall_loops": "5"}})
        (cad / "objekt.json").write_text(json.dumps({"borttagna": ["fotter"], "namn": {"lock": "Locket"}}))
        ut = bambu.bygg_3mf(self.p, set(), "PLA", self.t / "ut.3mf")
        z, inst, model = las_3mf(ut)
        self.assertEqual(len(inst["filament_settings_id"]), 2)             # PETG + PLA
        self.assertIn("Låda (PETG)", model)
        self.assertIn("Locket (PLA)", model)                                # användarens namn
        self.assertNotIn("Fötter", model)                                   # raderad i appen
        self.assertNotIn("Insats", model)                                   # underdel utan egen export
        self.assertIn('key="wall_loops" value="5"', model)
        self.assertIn('key="extruder" value="2"', model)
        per = len(inst["nozzle_temperature"]) // 2
        i = next(i for i, x in enumerate(inst["filament_settings_id"]) if "PETG" in x)   # lådans plats (PETG)
        self.assertEqual(inst["nozzle_temperature"][i * per:(i + 1) * per], ["238"] * per)
        self.assertNotIn("238", inst["nozzle_temperature"][(1 - i) * per:(2 - i) * per])
        self.assertIn(f'key="extruder" value="{i + 1}"', model)


class Stodplast(unittest.TestCase):
    def setUp(self):
        self.t, self.p = kopia()

    def tearDown(self):
        stada(self.t)

    def test_pla_stod_under_petg_pa_hjalpmunstycket(self):
        cad = self.p / "cad"
        utskrift.skriv(cad, {"lada": {"plast": "PETG", "enable_support": "1", "stodplast": "PLA"},
                             "lock": {"plast": "PETG"}})
        (cad / "objekt.json").write_text(json.dumps({"borttagna": ["fotter"]}))
        ut = bambu.bygg_3mf(self.p, set(), "PLA", self.t / "ut.3mf")
        z, inst, model = las_3mf(ut)
        ids = inst["filament_settings_id"]
        self.assertEqual(len(ids), 2)                                       # PETG (delarna) + PLA (bara stöd)
        pla = next(i for i, x in enumerate(ids) if "PLA" in x) + 1
        self.assertEqual(inst["filament_map"][pla - 1], "2")                # hjälpmunstycket
        self.assertEqual(inst["filament_map"][2 - pla], "1")
        self.assertEqual(inst["filament_map_mode"], "Manual")
        self.assertIn(f'key="support_interface_filament" value="{pla}"', model)
        self.assertEqual(model.count("support_interface_filament"), 1)      # bara lådan har stödplast
        self.assertIn('key="filament_map_mode" value="Manual"', model)
        self.assertNotIn('key="stodplast"', model)                          # ingen Bambu-nyckel
        self.assertNotIn("(PLA)", model)                                    # inget objekt skrivs i PLA

    def test_stodplast_utan_support_eller_samma_plast_ignoreras(self):
        cad = self.p / "cad"
        utskrift.skriv(cad, {"lada": {"plast": "PETG", "stodplast": "PLA"},
                             "lock": {"plast": "PLA", "enable_support": "1", "stodplast": "PLA"}})
        (cad / "objekt.json").write_text(json.dumps({"borttagna": ["fotter"]}))
        z, inst, model = las_3mf(bambu.bygg_3mf(self.p, set(), "PLA", self.t / "ut.3mf"))
        self.assertNotIn("support_interface_filament", model)
        self.assertEqual(inst["filament_map_mode"], "Auto For Flush")
        self.assertEqual(inst["filament_map"], ["1", "1"])


if __name__ == "__main__":
    unittest.main()
