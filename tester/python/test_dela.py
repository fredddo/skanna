"""cad/dela.py och motorns delningsanrop: paket, kryptering, delningar, kommentarer, brevlådan och /delat/."""
import base64
import gzip
import hashlib
import hmac
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from hjalp import HEM, kopia, stada

import sys
sys.path.insert(0, str(HEM))
os.environ["SKANNA_HEM"] = str(HEM)
import dela  # noqa: E402
import lagring  # noqa: E402
from motor.server import starta  # noqa: E402

NYCKEL = "test-nyckel"
HEMLIG = "brevlada-hemlig-test"


class Miljo:
    """Temporära inställningar, delat-mapp och visarkälla (rör aldrig användarens filer)."""

    def satt_upp(self, inst=None):
        self.m = Path(tempfile.mkdtemp(prefix="skanna-dela-"))
        self.delat = self.m / "delat"
        visare = self.m / "visare-kalla"
        visare.mkdir()
        (visare / "index.html").write_text("<!doctype html><title>Visare</title>")
        (visare / "visare.js").write_text("export const x = 1;\n")
        (visare / ".dold").write_text("ska inte kopieras")
        self.inst = self.m / "delning.json"
        self.inst.write_text(json.dumps(inst or {}))
        self._gamla = {k: os.environ.get(k) for k in ("SKANNA_DELNING_INST", "SKANNA_DELAT", "SKANNA_VISARE")}
        os.environ.update(SKANNA_DELNING_INST=str(self.inst), SKANNA_DELAT=str(self.delat), SKANNA_VISARE=str(visare))

    def riv(self):
        for k, v in self._gamla.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        stada(self.m)


def oppna(blob_fil, nyckel):
    return json.loads(gzip.decompress(dela.dekryptera(Path(blob_fil).read_bytes(), dela.fran_b64u(nyckel))))


