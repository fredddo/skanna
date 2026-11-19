"""Importerade delar: en fil från ett annat CAD-program blir en del i projektet.

Appen (Lägg till del → Importera fil …) kopierar filen till <projekt>/cad/import/ och skriver ett litet del-skript
cad/skript/50-import-<id>.py som anropar `importera(...)` här. Då byggs, versioneras och exporteras delen som alla
andra delar, och placeringen kan ändras som vanliga mått i appen ("<namn>: flytta x" osv.).

- STEP (.step/.stp): riktiga ytor och kanter (B-rep). Ytor/kanter går att välja, mäta och kantbehandla (fillet/fas),
  och ett annat del-skript kan bygga vidare på soliden med `las_step(prj, "import/fil.step")`.
  Fusions parametrar följer inte med i STEP; vill man ha redigerbara mått skrivs delen om som ett eget skript.
- STL/3MF/OBJ: bara trianglar. Plana ytor plockas ut så att de går att välja och mäta mot; resten blir en yta
  ("nät"). Delen kan visas, mätas och skrivas ut men inte kantbehandlas eller byggas vidare på.

Enheter: STEP och 3MF bär egna enheter (räknas om till mm). STL/OBJ saknar enhet och tolkas som mm – är delen
orimligt liten/stor, ändra "<namn>: skala" (25,4 = tum → mm, 1000 = m → mm).
"""
import json
import math
from pathlib import Path

MESH = (".stl", ".3mf", ".obj", ".ply", ".off")
STEP = (".step", ".stp")


def _placering(prj, namn):
    return prj.parametrar(namn, {
        "flytta x": (0.0, "mm"),
        "flytta y": (0.0, "mm"),
        "flytta z": (0.0, "mm"),
        "vrid x": (0.0, "°"),
        "vrid y": (0.0, "°"),
        "vrid z": (0.0, "°"),
        "skala": (1.0, "×"),
    })


def _matris(P):
    """4×4 (numpy): skala, vrid X → Y → Z kring origo, flytta."""
    import numpy as np
    def rot(axis, deg):
        a = math.radians(deg)
        c, s = math.cos(a), math.sin(a)
        R = np.eye(4)
        i, j = {"x": (1, 2), "y": (2, 0), "z": (0, 1)}[axis]
        R[i, i], R[i, j], R[j, i], R[j, j] = c, -s, s, c
        return R
    M = np.eye(4)
    M[:3, :3] *= P["skala"]
    for ax in "xyz":
        M = rot(ax, P[f"vrid {ax}"]) @ M
    M[:3, 3] = [P["flytta x"], P["flytta y"], P["flytta z"]]
    return M


def las_step(prj, fil):
    """Läs en STEP-fil (sökväg relativt cad/) som build123d-form i mm, utan placering."""
    from build123d import import_step
    return import_step(str(prj.cad / fil))


def importera(prj, pid, namn, fil, roll="design", farg="#8E8E93", beskrivning=None, utskrift=True):
    """Bygg en importerad del ur cad/<fil> (STEP eller mesh). Skriver mått, ytor, export och delar.json."""
    src = prj.cad / fil
    if not src.exists():
        raise SystemExit(f"Importfilen saknas: {src}")
    P = _placering(prj, namn)
    ext = src.suffix.lower()
    text = beskrivning or f"Importerad från {src.name}"
    if ext in STEP:
        _step(prj, pid, namn, src, P, roll, farg, text, utskrift)
    elif ext in MESH:
        _mesh(prj, pid, namn, src, P, roll, farg, text, utskrift)
    else:
        raise SystemExit(f"Okänt filformat: {src.name} (STEP, STL, 3MF eller OBJ går att importera)")
    prj.spara(beskrivning=None)


# ---- STEP --------------------------------------------------------------------------------------------------------
def _step(prj, pid, namn, src, P, roll, farg, text, utskrift):
    from build123d import Axis, Location
    s = las_step(prj, src.relative_to(prj.cad))
    if abs(P["skala"] - 1) > 1e-9:
        s = s.scale(P["skala"])
    for ax, axis in (("x", Axis.X), ("y", Axis.Y), ("z", Axis.Z)):
        if P[f"vrid {ax}"]:
            s = s.rotate(axis, P[f"vrid {ax}"])
    if any(P[f"flytta {a}"] for a in "xyz"):
        s = s.moved(Location((P["flytta x"], P["flytta y"], P["flytta z"])))
    if not list(s.faces()):
        raise SystemExit(f"{src.name} innehåller inga ytor (bara kurvor/punkter?)")
    bb = s.bounding_box()
    print(f"{src.name}: {len(s.solids())} kroppar, {len(s.faces())} ytor, "
          f"{bb.size.X:.1f} × {bb.size.Y:.1f} × {bb.size.Z:.1f} mm")
    prj.del_(pid, namn, s, roll=roll, farg=farg, beskrivning=text, utskrift=utskrift and bool(s.solids()))


