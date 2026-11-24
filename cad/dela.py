"""Dela en modell som en hemlig länk till webbvisaren (se PLAN-webbvisare.md).

  dela.py <projekt> [--med skanning,<delid>] [--fran Namn] [--mapp DIR] [--bas-url URL]   # ny delning
  dela.py --aterkalla <id> <projekt> [--mapp DIR]                                          # sluta dela
  dela.py --ta-emot <svarslänk> <projekt>                                                  # kommentarer ur en svarslänk
  dela.py --hamta <projekt>                                                                # kommentarer ur brevlådan
  dela.py --publicera [--mapp DIR]          # git add/commit/push i delat-mappen – bara när användaren sagt ja

Paketet (JSON → gzip) krypteras med SKD1: "SKD1" | iv (16) | AES-256-CBC/PKCS#7 | HMAC-SHA-256 (32), kryptera-sedan-MAC.
  k_enc = SHA-256(nyckel ‖ "skanna-enc"), k_mac = SHA-256(nyckel ‖ "skanna-mac"),
  mac = HMAC-SHA-256(k_mac, "SKD1" ‖ iv ‖ chiffertext) – kontrolleras före avkryptering.
AES körs med systemets openssl-kommando (/usr/bin/openssl i första hand), HMAC i Python. Nyckeln står bara i länkens
#-del och i projektets cad/delningar.json.

Mappar och inställningar:
  delat-mappen: --mapp, annars $SKANNA_DELAT, annars "mapp" i inställningarna, annars <Skanna-hem>/delat/.
    <delat>/d/<id>.skd   – krypterade paket;  <delat>/visare/ – kopia av webb/visare/ (samma för alla delningar).
  inställningar: $SKANNA_DELNING_INST, annars ~/.config/skanna/delning.json:
    {"mapp": "…", "bas_url": "https://…/",       # adressen där delat-mappen publiceras (länk = bas_url/visare/#d=…&k=…)
     "brevlada_url": "https://…", "brevlada_hemlig": "…", "fran": "Namn"}

Rå skanningsdata och nätdelar (.stl/.obj/.3mf) tas bara med när de står i `med`. Inga sökvägar, skript, mått eller
foton följer med. Alla skrivningar i projektets cad/ går via lagring (atomiskt, under skrivläset).
"""
import argparse
import base64
import copy
import gzip
import hashlib
import hmac
import json
import math
import os
import secrets
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from xml.etree import ElementTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lagring  # noqa: E402

HEM = Path(os.environ.get("SKANNA_HEM") or Path(__file__).resolve().parent.parent)
MAGI = b"SKD1"
NATANDELSER = (".stl", ".obj", ".3mf")
MAX_TRIANGLAR = 200_000
SKANNING_FARG = "#9AA4AE"
NAT_FARG = "#9AA4AE"


class DelaFel(ValueError):
    """Fel som ska visas för användaren. kod = HTTP-kod i motorn."""

    def __init__(self, text, kod=400):
        super().__init__(text)
        self.kod = kod


# ---- hjälp ---------------------------------------------------------------------------------------------------------
def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def fran_b64u(s):
    s = s.strip()
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def installningar():
    """Inställningarna ({} om filen saknas). Skrivs aldrig av dela.py."""
    f = Path(os.environ.get("SKANNA_DELNING_INST") or Path.home() / ".config" / "skanna" / "delning.json")
    d = lagring.las_json(f.expanduser(), {})
    return d if isinstance(d, dict) else {}


def delat_mapp(mapp=None):
    m = mapp or os.environ.get("SKANNA_DELAT") or installningar().get("mapp") or HEM / "delat"
    return Path(m).expanduser().resolve()


def visare_kalla():
    return Path(os.environ.get("SKANNA_VISARE") or HEM / "webb" / "visare")


def _projekt(projekt):
    p = Path(projekt).expanduser().resolve()
    if not (p / "cad").is_dir():
        raise DelaFel(f"inget projekt (cad/ saknas): {p.name}", 404)
    return p


