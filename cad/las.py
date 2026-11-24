"""Kör ett kommando med projektets lås (cad/lagring.py): `las.py <projekt> <namn> -- kommando …`.

bygg_projekt.sh kör sig själv så med namnet "bygg", så att två byggen av samma projekt (appens och Claudes) går efter
varandra i stället för samtidigt. Väntar den på ett annat bygge skrivs det ut.
"""
import fcntl
import os
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lagring  # noqa: E402


def main(argv):
    if len(argv) < 4 or argv[2] != "--":
        print(__doc__, file=sys.stderr)
        return 2
    projekt, namn, cmd = argv[0], argv[1], argv[3:]
    fil = Path(projekt).expanduser().resolve() / ".skanna" / f"{namn}.las"
    fil.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(fil, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"== väntar på ett annat {namn} av projektet …", flush=True)
        fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        barn = subprocess.Popen(cmd)
        # avbryts låset (appen stoppar bygget) ska bygget också avbrytas, inte fortsätta utan lås
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda n, _f: barn.send_signal(n))
        return barn.wait()
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
