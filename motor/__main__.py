"""Starta motorn: `python -m motor [--port N] [--foralder PID]` (från Skanna-hemmet, eller med SKANNA_HEM satt).

Skriver "MOTOR <port>" på första raden när den lyssnar (port 0 = valfri ledig port). Nyckeln som anropen måste ha i
X-Skanna-Nyckel läses från miljövariabeln SKANNA_MOTOR_NYCKEL (tom = ingen nyckel, bara för tester).
--foralder PID: avsluta när den processen (appen) inte längre finns.
"""
import argparse
import os
import sys
import threading
import time

from motor.server import starta


def main():
    ap = argparse.ArgumentParser(prog="python -m motor")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--foralder", type=int)
    a = ap.parse_args()
    srv = starta(a.port, os.environ.get("SKANNA_MOTOR_NYCKEL") or None)
    print(f"MOTOR {srv.server_address[1]}", flush=True)
    if a.foralder:
        def vakt():
            while True:
                time.sleep(1)
                try:
                    os.kill(a.foralder, 0)
                except ProcessLookupError:
                    os._exit(0)
                except PermissionError:
                    pass
        threading.Thread(target=vakt, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