# ---- STL / 3MF / OBJ ---------------------------------------------------------------------------------------------
def _las_mesh(src):
    import trimesh
    if src.suffix.lower() == ".3mf":   # egen läsare: trimesh behöver lxml för 3MF
        V, F, enhet = _las_3mf(src)
        m = trimesh.Trimesh(V, F, process=True)
        m.metadata["units"] = enhet
    else:
        m = trimesh.load(str(src), force="mesh", process=True)
    if not isinstance(m, trimesh.Trimesh) or len(m.faces) == 0:
        raise SystemExit(f"{src.name} innehåller inga trianglar")
    enhet = (getattr(m, "units", None) or m.metadata.get("units") or "").lower() if hasattr(m, "metadata") else ""
    if enhet and enhet not in ("mm", "millimeter", "millimeters", "millimetre"):
        try:
            m.units = enhet
            m.convert_units("mm")
            print(f"{src.name}: enhet {enhet} → mm")
        except Exception as e:  # okänd enhet: behåll siffrorna
            print(f"{src.name}: okänd enhet {enhet!r} ({e}) – tolkas som mm")
    m.merge_vertices()
    m.remove_unreferenced_vertices()
    return m


def _mesh(prj, pid, namn, src, P, roll, farg, text, utskrift):
    import numpy as np
    import trimesh
    m = _las_mesh(src)
    m.apply_transform(_matris(P))
    ext = m.extents
    print(f"{src.name}: {len(m.faces)} trianglar, {ext[0]:.1f} × {ext[1]:.1f} × {ext[2]:.1f} mm")
    if max(ext) < 2:
        print(f"OBS: delen är bara {max(ext):.3f} mm stor – filen är kanske i meter (sätt '{namn}: skala' = 1000)")
    elif max(ext) > 5000:
        print(f"OBS: delen är {max(ext):.0f} mm stor – kontrollera enheten ('{namn}: skala')")

    n = _mesh_ytor(m, prj.cad / f"{pid}-ytor.json")
    export = None
    if utskrift:
        p = m.copy()
        lo, hi = p.bounds
        p.apply_translation([-(lo[0] + hi[0]) / 2, -(lo[1] + hi[1]) / 2, -lo[2]])
        p.export(str(prj.cad / f"{pid}.stl"))
        _skriv_3mf(prj.cad / f"{pid}.3mf", p.vertices, p.faces, namn)
        export = f"{pid}.3mf"
    from ytor import register_part
    register_part(prj.cad, pid, namn, f"{pid}-ytor.json", roll, farg, export=export, beskrivning=text)
    print(f"{pid}: {n} ytor (mesh)")


# ---- 3MF med standardbiblioteket ----------------------------------------------------------------------------------
_ENHET = {"micron": 0.001, "millimeter": 1.0, "centimeter": 10.0, "inch": 25.4, "foot": 304.8, "meter": 1000.0}


def _las_3mf(src):
    """Alla byggobjekt i en 3MF (även komponenter i andra modellfiler, som Bambu Studio skriver) → (V, F, "mm")."""
    import zipfile
    import xml.etree.ElementTree as ET
    import numpy as np
    z = zipfile.ZipFile(src)
    namn = {n.lower(): n for n in z.namelist()}

    def tag(e):
        return e.tag.rsplit("}", 1)[-1]

    def matris(t):
        if not t:
            return np.eye(4)
        a = [float(x) for x in t.split()]
        M = np.eye(4)
        M[:3, :3] = np.array(a[:9]).reshape(3, 3).T
        M[:3, 3] = a[9:12]
        return M

    modeller, enhet = {}, None

    def modell(path):
        key = path.lstrip("/").lower()
        if key not in modeller:
            root = ET.fromstring(z.read(namn[key]))
            nonlocal enhet
            enhet = enhet or root.get("unit", "millimeter")
            obj = {}
            for o in root.iter():
                if tag(o) == "object":
                    obj[o.get("id")] = o
            modeller[key] = (root, obj)
        return modeller[key]

    huvud = next((n for n in namn if n.endswith("3dmodel.model") and n.startswith("3d/")), None)
    if huvud is None:
        raise SystemExit(f"{src.name}: ingen 3D/3dmodel.model i filen")
    V, F, nv = [], [], 0

    def lagg(path, oid, M, djup=0):
        nonlocal nv
        if djup > 16:
            return
        root, obj = modell(path)
        o = obj.get(oid)
        if o is None:
            return
        for c in o:
            if tag(c) == "mesh":
                vs = [(float(v.get("x")), float(v.get("y")), float(v.get("z")))
                      for v in c.iter() if tag(v) == "vertex"]
                ts = [(int(t.get("v1")), int(t.get("v2")), int(t.get("v3"))) for t in c.iter() if tag(t) == "triangle"]
                if vs and ts:
                    a = np.c_[np.array(vs), np.ones(len(vs))] @ M.T
                    V.append(a[:, :3]); F.append(np.array(ts) + nv); nv += len(vs)
            elif tag(c) == "components":
                for k in c:
                    p = next((v for a, v in k.attrib.items() if a.endswith("}path") or a == "path"), None)
                    lagg(p or path, k.get("objectid"), M @ matris(k.get("transform")), djup + 1)

    root, _ = modell(huvud)
    for it in root.iter():
        if tag(it) == "item":
            p = next((v for a, v in it.attrib.items() if a.endswith("}path")), None)
            lagg(p or huvud, it.get("objectid"), matris(it.get("transform")))
    if not V:
        raise SystemExit(f"{src.name} innehåller inga trianglar")
    skala = _ENHET.get(enhet or "millimeter", 1.0)
    return np.vstack(V) * skala, np.vstack(F), "mm"


