#!/usr/bin/env python3
"""Brevlådan: tar emot krypterade kommentarer från visaren och lämnar ut dem till ägaren (se PLAN-webbvisare.md).

Ren stdlib, Python 3.10+. Körs t.ex. på en Ubuntu-maskin bakom en omvänd tunnel:

    BREVLADA_HEMLIG=… python3 server.py --port 8787 --mapp ./data

Anrop (samma som brevlada/worker.js):
    PUT    /b/<id>  + X-Brevlada-Hemlig   öppnar en låda
    POST   /b/<id>  kropp: SKD1-blob       lägger ett brev (404 om lådan saknas, 429 efter 200 brev)
    GET    /b/<id>  + X-Brevlada-Hemlig   {"brev": [{"tid": "…", "data": "<base64>"}]}
    DELETE /b/<id>  + X-Brevlada-Hemlig   tar bort lådan och breven
    OPTIONS /b/<id>                        CORS för webbläsaren

Tjänsten ser aldrig innehållet (breven är krypterade med delningens nyckel) och loggar aldrig innehåll, id eller
hemlighet. Lagring: <mapp>/<id>/<tid_ns>-<slump>.brev, skrivs atomiskt (temporär fil + os.replace).
"""
import argparse
import base64
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ID_FORM = re.compile(r"^/b/([A-Za-z0-9_-]{22})$")
MAX_KROPP = 64 * 1024          # största brev (byte)
MAX_BREV = 200                 # brev per låda
MAX_LADOR = 1000               # lådor totalt (ändras med --max-lador)
MAX_SAMTIDIGA = 64             # samtidiga anslutningar
TIDSGRANS = 15                 # sekunder per läsning/skrivning på en anslutning
MAGI = b"SKD1"
MIN_HEMLIG = 24


class Fel(Exception):
    def __init__(self, kod, text):
        super().__init__(text)
        self.kod = kod


def _tid_text(ns):
    return datetime.fromtimestamp(ns / 1e9, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Lager:
    """Lådorna som kataloger, breven som filer. Ett lås gör räkning + skrivning till en enhet (en process)."""

    def __init__(self, mapp, max_lador=MAX_LADOR):
        self.mapp = Path(mapp)
        self.mapp.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.mapp, 0o700)
        except OSError:
            pass
        self.max_lador = max_lador
        self.lock = threading.Lock()

    def _lada(self, id):
        return self.mapp / id

    def _brevfiler(self, lada):
        return sorted(f for f in lada.iterdir() if f.is_file() and f.name.endswith(".brev"))

    def oppna(self, id):
        with self.lock:
            lada = self._lada(id)
            if lada.is_dir():
                return False
            antal = sum(1 for d in self.mapp.iterdir() if d.is_dir())
            if antal >= self.max_lador:
                raise Fel(507, "för många brevlådor")
            lada.mkdir(mode=0o700)
            return True

    def lagg(self, id, data):
        with self.lock:
            lada = self._lada(id)
            if not lada.is_dir():
                raise Fel(404, "ingen sådan brevlåda")
            if len(self._brevfiler(lada)) >= MAX_BREV:
                raise Fel(429, "brevlådan är full")
            ns = time.time_ns()
            namn = f"{ns:020d}-{secrets.token_hex(4)}.brev"
            tmp = lada / f".{namn}.tmp"
            with open(tmp, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, lada / namn)
            return _tid_text(ns)

    def hamta(self, id):
        with self.lock:
            lada = self._lada(id)
            if not lada.is_dir():
                raise Fel(404, "ingen sådan brevlåda")
            ut = []
            for f in self._brevfiler(lada):
                try:
                    ns = int(f.name.split("-", 1)[0])
                    data = f.read_bytes()
                except (ValueError, OSError):
                    continue
                ut.append({"tid": _tid_text(ns), "data": base64.b64encode(data).decode("ascii")})
            return ut

    def ta_bort(self, id):
        with self.lock:
            lada = self._lada(id)
            if not lada.is_dir():
                return False
            for f in lada.iterdir():
                try:
                    f.unlink()
                except OSError:
                    pass
            lada.rmdir()
            return True


