"""Skanna-motorn: lokal HTTP-tjänst som ändrar projektfilerna åt gränssnittet (se PLAN-motor.md).

Ren stdlib. Alla ändringar går via cad/lagring.py (atomiskt, under projektets skrivlås); byggen körs med
bygg_projekt.sh (som själv tar projektets bygglås) i en kö per projekt.
"""
import base64
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HEM = Path(os.environ.get("SKANNA_HEM") or Path(__file__).resolve().parent.parent)
sys.path.insert(0, str(HEM / "cad"))
import lagring  # noqa: E402

VERSION = 1
# filer i cad/ som /v1/fil och /v1/json får skriva (gränssnittets delade filer)
TILLATNA = {"parametrar-anvandare.json", "kantbehandling.json", "utskrift.json"}


class Fel(Exception):
    def __init__(self, kod, text):
        super().__init__(text)
        self.kod = kod


def _projekt(v):
    if not v or not isinstance(v, str):
        raise Fel(400, "projekt saknas")
    p = Path(v).expanduser().resolve()
    if not p.is_dir():
        raise Fel(404, f"projektet finns inte: {p}")
    return p


def _cadfil(p, fil):
    if fil not in TILLATNA:
        raise Fel(403, f"{fil} får inte skrivas via motorn")
    return p / "cad" / fil


def svar_lista(cad):
    """Posterna i svar.json som går att läsa (trasiga poster hoppas över, filen skrivs aldrig om här)."""
    d = lagring.las_json(cad / "svar.json", {"svar": []}) or {}
    return [s for s in d.get("svar", []) if isinstance(s, dict) and isinstance(s.get("tid"), str)]


# ---- byggkö --------------------------------------------------------------------------------------------------------
class Bygge:
    """Ett projekts byggkö. begar() ger ett löpnummer; ett bygge som startar täcker alla begäranden före start."""

    def __init__(self, projekt):
        self.projekt = projekt
        self.lock = threading.Condition()
        self.nasta = 0          # senast utdelade begäran
        self.klar_till = 0      # högsta begäran som ett avslutat bygge täcker
        self.kor = False
        self.kod = None
        self.logg = ""

    def begar(self):
        with self.lock:
            self.nasta += 1
            n = self.nasta
            if not self.kor:
                self.kor = True
                threading.Thread(target=self._loop, daemon=True).start()
            return n

    def _loop(self):
        while True:
            with self.lock:
                till = self.nasta
            kod, logg = self._kor()
            with self.lock:
                self.kod, self.logg, self.klar_till = kod, logg, till
                self.lock.notify_all()
                if self.nasta == till:
                    self.kor = False
                    return

    def _kor(self):
        env = dict(os.environ, SKANNA_HEM=str(HEM), PYTHONUTF8="1")
        env.pop("SKANNA_BYGGLAS", None)
        try:
            r = subprocess.run(["/bin/zsh", str(HEM / "bygg_projekt.sh"), str(self.projekt)], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3600)
            return r.returncode, r.stdout.decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError) as e:
            return 127, f"Kunde inte starta bygget: {e}"

    def status(self):
        with self.lock:
            return {"kor": self.kor, "begaran": self.nasta, "klar_till": self.klar_till, "kod": self.kod, "logg": self.logg}


_byggen = {}
_byggen_lock = threading.Lock()


def bygge(p):
    with _byggen_lock:
        return _byggen.setdefault(str(p), Bygge(p))


# ---- anrop ---------------------------------------------------------------------------------------------------------
def halsa(_q, _b):
    return {"ok": True, "version": VERSION, "hem": str(HEM), "pid": os.getpid()}


def projekt_info(q, _b):
    p = _projekt(q.get("projekt"))
    cad = p / "cad"
    ut = {"projekt": str(p)}
    for namn, fil, std in (("geometri", "geometri.json", None), ("delar", "delar.json", None),
                           ("claude", "claude.json", None), ("projektfil", "../projekt.json", None)):
        try:
            ut[namn] = lagring.las_json(cad / fil, std)
        except lagring.Trasig as e:
            ut[namn] = None
            ut.setdefault("fel", []).append(str(e))
    try:
        ut["svar"] = svar_lista(cad)
    except lagring.Trasig as e:
        ut["svar"] = []
        ut.setdefault("fel", []).append(str(e))
    return ut


def nytt_svar(_q, b):
    p = _projekt(b.get("projekt"))
    post = b.get("post")
    if not isinstance(post, dict) or not isinstance(post.get("svar"), str) or not isinstance(post.get("fraga_id"), str):
        raise Fel(400, "post måste ha fraga_id och svar")
    ut = {}

    def andra(data):
        if not isinstance(data, dict) or not isinstance(data.get("svar", []), list):
            raise lagring.Trasig("svar.json har fel form")
        lista = data.setdefault("svar", [])
        ny = dict(post)
        ny.setdefault("fraga", "")
        ny.setdefault("bilaga", None)
        ny["tid"] = lagring.ny_tid([s.get("tid") for s in lista if isinstance(s, dict)])
        lista.append(ny)
        ut["post"] = ny

    lagring.uppdatera_json(p / "cad" / "svar.json", andra, {"svar": []})
    return ut