def alla_strangar(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for k, v in x.items():
            yield k
            yield from alla_strangar(v)
    elif isinstance(x, list):
        for v in x:
            yield from alla_strangar(v)


class Kryptering(unittest.TestCase):
    def test_runt_och_tillbaka(self):
        n = os.urandom(32)
        for data in (b"", b"a", b"x" * 16, os.urandom(100_000)):
            blob = dela.kryptera(data, n)
            self.assertEqual(blob[:4], b"SKD1")
            self.assertEqual((len(blob) - 52) % 16, 0)
            self.assertEqual(dela.dekryptera(blob, n), data)

    def test_formatet_ar_det_i_planen(self):
        """Oberoende kontroll av mac-regeln: HMAC-SHA-256(SHA-256(nyckel‖"skanna-mac"), "SKD1"‖iv‖chiffertext)."""
        n = os.urandom(32)
        blob = dela.kryptera(b"hej", n)
        k_mac = hashlib.sha256(n + b"skanna-mac").digest()
        self.assertEqual(blob[-32:], hmac.new(k_mac, blob[:-32], hashlib.sha256).digest())
        self.assertEqual(len(blob), 4 + 16 + 16 + 32)

    def test_fel_nyckel_och_andrad_fil_avvisas(self):
        n = os.urandom(32)
        blob = dela.kryptera(b"hemligt innehall" * 10, n)
        with self.assertRaises(dela.DelaFel):
            dela.dekryptera(blob, os.urandom(32))
        for i in (5, 30, len(blob) - 1):
            andrad = bytearray(blob)
            andrad[i] ^= 1
            with self.assertRaises(dela.DelaFel):
                dela.dekryptera(bytes(andrad), n)
        with self.assertRaises(dela.DelaFel):
            dela.dekryptera(b"SKD0" + blob[4:], n)
        with self.assertRaises(dela.DelaFel):
            dela.dekryptera(blob[:-1], n)


class Paket(unittest.TestCase):
    def setUp(self):
        self.env = Miljo()
        self.env.satt_upp({"bas_url": "https://exempel.test/skanna/"})
        self.t, self.p = kopia()
        cad = self.p / "cad"
        # en nätdel (som "Överdel (skanning)") och en skalad skanning
        lagring.uppdatera_json(cad / "delar.json", lambda d: d["delar"].append(
            {"id": "overdel", "namn": "Överdel (skanning)", "fil": "lock.stl", "roll": "referens", "farg": "#AABBCC"}))
        (self.p / "modell").mkdir()
        (self.p / "modell" / "modell-mm.obj").write_text("v 0 0 0\nv 10 0 0\nv 10 10 0\nv 0 10 0\nf 1 2 3 4\n")
        lagring.skriv_json(cad / "objekt.json", {"dolda": ["lock", "skanning"], "ordning": ["lock", "lada"],
                                                 "namn": {"lada": "Min låda"}, "borttagna": ["fotter"]})

    def tearDown(self):
        stada(self.t)
        self.env.riv()

    def test_paketets_innehall(self):
        pk = dela.packa(self.p, fran="Fredrik")
        self.assertEqual((pk["version"], pk["namn"], pk["enhet"], pk["fran"], pk["brevlada"]), (1, "Testlåda", "mm", "Fredrik", None))
        ids = [d["id"] for d in pk["delar"]]
        self.assertEqual(ids, ["lock", "lada", "insats"])           # objekt.json-ordning, nya sist, borttagna ute
        delar = {d["id"]: d for d in pk["delar"]}
        self.assertEqual(delar["lada"]["namn"], "Min låda")
        self.assertTrue(delar["lock"]["dold"])
        self.assertFalse(delar["lada"]["dold"])
        self.assertEqual(delar["insats"]["foralder"], "lada")
        ytor = json.loads((self.p / "cad" / "lada-ytor.json").read_text())
        for k in ("ytor", "kanter", "kroppar"):
            self.assertEqual(delar["lada"][k], ytor[k])
        for d in pk["delar"]:
            self.assertFalse({"fil", "skript", "export", "bambu"} & set(d), d["id"])
            self.assertNotIn("nat", d)

    def test_nat_och_skanning_bara_med_med(self):
        self.assertNotIn("overdel", [d["id"] for d in dela.packa(self.p)["delar"]])
        self.assertNotIn("skanning", [d["id"] for d in dela.packa(self.p)["delar"]])
        pk = dela.packa(self.p, med=["overdel", "skanning"])
        delar = {d["id"]: d for d in pk["delar"]}
        self.assertEqual(len(delar["skanning"]["nat"]["t"]), 6)    # fyrhörning → två trianglar
        self.assertEqual(len(delar["skanning"]["nat"]["v"]), 12)
        self.assertTrue(delar["skanning"]["dold"])
        self.assertGreater(len(delar["overdel"]["nat"]["t"]), 0)
        self.assertNotIn("ytor", delar["overdel"])
        with self.assertRaises(dela.DelaFel):
            dela.packa(self.p, med=["finns-inte"])

    def test_stora_nat_forenklas(self):
        f = self.t / "stor.obj"
        n = 120
        rader = [f"v {i} {j} {(i * j) % 7 * 0.1}" for i in range(n) for j in range(n)]
        rader += [f"f {i * n + j + 1} {i * n + j + 2} {(i + 1) * n + j + 2} {(i + 1) * n + j + 1}"
                  for i in range(n - 1) for j in range(n - 1)]
        f.write_text("\n".join(rader))
        hel = dela.las_nat(f)
        self.assertEqual(len(hel["t"]) // 3, 2 * (n - 1) ** 2)
        liten = dela.las_nat(f, max_triangalar=2000)
        self.assertLessEqual(len(liten["t"]) // 3, 2000)
        self.assertGreater(len(liten["t"]) // 3, 200)

    def test_inga_sokvagar_i_paketet(self):
        pk = dela.packa(self.p, med=["overdel", "skanning"])
        for s in alla_strangar(pk):
            for bit in (str(self.t), str(self.p), str(HEM), "/Users/", "/private/", "/tmp/", ".stl", ".step", "skript"):
                self.assertNotIn(bit, s)

    def test_dela_skriver_paket_visare_och_delningar(self):
        r = dela.dela(self.p, med=["skanning"], fran="Fredrik")
        self.assertEqual(len(r["id"]), 22)
        self.assertEqual(len(r["nyckel"]), 43)
        self.assertEqual(r["lank"], f"https://exempel.test/skanna/visare/#d={r['id']}&k={r['nyckel']}")
        fil = self.env.delat / "d" / f"{r['id']}.skd"
        self.assertEqual(Path(r["fil"]), fil.resolve())
        pk = oppna(fil, r["nyckel"])
        self.assertIn("skanning", [d["id"] for d in pk["delar"]])
        self.assertNotIn("overdel", [d["id"] for d in pk["delar"]])
        self.assertIsNone(pk["brevlada"])
        self.assertIn(b"SKD1", fil.read_bytes()[:4])
        self.assertNotIn(b"lada", fil.read_bytes())
        self.assertTrue((self.env.delat / "visare" / "index.html").is_file())
        self.assertFalse((self.env.delat / "visare" / ".dold").exists())
        d = json.loads((self.p / "cad" / "delningar.json").read_text())["delningar"]
        self.assertEqual(len(d), 1)
        self.assertEqual({k: d[0][k] for k in ("id", "nyckel", "lank", "med", "aterkallad")},
                         {"id": r["id"], "nyckel": r["nyckel"], "lank": r["lank"], "med": ["skanning"], "aterkallad": None})
        self.assertIsNotNone(lagring.tid_datum(d[0]["tid"]))
        r2 = dela.dela(self.p)
        self.assertNotEqual(r2["id"], r["id"])
        self.assertEqual(len(dela.delningar(self.p)), 2)

    def test_utan_visare_inget_fel(self):
        os.environ["SKANNA_VISARE"] = str(self.t / "saknas")
        r = dela.dela(self.p)
        self.assertTrue(Path(r["fil"]).is_file())
        self.assertFalse((self.env.delat / "visare").exists())

    def test_aterkalla(self):
        r = dela.dela(self.p)
        a = dela.aterkalla(self.p, None, r["id"])
        self.assertFalse(Path(r["fil"]).exists())
        post = dela.delningar(self.p)[0]
        self.assertEqual(post["aterkallad"], a["aterkallad"])
        self.assertIsNotNone(lagring.tid_datum(post["aterkallad"]))
        with self.assertRaises(dela.DelaFel):
            dela.aterkalla(self.p, None, "finnsinte")
        with self.assertRaises(dela.DelaFel):
            dela.aterkalla(self.p, None, "../x")

    def test_publicera_lamnar_ingen_historik(self):
        """Publiceringen är en enda commit: en återkallad delning ska inte gå att hämta ur repots historik."""
        import subprocess

        def git(*a, i):
            return subprocess.run(["git", "-C", str(i), *a], check=True, capture_output=True, text=True).stdout.strip()

        fjarr = self.env.m / "fjarr.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(fjarr)], check=True)
        self.env.delat.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.env.delat)], check=True)
        for k, v in (("user.name", "Test"), ("user.email", "test@exempel.test")):
            git("config", k, v, i=self.env.delat)
        git("remote", "add", "origin", str(fjarr), i=self.env.delat)
        r = dela.dela(self.p)
        self.assertEqual(dela.publicera(), "publicerat")
        self.assertIn(f"d/{r['id']}.skd", git("ls-tree", "-r", "--name-only", "main", i=fjarr))
        dela.aterkalla(self.p, None, r["id"])
        self.assertEqual(dela.publicera(), "publicerat")
        self.assertEqual(git("rev-list", "--count", "main", i=fjarr), "1")
        self.assertNotIn(r["id"], git("ls-tree", "-r", "--name-only", "main", i=fjarr))
        self.assertEqual(dela.publicera(), "inget nytt att publicera")
        # utan inställningen publiceras inget av sig självt; med den publicerar dela() och aterkalla() direkt
        r2 = dela.dela(self.p)
        self.assertFalse(r2["publicerad"])
        self.assertNotIn(r2["id"], git("ls-tree", "-r", "--name-only", "main", i=fjarr))
        self.env.inst.write_text(json.dumps({"bas_url": "https://exempel.test/skanna/", "publicera_automatiskt": True}))
        r3 = dela.dela(self.p)
        self.assertTrue(r3["publicerad"])
        self.assertIn(r3["id"], git("ls-tree", "-r", "--name-only", "main", i=fjarr))
        dela.aterkalla(self.p, None, r3["id"])
        self.assertNotIn(r3["id"], git("ls-tree", "-r", "--name-only", "main", i=fjarr))
        self.assertEqual(git("rev-list", "--count", "main", i=fjarr), "1")

    def test_svarslank_till_kommentarer_utan_dubbletter(self):
        r = dela.dela(self.p)
        innehall = {"fran": "Anna", "kommentarer": [
            {"id": "k1", "tid": "2026-11-24T12:00:00.000+01:00", "text": "För tunn vägg", "punkt": [1, 2, 3], "del": "lada", "kropp": 0},
            {"id": "k2", "tid": "2026-11-24T12:01:00.000+01:00", "text": "Bra!", "punkt": None, "del": None, "okant": "x"},
            {"text": 5}]}
        c = dela.b64u(gzip.compress(json.dumps(innehall).encode()))
        lank = r["lank"] + "&c=" + c
        s = dela.las_svarslank(lank)
        self.assertEqual((s["delning"], s["fran"], len(s["kommentarer"])), (r["id"], "Anna", 2))
        self.assertEqual(dela.ta_emot(self.p, lank)["nya"], 2)
        self.assertEqual(dela.ta_emot(self.p, lank)["nya"], 0)
        k = json.loads((self.p / "cad" / "kommentarer.json").read_text())["kommentarer"]
        self.assertEqual([x["text"] for x in k], ["För tunn vägg", "Bra!"])
        self.assertEqual(k[0]["punkt"], [1.0, 2.0, 3.0])
        self.assertEqual((k[0]["delning"], k[0]["fran"]), (r["id"], "Anna"))
        self.assertNotIn("okant", k[1])
        self.assertLess(lagring.tid_datum(k[0]["mottagen"]), lagring.tid_datum(k[1]["mottagen"]))
        # länk till en annan delning eller med fel nyckel avvisas
        with self.assertRaises(dela.DelaFel):
            dela.ta_emot(self.p, f"https://x/visare/#d=AAAAAAAAAAAAAAAAAAAAAA&k=x&c={c}")
        with self.assertRaises(dela.DelaFel):
            dela.ta_emot(self.p, f"https://x/visare/#d={r['id']}&k=fel&c={c}")
        with self.assertRaises(dela.DelaFel):
            dela.las_svarslank(r["lank"])

    def test_cli(self):
        import contextlib
        import io
        ut = io.StringIO()
        with contextlib.redirect_stdout(ut):
            self.assertEqual(dela.main([str(self.p), "--med", "skanning", "--fran", "Fredrik", "--bas-url", "https://a.test"]), 0)
        r = json.loads(ut.getvalue())
        self.assertTrue(r["lank"].startswith("https://a.test/visare/#d="))
        self.assertEqual(oppna(r["fil"], r["nyckel"])["fran"], "Fredrik")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dela.main(["--aterkalla", r["id"], str(self.p)]), 0)
        self.assertFalse(Path(r["fil"]).exists())


