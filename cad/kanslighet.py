"""Känslighet: vad ändras när ett mått ändras? Körs i bakgrunden av appen efter ett bygge: python kanslighet.py <projekt>.

För varje mått i geometri.json (från del-skripten) byggs projektet en gång till i en tillfällig mapp med måttet + delta
(1 mm eller 5°). Ytorna jämförs med nuvarande bygge och resultatet skrivs till <projekt>/cad/visningar/kanslighet.json
(visningar/ hålls utanför projektets git – det är en härledd cache):

    {"stampel": "…", "parametrar": {"Låda: bredd (inv)": {"delta": 1.0, "delar": {"lada": {"ytor": {"12": [0.5, 0, 0], …},
     "max": 0.5, "ny_form": false}, "lock": {…}}}}}

ytor: hur ytans mittpunkt flyttas per enhet av måttet (mm/mm). ny_form: antalet ytor ändrades (t.ex. fler fack).
Projektet rörs inte: skript, json och mått kopieras, och resten länkas läsbart. Samma stämpel → inget görs om.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HEM = Path(os.environ.get("SKANNA_HEM") or Path(__file__).resolve().parent.parent)
PY = HEM / ".venv" / "bin" / "python"
MAX_MATT = 40


def _ytor(path):
    try:
        d = json.loads(Path(path).read_text())
    except Exception:
        return None
    return [{"id": y["id"], "typ": y.get("typ"), "c": y.get("centrum"), "n": y.get("normal"), "a": y.get("area", 0)}
            for y in d.get("ytor", []) if y.get("centrum")]


def _matcha(bas, ny):
    """Para ihop ytor (samma typ, plan: samma normal) girigt efter kortast avstånd mellan mittpunkterna."""
    par = []
    for i, b in enumerate(bas):
        for j, n in enumerate(ny):
            if b["typ"] != n["typ"]:
                continue
            if b["n"] and n["n"] and sum(x * y for x, y in zip(b["n"], n["n"])) < 0.999:
                continue
            d = sum((x - y) ** 2 for x, y in zip(b["c"], n["c"])) ** 0.5
            par.append((d, i, j))
    par.sort()
    tagna_b, tagna_n, ut = set(), set(), {}
    for d, i, j in par:
        if i in tagna_b or j in tagna_n:
            continue
        tagna_b.add(i)
        tagna_n.add(j)
        ut[i] = j
    return ut


def _delta(p):
    e = p.get("enhet") or "mm"
    return 1.0 if e in ("mm", "st") else (5.0 if e == "°" else 1.0)


def _stampel(prj, cad, params, ov):
    h = hashlib.sha256()
    for s in sorted((cad / "skript").glob("*.py")):
        h.update(s.name.encode())
        h.update(s.read_bytes())
    h.update(json.dumps(ov, sort_keys=True).encode())
    h.update(json.dumps([(p["namn"], p.get("varde")) for p in params], sort_keys=True).encode())
    imp = cad / "import"
    if imp.is_dir():
        for f in sorted(imp.iterdir()):
            h.update(f"{f.name}{f.stat().st_size}{f.stat().st_mtime}".encode())
    return h.hexdigest()[:16]


def _kor(prj, cad, skript, ov, p, bas):
    d = _delta(p)
    tmp = Path(tempfile.mkdtemp(prefix="skanna-kanslighet-"))
    try:
        tp = tmp / prj.name
        tp.mkdir()
        for e in prj.iterdir():
            if e.name != "cad" and not e.name.startswith("."):
                (tp / e.name).symlink_to(e)
        tc = tp / "cad"
        tc.mkdir()
        for e in cad.iterdir():
            if e.is_file() and e.suffix == ".json" and not e.name.endswith("-ytor.json"):
                shutil.copy2(e, tc / e.name)
            elif e.name == "skript" and e.is_dir():
                shutil.copytree(e, tc / "skript")
            elif e.name == "import" and e.is_dir():
                (tc / "import").symlink_to(e)
        o = dict(ov)
        o[p["namn"]] = float(p["varde"]) + d
        (tc / "parametrar-anvandare.json").write_text(json.dumps(o, ensure_ascii=False))
        env = dict(os.environ, SKANNA_SNABB="1", SKANNA_HEM=str(HEM))
        for s in skript:
            r = subprocess.run([str(PY), str(tc / "skript" / s.name), str(tp)], env=env, capture_output=True, text=True,
                               timeout=180)
            if r.returncode != 0:
                rad = [x for x in (r.stderr or r.stdout).splitlines() if x.strip()]
                return p["namn"], {"delta": d, "fel": rad[-1] if rad else "bygget misslyckades"}
        delar = {}
        try:
            lista = json.loads((tc / "delar.json").read_text()).get("delar", [])
        except Exception:
            lista = []
        for dl in lista:
            pid = dl["id"]
            if pid not in bas or not (tc / dl["fil"]).exists():
                continue
            ny = _ytor(tc / dl["fil"]) or []
            b = bas[pid]
            m = _matcha(b, ny)
            ytor, mx = {}, 0.0
            for i, j in m.items():
                v = [(y - x) / d for x, y in zip(b[i]["c"], ny[j]["c"])]
                l = sum(x * x for x in v) ** 0.5
                if l > 0.005:
                    ytor[str(b[i]["id"])] = [round(x, 4) for x in v]
                    mx = max(mx, l)
            ny_form = len(ny) != len(b) or len(m) != len(b)
            if ytor or ny_form:
                delar[pid] = {"ytor": ytor, "max": round(mx, 4), "ny_form": ny_form}
        return p["namn"], {"delta": d, "delar": delar}
    except subprocess.TimeoutExpired:
        return p["namn"], {"delta": d, "fel": "tog för lång tid"}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(prj):
    prj = Path(prj).resolve()
    cad = prj / "cad"
    ut = cad / "visningar" / "kanslighet.json"
    skript = sorted((cad / "skript").glob("*.py"))
    if not skript:
        return
    geo = json.loads((cad / "geometri.json").read_text())
    params = [p for p in geo.get("parametrar", [])
              if isinstance(p.get("varde"), (int, float)) and p.get("grupp") and p.get("enhet") != "st"][:MAX_MATT]
    ovp = cad / "parametrar-anvandare.json"
    ov = json.loads(ovp.read_text()) if ovp.exists() else {}
    stampel = _stampel(prj, cad, params, ov)
    if ut.exists():
        try:
            if json.loads(ut.read_text()).get("stampel") == stampel:
                print("känsligheten är redan beräknad")
                return
        except Exception:
            pass
    bas = {}
    for dl in json.loads((cad / "delar.json").read_text()).get("delar", []):
        y = _ytor(cad / dl["fil"])
        if y is not None:
            bas[dl["id"]] = y
    res = {}
    with ThreadPoolExecutor(max_workers=max(1, min(4, (os.cpu_count() or 4) // 2))) as ex:
        for namn, r in ex.map(lambda p: _kor(prj, cad, skript, ov, p, bas), params):
            res[namn] = r
            print(f"{namn}: {len(r.get('delar', {}))} delar påverkas" + (f" (fel: {r['fel']})" if r.get("fel") else ""))
    ut.parent.mkdir(exist_ok=True)
    tmp = ut.with_suffix(".tmp")
    tmp.write_text(json.dumps({"stampel": stampel, "parametrar": res}, ensure_ascii=False, separators=(",", ":")))
    tmp.replace(ut)


if __name__ == "__main__":
    main(sys.argv[1])
