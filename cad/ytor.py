"""Exportera en build123d-solids ytor var för sig, så att Skanna.app kan lysa upp och välja enskilda ytor.

Skriver modell-cad-ytor.json:
{"ytor": [{"id": 0, "typ": "plan|cylinder|…", "area": mm², "centrum": [x,y,z], "normal": [x,y,z] | null,
           "radie": r | null, "v": [x0,y0,z0, x1,…], "t": [i0,i1,i2, …]}]}
"""
import json
from pathlib import Path

from build123d import GeomType

TYP = {GeomType.PLANE: "plan", GeomType.CYLINDER: "cylinder", GeomType.CONE: "kon", GeomType.SPHERE: "sfär",
       GeomType.TORUS: "torus"}


def _radius(face):
    try:
        from OCP.BRepAdaptor import BRepAdaptor_Surface
        s = BRepAdaptor_Surface(face.wrapped)
        if face.geom_type == GeomType.CYLINDER:
            return s.Cylinder().Radius()
    except Exception:
        pass
    return None


def _kant(e, i, face_ids):
    """En kant som polylinje (≈0,2 mm kordafel, högst 64 punkter) + typ/radie/centrum."""
    import math
    gt = e.geom_type
    typ, radie, centrum = "spline", None, None
    if gt == GeomType.LINE:
        n, typ = 2, "linje"
    elif gt == GeomType.CIRCLE:
        r = e.radius
        typ = "cirkel" if e.is_closed else "båge"
        radie = r
        c = e.arc_center
        centrum = [round(c.X, 3), round(c.Y, 3), round(c.Z, 3)]
        theta = 2 * math.acos(max(-1.0, min(1.0, 1 - 0.2 / max(r, 0.2))))
        sweep = 2 * math.pi if e.is_closed else e.length / r
        n = int(math.ceil(sweep / max(theta, 0.05))) + 1
    else:
        n = int(math.ceil(e.length / 2)) + 1
    n = 2 if gt == GeomType.LINE else min(64, max(n, 8 if gt != GeomType.CIRCLE else 5))
    pts = [e.position_at(k / (n - 1)) for k in range(n)]
    c = e.position_at(0.5)   # mittpunkt på kurvan (samma som projekt.py matchar mot)
    return {"id": i, "typ": typ, "langd": round(e.length, 3), "radie": round(radie, 3) if radie else None,
            "centrum": centrum, "mitt": [round(c.X, 3), round(c.Y, 3), round(c.Z, 3)],
            "p": [round(x, 4) for q in pts for x in (q.X, q.Y, q.Z)], "ytor": sorted(face_ids)}


def _tessellera(f, tolerance, angular):
    """Trianglar för en yta. Vissa ytor (ofta i importerad STEP) får ingen triangulering alls – då gör OCCT:s
    tessellate ett AttributeError på None. Försök igen med grövre tolerans; går det inte returneras ([], [])
    så att ytan hoppas över i stället för att hela bygget fallerar."""
    for tol, ang in ((tolerance, angular), (tolerance * 10, angular * 2), (max(tolerance * 50, 0.5), 0.5)):
        try:
            from OCP.BRepMesh import BRepMesh_IncrementalMesh
            from OCP.BRepTools import BRepTools
            if (tol, ang) != (tolerance, angular):
                BRepTools.Clean_s(f.wrapped)
                BRepMesh_IncrementalMesh(f.wrapped, tol, False, ang, True)
            verts, tris = f.tessellate(tol, ang)
            if tris:
                return verts, tris
        except Exception:
            continue
    return [], []


