#!/usr/bin/env python3
"""Utskriftsinställningar per del (Bambu Lab X2D): <projekt>/cad/utskrift.json.

    cad/utskrift.py <projekt>                          # visa alla designdelars gällande inställningar
    cad/utskrift.py <projekt> <del> plast=PETG-CF wall_loops=4 sparse_infill_density=25% enable_support=1
    cad/utskrift.py <projekt> <del> --ta-bort wall_loops   # tillbaka till skriptets/profilens värde
    cad/utskrift.py --plaster                          # plastsorter med installerad X2D 0.4-profil

Filen skrivs av appen (inspektören, när en konstruktionsdel är vald) och av agenten:

    {"delar": {"lock": {"plast": "PETG-CF", "wall_loops": "4", "sparse_infill_density": "25%",
                        "top_shell_layers": "5", "bottom_shell_layers": "4",
                        "enable_support": "1", "support_type": "tree(auto)"}}}

Nycklarna är Bambu Studios egna processnycklar (som i `prj.del_(…, bambu={…})`) plus "plast". Värden är strängar.
Gällande värde per del: processprofilen < delens "bambu" i delar.json (skriptet) < utskrift.json. Plast utan värde = PLA
(eller `--material` till bambu.py).
"""
import json
import sys
from pathlib import Path

FIL = "utskrift.json"
# alltid redigerbara i appen (ordning = appens ordning)
GRUND = ("wall_loops", "sparse_infill_density", "top_shell_layers", "bottom_shell_layers", "enable_support", "support_type")
SUPPORTTYPER = ("tree(auto)", "normal(auto)", "tree(manual)", "normal(manual)")
STANDARDPLAST = "PLA"


def las(cad):
    """{del-id: {nyckel: värde}} ur cad/utskrift.json (tom om filen saknas eller är trasig)."""
    try:
        d = json.loads((Path(cad) / FIL).read_text())
    except (OSError, ValueError):
        return {}
    delar = d.get("delar") if isinstance(d, dict) else None
    if not isinstance(delar, dict):
        return {}
    return {pid: {k: normalisera(k, v) for k, v in (s or {}).items()} for pid, s in delar.items() if isinstance(s, dict)}


def skriv(cad, delar):
    path = Path(cad) / FIL
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    data["delar"] = {pid: s for pid, s in delar.items() if s}
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def normalisera(k, v):
    """Bambu vill ha strängar; infill med %; bool som 0/1."""
    if isinstance(v, bool):
        v = "1" if v else "0"
    s = str(v).strip()
    if k == "sparse_infill_density" and s and not s.endswith("%"):
        try:
            s = f"{float(s.replace(',', '.')):g}%"
        except ValueError:
            pass
    if k in ("wall_loops", "top_shell_layers", "bottom_shell_layers"):
        try:
            s = str(int(round(float(s.replace(",", ".")))))
        except ValueError:
            pass
    if k == "enable_support" and s.lower() in ("på", "ja", "true", "on"):
        s = "1"
    if k == "enable_support" and s.lower() in ("av", "nej", "false", "off"):
        s = "0"
    return s


def gallande(pid, skript_bambu, fil, standardplast=STANDARDPLAST):
    """(plast, {nyckel: värde}) för en del: skriptets bambu-dict med utskrift.json över. "plast" lyfts ut."""
    s = {k: normalisera(k, v) for k, v in (skript_bambu or {}).items()}
    s.update(fil.get(pid, {}))
    plast = (s.pop("plast", "") or standardplast).strip()
    return plast, s


def main(argv):
    if argv[:1] == ["--plaster"]:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from bambu import installerade_plaster
        print("\n".join(installerade_plaster()))
        return 0
    if not argv:
        print(__doc__)
        return 2
    prj = Path(argv[0]).expanduser().resolve()
    cad = prj / "cad"
    delar = las(cad)
    if len(argv) == 1:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from bambu import profil_for
        try:
            alla = json.loads((cad / "delar.json").read_text())["delar"]
        except (OSError, ValueError, KeyError):
            alla = []
        for d in alla:
            if d.get("roll") != "design":
                continue
            plast, s = gallande(d["id"], d.get("bambu"), delar)
            prof, varn = profil_for(plast)
            print(f"{d['id']}: {d.get('namn')} ({plast}) – profil {prof}{' – ' + varn if varn else ''}")
            for k, v in s.items():
                kalla = "utskrift.json" if k in delar.get(d["id"], {}) else "skript"
                print(f"    {k} = {v}   [{kalla}]")
        return 0
    pid, rest = argv[1], argv[2:]
    s = dict(delar.get(pid, {}))
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--ta-bort":
            s.pop(rest[i + 1], None)
            i += 2
            continue
        if "=" not in a:
            raise SystemExit(f"väntade nyckel=värde, fick {a!r}")
        k, v = a.split("=", 1)
        s[k.strip()] = normalisera(k.strip(), v)
        i += 1
    delar[pid] = s
    skriv(cad, delar)
    print(json.dumps(s, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
