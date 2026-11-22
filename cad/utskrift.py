#!/usr/bin/env python3
"""Utskriftsinställningar per del (Bambu Lab X2D): <projekt>/cad/utskrift.json.

    cad/utskrift.py <projekt>                          # visa alla designdelars gällande inställningar
    cad/utskrift.py <projekt> <del> plast=PETG-CF wall_loops=4 sparse_infill_density=25% enable_support=1
    cad/utskrift.py <projekt> <del> --ta-bort wall_loops   # tillbaka till skriptets/profilens värde
    cad/utskrift.py <projekt> <del> filament.nozzle_temperature=240 filament.filament_retraction_length=0.8
    cad/utskrift.py --plaster                          # plastsorter med installerad X2D 0.4-profil

Filen skrivs av appen (pilen vid Skriv ut) och av agenten:

    {"delar": {"lock": {"plast": "PETG-CF", "wall_loops": "4", "sparse_infill_density": "25%",
                        "top_shell_layers": "5", "bottom_shell_layers": "4",
                        "enable_support": "1", "support_type": "tree(auto)"}}}

Filamentinställningar per del: "filament": {nyckel: värde} med Bambu Studios filamentnycklar (nozzle_temperature,
nozzle_temperature_initial_layer, filament_retraction_length, filament_max_volumetric_speed …):

    {"delar": {"lock": {"plast": "PETG", "filament": {"nozzle_temperature": "240",
                                                      "filament_retraction_length": "0.8"}}}}

Delar med samma plast delar filamentplats i Bambu Studio, så deras filament-värden slås ihop (cad/bambu.py varnar om två
delar vill ha olika värden på samma nyckel; första delen i ordningen vinner). Värdet sätts i filamentplatsens alla
munstycksvarianter (de som profilen inte lämnar tomma, "nil"). Skriptet kan sätta samma sak i `bambu={"filament": {…}}`.

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
    return {pid: {k: (_filament(v) if k == "filament" else normalisera(k, v)) for k, v in (s or {}).items()}
            for pid, s in delar.items() if isinstance(s, dict)}


def _filament(v):
    """{"nozzle_temperature": 240} -> {"nozzle_temperature": "240"} (Bambu vill ha strängar)."""
    if not isinstance(v, dict):
        return {}
    return {str(k): normalisera(k, x) for k, x in v.items() if x is not None and str(x).strip() != ""}


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
    s = {k: normalisera(k, v) for k, v in (skript_bambu or {}).items() if k != "filament"}
    s.update({k: v for k, v in fil.get(pid, {}).items() if k != "filament"})
    plast = (s.pop("plast", "") or standardplast).strip()
    return plast, s


def filament_gallande(pid, skript_bambu, fil):
    """Delens filament-värden: skriptets bambu["filament"] med utskrift.json:s "filament" över."""
    f = _filament((skript_bambu or {}).get("filament"))
    f.update(fil.get(pid, {}).get("filament") or {})
    return f


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
            for k, v in filament_gallande(d["id"], d.get("bambu"), delar).items():
                kalla = "utskrift.json" if k in (delar.get(d["id"], {}).get("filament") or {}) else "skript"
                print(f"    filament.{k} = {v}   [{kalla}]")
        return 0
    pid, rest = argv[1], argv[2:]
    s = dict(delar.get(pid, {}))
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--ta-bort":
            k = rest[i + 1]
            if k.startswith("filament."):
                f = dict(s.get("filament") or {})
                f.pop(k[len("filament."):], None)
                s["filament"] = f
                if not f:
                    s.pop("filament")
            else:
                s.pop(k, None)
            i += 2
            continue
        if "=" not in a:
            raise SystemExit(f"väntade nyckel=värde, fick {a!r}")
        k, v = a.split("=", 1)
        k = k.strip()
        if k.startswith("filament."):
            k = k[len("filament."):]
            s["filament"] = {**(s.get("filament") or {}), k: normalisera(k, v)}
        else:
            s[k] = normalisera(k, v)
        i += 1
    delar[pid] = s
    skriv(cad, delar)
    print(json.dumps(s, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