def gor_handler(lager, hemlig):
    hemlig_b = hemlig.encode("utf-8")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "brevlada"
        sys_version = ""
        timeout = TIDSGRANS

        def log_message(self, *a):
            pass   # inga loggar: varken id, innehåll eller avsändare

        def log_error(self, *a):
            pass

        def _svara(self, kod, data=None, cors=False, stang=False):
            body = b"" if data is None else json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(kod)
            if data is not None:
                self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if cors:
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Access-Control-Max-Age", "86400")
            if stang:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _id(self):
            m = ID_FORM.match(urlparse(self.path).path)
            if not m:
                raise Fel(404, "okänd adress")
            return m.group(1)

        def _krav_hemlig(self):
            given = (self.headers.get("X-Brevlada-Hemlig") or "").encode("utf-8")
            if not hmac.compare_digest(given, hemlig_b):
                raise Fel(401, "fel eller saknad hemlighet")

        def _las_kropp(self):
            """Läser högst MAX_KROPP byte; större (eller okänd längd) avvisas utan att läsas."""
            if self.headers.get("Transfer-Encoding"):
                raise Fel(411, "Content-Length krävs")
            try:
                n = int(self.headers.get("Content-Length", ""))
            except ValueError:
                raise Fel(411, "Content-Length krävs") from None
            if n < 0:
                raise Fel(400, "felaktig Content-Length")
            if n > MAX_KROPP:
                raise Fel(413, "brevet är för stort")
            data = self.rfile.read(n)
            self._last = True
            if len(data) != n:
                raise Fel(400, "kroppen tog slut i förtid")
            return data

        def _olast_kropp(self):
            return not self._last and (self.headers.get("Transfer-Encoding")
                                       or (self.headers.get("Content-Length") or "0").strip() not in ("", "0"))

        def _kor(self, metod, fn, cors=False):
            self._last = False
            try:
                kod, data = fn()
                # en kropp vi inte läst (t.ex. på PUT) skulle förvirra nästa anrop på anslutningen
                self._svara(kod, data, cors=cors, stang=bool(self._olast_kropp()))
            except Fel as e:
                self._svara(e.kod, {"fel": str(e)}, cors=cors, stang=bool(self._olast_kropp()))
            except (TimeoutError, ConnectionError):
                self.close_connection = True
            except Exception:  # noqa: BLE001 – tjänsten ska svara, inte dö (och inte logga innehåll)
                self._svara(500, {"fel": "internt fel"}, cors=cors, stang=True)

        def do_PUT(self):
            def f():
                id = self._id()
                self._krav_hemlig()
                ny = lager.oppna(id)
                return (201 if ny else 200), {"ok": True}
            self._kor("PUT", f)

        def do_POST(self):
            def f():
                id = self._id()
                data = self._las_kropp()
                if not data.startswith(MAGI):
                    raise Fel(400, "brevet ska vara ett SKD1-paket")
                lager.lagg(id, data)
                return 201, {"ok": True}
            self._kor("POST", f, cors=True)

        def do_GET(self):
            def f():
                id = self._id()
                self._krav_hemlig()
                return 200, {"brev": lager.hamta(id)}
            self._kor("GET", f)

        def do_DELETE(self):
            def f():
                id = self._id()
                self._krav_hemlig()
                return 200, {"ok": True, "fanns": lager.ta_bort(id)}
            self._kor("DELETE", f)

        def do_OPTIONS(self):
            def f():
                self._id()
                return 204, None
            self._kor("OPTIONS", f, cors=True)

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, adress, handler, max_samtidiga=MAX_SAMTIDIGA):
        super().__init__(adress, handler)
        self._platser = threading.BoundedSemaphore(max_samtidiga)

    def process_request(self, request, client_address):
        # fler samtidiga anslutningar än gränsen stängs direkt i stället för att få en egen tråd
        if not self._platser.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._platser.release()


def starta(mapp, hemlig, port=8787, vard="127.0.0.1", max_lador=MAX_LADOR):
    if not hemlig or len(hemlig) < MIN_HEMLIG:
        raise ValueError(f"hemligheten måste vara minst {MIN_HEMLIG} tecken")
    return Server((vard, port), gor_handler(Lager(mapp, max_lador), hemlig))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Brevlådan för Skannas delningar (hemligheten i BREVLADA_HEMLIG).")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--mapp", default="./data", help="var breven lagras")
    ap.add_argument("--vard", default="127.0.0.1", help="adress att lyssna på (standard 127.0.0.1, för tunneln)")
    ap.add_argument("--max-lador", type=int, default=MAX_LADOR, help="största antal öppna lådor")
    a = ap.parse_args(argv)
    hemlig = os.environ.get("BREVLADA_HEMLIG", "")
    if len(hemlig) < MIN_HEMLIG:
        print(f"brevlada: BREVLADA_HEMLIG saknas eller är kortare än {MIN_HEMLIG} tecken – startar inte.",
              file=sys.stderr)
        return 2
    srv = starta(a.mapp, hemlig, a.port, a.vard, a.max_lador)
    print(f"brevlada: lyssnar på {a.vard}:{srv.server_address[1]}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
