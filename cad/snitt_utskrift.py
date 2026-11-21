"""Skriv ut ett snitt: konstruktionsdelarna avskurna vid appens snittplan – den sida som syns i vyn behålls.

    .venv/bin/python cad/snitt_utskrift.py <projekt> --axel 0|1|2 --lage <mm> --tecken 1|-1 --delar id,id [--ut <mapp>]

Planet är appens: allt där tecken · (p[axel] − lage) > 0 tas bort (kamerans sida). Skriver <ut>/<id>.stl (standard
<projekt>/cad/visningar/snitt/) i utskriftsläge med snittytan nedåt mot plattan, och skriver ut mappen på sista raden – den ges
sedan till bambu.py --stl-mapp.

Källa per del (i modellens ram): <id>-enhet.step (utskriftsenhet med barnen, t.ex. distansring + cellbädd) om den finns,
annars <id>.step ihop med barnens (delar med "foralder": id) .step, annars ytorna i <id>-ytor.json som nät.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np


def _rotation(axel, tecken):
    """Rotation (grader runt X eller Y) som vänder snittytan (normal −tecken·axel) nedåt mot plattan."""
    if axel == 2:
        return (0, 0) if tecken < 0 else ((0, 180))       # behåller nedre delen → snittytan uppåt → vänd
    if axel == 0:
        return (1, 90 if tecken > 0 else -90)              # runt Y: +X → −Z vid +90°
    return (0, -90 if tecken > 0 else 90)                  # runt X: +Y → −Z vid −90°


def _nat_ur_ytor(path):
    import trimesh
    d = json.loads(Path(path).read_text())
    V, F, off = [], [], 0
    for y in d.get("ytor", []):
        v = np.asarray(y["v"], dtype=float).reshape(-1, 3)
        t = np.asarray(y["t"], dtype=int).reshape(-1, 3)
        V.append(v)
        F.append(t + off)
        off += len(v)
    m = trimesh.Trimesh(np.vstack(V), np.vstack(F), process=False)
    m.vertices = np.round(m.vertices, 3)
    m.merge_vertices()
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("projekt")
    ap.add_argument("--axel", type=int, required=True)
    ap.add_argument("--lage", type=float, required=True)
    ap.add_argument("--tecken", type=float, default=1.0)
    ap.add_argument("--delar", required=True)
    ap.add_argument("--ut")
    a = ap.parse_args()
    import trimesh
    prj = Path(a.projekt).expanduser().resolve()
    cad = prj / "cad"
    ut = Path(a.ut) if a.ut else cad / "visningar" / "snitt"
    ut.mkdir(parents=True, exist_ok=True)
    for f in ut.glob("*.stl"):
        f.unlink()
    delar = json.loads((cad / "delar.json").read_text())["delar"]
    barn = {}
    for d in delar:
        if d.get("foralder"):
            barn.setdefault(d["foralder"], []).append(d["id"])
    axel, lage, tecken = a.axel, a.lage, 1.0 if a.tecken >= 0 else -1.0
    rot_axel, grader = _rotation(axel, tecken)
    n = np.zeros(3)
    n[axel] = -tecken                                     # trimesh behåller sidan normalen pekar mot
    origo = np.zeros(3)
    origo[axel] = lage
    gjorda = 0
    for pid in [s for s in a.delar.split(",") if s]:
        mesh = None
        enhet = cad / f"{pid}-enhet.step"
        steg = [enhet] if enhet.exists() else [cad / f"{x}.step" for x in [pid] + barn.get(pid, [])]
        steg = [s for s in steg if s.exists()]
        if steg:
            from build123d import Axis, Box, Pos, export_stl, import_step
            solid = None
            for s in steg:
                x = import_step(str(s))
                solid = x if solid is None else solid + x
            BIG = 4000.0
            c = [0.0, 0.0, 0.0]
            c[axel] = lage - tecken * BIG / 2
            kvar = solid & (Pos(*c) * Box(BIG, BIG, BIG))
            if kvar is None or kvar.volume < 1e-3:
                print(f"{pid}: inget kvar efter snittet", file=sys.stderr)
                continue
            if grader:
                kvar = kvar.rotate(Axis.Y if rot_axel == 1 else Axis.X, grader)
            tmp = ut / f"{pid}.tmp.stl"
            export_stl(kvar, str(tmp), tolerance=0.005, angular_tolerance=0.05)
            mesh = trimesh.load(str(tmp), force="mesh")
            tmp.unlink()
        else:
            f = cad / f"{pid}-ytor.json"
            if not f.exists():
                print(f"{pid}: ingen STEP eller ytfil att skära", file=sys.stderr)
                continue
            m = _nat_ur_ytor(f)
            for b in barn.get(pid, []):
                if (cad / f"{b}-ytor.json").exists():
                    m = trimesh.util.concatenate([m, _nat_ur_ytor(cad / f"{b}-ytor.json")])
            mesh = m.slice_plane(origo, n, cap=True)
            if mesh is None or len(mesh.faces) == 0:
                print(f"{pid}: inget kvar efter snittet", file=sys.stderr)
                continue
            if grader:
                ax = [0, 0, 0]
                ax[rot_axel] = 1
                mesh.apply_transform(trimesh.transformations.rotation_matrix(np.radians(grader), ax))
        mesh.vertices = np.round(mesh.vertices, 4)
        mesh.merge_vertices()
        mesh.remove_unreferenced_vertices()
        if not mesh.is_watertight:
            trimesh.repair.fill_holes(mesh)
        mesh.fix_normals()
        lo, hi = mesh.bounds
        mesh.apply_translation([-(lo[0] + hi[0]) / 2, -(lo[1] + hi[1]) / 2, -lo[2]])
        mesh.export(ut / f"{pid}.stl")
        e = mesh.extents
        print(f"{pid}: {e[0]:.1f} × {e[1]:.1f} × {e[2]:.1f} mm, vattentät {mesh.is_watertight}")
        gjorda += 1
    if not gjorda:
        sys.exit("inget av de valda delarna finns kvar efter snittet")
    print(ut)


if __name__ == "__main__":
    main()
