"""Rita delarnas CAD-kanter på en bildruta – samma vy som användaren ser i Skanna.app (Foto-läget) – för att bedöma diffen.

  .venv/bin/python cad/visa.py <skanning> <bild> [u v] [--radie 350]
    bild: t.ex. bilder/klipp1_0056.jpg (eller bara klipp1_0056.jpg)
    u v : pixel att zooma in kring (från svar.json → foto_px); utan = hela bilden
Skriver <skanning>/cad/visningar/<bild>[-u-v].png och skriver ut sökvägen.
"""
import argparse
import json
from pathlib import Path

import matplotlib
import numpy as np

matplotlib.use("Agg")
import matplotlib.image as mpimg  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("scan")
ap.add_argument("bild")
ap.add_argument("uv", nargs="*", type=float)
ap.add_argument("--radie", type=float, default=350)
a = ap.parse_args()

scan = Path(a.scan).expanduser()
cad = scan / "cad"
bild = a.bild if a.bild.startswith("bilder/") else "bilder/" + a.bild
foto = next(f for f in json.loads((cad / "foton.json").read_text())["foton"] if f["bild"] == bild)
pose, K = np.array(foto["kamera_till_modell"]), np.array(foto["K"])
img = mpimg.imread(scan / bild)

delar = json.loads((cad / "delar.json").read_text())["delar"] if (cad / "delar.json").exists() else []
fig, ax = plt.subplots(figsize=(14, 8) if not a.uv else (9, 9))
ax.imshow(img)
for d in delar:
    ytor = json.loads((cad / d["fil"]).read_text())["ytor"]
    for y in ytor:
        v = np.array(y["v"]).reshape(-1, 3)
        t = np.array(y["t"]).reshape(-1, 3)
        cnt = {}
        for tri in t:
            for i, j in ((0, 1), (1, 2), (2, 0)):
                k = tuple(sorted((tri[i], tri[j])))
                cnt[k] = cnt.get(k, 0) + 1
        edges = [k for k, n in cnt.items() if n == 1]
        Xc = (v - pose[:3, 3]) @ pose[:3, :3]
        z = -Xc[:, 2]
        u = K[0, 0] * Xc[:, 0] / z + K[0, 2]
        w = K[1, 2] - K[1, 1] * Xc[:, 1] / z
        for i, j in edges:
            if z[i] > 1 and z[j] > 1:
                ax.plot([u[i], u[j]], [w[i], w[j]], "-", color=d.get("farg", "#F28C26"), lw=1.0)
if a.uv:
    cu, cv = a.uv[:2]
    ax.plot(cu, cv, "o", ms=14, mfc="none", mec="red", mew=2)
    ax.set_xlim(cu - a.radie, cu + a.radie)
    ax.set_ylim(cv + a.radie, cv - a.radie)
else:
    ax.set_xlim(0, img.shape[1])
    ax.set_ylim(img.shape[0], 0)
ax.axis("off")
out = cad / "visningar"
out.mkdir(exist_ok=True)
name = Path(bild).stem + ("-%d-%d" % tuple(a.uv[:2]) if a.uv else "") + ".png"
plt.tight_layout()
plt.savefig(out / name, dpi=80)
print(out / name)
