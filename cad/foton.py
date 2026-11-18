"""Foton med kamerans exakta läge i modellens ram – för CAD-overlay i Skanna.app.

  1. skanna poser <skanning>/bilder <skanning>/cad/poser.json   (kamerapositioner + snabbmodell i samma session)
  2. .venv/bin/python cad/foton.py <skanning>

Passar in snabbmodellen mot modell/modell-mm.obj (PCA-start + ICP med skala), flyttar alla kameror till mm-ramen och
väljer bästa bild per huvudriktning. Skriver <skanning>/cad/foton.json.
"""
import itertools
import json
import sys
from pathlib import Path

import numpy as np
import trimesh

scan = Path(sys.argv[1]).expanduser()
cad = scan / "cad"
poser = json.loads((cad / "poser.json").read_text())
preview_dir = Path(poser["snabbmodell"])
preview = trimesh.load(next(preview_dir.glob("*.obj")), force="mesh", process=False)
target = trimesh.load(scan / "modell" / "modell-mm.obj", force="mesh", process=False)


def pca(points):
    c = points.mean(0)
    _, vec = np.linalg.eigh(np.cov((points - c).T))
    vec = vec[:, ::-1]  # störst först
    if np.linalg.det(vec) < 0:
        vec[:, 2] *= -1  # högerhänt
    ext = np.ptp((points - c) @ vec, axis=0)
    return c, vec, ext


P = preview.vertices
T = target.vertices[np.unique(target.faces)]  # bara hörn som används (bord/ark kan vara borttaget)


def crop_to_object(points):
    """Snabbmodellen innehåller bord/ark: ta bara punkterna ovanför det dominerande planet (om ett sådant finns)."""
    rng_ = np.random.default_rng(7)
    diag = np.linalg.norm(np.ptp(points, axis=0))
    thr = diag * 0.005
    samp = points[rng_.choice(len(points), size=min(15000, len(points)), replace=False)]
    best_ = (0, None)
    for _ in range(500):
        a, b, c = samp[rng_.choice(len(samp), 3, replace=False)]
        n = np.cross(b - a, c - a)
        ln = np.linalg.norm(n)
        if ln < 1e-12:
            continue
        n /= ln
        cnt = int((np.abs(samp @ n - n @ a) < thr).sum())
        if cnt > best_[0]:
            best_ = (cnt, (n, n @ a))
    if best_[1] is None or best_[0] < 0.25 * len(samp):
        return points
    n, d = best_[1]
    off = points @ n - d
    side = 1 if (off > 3 * thr).sum() >= (off < -3 * thr).sum() else -1
    kept = points[side * off > 2 * thr]
    # största sammanhängande klump ovanför planet (bort med bordsrester/lösa bitar)
    u_ = np.cross(n, [1, 0, 0] if abs(n[0]) < 0.9 else [0, 1, 0]); u_ /= np.linalg.norm(u_); w_ = np.cross(n, u_)
    cell = diag / 80
    keys = np.floor(np.c_[kept @ u_, kept @ w_] / cell).astype(int)
    occ = {}
    for i, k in enumerate(map(tuple, keys)):
        occ.setdefault(k, []).append(i)
    seen, best_c = set(), []
    for k in occ:
        if k in seen:
            continue
        comp, stack = [], [k]
        seen.add(k)
        while stack:
            c = stack.pop()
            comp += occ[c]
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    nk = (c[0] + dx, c[1] + dy)
                    if nk in occ and nk not in seen:
                        seen.add(nk); stack.append(nk)
        if len(comp) > len(best_c):
            best_c = comp
    kept = kept[best_c]
    print(f"snabbmodell: tog bort bordsplanet och lösa bitar, {len(kept)} av {len(points)} punkter kvar")
    return kept if len(kept) > 500 else points


P = crop_to_object(P)
cp, vp, ep = pca(P)
ct, vt, et = pca(T)
s0 = et[0] / ep[0]
rng = np.random.default_rng(0)
sample = P[rng.choice(len(P), size=min(4000, len(P)), replace=False)]

best = None
for sx, sy in itertools.product((1, -1), (1, -1)):
    flip = np.diag([sx, sy, sx * sy])  # bara rotationer (det = +1)
    R0 = vt @ flip @ vp.T
    if np.linalg.det(R0) < 0:
        continue
    A0 = np.eye(4)
    A0[:3, :3] = s0 * R0
    A0[:3, 3] = ct - s0 * R0 @ cp
    M, _, cost = trimesh.registration.icp(sample, target, initial=A0, threshold=1e-6, max_iterations=60,
                                          reflection=False, translation=True, scale=True)
    s_ = np.cbrt(np.linalg.det(M[:3, :3]))
    cam = np.array([np.array(p["kamera_till_modell"])[:3, 3] for p in poser["poser"]])
    dist_ = np.median(np.linalg.norm((cam * s_) @ (M[:3, :3] / s_).T + M[:3, 3] - T.mean(0), axis=1))
    ok_ = 60 < dist_ < 1500   # kameran ska stå 6 cm – 1,5 m från objektet
    print(f"  kandidat: skala {s_:.2f}, kostnad {cost:.3f}, kameraavstånd {dist_:.0f} mm {'' if ok_ else '(orimligt)'}")
    if ok_ and (best is None or cost < best[1]):
        best = (M, cost)
