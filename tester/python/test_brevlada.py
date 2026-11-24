"""brevlada/: mottagaren för kommentarer från webbvisaren (se PLAN-webbvisare.md, "Brevlådan").

Startar brevlada/server.py som egen process på en ledig port på 127.0.0.1 och provar hela API:t. Om node finns provas
också brevlada/worker.js mot ett låtsas-KV (inte mot riktiga Cloudflare).
"""
import base64
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from hjalp import HEM, stada

SERVER = HEM / "brevlada" / "server.py"
WORKER = HEM / "brevlada" / "worker.js"
HEMLIG = "test-hemlighet-som-ar-lang-nog-0123456789"
ID = "AbCdEfGhIjKlMnOpQrSt_-"     # 22 tecken base64url
ID2 = "zzzzzzzzzzzzzzzzzzzzzz"
NODE = next((p for p in ("/opt/homebrew/bin/node", shutil.which("node")) if p and os.path.exists(p)), None)


def ledig_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def starta_server(mapp, hemlig=HEMLIG, *extra):
    port = ledig_port()
    env = dict(os.environ, BREVLADA_HEMLIG=hemlig)
    p = subprocess.Popen([sys.executable, str(SERVER), "--port", str(port), "--mapp", str(mapp), *extra],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    rad = p.stdout.readline()
    if "lyssnar" not in rad:
        p.kill()
        raise RuntimeError(f"brevlådan startade inte: {rad!r} {p.stderr.read()!r}")
    return p, port


class Brevlada(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.t = Path(tempfile.mkdtemp(prefix="skanna-brevlada-"))
        cls.mapp = cls.t / "data"
        cls.proc, cls.port = starta_server(cls.mapp)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            out, err = cls.proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
            out, err = cls.proc.communicate()
        stada(cls.t)
        # inget innehåll, id eller hemlighet får loggas
        for text in (out, err):
            for hemligt in (HEMLIG, ID, "SKD1"):
                assert hemligt not in text, f"loggen innehåller {hemligt!r}"

    def tearDown(self):
        for id in (ID, ID2):
            self.anrop("DELETE", f"/b/{id}", hemlig=HEMLIG)

    def anrop(self, metod, sokvag, kropp=None, hemlig=None, huvuden=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        h = dict(huvuden or {})
        if hemlig is not None:
            h["X-Brevlada-Hemlig"] = hemlig
        if kropp is not None:
            h.setdefault("Content-Type", "application/octet-stream")
        c.request(metod, sokvag, body=kropp, headers=h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, dict(r.getheaders()), (json.loads(data) if data else None)

    def test_hela_flodet(self):
        self.assertEqual(self.anrop("PUT", f"/b/{ID}", hemlig=HEMLIG)[0], 201)
        self.assertEqual(self.anrop("PUT", f"/b/{ID}", hemlig=HEMLIG)[0], 200)   # redan öppen: ingen skada
        brev = [b"SKD1" + bytes([i]) * 40 for i in range(3)]
        for b in brev:
            kod, h, d = self.anrop("POST", f"/b/{ID}", b)
            self.assertEqual(kod, 201, d)
            self.assertEqual(h.get("Access-Control-Allow-Origin"), "*")
        kod, h, d = self.anrop("GET", f"/b/{ID}", hemlig=HEMLIG)
        self.assertEqual(kod, 200)
        self.assertNotIn("Access-Control-Allow-Origin", h)
        self.assertEqual([base64.b64decode(x["data"]) for x in d["brev"]], brev)
        for x in d["brev"]:
            self.assertRegex(x["tid"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
        # andra lådor påverkas inte
        self.assertEqual(self.anrop("PUT", f"/b/{ID2}", hemlig=HEMLIG)[0], 201)
        self.assertEqual(self.anrop("GET", f"/b/{ID2}", hemlig=HEMLIG)[2], {"brev": []})
        # DELETE tar bort lådan och breven
        kod, _, d = self.anrop("DELETE", f"/b/{ID}", hemlig=HEMLIG)
        self.assertEqual((kod, d["fanns"]), (200, True))
        self.assertEqual(self.anrop("GET", f"/b/{ID}", hemlig=HEMLIG)[0], 404)
        self.assertEqual(self.anrop("POST", f"/b/{ID}", b"SKD1xx")[0], 404)
        self.assertFalse((self.mapp / ID).exists())
        self.assertEqual(self.anrop("DELETE", f"/b/{ID}", hemlig=HEMLIG)[2]["fanns"], False)

    def test_hemligheten_kravs(self):
        for hemlig in (None, "", "fel", HEMLIG + "x", HEMLIG[:-1]):
            for metod in ("PUT", "GET", "DELETE"):
                self.assertEqual(self.anrop(metod, f"/b/{ID}", hemlig=hemlig)[0], 401, (metod, hemlig))
        self.assertFalse((self.mapp / ID).exists())
        # POST kräver ingen hemlighet men lådan måste finnas
        self.assertEqual(self.anrop("POST", f"/b/{ID}", b"SKD1abc")[0], 404)

    def test_okand_lada(self):
        self.assertEqual(self.anrop("GET", f"/b/{ID}", hemlig=HEMLIG)[0], 404)
        kod, h, _ = self.anrop("POST", f"/b/{ID}", b"SKD1abc")
        self.assertEqual(kod, 404)
        self.assertEqual(h.get("Access-Control-Allow-Origin"), "*")

    def test_fel_id_form(self):
        for sokvag in ("/b/kort", f"/b/{ID}x", f"/b/{ID[:-1]}=", "/b/AbCdEfGhIjKlMnOpQrSt.-", "/b/../../etc/passwd",
                       f"/x/{ID}", f"/b/{ID}/", "/", f"/b/%2E%2E{ID[4:]}"):
            for metod, kropp in (("PUT", None), ("GET", None), ("DELETE", None), ("POST", b"SKD1a")):
                self.assertEqual(self.anrop(metod, sokvag, kropp, hemlig=HEMLIG)[0], 404, (metod, sokvag))
        self.assertEqual(list(self.mapp.iterdir()), [])

    def test_kroppen_kontrolleras(self):
        self.anrop("PUT", f"/b/{ID}", hemlig=HEMLIG)
        self.assertEqual(self.anrop("POST", f"/b/{ID}", b"SKD2abc")[0], 400)
        self.assertEqual(self.anrop("POST", f"/b/{ID}", b"")[0], 400)
        # exakt 64 kB går bra, en byte till inte
        self.assertEqual(self.anrop("POST", f"/b/{ID}", b"SKD1" + b"x" * (64 * 1024 - 4))[0], 201)
        self.assertEqual(self.anrop("POST", f"/b/{ID}", b"SKD1" + b"x" * (64 * 1024 - 3))[0], 413)
        self.assertEqual(len(self.anrop("GET", f"/b/{ID}", hemlig=HEMLIG)[2]["brev"]), 1)

    def test_stor_kropp_lases_inte(self):
        """En klient som utlovar en jättekropp får 413 direkt, utan att tjänsten väntar på kroppen."""
        self.anrop("PUT", f"/b/{ID}", hemlig=HEMLIG)
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(f"POST /b/{ID} HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000000\r\n\r\nSKD1".encode())
            svar = s.recv(4096).decode("latin-1")
        self.assertTrue(svar.startswith("HTTP/1.1 413"), svar)
        self.assertIn("Connection: close", svar)
        # utan Content-Length (chunked) avvisas också
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(f"POST /b/{ID} HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nSKD1\r\n0\r\n\r\n".encode())
            svar = s.recv(4096).decode("latin-1")
        self.assertTrue(svar.startswith("HTTP/1.1 411"), svar)

    def test_200_brev_sedan_full(self):
        self.anrop("PUT", f"/b/{ID}", hemlig=HEMLIG)
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)   # en anslutning (keep-alive)
        for i in range(200):
            c.request("POST", f"/b/{ID}", body=b"SKD1" + str(i).encode())
            r = c.getresponse()
            r.read()
            self.assertEqual(r.status, 201, i)
        c.request("POST", f"/b/{ID}", body=b"SKD1sista")
        r = c.getresponse()
        r.read()
        c.close()
        self.assertEqual(r.status, 429)
        d = self.anrop("GET", f"/b/{ID}", hemlig=HEMLIG)[2]
        self.assertEqual([base64.b64decode(x["data"]) for x in d["brev"]], [b"SKD1" + str(i).encode() for i in range(200)])

    def test_cors(self):
        kod, h, d = self.anrop("OPTIONS", f"/b/{ID}", huvuden={"Origin": "https://exempel.se",
                                                                "Access-Control-Request-Method": "POST",
                                                                "Access-Control-Request-Headers": "content-type"})
        self.assertEqual((kod, d), (204, None))
        self.assertEqual(h.get("Access-Control-Allow-Origin"), "*")
        self.assertEqual(h.get("Access-Control-Allow-Methods"), "POST, OPTIONS")
        self.assertEqual(h.get("Access-Control-Allow-Headers"), "Content-Type")
        self.assertNotIn("Access-Control-Allow-Origin", self.anrop("PUT", f"/b/{ID}", hemlig=HEMLIG)[1])

    def test_ingen_aterstod_av_temporara_filer(self):
        self.anrop("PUT", f"/b/{ID}", hemlig=HEMLIG)
        self.anrop("POST", f"/b/{ID}", b"SKD1abc")
        self.assertEqual([f.suffix for f in (self.mapp / ID).iterdir()], [".brev"])


class Start(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="skanna-brevlada-"))

    def tearDown(self):
        stada(self.t)

    def test_vagrar_starta_utan_lang_hemlighet(self):
        for hemlig in (None, "", "x" * 23):
            env = {k: v for k, v in os.environ.items() if k != "BREVLADA_HEMLIG"}
            if hemlig is not None:
                env["BREVLADA_HEMLIG"] = hemlig
            r = subprocess.run([sys.executable, str(SERVER), "--port", str(ledig_port()), "--mapp", str(self.t / "d")],
                               env=env, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("BREVLADA_HEMLIG", r.stderr)

    def test_totalgrans_for_lador(self):
        p, port = starta_server(self.t / "d", HEMLIG, "--max-lador", "2")
        try:
            koder = []
            for id in ("a" * 22, "b" * 22, "c" * 22):
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                c.request("PUT", f"/b/{id}", headers={"X-Brevlada-Hemlig": HEMLIG})
                koder.append(c.getresponse().status)
                c.close()
            self.assertEqual(koder, [201, 201, 507])
        finally:
            p.terminate()
            p.communicate(timeout=10)


NODE_PROV = r"""
import assert from "node:assert/strict";
const worker = (await import(process.argv[2])).default;

class KV {
  constructor() { this.m = new Map(); }
  async get(k, typ) {
    if (!this.m.has(k)) return null;
    const v = this.m.get(k).v;
    if (typ === "arrayBuffer") return v instanceof Uint8Array ? v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength) : new TextEncoder().encode(v).buffer;
    return typeof v === "string" ? v : new TextDecoder().decode(v);
  }
  async put(k, v, opt) {
    if (v instanceof ArrayBuffer) v = new Uint8Array(v);
    else if (ArrayBuffer.isView(v)) v = new Uint8Array(v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength));
    this.m.set(k, { v, metadata: opt && opt.metadata });
  }
  async delete(k) { this.m.delete(k); }
  async list({ prefix = "", cursor, limit = 1000 } = {}) {
    const alla = [...this.m.keys()].filter((k) => k.startsWith(prefix)).sort();
    const start = cursor ? Number(cursor) : 0;
    const keys = alla.slice(start, start + limit).map((name) => ({ name, metadata: this.m.get(name).metadata }));
    const slut = start + limit >= alla.length;
    return { keys, list_complete: slut, cursor: slut ? undefined : String(start + limit) };
  }
}

const HEMLIG = process.argv[3];
const env = { BREV: new KV(), BREVLADA_HEMLIG: HEMLIG, MAX_LADOR: "3" };
const ID = "AbCdEfGhIjKlMnOpQrSt_-";
const bas = "https://brevlada.example";
const go = (metod, sokvag, { kropp, hemlig } = {}) => {
  const h = {};
  if (hemlig !== undefined) h["X-Brevlada-Hemlig"] = hemlig;
  return worker.fetch(new Request(bas + sokvag, { method: metod, headers: h, body: kropp }), env);
};
const skd = (s) => new TextEncoder().encode("SKD1" + s);

// hemligheten
for (const m of ["PUT", "GET", "DELETE"]) {
  for (const h of [undefined, "", "fel", HEMLIG + "x"]) assert.equal((await go(m, "/b/" + ID, { hemlig: h })).status, 401);
}
// okänd låda, fel id-form
assert.equal((await go("GET", "/b/" + ID, { hemlig: HEMLIG })).status, 404);
let r = await go("POST", "/b/" + ID, { kropp: skd("a") });
assert.equal(r.status, 404);
assert.equal(r.headers.get("Access-Control-Allow-Origin"), "*");
for (const s of ["/b/kort", "/b/" + ID + "x", "/b/" + ID + "/", "/x/" + ID, "/"]) {
  assert.equal((await go("PUT", s, { hemlig: HEMLIG })).status, 404, s);
}
// öppna, posta, hämta
assert.equal((await go("PUT", "/b/" + ID, { hemlig: HEMLIG })).status, 201);
assert.equal((await go("PUT", "/b/" + ID, { hemlig: HEMLIG })).status, 200);
assert.equal((await go("POST", "/b/" + ID, { kropp: new TextEncoder().encode("SKD2x") })).status, 400);
assert.equal((await go("POST", "/b/" + ID, { kropp: new Uint8Array(0) })).status, 400);
assert.equal((await go("POST", "/b/" + ID, { kropp: new Uint8Array(64 * 1024 + 1).fill(65) })).status, 413);
const stor = new Uint8Array(64 * 1024).fill(120); stor.set([0x53, 0x4b, 0x44, 0x31]);
assert.equal((await go("POST", "/b/" + ID, { kropp: stor })).status, 201);
for (let i = 1; i < 200; i++) {
  r = await go("POST", "/b/" + ID, { kropp: skd(String(i)) });
  assert.equal(r.status, 201, String(i));
  assert.equal(r.headers.get("Access-Control-Allow-Origin"), "*");
}
assert.equal((await go("POST", "/b/" + ID, { kropp: skd("sista") })).status, 429);
r = await go("GET", "/b/" + ID, { hemlig: HEMLIG });
assert.equal(r.status, 200);
assert.equal(r.headers.get("Access-Control-Allow-Origin"), null);
const d = await r.json();
assert.equal(d.brev.length, 200);
assert.deepEqual(Buffer.from(d.brev[0].data, "base64"), Buffer.from(stor));
assert.equal(Buffer.from(d.brev[199].data, "base64").toString(), "SKD1199");
assert.match(d.brev[0].tid, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
// CORS
r = await go("OPTIONS", "/b/" + ID);
assert.equal(r.status, 204);
assert.equal(r.headers.get("Access-Control-Allow-Origin"), "*");
assert.equal(r.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
assert.equal(r.headers.get("Access-Control-Allow-Headers"), "Content-Type");
// DELETE
r = await go("DELETE", "/b/" + ID, { hemlig: HEMLIG });
assert.equal(r.status, 200);
assert.equal((await r.json()).fanns, true);
assert.equal(env.BREV.m.size, 0);
assert.equal((await go("GET", "/b/" + ID, { hemlig: HEMLIG })).status, 404);
// totalgräns för lådor
for (const [id, kod] of [["a", 201], ["b", 201], ["c", 201], ["d", 507]]) {
  assert.equal((await go("PUT", "/b/" + id.repeat(22), { hemlig: HEMLIG })).status, kod, id);
}
// utan hemlighet i miljön vägrar den
const env2 = { BREV: new KV(), BREVLADA_HEMLIG: "kort" };
assert.equal((await worker.fetch(new Request(bas + "/b/" + ID, { method: "PUT", headers: { "X-Brevlada-Hemlig": "kort" } }), env2)).status, 500);
console.log("ok");
"""


@unittest.skipUnless(NODE, "node saknas")
class Worker(unittest.TestCase):
    def test_worker_mot_latsas_kv(self):
        t = Path(tempfile.mkdtemp(prefix="skanna-brevlada-node-"))
        try:
            shutil.copy(WORKER, t / "worker.mjs")
            (t / "prov.mjs").write_text(NODE_PROV, encoding="utf-8")
            r = subprocess.run([NODE, str(t / "prov.mjs"), (t / "worker.mjs").as_uri(), HEMLIG],
                               capture_output=True, text=True, timeout=120, cwd=t)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(r.stdout.strip(), "ok")
        finally:
            stada(t)


if __name__ == "__main__":
    unittest.main()