def export_faces(solid, path: Path, tolerance=0.02, angular=0.15):
    faces = list(solid.faces())
    fidx = {hash(f): i for i, f in enumerate(faces)}
    kropp_av = {}
    kroppar = []
    for k, s in enumerate(solid.solids()):
        bb = s.bounding_box()
        kroppar.append({"id": k, "namn": f"Kropp {k + 1}", "volym": round(s.volume, 2),
                        "min": [round(bb.min.X, 3), round(bb.min.Y, 3), round(bb.min.Z, 3)],
                        "max": [round(bb.max.X, 3), round(bb.max.Y, 3), round(bb.max.Z, 3)]})
        for f in s.faces():
            kropp_av[fidx.get(hash(f))] = k
    ytor = []
    edge_faces = {}
    hoppade = 0
    for i, f in enumerate(faces):
        for e in f.edges():
            edge_faces.setdefault(hash(e), set()).add(i)
        verts, tris = _tessellera(f, tolerance, angular)
        if not tris:
            hoppade += 1
            continue
        c = f.center()
        normal = None
        if f.geom_type == GeomType.PLANE:
            n = f.normal_at(c)
            normal = [round(n.X, 5), round(n.Y, 5), round(n.Z, 5)]
        r = _radius(f)
        ytor.append({
            "id": i,
            "typ": TYP.get(f.geom_type, f.geom_type.name.lower()),
            "area": round(f.area, 2),
            "centrum": [round(c.X, 3), round(c.Y, 3), round(c.Z, 3)],
            "normal": normal,
            "radie": round(r, 3) if r else None,
            "kropp": kropp_av.get(i, 0),
            "v": [round(x, 4) for p in verts for x in (p.X, p.Y, p.Z)],
            "t": [int(k) for tri in tris for k in tri],
        })
    kanter = []
    for i, e in enumerate(solid.edges()):
        try:
            kanter.append(_kant(e, i, edge_faces.get(hash(e), ())))
        except Exception:
            continue
    if hoppade:
        print(f"Varning: {hoppade} av {len(faces)} ytor gick inte att triangulera och visas/går inte att välja "
              f"(trasig eller degenererad yta i geometrin)", flush=True)
    Path(path).write_text(json.dumps({"ytor": ytor, "kanter": kanter, "kroppar": kroppar},
                                     separators=(",", ":"), ensure_ascii=False))
    return len(ytor)


def register_part(cad_dir, pid, namn, fil, roll, farg, export=None, beskrivning=None, bambu=None, skript=None):
    """Lägg till/uppdatera en del i <skanning>/cad/delar.json (som Skanna.app visar i objektträdet).

    roll: "referens" (rekonstruerad befintlig del) | "design" (ny del att tillverka)
    bambu: valfri dict med Bambu Studio-inställningar för delen (t.ex. {"wall_loops": "4"}).
    farg: "#RRGGBB"; export: filnamn (t.ex. "provring.3mf") som appens Exportera-knapp öppnar i Bambu Studio.
    skript: del-skriptets filnamn i cad/skript/ (appens Radera tar bort skriptet om det bara gör den här delen).
    """
    path = Path(cad_dir) / "delar.json"
    data = json.loads(path.read_text()) if path.exists() else {"delar": []}
    delar = [d for d in data["delar"] if d["id"] != pid]
    delar.append({"id": pid, "namn": namn, "fil": fil, "roll": roll, "farg": farg, "export": export,
                  "beskrivning": beskrivning})
    if bambu:
        delar[-1]["bambu"] = {k: ({fk: str(fv) for fk, fv in v.items()} if isinstance(v, dict) else str(v))
                              for k, v in bambu.items()}
    if skript:
        delar[-1]["skript"] = skript
    order = {"referens": 0, "design": 1}
    data["delar"] = sorted(delar, key=lambda d: (order.get(d["roll"], 2), d["namn"]))
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))


def apply_overrides(cad_dir, D):
    """Användarens egna värden (från appen) går före skanning/antaganden: <cad>/parametrar-anvandare.json {namn: värde}."""
    path = Path(cad_dir) / "parametrar-anvandare.json"
    if not path.exists():
        return set()
    ov = json.loads(path.read_text())
    done = set()
    for k, val in ov.items():
        if k in D:
            old = D[k]
            D[k] = (float(val), "användare", old[2] if len(old) > 2 else None)
            done.add(k)
    return done