class Lattsasbrevlada:
    """Liten brevlåda med samma API som brevlada/ (bara för testerna)."""

    def __init__(self):
        self.lador, self.logg = {}, []
        lada = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _svar(self, kod, data=None):
                body = json.dumps(data).encode() if data is not None else b""
                self.send_response(kod)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _id(self):
                return self.path[len("/b/"):] if self.path.startswith("/b/") else None

            def _hemlig(self):
                return self.headers.get("X-Brevlada-Hemlig") == HEMLIG

            def do_PUT(self):
                lada.logg.append(("PUT", self._id(), self._hemlig()))
                if not self._hemlig():
                    return self._svar(403, {})
                lada.lador.setdefault(self._id(), [])
                self._svar(201, {"ok": True})

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                data = self.rfile.read(n)
                if self._id() not in lada.lador:
                    return self._svar(404, {})
                lada.lador[self._id()].append(data)
                self._svar(200, {"ok": True})

            def do_GET(self):
                lada.logg.append(("GET", self._id(), self._hemlig()))
                if not self._hemlig():
                    return self._svar(403, {})
                if self._id() not in lada.lador:
                    return self._svar(404, {})
                self._svar(200, {"brev": [{"tid": "2026-11-24T12:00:00Z", "data": base64.b64encode(b).decode()}
                                          for b in lada.lador[self._id()]]})

            def do_DELETE(self):
                lada.logg.append(("DELETE", self._id(), self._hemlig()))
                if not self._hemlig():
                    return self._svar(403, {})
                lada.lador.pop(self._id(), None)
                self._svar(204)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"