M, cost = best
s = np.cbrt(np.linalg.det(M[:3, :3]))
Rm = M[:3, :3] / s
# kvarvarande avstånd (mm) mellan inpassad snabbmodell och mm-modellen
moved = trimesh.transform_points(sample, M)
_, dist, _ = trimesh.proximity.closest_point(target, moved)
print(f"inpassning: skala {s:.2f}, median {np.median(dist):.2f} mm, 90 % < {np.percentile(dist, 90):.2f} mm")

AXES = {"ovanifrån": (0, 0, 1), "underifrån": (0, 0, -1), "från +X": (-1, 0, 0), "från −X": (1, 0, 0),
        "från +Y": (0, -1, 0), "från −Y": (0, 1, 0)}  # kamerans blickriktning för respektive vy (öppningen mot −Z)
fotos = []
for p in poser["poser"]:
    C = np.array(p["kamera_till_modell"])
    Rc, tc = C[:3, :3], C[:3, 3]
    pose = np.eye(4)
    pose[:3, :3] = Rm @ Rc
    pose[:3, 3] = s * Rm @ tc + M[:3, 3]
    look = -pose[:3, 2]
    fotos.append({"bild": "bilder/" + p["bild"], "kamera_till_modell": pose.round(6).tolist(), "K": p.get("K"),
                  "bredd": 3840, "hojd": 2160, "blick": look.round(4).tolist(), "vy": None})
# pålitlighet: bilderna kommer ur en video, så kameran rör sig jämnt. En bild vars läge hoppar mot ALLA grannpar
# (±1/±2) är felplacerad av fotogrammetrin och används inte för vyer.
order = sorted(range(len(fotos)), key=lambda i: fotos[i]["bild"])
pos = np.array([np.array(fotos[i]["kamera_till_modell"])[:3, 3] for i in order])
look = np.array([fotos[i]["blick"] for i in order])
devs = []
for k in range(len(order)):
    best_d = (np.inf, np.inf)
    for a_, b_ in ((-1, 1), (-2, 2), (-1, 2), (-2, 1)):
        if 0 <= k + a_ < len(order) and 0 <= k + b_ < len(order):
            w = -a_ / (b_ - a_)
            p_ = pos[k + a_] * (1 - w) + pos[k + b_] * w
            l_ = look[k + a_] * (1 - w) + look[k + b_] * w
            l_ /= np.linalg.norm(l_)
            d_ = (np.linalg.norm(pos[k] - p_), np.degrees(np.arccos(np.clip(look[k] @ l_, -1, 1))))
            if d_[0] < best_d[0]:
                best_d = d_
    if not np.isfinite(best_d[0]):  # första/sista bilden: jämför med närmaste granne
        j = k + 1 if k == 0 else k - 1
        best_d = (np.linalg.norm(pos[k] - pos[j]), np.degrees(np.arccos(np.clip(look[k] @ look[j], -1, 1))))
    devs.append(best_d)
devs = np.array(devs)
med = np.median(devs[np.isfinite(devs[:, 0])], axis=0)
for k, i in enumerate(order):
    ok = bool(devs[k, 0] < 6 * med[0] and devs[k, 1] < max(20, 6 * med[1]))
    fotos[i]["palitlig"] = ok
    if not ok:
        print("opålitlig:", fotos[i]["bild"], np.round(devs[k], 1))

for name, d in AXES.items():
    d = np.array(d, float)
    angs = [np.degrees(np.arccos(np.clip(np.dot(f["blick"], d), -1, 1))) if f["palitlig"] else 999 for f in fotos]
    i = int(np.argmin(angs))
    if angs[i] < 40 and fotos[i]["vy"] is None:
        fotos[i]["vy"] = name
        fotos[i]["vinkel"] = round(float(angs[i]), 1)
        print(f"{name:11s}: {fotos[i]['bild']}  ({angs[i]:.0f}° från rak vy)")
# bildstorlek ur första bilden
try:
    import subprocess
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(scan / fotos[0]["bild"])],
                         capture_output=True, text=True).stdout.split()
    w, h = int(out[out.index("pixelWidth:") + 1]), int(out[out.index("pixelHeight:") + 1])
    for f in fotos:
        f["bredd"], f["hojd"] = w, h
except Exception:
    pass
(cad / "foton.json").write_text(json.dumps({"inpassning_median_mm": round(float(np.median(dist)), 3), "foton": fotos},
                                           ensure_ascii=False))
print("skrev", cad / "foton.json", len(fotos), "foton")