def _skriv_3mf(path, V, F, namn):
    """Minimal 3MF (mm) som Bambu Studio och andra slicers läser."""
    import zipfile
    from xml.sax.saxutils import quoteattr
    vs = "".join(f'<vertex x="{x:.4f}" y="{y:.4f}" z="{z:.4f}"/>' for x, y, z in V)
    ts = "".join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in F)
    model = ('<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="sv-SE" '
             'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
             f'<resources><object id="1" type="model" name={quoteattr(namn)}><mesh><vertices>{vs}</vertices>'
             f'<triangles>{ts}</triangles></mesh></object></resources><build><item objectid="1"/></build></model>')
    ct = ('<?xml version="1.0" encoding="UTF-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Target="/3D/3dmodel.model" Id="rel0" '
            'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", rels)
        z.writestr("3D/3dmodel.model", model)


def _r(a, d=4):
    import numpy as np
    return [round(float(x), d) for x in np.ravel(a)]


def _mesh_ytor(m, path, max_plan=400):
    """ytor.json för ett triangelnät: stora plana partier blir egna "plan"-ytor (valbara, mätbara), resten en
    "nät"-yta per kropp. Hörn delas upp vid skarpa veck så att skuggningen blir rätt."""
    import numpy as np
    import trimesh
    total = float(m.area) or 1.0
    # kroppar = sammanhängande trianglar
    labels = trimesh.graph.connected_component_labels(m.face_adjacency, node_count=len(m.faces))
    kroppar = []
    for k in range(int(labels.max()) + 1 if len(labels) else 0):
        sub = m.submesh([np.nonzero(labels == k)[0]], append=True)
        lo, hi = sub.bounds
        vol = abs(float(sub.volume)) if sub.is_watertight else None
        kroppar.append({"id": k, "namn": f"Kropp {k + 1}", "volym": round(vol, 2) if vol else None,
                        "min": _r(lo, 3), "max": _r(hi, 3)})
    # plana partier (facets) – de största, minst 0,5 % av ytan eller 4 mm²
    used = np.zeros(len(m.faces), bool)
    ytor = []
    facets = list(m.facets)
    areas = m.facets_area if len(facets) else []
    order = sorted(range(len(facets)), key=lambda i: -areas[i])
    for i in order[:max_plan]:
        if areas[i] < max(4.0, 0.005 * total) and areas[i] < 0.02 * total:
            break
        fi = facets[i]
        used[fi] = True
        ytor.append(_yta(m, fi, len(ytor), "plan", m.facets_normal[i], labels))
    # enstaka stora trianglar som inte ingår i ett facet (t.ex. en platt sida av två trianglar räknas som facet,
    # men en ensam triangel gör det inte)
    single = [f for f in np.argsort(-m.area_faces) if not used[f] and m.area_faces[f] >= max(4.0, 0.005 * total)]
    for f in single[:max(0, max_plan - len(ytor))]:
        used[f] = True
        ytor.append(_yta(m, np.array([f]), len(ytor), "plan", m.face_normals[f], labels))
    # resten: en nät-yta per kropp
    rest = np.nonzero(~used)[0]
    for k in np.unique(labels[rest]) if len(rest) else []:
        fi = rest[labels[rest] == k]
        ytor.append(_yta(m, fi, len(ytor), "nät", None, labels, delad=True))
    Path(path).write_text(json.dumps({"ytor": ytor, "kanter": [], "kroppar": kroppar, "kalla": "mesh"},
                                     separators=(",", ":"), ensure_ascii=False))
    return len(ytor)


def _yta(m, fi, yid, typ, normal, labels, delad=False):
    import numpy as np
    import trimesh
    sub = m.submesh([fi], append=True)
    if delad and len(sub.faces) > 1:
        try:   # dela hörn vid veck > 30° så att mjuka normaler inte smetar ut skarpa kanter
            sub = trimesh.graph.smooth_shade(sub, angle=math.radians(30))
        except Exception:
            pass
    c = sub.centroid if sub.area > 0 else sub.vertices.mean(axis=0)
    return {"id": yid, "typ": typ, "area": round(float(sub.area), 2), "centrum": _r(c, 3),
            "normal": _r(normal, 5) if normal is not None else None, "radie": None,
            "kropp": int(labels[fi[0]]),
            "v": _r(sub.vertices), "t": [int(x) for x in np.ravel(sub.faces)]}
