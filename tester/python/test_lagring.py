"""cad/lagring.py: atomisk skrivning, trasiga filer skrivs inte över, lås mellan processer, unika tider."""
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from hjalp import HEM, stada

import lagring


class Lagring(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="skanna-lagring-"))
        (self.t / "cad").mkdir()

    def tearDown(self):
        stada(self.t)

    def test_saknad_fil_ger_standardvarde_som_kopia(self):
        std = {"svar": []}
        v = lagring.las_json(self.t / "cad" / "x.json", std)
        v["svar"].append(1)
        self.assertEqual(std, {"svar": []})

    def test_trasig_fil_skrivs_inte_over(self):
        f = self.t / "cad" / "geometri.json"
        f.write_text('{"parametrar": [')
        with self.assertRaises(lagring.Trasig):
            lagring.uppdatera_json(f, lambda d: d, {})
        self.assertEqual(f.read_text(), '{"parametrar": [')

    def test_atomisk_skrivning_lamnar_inga_tempfiler(self):
        f = self.t / "cad" / "a.json"
        lagring.skriv_json(f, {"å": "ö"})
        self.assertEqual(json.loads(f.read_text(encoding="utf-8")), {"å": "ö"})
        self.assertEqual([p.name for p in (self.t / "cad").iterdir()], ["a.json"])

    def test_samtidiga_processer_tappar_inga_tillagg(self):
        """20 processer lägger till var sin post samtidigt – alla ska finnas kvar."""
        f = self.t / "cad" / "svar.json"
        kod = ("import sys; sys.path.insert(0, %r); import lagring; "
               "lagring.uppdatera_json(sys.argv[1], lambda d: d['svar'].append(sys.argv[2]), {'svar': []})" % str(HEM / "cad"))
        ps = [subprocess.Popen([sys.executable, "-c", kod, str(f), str(i)]) for i in range(20)]
        for p in ps:
            self.assertEqual(p.wait(), 0)
        self.assertEqual(sorted(json.loads(f.read_text())["svar"], key=int), [str(i) for i in range(20)])

    def test_laset_ar_aterintradande_i_samma_trad(self):
        with lagring.las(self.t):
            with lagring.las(self.t):
                lagring.uppdatera_json(self.t / "cad" / "b.json", lambda d: d.update(x=1), {})
        self.assertEqual(json.loads((self.t / "cad" / "b.json").read_text()), {"x": 1})

    def test_unika_tider_och_jamforelse_over_tidszoner(self):
        t1 = lagring.ny_tid()
        t2 = lagring.ny_tid([t1])
        self.assertGreater(lagring.tid_datum(t2), lagring.tid_datum(t1))
        framtid = "2099-01-01T00:00:00+01:00"
        self.assertGreater(lagring.tid_datum(lagring.ny_tid([framtid])), lagring.tid_datum(framtid))
        # sommartid/vintertid: samma ögonblick, olika text
        self.assertEqual(lagring.tid_datum("2026-03-29T03:00:00+02:00"), lagring.tid_datum("2026-03-29T02:00:00+01:00"))
        self.assertLess(lagring.tid_datum("2026-11-24T10:00:00+01:00"), lagring.tid_datum("2026-11-24T10:00:00.500+01:00"))


if __name__ == "__main__":
    unittest.main()
