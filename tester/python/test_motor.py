"""motor/: HTTP-API:t som appen ändrar projektfilerna och bygger genom (se PLAN-motor.md)."""
import base64
import json
import os
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from hjalp import HEM, stada

import sys
sys.path.insert(0, str(HEM))
os.environ["SKANNA_HEM"] = str(HEM)
from motor.server import starta  # noqa: E402

NYCKEL = "test-nyckel"


class Motor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = starta(0, NYCKEL)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.bas = f"http://127.0.0.1:{cls.srv.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="skanna-motor-"))
        self.p = self.t / "Proj"
        (self.p / "cad").mkdir(parents=True)

    def tearDown(self):
        stada(self.t)

    def anrop(self, metod, sokvag, kropp=None, nyckel=NYCKEL, **q):
        url = self.bas + sokvag + ("?" + "&".join(f"{k}={urllib.request.quote(str(v))}" for k, v in q.items()) if q else "")
        req = urllib.request.Request(url, method=metod, data=json.dumps(kropp).encode() if kropp is not None else None,
                                     headers={"X-Skanna-Nyckel": nyckel, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_nyckel_kravs(self):
        self.assertEqual(self.anrop("GET", "/v1/halsa", nyckel="fel")[0], 401)
        self.assertEqual(self.anrop("GET", "/v1/halsa")[0], 200)

    def test_svar_far_unik_tid_och_bevarar_okanda_falt(self):
        f = self.p / "cad" / "svar.json"
        f.write_text(json.dumps({"svar": [{"fraga_id": "meddelande", "fraga": "", "svar": "gammal", "tid": "2099-01-01T00:00:00+01:00",
                                           "framtida_falt": [1, 2]}], "annat": True}))
        tider = set()
        for i in range(5):
            kod, r = self.anrop("POST", "/v1/svar", {"projekt": str(self.p), "post": {"fraga_id": "meddelande", "svar": f"m{i}", "trad": "x"}})
            self.assertEqual(kod, 200, r)
            tider.add(r["post"]["tid"])
        d = json.loads(f.read_text())
        self.assertEqual(len(tider), 5)
        self.assertTrue(d["annat"])
        self.assertEqual(d["svar"][0]["framtida_falt"], [1, 2])
        self.assertEqual([s["svar"] for s in d["svar"]], ["gammal", "m0", "m1", "m2", "m3", "m4"])

    def test_trasig_svar_skrivs_inte_over(self):
        f = self.p / "cad" / "svar.json"
        f.write_text('{"svar": [ {"tid": ')
        kod, r = self.anrop("POST", "/v1/svar", {"projekt": str(self.p), "post": {"fraga_id": "meddelande", "svar": "x"}})
        self.assertEqual(kod, 409)
        self.assertEqual(f.read_text(), '{"svar": [ {"tid": ')

    def test_parameter_satts_och_tas_bort_och_validerar(self):
        f = self.p / "cad" / "parametrar-anvandare.json"
        f.write_text(json.dumps({"Låda: höjd": 30}))
        self.assertEqual(self.anrop("POST", "/v1/parameter", {"projekt": str(self.p), "namn": "Låda: bredd", "varde": -12.5})[0], 200)
        self.assertEqual(self.anrop("POST", "/v1/parameter", {"projekt": str(self.p), "namn": "Låda: bredd", "varde": "3,5"})[0], 400)
        self.assertEqual(json.loads(f.read_text()), {"Låda: höjd": 30, "Låda: bredd": -12.5})
        self.anrop("POST", "/v1/parameter", {"projekt": str(self.p), "namn": "Låda: bredd", "varde": None})
        self.assertEqual(json.loads(f.read_text()), {"Låda: höjd": 30})

    def test_kantbehandling_ersatter_samma_kant(self):
        for m in (1, 2):
            self.anrop("POST", "/v1/kantbehandling", {"projekt": str(self.p), "post": {"del": "lada", "kant": 3, "typ": "fillet", "matt": m}})
        self.anrop("POST", "/v1/kantbehandling", {"projekt": str(self.p), "post": {"del": "lada", "kant": 4, "typ": "fas", "matt": 1}})
        poster = json.loads((self.p / "cad" / "kantbehandling.json").read_text())
        self.assertEqual([(p["kant"], p["matt"]) for p in poster], [(3, 2), (4, 1)])

    def test_json_nyckel_och_fil_bara_tillatna_filer(self):
        u = self.p / "cad" / "utskrift.json"
        u.write_text(json.dumps({"delar": {}, "egen": 1}))
        self.anrop("POST", "/v1/json", {"projekt": str(self.p), "fil": "utskrift.json", "nyckel": "delar", "varde": {"lock": {"plast": "PETG"}}})
        self.assertEqual(json.loads(u.read_text()), {"delar": {"lock": {"plast": "PETG"}}, "egen": 1})
        self.assertEqual(self.anrop("POST", "/v1/fil", {"projekt": str(self.p), "fil": "svar.json", "data": None})[0], 403)
        data = base64.b64encode(json.dumps([{"del": "x"}]).encode()).decode()
        self.anrop("POST", "/v1/fil", {"projekt": str(self.p), "fil": "kantbehandling.json", "data": data})
        self.assertEqual(json.loads((self.p / "cad" / "kantbehandling.json").read_text()), [{"del": "x"}])
        self.anrop("POST", "/v1/fil", {"projekt": str(self.p), "fil": "kantbehandling.json", "data": None})
        self.assertFalse((self.p / "cad" / "kantbehandling.json").exists())

    def test_byggko_slar_ihop_begaranden(self):
        """Tre begäranden medan ett bygge pågår → högst två byggen, och alla begäranden täcks."""
        skript = self.p / "cad" / "skript"
        skript.mkdir()
        (skript / "10-del.py").write_text("import sys, time, pathlib\ntime.sleep(1)\n"
                                         "f = pathlib.Path(sys.argv[1]) / 'antal'\nf.write_text(str(int(f.read_text() if f.exists() else 0) + 1))\n")
        n = [self.anrop("POST", "/v1/bygg", {"projekt": str(self.p)})[1]["begaran"] for _ in range(3)]
        slut = time.time() + 30
        while time.time() < slut:
            s = self.anrop("GET", "/v1/bygg", projekt=str(self.p))[1]
            if s["klar_till"] >= n[-1] and not s["kor"]:
                break
            time.sleep(0.2)
        self.assertGreaterEqual(s["klar_till"], n[-1])
        self.assertEqual(s["kod"], 0, s["logg"])
        self.assertLessEqual(int((self.p / "antal").read_text()), 2)

    def test_vanta_svarar_nar_meddelande_kommer(self):
        f = self.p / "cad" / "svar.json"
        (self.p / "cad" / "claude.json").write_text(json.dumps({"mottaget": "2026-01-01T00:00:00+01:00"}))
        f.write_text(json.dumps({"svar": [{"fraga_id": "meddelande", "fraga": "", "svar": "gammal", "tid": "2025-01-01T00:00:00+01:00"}]}))
        threading.Timer(0.6, lambda: self.anrop("POST", "/v1/svar", {"projekt": str(self.p), "post": {"fraga_id": "meddelande", "svar": "ny"}})).start()
        t0 = time.time()
        kod, r = self.anrop("GET", "/v1/vanta", projekt=str(self.p), sek=10)
        self.assertEqual([s["svar"] for s in r["svar"]], ["ny"])
        self.assertLess(time.time() - t0, 5)


if __name__ == "__main__":
    unittest.main()
