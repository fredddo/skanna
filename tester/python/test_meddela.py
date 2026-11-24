"""cad/meddela.py och cad/bevaka.py: chattprotokollet som Claude använder."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from hjalp import HEM, stada

MEDDELA = [sys.executable, str(HEM / "cad" / "meddela.py")]
BEVAKA = [sys.executable, str(HEM / "cad" / "bevaka.py")]


def kor(*a):
    return subprocess.run([*a], capture_output=True, text=True, check=True).stdout


class Meddela(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="skanna-meddela-"))
        self.cad = self.t / "cad"
        self.cad.mkdir()
        (self.cad / "svar.json").write_text(json.dumps({"svar": [
            {"fraga_id": "meddelande", "fraga": "", "svar": "Gör locket tjockare", "tid": "2026-11-24T10:00:00+01:00"},
            {"fraga_id": "parameter", "fraga": "Låda: bredd", "svar": "Låda: bredd = 60", "tid": "2026-11-24T10:05:00+01:00"}]}))

    def tearDown(self):
        stada(self.t)

    def claude(self):
        return json.loads((self.cad / "claude.json").read_text())

    def test_svar_utan_svar_pa_ar_fristaende(self):
        kor(*MEDDELA, str(self.t), "--svar", "Hej!")
        m = self.claude()["meddelanden"][-1]
        self.assertNotIn("svar_pa", m)

    def test_svar_pa_och_unika_tider(self):
        for i in range(5):
            kor(*MEDDELA, str(self.t), "--svar", f"svar {i}", "--svar-pa", "2026-11-24T10:00:00+01:00")
        ms = self.claude()["meddelanden"]
        self.assertEqual(len({m["tid"] for m in ms}), 5)
        self.assertTrue(all(m["svar_pa"] == "2026-11-24T10:00:00+01:00" for m in ms))

    def test_mottaget_och_trad(self):
        kor(*MEDDELA, str(self.t), "--mottaget")
        kor(*MEDDELA, str(self.t), "--trad", "2026-11-24T10:00:00+01:00", "--status", "arbetar", "--titel", "Locket")
        c = self.claude()
        self.assertEqual(c["mottaget"], "2026-11-24T10:05:00+01:00")
        self.assertEqual(c["tradar"]["2026-11-24T10:00:00+01:00"], {"status": "arbetar", "titel": "Locket"})

    def test_samtidiga_svar_tappas_inte(self):
        ps = [subprocess.Popen([*MEDDELA, str(self.t), "--svar", f"s{i}"], stdout=subprocess.DEVNULL) for i in range(10)]
        for p in ps:
            self.assertEqual(p.wait(), 0)
        self.assertEqual(sorted(m["text"] for m in self.claude()["meddelanden"]), sorted(f"s{i}" for i in range(10)))

    def test_bevaka_ser_meddelanden_som_kom_innan_start(self):
        """Ett meddelande som kom medan Claude arbetade (före bevakningen) ska väcka direkt."""
        ut = kor(*BEVAKA, str(self.t), "--sek", "3", "--intervall", "0.2")
        self.assertIn("NYTT:", ut)
        kor(*MEDDELA, str(self.t), "--mottaget")
        ut = kor(*BEVAKA, str(self.t), "--sek", "1", "--intervall", "0.2")
        self.assertEqual(ut.strip(), "timeout")


if __name__ == "__main__":
    unittest.main()