def parameter(_q, b):
    p = _projekt(b.get("projekt"))
    namn, varde = b.get("namn"), b.get("varde")
    if not isinstance(namn, str) or not namn:
        raise Fel(400, "namn saknas")
    if varde is not None and (isinstance(varde, bool) or not isinstance(varde, (int, float)) or varde != varde):
        raise Fel(400, f"{varde!r} är inget tal")

    def andra(d):
        if not isinstance(d, dict):
            raise lagring.Trasig("parametrar-anvandare.json har fel form")
        if varde is None:
            d.pop(namn, None)
        else:
            d[namn] = varde

    return {"parametrar": lagring.uppdatera_json(p / "cad" / "parametrar-anvandare.json", andra, {})}


def kantbehandling(_q, b):
    p = _projekt(b.get("projekt"))
    post = b.get("post")
    if not isinstance(post, dict) or "del" not in post or post.get("typ") not in ("fillet", "fas"):
        raise Fel(400, "post måste ha del och typ fillet|fas")

    def andra(lista):
        if not isinstance(lista, list):
            raise lagring.Trasig("kantbehandling.json har fel form")
        lista[:] = [x for x in lista if not (x.get("del") == post.get("del") and x.get("kant") == post.get("kant"))]
        lista.append(post)

    return {"poster": lagring.uppdatera_json(p / "cad" / "kantbehandling.json", andra, [])}


def json_nyckel(_q, b):
    p = _projekt(b.get("projekt"))
    f = _cadfil(p, b.get("fil"))
    nyckel = b.get("nyckel")
    if not isinstance(nyckel, str):
        raise Fel(400, "nyckel saknas")

    def andra(d):
        if not isinstance(d, dict):
            d = {}
        if b.get("varde") is None:
            d.pop(nyckel, None)
        else:
            d[nyckel] = b["varde"]
        return d

    lagring.uppdatera_json(f, andra, {})
    return {"ok": True}


def fil(_q, b):
    p = _projekt(b.get("projekt"))
    f = _cadfil(p, b.get("fil"))
    with lagring.las(p, "skriv"):
        if b.get("data") is None:
            try:
                f.unlink()
            except FileNotFoundError:
                pass
            return {"ok": True}
        try:
            data = json.loads(base64.b64decode(b["data"]).decode("utf-8"))
        except (ValueError, TypeError) as e:
            raise Fel(400, f"data är inte JSON: {e}")
        lagring.skriv_json(f, data)
    return {"ok": True}


def bygg_post(_q, b):
    p = _projekt(b.get("projekt"))
    return {"begaran": bygge(p).begar()}


def bygg_get(q, _b):
    p = _projekt(q.get("projekt"))
    return bygge(p).status()


def vanta(q, _b):
    """Long-poll: användarmeddelanden nyare än `sedan` (eller alla okvitterade om sedan saknas), väntar högst `sek`."""
    p = _projekt(q.get("projekt"))
    sek = min(float(q.get("sek") or 25), 300)
    cad = p / "cad"
    sedan = lagring.tid_datum(q.get("sedan"))
    if sedan is None:
        sedan = lagring.tid_datum((lagring.las_json(cad / "claude.json", {}) or {}).get("mottaget"))
    slut = time.monotonic() + sek
    while True:
        nya = [s for s in svar_lista(cad) if sedan is None or (lagring.tid_datum(s["tid"]) or sedan) > sedan]
        if nya or time.monotonic() >= slut:
            return {"svar": nya}
        time.sleep(0.5)


ROUTES = {
    ("GET", "/v1/halsa"): halsa,
    ("GET", "/v1/projekt"): projekt_info,
    ("POST", "/v1/svar"): nytt_svar,
    ("POST", "/v1/parameter"): parameter,
    ("POST", "/v1/kantbehandling"): kantbehandling,
    ("POST", "/v1/json"): json_nyckel,
    ("POST", "/v1/fil"): fil,
    ("POST", "/v1/bygg"): bygg_post,
    ("GET", "/v1/bygg"): bygg_get,
    ("GET", "/v1/vanta"): vanta,
}


def gor_handler(nyckel):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _svara(self, kod, data):
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(kod)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _hantera(self, metod):
            u = urlparse(self.path)
            try:
                if nyckel and self.headers.get("X-Skanna-Nyckel") != nyckel:
                    raise Fel(401, "fel eller saknad nyckel")
                fn = ROUTES.get((metod, u.path))
                if fn is None:
                    raise Fel(404, f"okänt anrop {metod} {u.path}")
                q = {k: v[-1] for k, v in parse_qs(u.query).items()}
                b = {}
                if metod == "POST":
                    n = int(self.headers.get("Content-Length") or 0)
                    b = json.loads(self.rfile.read(n) or b"{}") if n else {}
                    if not isinstance(b, dict):
                        raise Fel(400, "kroppen ska vara ett JSON-objekt")
                self._svara(200, fn(q, b))
            except Fel as e:
                self._svara(e.kod, {"fel": str(e)})
            except lagring.Trasig as e:
                self._svara(409, {"fel": str(e)})
            except ValueError as e:
                self._svara(400, {"fel": str(e)})
            except Exception as e:  # noqa: BLE001 – motorn ska svara, inte dö
                self._svara(500, {"fel": f"{type(e).__name__}: {e}"})

        def do_GET(self):
            self._hantera("GET")

        def do_POST(self):
            self._hantera("POST")

    return Handler


def starta(port=0, nyckel=None, vard="127.0.0.1"):
    srv = ThreadingHTTPServer((vard, port), gor_handler(nyckel))
    srv.daemon_threads = True
    return srv