class Brevlada(unittest.TestCase):
    def setUp(self):
        self.b = Lattsasbrevlada()
        self.env = Miljo()
        self.env.satt_upp({"brevlada_url": self.b.url + "/", "brevlada_hemlig": HEMLIG})
        self.t, self.p = kopia()

    def tearDown(self):
        self.b.srv.shutdown()
        self.b.srv.server_close()
        stada(self.t)
        self.env.riv()

    def posta(self, adress, nyckel, innehall):
        blob = dela.kryptera(gzip.compress(json.dumps(innehall).encode()), dela.fran_b64u(nyckel))
        req = urllib.request.Request(adress, data=blob, method="POST", headers={"Content-Type": "application/octet-stream"})
        with urllib.request.urlopen(req, timeout=10) as r:
            self.assertEqual(r.status, 200)

    def test_oppna_hamta_och_stang(self):
        r = dela.dela(self.p, fran="Fredrik")
        adress = f"{self.b.url}/b/{r['id']}"
        self.assertEqual(r["brevlada"], adress)
        self.assertIn(("PUT", r["id"], True), self.b.logg)
        self.assertEqual(oppna(r["fil"], r["nyckel"])["brevlada"], adress)
        self.assertEqual(dela.delningar(self.p)[0]["brevlada"], adress)

        self.posta(adress, r["nyckel"], {"fran": "Anna", "kommentarer": [{"id": "a1", "text": "Hål här", "punkt": [0, 0, 1]}]})
        self.posta(adress, r["nyckel"], {"fran": "Bo", "kommentarer": [{"id": "b1", "text": "Och här"}, {"id": "b2", "text": "Mer"}]})
        self.b.lador[r["id"]].append(b"SKD1" + os.urandom(80))      # skräp eller fel nyckel → hoppas över
        h = dela.hamta(self.p)
        self.assertEqual((h["nya"], h["trasiga"], h["fel"]), (3, 1, []))
        self.assertEqual(dela.hamta(self.p)["nya"], 0)               # samma brev igen → inga dubbletter
        k = dela.kommentarer(self.p)
        self.assertEqual([(x["fran"], x["text"]) for x in k], [("Anna", "Hål här"), ("Bo", "Och här"), ("Bo", "Mer")])
        self.assertTrue(all(x["delning"] == r["id"] for x in k))

        dela.aterkalla(self.p, None, r["id"])
        self.assertIn(("DELETE", r["id"], True), self.b.logg)
        self.assertNotIn(r["id"], self.b.lador)
        n = len(self.b.logg)
        self.assertEqual(dela.hamta(self.p)["nya"], 0)               # återkallade delningar hämtas inte
        self.assertEqual(len(self.b.logg), n)

    def test_fel_hemlighet_ger_fel(self):
        self.env.inst.write_text(json.dumps({"brevlada_url": self.b.url, "brevlada_hemlig": "fel"}))
        with self.assertRaises(dela.DelaFel):
            dela.dela(self.p)
        self.assertEqual(dela.delningar(self.p), [])


