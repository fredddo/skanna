"""Säker läsning och skrivning av projektets JSON-filer (appen via motorn, byggskripten och Claude delar dem).

- skriv_json: atomiskt (temporär fil i samma mapp + os.replace) – en läsare ser aldrig en halv fil.
- las_json: saknas → standardvärdet; finns men går inte att tolka → Trasig (skrivs aldrig över med ett standardvärde).
- las(projekt, "skriv"|"bygg"): projektets lås (fcntl.flock på <projekt>/.skanna/<namn>.las). Återinträdande i samma tråd.
- uppdatera_json: läs–ändra–skriv under skrivläset.
- ny_tid / tid_datum: tider med millisekunder, unika i sin fil, och jämförelse som tidpunkter.

Bara stdlib – används av motorn, del-skripten (projekt.py/ytor.py) och CLI-verktygen (meddela.py, utskrift.py).
"""
import contextlib
import copy
import fcntl
import json
import os
import tempfile
import threading
from datetime import datetime, timedelta
from pathlib import Path


class Trasig(ValueError):
    """Filen finns men är inte giltig JSON."""


def projektmapp(path):
    """Projektmappen för en fil i <projekt>/cad/… (eller mappen själv)."""
    p = Path(path).expanduser().resolve()
    for q in [p, *p.parents]:
        if q.name == "cad":
            return q.parent
    return p if p.is_dir() else p.parent


_lokalt = threading.local()


@contextlib.contextmanager
def las(projekt, namn="skriv"):
    """Exklusivt lås för projektet. Samma tråd kan ta samma lås flera gånger (räknas upp/ner)."""
    d = Path(projekt).expanduser().resolve() / ".skanna"
    d.mkdir(parents=True, exist_ok=True)
    key = str(d / f"{namn}.las")
    held = getattr(_lokalt, "held", None)
    if held is None:
        held = _lokalt.held = {}
    if key in held:
        held[key][1] += 1
        try:
            yield
        finally:
            held[key][1] -= 1
        return
    fd = os.open(key, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        held[key] = [fd, 1]
        try:
            yield
        finally:
            del held[key]
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def las_json(path, standard=None):
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return copy.deepcopy(standard)
    try:
        return json.loads(text)
    except ValueError as e:
        raise Trasig(f"{path.name} är trasig och skrivs inte över ({e}). Rätta eller ta bort filen.") from e


def skriv_json(path, data, indent=2, kompakt=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = (json.dumps(data, ensure_ascii=False, separators=(",", ":")) if kompakt
            else json.dumps(data, ensure_ascii=False, indent=indent))
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            if not text.endswith("\n"):
                f.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def uppdatera_json(path, fn, standard=None, **skrivargs):
    """Läs filen, låt fn ändra värdet (returnera ett nytt värde eller ändra på plats → None) och skriv – under skrivläset.
    Returnerar det skrivna värdet."""
    with las(projektmapp(path), "skriv"):
        data = las_json(path, standard)
        ny = fn(data)
        data = data if ny is None else ny
        skriv_json(path, data, **skrivargs)
        return data


def tid_datum(s):
    """ISO-tid (med eller utan millisekunder, med tidszon) → datetime med tidszon; None om den inte går att läsa."""
    if not isinstance(s, str) or not s:
        return None
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.astimezone()


def ny_tid(befintliga=()):
    """Nu, lokal tid med millisekunder, garanterat senare än alla befintliga tider i listan (unik)."""
    nu = datetime.now().astimezone()
    nu = nu.replace(microsecond=nu.microsecond // 1000 * 1000)   # jämför det som faktiskt skrivs (millisekunder)
    senast = max((d for d in map(tid_datum, befintliga) if d), default=None)
    if senast and nu <= senast:
        nu = (senast + timedelta(milliseconds=1)).astimezone()
    return nu.isoformat(timespec="milliseconds")