# ---- kryptering ----------------------------------------------------------------------------------------------------
def _openssl():
    if os.access("/usr/bin/openssl", os.X_OK):
        return "/usr/bin/openssl"
    o = shutil.which("openssl")
    if not o:
        raise DelaFel("openssl-kommandot saknas", 500)
    return o


def _nycklar(nyckel):
    if not isinstance(nyckel, (bytes, bytearray)) or not nyckel:
        raise DelaFel("nyckeln ska vara bytes")
    return hashlib.sha256(bytes(nyckel) + b"skanna-enc").digest(), hashlib.sha256(bytes(nyckel) + b"skanna-mac").digest()


def _aes(data, k, iv, avkryptera=False):
    r = subprocess.run([_openssl(), "enc", "-aes-256-cbc", *(["-d"] if avkryptera else []), "-K", k.hex(), "-iv", iv.hex()],
                       input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        raise DelaFel(f"openssl misslyckades: {r.stderr.decode('utf-8', 'replace').strip()[:200]}", 500)
    return r.stdout


def kryptera(data: bytes, nyckel: bytes) -> bytes:
    k_enc, k_mac = _nycklar(nyckel)
    iv = secrets.token_bytes(16)
    ct = _aes(data, k_enc, iv)
    return MAGI + iv + ct + hmac.new(k_mac, MAGI + iv + ct, hashlib.sha256).digest()


def dekryptera(blob: bytes, nyckel: bytes) -> bytes:
    k_enc, k_mac = _nycklar(nyckel)
    if len(blob) < 4 + 16 + 16 + 32 or blob[:4] != MAGI or (len(blob) - 52) % 16:
        raise DelaFel("inte ett SKD1-paket")
    iv, ct, mac = blob[4:20], blob[20:-32], blob[-32:]
    if not hmac.compare_digest(mac, hmac.new(k_mac, blob[:-32], hashlib.sha256).digest()):
        raise DelaFel("fel nyckel eller ändrad fil")
    return _aes(ct, k_enc, iv, avkryptera=True)


# ---- nät -----------------------------------------------------------------------------------------------------------
def _las_stl(f):
    b = f.read_bytes()
    if len(b) >= 84:
        n = int.from_bytes(b[80:84], "little")
        if 84 + 50 * n == len(b):
            import struct
            v = []
            for i in range(n):
                v.extend(struct.unpack_from("<9f", b, 84 + 50 * i + 12))
            return v, list(range(3 * n))
    v = []
    for rad in b.decode("utf-8", "replace").splitlines():
        s = rad.split()
        if len(s) == 4 and s[0] == "vertex":
            v.extend(float(x) for x in s[1:])
    return v, list(range(len(v) // 3))


def _las_obj(f):
    v, t = [], []
    with open(f, encoding="utf-8", errors="replace") as fh:
        for rad in fh:
            if rad.startswith("v "):
                s = rad.split()
                v.extend((float(s[1]), float(s[2]), float(s[3])))
            elif rad.startswith("f "):
                n = len(v) // 3
                idx = []
                for x in rad.split()[1:]:
                    i = int(x.split("/")[0])
                    idx.append(i - 1 if i > 0 else n + i)
                for k in range(1, len(idx) - 1):
                    t.extend((idx[0], idx[k], idx[k + 1]))
    return v, t


def _las_3mf(f):
    """Alla <mesh> i 3MF-filens modeller (utan byggtransformer – räcker för appens egna exportfiler)."""
    v, t = [], []
    with zipfile.ZipFile(f) as z:
        for namn in z.namelist():
            if not namn.lower().endswith(".model"):
                continue
            rot = ElementTree.fromstring(z.read(namn))
            for mesh in rot.iter():
                if not mesh.tag.endswith("}mesh") and mesh.tag != "mesh":
                    continue
                bas = len(v) // 3
                for e in mesh.iter():
                    tag = e.tag.rsplit("}", 1)[-1]
                    if tag == "vertex":
                        v.extend((float(e.get("x")), float(e.get("y")), float(e.get("z"))))
                    elif tag == "triangle":
                        t.extend((bas + int(e.get("v1")), bas + int(e.get("v2")), bas + int(e.get("v3"))))
    return v, t


def _sla_ihop(v, t, cell=None):
    """Slå ihop hörn (exakt lika, eller i samma ruta om cell anges), ta bort urartade och dubblerade trianglar."""
    nya, index, medel = {}, [], []
    for i in range(0, len(v), 3):
        x, y, z = v[i], v[i + 1], v[i + 2]
        k = (x, y, z) if cell is None else (math.floor(x / cell), math.floor(y / cell), math.floor(z / cell))
        j = nya.get(k)
        if j is None:
            j = nya[k] = len(medel)
            medel.append([0.0, 0.0, 0.0, 0])
        m = medel[j]
        m[0] += x; m[1] += y; m[2] += z; m[3] += 1
        index.append(j)
    ut_v = [round(m[a] / m[3], 4) for m in medel for a in range(3)]
    ut_t, sett = [], set()
    for i in range(0, len(t) - 2, 3):
        a, b, c = index[t[i]], index[t[i + 1]], index[t[i + 2]]
        if a == b or b == c or a == c:
            continue
        k = tuple(sorted((a, b, c)))
        if k in sett:
            continue
        sett.add(k)
        ut_t.extend((a, b, c))
    return ut_v, ut_t


def las_nat(f, max_triangalar=MAX_TRIANGLAR):
    """{"v": [...], "t": [...]} ur en .stl/.obj/.3mf; förenklas (rutnätsklustring) till högst max_triangalar."""
    f = Path(f)
    ext = f.suffix.lower()
    v, t = {".stl": _las_stl, ".obj": _las_obj, ".3mf": _las_3mf}[ext](f)
    if not t:
        raise DelaFel(f"{f.name} innehåller inga trianglar")
    v, t = _sla_ihop(v, t)
    if len(t) // 3 > max_triangalar:
        xs, ys, zs = v[0::3], v[1::3], v[2::3]
        storst = max(max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs)) or 1.0
        upplosning = math.sqrt(max_triangalar / 2)
        ov, ot = v, t
        while len(t) // 3 > max_triangalar:
            v, t = _sla_ihop(ov, ot, cell=storst / upplosning)
            upplosning *= 0.85
    return {"v": v, "t": t}


# ---- paketet -------------------------------------------------------------------------------------------------------
def _projektnamn(p):
    try:
        d = lagring.las_json(p / "projekt.json", {}) or {}
    except lagring.Trasig:
        d = {}
    n = d.get("namn") if isinstance(d, dict) else None
    return n if isinstance(n, str) and n.strip() else p.name


def _skanning(p):
    f = p / "modell" / "modell-mm.obj"
    return f if f.is_file() else None


def packa(projekt, med=(), fran=None) -> dict:
    """Paketets JSON (version 1) – CAD-delar alltid, nätdelar och skanningen bara om de står i med."""
    p = _projekt(projekt)
    cad = p / "cad"
    med = [m for m in (med or ()) if m]
    delar_fil = lagring.las_json(cad / "delar.json", {"delar": []}) or {}
    poster = [d for d in delar_fil.get("delar", []) if isinstance(d, dict) and isinstance(d.get("id"), str)]
    try:
        obj = lagring.las_json(cad / "objekt.json", {}) or {}
    except lagring.Trasig:
        obj = {}
    obj = obj if isinstance(obj, dict) else {}
    dolda = set(x for x in obj.get("dolda") or [] if isinstance(x, str))
    borttagna = set(x for x in obj.get("borttagna") or [] if isinstance(x, str))
    egna = {k: v for k, v in (obj.get("namn") or {}).items() if isinstance(v, str) and v.strip()}
    ordning = [x for x in obj.get("ordning") or [] if isinstance(x, str)]

    kanda = {d["id"] for d in poster} | {"skanning"}
    okanda = [m for m in med if m not in kanda]
    if okanda:
        raise DelaFel(f"okänd del i med: {', '.join(okanda)}")

    ut = []
    for d in poster:
        if d["id"] in borttagna:
            continue
        fil = d.get("fil") if isinstance(d.get("fil"), str) else ""
        ext = Path(fil).suffix.lower()
        post = {"id": d["id"], "namn": d.get("namn") or d["id"], "farg": d.get("farg"),
                "foralder": d.get("foralder") or None, "roll": d.get("roll") or "del"}
        if isinstance(d.get("beskrivning"), str) and d["beskrivning"]:
            post["beskrivning"] = d["beskrivning"]
        if ext == ".json":
            f = cad / Path(fil).name
            if not f.is_file():
                continue
            ytor = lagring.las_json(f, {}) or {}
            for k in ("ytor", "kanter", "kroppar"):
                post[k] = copy.deepcopy(ytor.get(k) or [])
        elif ext in NATANDELSER:
            if d["id"] not in med:
                continue
            f = cad / Path(fil).name
            if not f.is_file():
                raise DelaFel(f"nätfilen för {post['namn']} saknas")
            post["nat"] = las_nat(f)
            post["farg"] = post["farg"] or NAT_FARG
        else:
            continue
        ut.append(post)
    if "skanning" in med:
        f = _skanning(p)
        if f is None:
            raise DelaFel("projektet har ingen skalad skanning (modell/modell-mm.obj)")
        ut.append({"id": "skanning", "namn": "Skanning", "farg": SKANNING_FARG, "foralder": None, "roll": "skanning",
                   "nat": las_nat(f)})

    ids = {d["id"] for d in ut}
    rang = {x: i for i, x in reversed(list(enumerate(ordning)))}
    ut = [d for _, d in sorted(enumerate(ut), key=lambda e: (rang.get(e[1]["id"], 100_000 + e[0]), e[0]))]
    for d in ut:
        if d["id"] in egna:
            d["namn"] = egna[d["id"]]
        if d.get("foralder") not in ids:
            d["foralder"] = None
        d["dold"] = d["id"] in dolda
    return {"version": 1, "namn": _projektnamn(p), "skapad": lagring.ny_tid(), "enhet": "mm",
            "fran": fran if isinstance(fran, str) and fran.strip() else None, "brevlada": None, "delar": ut}


def _kodat(paket):
    return gzip.compress(json.dumps(paket, ensure_ascii=False, separators=(",", ":")).encode("utf-8"), mtime=0)


def _kopiera_visare(delat):
    kalla = visare_kalla()
    if not kalla.is_dir():
        return False
    mal = delat / "visare"
    tmp = delat / ".visare.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.copytree(kalla, tmp, ignore=shutil.ignore_patterns(".*", "__pycache__", "test"))
    shutil.rmtree(mal, ignore_errors=True)
    os.replace(tmp, mal)
    return True


def _skriv_atomiskt(f, data):
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(f".{f.name}.{secrets.token_hex(4)}.tmp")
    tmp.write_bytes(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, f)


def lank_for(bas_url, id, nyckel):
    """Länken till visaren. bas_url = adressen där delat-mappen ligger; None → relativ länk inom delat-mappen."""
    frag = f"#d={id}&k={nyckel}"
    return (bas_url.rstrip("/") + "/visare/" if bas_url else "visare/") + frag


# ---- brevlådan (klient) --------------------------------------------------------------------------------------------
def _brevlada_anrop(metod, url, hemlig, timeout=15):
    req = urllib.request.Request(url, method=metod, data=b"" if metod == "PUT" else None,
                                 headers={"X-Brevlada-Hemlig": hemlig, "User-Agent": "Skanna"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            return r.status, body
    except urllib.error.HTTPError as e:
        with e:
            return e.code, e.read()
    except (urllib.error.URLError, OSError) as e:
        raise DelaFel(f"brevlådan svarar inte: {getattr(e, 'reason', e)}", 502)


def _oppna_brevlada(id, inst):
    url, hemlig = inst.get("brevlada_url"), inst.get("brevlada_hemlig")
    if not url or not hemlig:
        return None
    adress = url.rstrip("/") + "/b/" + id
    kod, body = _brevlada_anrop("PUT", adress, hemlig)
    if kod not in (200, 201, 204):
        raise DelaFel(f"brevlådan svarade {kod} när lådan skulle öppnas", 502)
    return adress


# ---- delningar -----------------------------------------------------------------------------------------------------
def dela(projekt, delat_mapp_=None, bas_url=None, med=(), fran=None) -> dict:
    """Ny delning → {"id", "nyckel", "fil", "lank", "brevlada"}. Skriver <delat>/d/<id>.skd, kopierar visaren och
    lägger en post i <projekt>/cad/delningar.json."""
    p = _projekt(projekt)
    inst = installningar()
    delat = delat_mapp(delat_mapp_)
    fran = fran if fran is not None else inst.get("fran")
    paket = packa(p, med, fran)
    id = b64u(secrets.token_bytes(16))
    nyckel_b = secrets.token_bytes(32)
    nyckel = b64u(nyckel_b)
    paket["brevlada"] = _oppna_brevlada(id, inst)
    blob = kryptera(_kodat(paket), nyckel_b)
    fil = delat / "d" / f"{id}.skd"
    _skriv_atomiskt(fil, blob)
    _kopiera_visare(delat)
    lank = lank_for(bas_url if bas_url is not None else inst.get("bas_url"), id, nyckel)
    post = {"id": id, "nyckel": nyckel, "tid": None, "lank": lank, "med": list(med or ()),
            "fran": paket["fran"], "brevlada": paket["brevlada"], "aterkallad": None}

    def andra(d):
        if not isinstance(d, dict) or not isinstance(d.get("delningar", []), list):
            raise lagring.Trasig("delningar.json har fel form")
        lista = d.setdefault("delningar", [])
        post["tid"] = lagring.ny_tid([x.get("tid") for x in lista if isinstance(x, dict)])
        lista.append(post)

    lagring.uppdatera_json(p / "cad" / "delningar.json", andra, {"delningar": []})
    return {"id": id, "nyckel": nyckel, "fil": str(fil), "lank": lank, "brevlada": paket["brevlada"]}


def delningar(projekt):
    p = _projekt(projekt)
    d = lagring.las_json(p / "cad" / "delningar.json", {"delningar": []}) or {}
    return [x for x in d.get("delningar", []) if isinstance(x, dict) and isinstance(x.get("id"), str)]


def aterkalla(projekt, delat_mapp_=None, id=None) -> dict:
    """Sluta dela: tar bort d/<id>.skd, stänger brevlådan och markerar posten (aterkallad = tid)."""
    p = _projekt(projekt)
    if not isinstance(id, str) or not id or "/" in id or id.startswith("."):
        raise DelaFel("ogiltigt id")
    post = next((x for x in delningar(p) if x["id"] == id), None)
    if post is None:
        raise DelaFel(f"delningen {id} finns inte i projektet", 404)
    fil = delat_mapp(delat_mapp_) / "d" / f"{id}.skd"
    try:
        fil.unlink()
    except FileNotFoundError:
        pass
    varning = None
    inst = installningar()
    if post.get("brevlada") and inst.get("brevlada_hemlig"):
        try:
            kod, _ = _brevlada_anrop("DELETE", post["brevlada"], inst["brevlada_hemlig"])
            if kod not in (200, 204, 404):
                varning = f"brevlådan svarade {kod} när lådan skulle tas bort"
        except DelaFel as e:
            varning = str(e)
    ut = {}

    def andra(d):
        for x in d.get("delningar", []):
            if isinstance(x, dict) and x.get("id") == id:
                x["aterkallad"] = x.get("aterkallad") or lagring.ny_tid()
                ut["post"] = x

    lagring.uppdatera_json(p / "cad" / "delningar.json", andra, {"delningar": []})
    return {"id": id, "aterkallad": ut["post"]["aterkallad"], "varning": varning}


# ---- kommentarer ---------------------------------------------------------------------------------------------------
def _rensa_kommentar(k):
    """Bara kända fält med rätt typ (kommentarer kommer från okända besökare)."""
    if not isinstance(k, dict) or not isinstance(k.get("text"), str):
        return None
    ut = {"id": k["id"][:100] if isinstance(k.get("id"), str) else None,
          "tid": k["tid"][:40] if isinstance(k.get("tid"), str) else None,
          "text": k["text"][:5000]}
    pkt = k.get("punkt")
    ut["punkt"] = ([float(x) for x in pkt] if isinstance(pkt, list) and len(pkt) == 3
                   and all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in pkt) else None)
    ut["del"] = k["del"][:100] if isinstance(k.get("del"), str) else None
    ut["kropp"] = k["kropp"] if isinstance(k.get("kropp"), int) and not isinstance(k.get("kropp"), bool) else None
    return ut


def _brev_innehall(data):
    """gzip(JSON {"fran", "kommentarer"}) → (fran, [kommentarer])."""
    try:
        d = json.loads(gzip.decompress(data).decode("utf-8"))
    except (OSError, ValueError, EOFError) as e:
        raise DelaFel(f"kommentarerna går inte att läsa: {e}")
    if not isinstance(d, dict) or not isinstance(d.get("kommentarer"), list):
        raise DelaFel("kommentarerna har fel form")
    fran = d.get("fran")[:100] if isinstance(d.get("fran"), str) else None
    return fran, [k for k in map(_rensa_kommentar, d["kommentarer"]) if k]


def las_svarslank(lank) -> dict:
    """Svarslänk (…#d=<id>&k=<nyckel>&c=<base64url(gzip(JSON))>) → {"delning", "nyckel", "fran", "kommentarer"}."""
    if not isinstance(lank, str):
        raise DelaFel("länken saknas")
    frag = lank.split("#", 1)[1] if "#" in lank else lank
    q = {k: v[-1] for k, v in urllib.parse.parse_qs(frag, keep_blank_values=True).items()}
    if not q.get("d") or not q.get("c"):
        raise DelaFel("inte en svarslänk (d= eller c= saknas)")
    try:
        data = fran_b64u(q["c"])
    except ValueError as e:
        raise DelaFel(f"svarslänken är trasig: {e}")
    fran, kommentarer = _brev_innehall(data)
    return {"delning": q["d"], "nyckel": q.get("k"), "fran": fran, "kommentarer": kommentarer}


def _nyckel_kommentar(delning, k):
    if k.get("id"):
        return (delning, "id", k["id"])
    return (delning, "innehall", json.dumps([k.get("tid"), k.get("text"), k.get("punkt"), k.get("del")], ensure_ascii=False))


def _lagg_kommentarer(p, delning, fran, kommentarer):
    """Lägger nya kommentarer i cad/kommentarer.json (dubbletter hoppas över). Returnerar antalet nya."""
    ut = {"nya": 0}

    def andra(d):
        if not isinstance(d, dict) or not isinstance(d.get("kommentarer", []), list):
            raise lagring.Trasig("kommentarer.json har fel form")
        lista = d.setdefault("kommentarer", [])
        sett = {_nyckel_kommentar(x.get("delning"), x) for x in lista if isinstance(x, dict)}
        for k in kommentarer:
            n = _nyckel_kommentar(delning, k)
            if n in sett:
                continue
            sett.add(n)
            lista.append({**k, "delning": delning, "fran": fran,
                          "mottagen": lagring.ny_tid([x.get("mottagen") for x in lista if isinstance(x, dict)])})
            ut["nya"] += 1

    lagring.uppdatera_json(p / "cad" / "kommentarer.json", andra, {"kommentarer": []})
    return ut["nya"]


def ta_emot(projekt, lank) -> dict:
    """Kommentarerna i en svarslänk → cad/kommentarer.json. Länken måste höra till en av projektets delningar."""
    p = _projekt(projekt)
    s = las_svarslank(lank)
    post = next((x for x in delningar(p) if x["id"] == s["delning"]), None)
    if post is None:
        raise DelaFel("svarslänken hör inte till någon delning i det här projektet", 404)
    if s["nyckel"] is not None and s["nyckel"] != post.get("nyckel"):
        raise DelaFel("svarslänkens nyckel stämmer inte med delningen")
    return {"delning": s["delning"], "fran": s["fran"], "nya": _lagg_kommentarer(p, s["delning"], s["fran"], s["kommentarer"])}


def hamta(projekt) -> dict:
    """Hämtar breven i projektets brevlådor (delningar som inte är återkallade), avkrypterar och lägger nya
    kommentarer i cad/kommentarer.json → {"nya": n, "trasiga": n, "fel": [...]}."""
    p = _projekt(projekt)
    hemlig = installningar().get("brevlada_hemlig")
    ut = {"nya": 0, "trasiga": 0, "fel": []}
    for post in delningar(p):
        if not post.get("brevlada") or post.get("aterkallad"):
            continue
        if not hemlig:
            ut["fel"].append("brevlada_hemlig saknas i inställningarna")
            break
        try:
            kod, body = _brevlada_anrop("GET", post["brevlada"], hemlig)
        except DelaFel as e:
            ut["fel"].append(str(e))
            continue
        if kod != 200:
            ut["fel"].append(f"brevlådan för {post['id']} svarade {kod}")
            continue
        try:
            brev = json.loads(body).get("brev") or []
        except (ValueError, AttributeError):
            ut["fel"].append(f"brevlådan för {post['id']} gav ett oläsbart svar")
            continue
        nyckel = fran_b64u(post["nyckel"])
        for b in brev:
            try:
                data = b["data"]
                blob = base64.b64decode(data.replace("-", "+").replace("_", "/") + "=" * (-len(data) % 4))
                fran, kommentarer = _brev_innehall(dekryptera(blob, nyckel))
            except (DelaFel, KeyError, TypeError, ValueError, AttributeError):
                ut["trasiga"] += 1
                continue
            ut["nya"] += _lagg_kommentarer(p, post["id"], fran, kommentarer)
    return ut


def kommentarer(projekt):
    p = _projekt(projekt)
    d = lagring.las_json(p / "cad" / "kommentarer.json", {"kommentarer": []}) or {}
    return [x for x in d.get("kommentarer", []) if isinstance(x, dict)]


# ---- publicering ---------------------------------------------------------------------------------------------------
def publicera(delat_mapp_=None) -> str:
    """git add/commit/push i delat-mappen. Körs bara uttryckligen av användaren – aldrig automatiskt."""
    delat = delat_mapp(delat_mapp_)
    if not (delat / ".git").exists():
        raise DelaFel(f"{delat} är inget git-repo – publicera filerna på annat sätt")

    def git(*a, kontroll=True):
        r = subprocess.run(["git", "-C", str(delat), *a], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if kontroll and r.returncode != 0:
            raise DelaFel(f"git {a[0]} misslyckades: {r.stdout.decode('utf-8', 'replace').strip()[:500]}", 500)
        return r

    git("add", "-A", "--", "d", "visare")
    if git("diff", "--cached", "--quiet", kontroll=False).returncode == 0:
        return "inget nytt att publicera"
    git("commit", "-m", "Uppdatera delningar")
    git("push")
    return "publicerat"


# ---- CLI -----------------------------------------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="Dela en modell som en hemlig länk till webbvisaren.")
    ap.add_argument("projekt", nargs="?")
    ap.add_argument("--med", default="", help="nätdelar/skanning som ska med, kommaseparerat (t.ex. skanning,overdel)")
    ap.add_argument("--fran", help="vem som delar (visas i visaren)")
    ap.add_argument("--mapp", help="delat-mappen")
    ap.add_argument("--bas-url", help="adressen där delat-mappen publiceras")
    ap.add_argument("--aterkalla", metavar="ID")
    ap.add_argument("--ta-emot", metavar="LÄNK")
    ap.add_argument("--hamta", action="store_true", help="hämta kommentarer från brevlådan")
    ap.add_argument("--publicera", action="store_true", help="git add/commit/push i delat-mappen")
    a = ap.parse_args(argv)
    try:
        if a.publicera:
            print(publicera(a.mapp))
            return 0
        if not a.projekt:
            ap.error("projekt saknas")
        if a.aterkalla:
            r = aterkalla(a.projekt, a.mapp, a.aterkalla)
        elif a.ta_emot:
            r = ta_emot(a.projekt, a.ta_emot)
        elif a.hamta:
            r = hamta(a.projekt)
        else:
            r = dela(a.projekt, a.mapp, a.bas_url, [m.strip() for m in a.med.split(",") if m.strip()], a.fran)
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 0
    except (DelaFel, lagring.Trasig) as e:
        print(f"Fel: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