class MotorDela(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = starta(0, NYCKEL)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.port = cls.srv.server_address[1]
        cls.bas = f"http://127.0.0.1:{cls.port}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.env = Miljo()
        self.env.satt_upp({})
        self.t, self.p = kopia()

    def tearDown(self):
        stada(self.t)
        self.env.riv()

    def anrop(self, metod, sokvag, kropp=None, nyckel=NYCKEL, ra=False, **q):
        url = self.bas + sokvag + ("?" + "&".join(f"{k}={urllib.request.quote(str(v))}" for k, v in q.items()) if q else "")
        h = {"Content-Type": "application/json"}
        if nyckel:
            h["X-Skanna-Nyckel"] = nyckel
        req = urllib.request.Request(url, method=metod, data=json.dumps(kropp).encode() if kropp is not None else None, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read()
                return r.status, (r.headers, body) if ra else json.loads(body)
        except urllib.error.HTTPError as e:
            with e:
                body = e.read()
            return e.code, (e.headers, body) if ra else (json.loads(body) if body else {})

    def test_dela_delningar_kommentarer_och_aterkalla(self):
        kod, r = self.anrop("POST", "/v1/dela", {"projekt": str(self.p), "med": [], "fran": "Fredrik"})
        self.assertEqual(kod, 200, r)
        self.assertEqual(r["lokal_lank"], f"http://127.0.0.1:{self.port}/delat/visare/#d={r['id']}&k={r.get('lank').split('&k=')[1]}")
        self.assertEqual(r["lank"], r["lokal_lank"])                  # ingen bas_url inställd → lokal förhandsvisning
        kod, d = self.anrop("GET", "/v1/delningar", projekt=str(self.p))
        self.assertEqual([x["id"] for x in d["delningar"]], [r["id"]])
        self.assertEqual(d["delningar"][0]["lokal_lank"], r["lokal_lank"])

        # paketet och visaren går att hämta utan nyckel
        kod, (h, body) = self.anrop("GET", f"/delat/d/{r['id']}.skd", nyckel=None, ra=True)
        self.assertEqual(kod, 200)
        self.assertEqual(h["Cache-Control"], "no-store")
        self.assertEqual(h["Content-Type"], "application/octet-stream")
        nyckel = r["lank"].split("&k=")[1]
        self.assertEqual(json.loads(gzip.decompress(dela.dekryptera(body, dela.fran_b64u(nyckel))))["fran"], "Fredrik")
        kod, (h, body) = self.anrop("GET", "/delat/visare/", nyckel=None, ra=True)
        self.assertEqual((kod, h["Content-Type"]), (200, "text/html; charset=utf-8"))
        self.assertIn(b"Visare", body)
        kod, (h, _) = self.anrop("GET", "/delat/visare/visare.js", nyckel=None, ra=True)
        self.assertEqual(h["Content-Type"], "text/javascript; charset=utf-8")

        c = dela.b64u(gzip.compress(json.dumps({"fran": "Anna", "kommentarer": [{"id": "x", "text": "Hej"}]}).encode()))
        kod, k = self.anrop("POST", "/v1/kommentarer", {"projekt": str(self.p), "lank": r["lank"] + "&c=" + c})
        self.assertEqual((kod, k["nya"]), (200, 1))
        self.assertEqual(self.anrop("POST", "/v1/kommentarer", {"projekt": str(self.p), "lank": r["lank"] + "&c=" + c})[1]["nya"], 0)
        kod, k = self.anrop("GET", "/v1/kommentarer", projekt=str(self.p))
        self.assertEqual([x["text"] for x in k["kommentarer"]], ["Hej"])
        kod, h = self.anrop("POST", "/v1/kommentarer/hamta", {"projekt": str(self.p)})
        self.assertEqual((kod, h["nya"]), (200, 0))                   # ingen brevlåda inställd

        kod, a = self.anrop("POST", "/v1/dela/aterkalla", {"projekt": str(self.p), "id": r["id"]})
        self.assertEqual(kod, 200, a)
        self.assertEqual(self.anrop("GET", f"/delat/d/{r['id']}.skd", nyckel=None)[0], 404)
        self.assertEqual(self.anrop("POST", "/v1/dela/aterkalla", {"projekt": str(self.p), "id": "finnsinte"})[0], 404)
        self.assertEqual(self.anrop("POST", "/v1/dela", {"projekt": str(self.p), "med": ["finnsinte"]})[0], 400)

    def test_delat_skyddar_mot_utbrytning(self):
        self.env.delat.mkdir(parents=True)
        (self.env.delat / "ok.json").write_text("{}")
        hemligt = self.env.m / "hemligt.txt"
        hemligt.write_text("hemligt")
        (self.env.delat / "lank.txt").symlink_to(hemligt)
        (self.env.delat / ".git").mkdir()
        (self.env.delat / ".git" / "config").write_text("x")
        self.assertEqual(self.anrop("GET", "/delat/ok.json", nyckel=None)[0], 200)
        for s in ("/delat/../hemligt.txt", "/delat/%2e%2e/hemligt.txt", "/delat/d/..%2f..%2fhemligt.txt",
                  "/delat/lank.txt", "/delat/.git/config", "/delat/finns-inte.html"):
            kod, (h, body) = self.anrop("GET", s, nyckel=None, ra=True)
            self.assertEqual(kod, 404, s)
            self.assertNotIn(b"hemligt", body.replace(b"hemligt.txt", b""))
        kod, (h, _) = self.anrop("GET", "/delat", nyckel=None, ra=True)
        self.assertIn(kod, (200, 404))   # urllib följer omdirigeringen till /delat/ (ingen index.html → 404)

    def test_publicera_utan_git_repo_ger_fel(self):
        kod, svar = self.anrop("POST", "/v1/dela/publicera", {})
        self.assertNotEqual(kod, 200)
        self.assertIn("git-repo", json.dumps(svar, ensure_ascii=False))

    def test_ovriga_anrop_kraver_nyckel(self):
        for metod, s, kropp in (("POST", "/v1/dela", {"projekt": str(self.p)}), ("GET", f"/v1/delningar?projekt={self.p}", None),
                                ("POST", "/v1/kommentarer", {"projekt": str(self.p), "lank": "x"}),
                                ("POST", "/v1/kommentarer/hamta", {"projekt": str(self.p)}),
                                ("POST", "/v1/dela/publicera", {}),
                                ("GET", "/v1/halsa", None), ("POST", "/delat/x", {})):
            self.assertEqual(self.anrop(metod, urllib.request.quote(s, safe="/?=&"), kropp, nyckel=None)[0], 401, s)
            self.assertEqual(self.anrop(metod, urllib.request.quote(s, safe="/?=&"), kropp, nyckel="fel")[0], 401, s)
        self.assertFalse((self.p / "cad" / "delningar.json").exists())


if __name__ == "__main__":
    unittest.main()
