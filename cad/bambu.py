#!/usr/bin/env python3
"""Bambu Studio-projekt-3MF för Bambu Lab X2D (0,4 mm) av ett Skanna-projekts konstruktionsdelar.

    cad/bambu.py <projekt> [--delar id,id] [--material PLA] [--ut fil.3mf] [--stl-mapp <mapp> --namn-tillagg " – snitt"]
    cad/bambu.py --bygg-mall [--material PETG-CF]      # bygg om bambu/x2d-<plast>-project_settings.json

--stl-mapp: ta delarnas STL ur den mappen (<id>.stl, utskriftsläge) i stället för cad/ – t.ex. snittet från
cad/snitt_utskrift.py; bara delar som har en fil där tas med. Skriver sökvägen till 3MF-filen på sista raden. Utan --ut: <projekt>/cad/<projektnamn>-bambu.3mf.
Delarna = rader i cad/delar.json med roll "design" och "export" (utskriftsfilen <id>.stl, redan i utskriftsläge:
lägsta z = 0). De radpackas på platta 1, 2, 3 … (10 mm mellanrum, centrerat per platta, 256 × 256 mm).

Inställningar per del (cad/utskrift.py): delens "bambu"-dict i delar.json (skriptet) med cad/utskrift.json över blir
objektinställningar (model_settings.config) – t.ex. wall_loops, sparse_infill_density, top_shell_layers,
bottom_shell_layers, enable_support, support_type, brim_type. Nyckeln "plast" (PLA, PETG, PETG-CF …; annars --material)
väljer filamentprofil och står i objektnamnet: "Lock (PETG-CF)". Olika plaster ger en filamentplats per plast, och varje
objekt får sin plats (extruder). Bambu Studio startas aldrig härifrån; filen öppnas av användaren.

Projektinställningarna (project_settings.config) kommer ur bambu/x2d-<plast>-project_settings.json (en per plast, slås ihop
till flera filamentplatser), som byggs av användarens installerade systemprofiler (X2D 0.4 + "0.20mm Standard @BBL X2D" +
filamentprofilen för plasten, t.ex. "Bambu PETG-CF @BBL X2D 0.4 nozzle",
`inherits` upplöst) lagda över skelettet bambu/x2d-referens-project_settings.json (en riktig X2D-export; ger
maskin-g-kod, per-variant-arrayer m.m.). Se bambu/README.txt.
"""
import argparse
import json
import re
import sys
import uuid
import zipfile
from pathlib import Path
from xml.sax.saxutils import quoteattr

HEM = Path(__file__).resolve().parent.parent
BAMBU_DIR = HEM / "bambu"
PROFILER = Path("/Applications/BambuStudio.app/Contents/Resources/profiles/BBL")
SKELETT = BAMBU_DIR / "x2d-referens-project_settings.json"
VERSION = "02.08.02.61"          # samma som skelettet / installerad Bambu Studio (Info.plist)
PROCESS = "0.20mm Standard @BBL X2D"
MASKIN = "Bambu Lab X2D 0.4 nozzle"
FIL_SUFFIX = " @BBL X2D 0.4 nozzle"
STANDARDPLAST = "PLA"
# filamentplatsernas färger i Bambu Studio när delarna har olika plast (en plast: grå som förut)
PLATSFARGER = ["#2E7DD7", "#E0A030", "#3BA55C", "#C0392B", "#8E44AD", "#16A085", "#D35400", "#7F8C8D"]
PLATTA = 256.0
GLAPP = 10.0
NS = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02"


# ---- mallbygge (kräver installerad Bambu Studio, görs sällan) ------------------------------------------------------
def _los(kind, name):
    d = json.loads((PROFILER / kind / f"{name}.json").read_text())
    base = _los(kind, d["inherits"]) if d.get("inherits") else {}
    base.update({k: v for k, v in d.items() if k != "inherits"})
    return base


def _num(v):
    try:
        return float(str(v).rstrip("%"))
    except ValueError:
        return None


def _lika(a, b):
    """Samma värde fast olika skrivsätt ('100' / '100%', '12.0' / '12')?"""
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_lika(x, y) for x, y in zip(a, b))
    if a == b:
        return True
    na, nb = _num(a), _num(b)
    return na is not None and nb is not None and na == nb


# ---- plast -> filamentprofil ---------------------------------------------------------------------------------------
def installerade_plaster():
    """Plastsorter med en installerad X2D 0.4-profil, som korta namn ("PLA", "PETG-CF", "Generic PETG" …)."""
    try:
        namn = sorted(f.name[:-len(FIL_SUFFIX) - 5] for f in (PROFILER / "filament").glob(f"*{FIL_SUFFIX}.json"))
    except OSError:
        return []
    return [_kort(n) for n in namn]


def _kort(profilnamn):
    n = profilnamn[:-len(FIL_SUFFIX)] if profilnamn.endswith(FIL_SUFFIX) else profilnamn
    if n.startswith("Bambu "):
        n = n[len("Bambu "):]
    return n[:-len(" Basic")] if n.endswith(" Basic") else n


def _finns(namn):
    return (PROFILER / "filament" / f"{namn}{FIL_SUFFIX}.json").exists()


def profil_for(plast):
    """(filamentprofil, varning|None). "PETG-CF" -> "Bambu PETG-CF @BBL X2D 0.4 nozzle". Saknas en installerad profil
    prövas basplasten ("PETG-CF2" -> PETG) och sist PLA – med en varning. Utan installerad Bambu Studio: PLA/PETG-namnen."""
    p = " ".join((plast or STANDARDPLAST).split())
    def kandidater(x):
        return [f"Bambu {x}", f"Bambu {x} Basic", f"Generic {x}", x]
    alla = {}
    try:
        alla = {f.name[:-len(FIL_SUFFIX) - 5].lower(): f.name[:-5]
                for f in (PROFILER / "filament").glob(f"*{FIL_SUFFIX}.json")}
    except OSError:
        pass
    def hitta(x):
        for k in kandidater(x):
            if k.lower() in alla:
                return alla[k.lower()]
        return None
    if not alla:                               # ingen Bambu Studio: bara mallarna i bambu/ går
        bas = p.upper().split("-")[0].split()[0]
        n = "PETG" if bas == "PETG" else "PLA"
        return f"Bambu {n} Basic{FIL_SUFFIX}", (None if p.upper() == n else f"ingen profil för {p} – {n}-mallen används")
    if (f := hitta(p)):
        return f, None
    bas = re.split(r"[-\s]", p)[0]
    if bas != p and (f := hitta(bas)):
        return f, f"ingen installerad profil för {p} – {_kort(f)} används"
    return f"Bambu PLA Basic{FIL_SUFFIX}", f"ingen installerad profil för {p} – PLA används"


def mallfil(profil):
    """bambu/x2d-<kort namn>-project_settings.json, t.ex. x2d-PETG-CF-…"""
    slug = re.sub(r"[^A-Za-z0-9+.-]+", "-", _kort(profil)).strip("-")
    return BAMBU_DIR / f"x2d-{slug}-project_settings.json"


def bygg_mall(material):
    """material = plastsort ("PETG-CF") eller filamentprofilens fulla namn."""
    profil = material if material.endswith(FIL_SUFFIX) else profil_for(material)[0]
    ref = json.loads(SKELETT.read_text())
    ut = dict(ref)
    # 1) process: systemprofilens värden över skelettet (samma nycklar; skrivsätt behålls om värdet är detsamma)
    proc = _los("process", PROCESS)
    for k, v in proc.items():
        if k in ref and k not in ("name", "from", "print_settings_id", "type", "instantiation", "inherits"):
            if not _lika(v, ref[k]):
                ut[k] = v
    ut["print_settings_id"] = PROCESS
    # 2) filament: en filamentplats (skelettet har två). Per filament har skelettet len/2 element per nyckel.
    fil = _los("filament", profil)
    hopp = {"type", "name", "from", "instantiation", "inherits", "setting_id", "description", "compatible_printers",
            "compatible_printers_condition", "filament_id", "filament_settings_id", "include"}
    for k, v in fil.items():
        if k in hopp or k not in ref:
            continue
        if not isinstance(ref[k], list):
            ut[k] = v
            continue
        n = len(ref[k]) // 2
        halv = ref[k][:n]
        cand = v if isinstance(v, list) else [v]
        if len(cand) == 1 and n > 1:
            cand = cand * n
        ut[k] = halv if _lika(cand, halv) or len(cand) != n else cand
    for k, v in ref.items():            # filamentnycklar utan motsvarighet i profilen: första filamentets halva
        if k.startswith("filament_") and k not in fil and isinstance(v, list) and len(v) in (2, 12):
            ut[k] = v[:len(v) // 2]
    # varianterna (Direct Drive/Bowden × Standard/High Flow/E3D) som Bambu Studio själv skriver dem: skelettets första
    # filament (profilens egen lista kan vara kortare, t.ex. bara "Direct Drive Standard")
    ut["filament_extruder_variant"] = ref["filament_extruder_variant"][:len(ref["filament_extruder_variant"]) // 2]
    ut["filament_self_index"] = ["1"] * (len(ref["filament_self_index"]) // 2)
    ut["default_filament_colour"] = [""]
    ut["filament_settings_id"] = [profil]
    ut["filament_ids"] = [fil.get("filament_id", "")]
    ut["default_filament_profile"] = [profil]
    ut["filament_map"] = ["1"]
    ut["filament_volume_map"] = ["0"]
    ut["filament_nozzle_map"] = ["0"]
    ut["flush_volumes_matrix"] = ["0"]
    ut["flush_volumes_vector"] = ref["flush_volumes_vector"][:2]
    ut["different_settings_to_system"] = ["", "", ""]      # process, 1 filament, maskin: inget avviker från systemet
    ut["version"] = VERSION
    ut["name"] = "project_settings"
    ut["from"] = "project"
    out = mallfil(profil)
    out.write_text(json.dumps(ut, ensure_ascii=False, indent=4))
    return out


def mall_for(profil):
    """Projektinställningar med en filamentplats för profilen (byggs och sparas i bambu/ första gången)."""
    f = mallfil(profil)
    if not f.exists():
        if not PROFILER.exists():
            f = BAMBU_DIR / "x2d-PLA-project_settings.json"
        else:
            f = bygg_mall(profil)
    return json.loads(f.read_text())


def kombinera(profiler):
    """En filamentplats per profil (i ordning). Per-filament-nycklar = de vars lista i skelettet (två filament) är dubbelt
    så lång som i en enplatsmall; de läggs efter varandra. Övrigt (process, maskin) från första mallen."""
    mallar = [mall_for(p) for p in profiler]
    ut = dict(mallar[0])
    n = len(mallar)
    if n == 1:
        return ut
    ref = json.loads(SKELETT.read_text())
    for k, v in mallar[0].items():
        if k in ("flush_volumes_matrix", "different_settings_to_system"):
            continue
        if isinstance(v, list) and isinstance(ref.get(k), list) and len(ref[k]) == 2 * len(v):
            ut[k] = [x for m in mallar for x in m.get(k, v)]
    per = len(mallar[0]["filament_self_index"])
    ut["filament_self_index"] = [str(i + 1) for i in range(n) for _ in range(per)]
    farger = [PLATSFARGER[i % len(PLATSFARGER)] for i in range(n)]
    ut["filament_colour"] = farger
    if "filament_multi_colour" in ut:
        ut["filament_multi_colour"] = farger
    ut["filament_map"] = ["1"] * n
    ut["filament_volume_map"] = ["0"] * n
    ut["filament_nozzle_map"] = ["0"] * n
    munstycken = len(ref["flush_volumes_matrix"]) // 4          # skelettet: 2 filament → 2 × 2×2
    ut["flush_volumes_matrix"] = ["0" if a == b else "152" for _ in range(munstycken) for a in range(n) for b in range(n)]
    ut["different_settings_to_system"] = [""] * (n + 2)
    return ut


# ---- projekt -> 3MF ------------------------------------------------------------------------------------------------
def _uuid(seed):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "skanna-bambu/" + seed))


def _mesh_xml(oid, verts, faces):
    r = [f'<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" xmlns="{NS}" '
         'xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" '
         'xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">\n'
         ' <metadata name="BambuStudio:3mfVersion">1</metadata>\n <resources>\n'
         f'  <object id="{oid}" p:UUID="{_uuid(f"mesh{oid}")}" type="model">\n   <mesh>\n    <vertices>\n']
    r += [f'     <vertex x="{x:.6g}" y="{y:.6g}" z="{z:.6g}"/>\n' for x, y, z in verts]
    r.append("    </vertices>\n    <triangles>\n")
    r += [f'     <triangle v1="{a}" v2="{b}" v3="{c}"/>\n' for a, b, c in faces]
    r.append("    </triangles>\n   </mesh>\n  </object>\n </resources>\n <build/>\n</model>\n")
    return "".join(r)


def packa(storlekar):
    """Radpackning över flera plattor: [(bredd, djup)] -> [(platta_index, x, y)] (nedre vänstra hörn i plattans eget
    system, varje plattas innehåll centrerat) och en lista med index för delar som inte ryms ens ensamma."""
    marg = 5.0
    maxb = PLATTA - 2 * marg
    plattor = [[]]                       # per platta: [(del_index, x, y)]
    x = y = radh = 0.0
    for i, (w, d) in enumerate(storlekar):
        if plattor[-1] and x > 0 and x + w > maxb:
            x, y, radh = 0.0, y + radh + GLAPP, 0.0
        if plattor[-1] and y + d > maxb:             # ryms inte på plattan: ny platta
            plattor.append([])
            x = y = radh = 0.0
        plattor[-1].append((i, x, y))
        x += w + GLAPP
        radh = max(radh, d)
    pos = [None] * len(storlekar)
    for pi, pl in enumerate(plattor):
        xmax = max(px + storlekar[i][0] for i, px, py in pl)
        ymax = max(py + storlekar[i][1] for i, px, py in pl)
        ox, oy = (PLATTA - xmax) / 2, (PLATTA - ymax) / 2
        for i, px, py in pl:
            pos[i] = (pi, px + ox, py + oy)
    stora = [i for i, (w, d) in enumerate(storlekar) if w > PLATTA or d > PLATTA]
    return pos, stora


def plattorigo(index, antal):
    """Bambu Studio lägger plattorna i ett rutnät med ceil(sqrt(n)) kolumner, rad för rad nedåt (−Y), med
    1,2 × plattstorlek mellan origon. Verifierat mot referensfilen: platta 2 vid x +307,2, platta 3 vid y −307,2."""
    import math
    kol = math.ceil(math.sqrt(antal))
    return (index % kol) * 1.2 * PLATTA, -(index // kol) * 1.2 * PLATTA


def bygg_3mf(projekt, delar_ids, material, ut, stl_mapp=None, namn_tillagg=""):
    import numpy as np
    import trimesh
    prj = Path(projekt).expanduser().resolve()
    cad = prj / "cad"
    delar = json.loads((cad / "delar.json").read_text())["delar"]
    # användarens namn och ordning ur appen (cad/objekt.json) går före delar.json
    try:
        ov = json.loads((cad / "objekt.json").read_text())
    except (OSError, ValueError):
        ov = {}
    for d in delar:
        if (ov.get("namn") or {}).get(d["id"]):
            d["namn"] = ov["namn"][d["id"]]
    ordning = {i: k for k, i in enumerate(ov.get("ordning") or [])}
    delar.sort(key=lambda d: ordning.get(d["id"], len(ordning)))
    val = [d for d in delar if d.get("roll") == "design" and d.get("export")
           and (not delar_ids or d["id"] in delar_ids)]
    if stl_mapp:
        val = [d for d in val if (Path(stl_mapp) / f"{d['id']}.stl").exists()]
    if not val:
        raise SystemExit("inga konstruktionsdelar med utskriftsfil att exportera (kör Bygg om först?)")
    from utskrift import gallande, las
    utsk = las(cad)
    # plast och objektinställningar per del; en filamentplats per använd profil (i delarnas ordning)
    inst_per_del, profiler, plats = [], [], []
    for d in val:
        plast, s = gallande(d["id"], d.get("bambu"), utsk, material)
        prof, varn = profil_for(plast)
        if varn:
            print(f"varning: {d.get('namn') or d['id']}: {varn}", file=sys.stderr)
        if prof not in profiler:
            profiler.append(prof)
        inst_per_del.append((plast, s))
        plats.append(profiler.index(prof) + 1)
    inst = json.dumps(kombinera(profiler), ensure_ascii=False, indent=4)

    meshar = []
    for d in val:
        f = Path(stl_mapp) / f"{d['id']}.stl" if stl_mapp else cad / (Path(d["export"]).stem + ".stl")
        m = trimesh.load(str(f), force="mesh")
        v = np.asarray(m.vertices, dtype=float)
        lo, hi = v.min(axis=0), v.max(axis=0)
        meshar.append((d, m, lo, hi))
    storlekar = [(hi[0] - lo[0], hi[1] - lo[1]) for _, _, lo, hi in meshar]
    pos, stora = packa(storlekar)
    nplattor = max(p[0] for p in pos) + 1
    for i in stora:
        print(f"varning: {meshar[i][0]['id']} ryms inte på en platta (256 × 256 mm), ligger ändå på platta {pos[i][0] + 1}",
              file=sys.stderr)

    # 3dmodel.model: varje del = wrapper-objekt (id 2i) med en komponent (mesh-objekt id 2i-1 i egen fil)
    res, build, rels, cfg_obj, cfg_plat, filer = [], [], [], [], {}, {}
    for i, ((d, m, lo, hi), (pl, px, py), (plast, s), fp) in enumerate(zip(meshar, pos, inst_per_del, plats), start=1):
        ox, oy = plattorigo(pl, nplattor)
        mid, wid = 2 * i - 1, 2 * i
        namn = f'{d.get("namn") or d["id"]}{namn_tillagg} ({plast})'          # plasten i namnet, så att delarna inte blandas ihop
        c = (lo + hi) / 2
        v = np.asarray(m.vertices) - c                    # meshen centrerad kring origo, som i Bambus egna filer
        fil = f"3D/Objects/object_{wid}.model"
        filer[fil] = _mesh_xml(mid, v.tolist(), np.asarray(m.faces).tolist())
        rels.append(f' <Relationship Target="/{fil}" Id="rel-{i}" '
                    'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\n')
        res.append(f'  <object id="{wid}" name={quoteattr(namn)} p:UUID="{_uuid(f"obj{wid}")}" type="model">\n   <components>\n'
                   f'    <component p:path="/{fil}" objectid="{mid}" p:UUID="{_uuid(f"comp{wid}")}" '
                   'transform="1 0 0 0 1 0 0 0 1 0 0 0"/>\n   </components>\n  </object>\n')
        tx, ty, tz = ox + px + (hi[0] - lo[0]) / 2, oy + py + (hi[1] - lo[1]) / 2, (hi[2] - lo[2]) / 2
        build.append(f'  <item objectid="{wid}" p:UUID="{_uuid(f"item{wid}")}" '
                     f'transform="1 0 0 0 1 0 0 0 1 {tx:.6g} {ty:.6g} {tz:.6g}" printable="1"/>\n')
        extra = "".join(f'    <metadata key={quoteattr(k)} value={quoteattr(str(v_))}/>\n' for k, v_ in s.items())
        cfg_obj.append(
            f'  <object id="{wid}">\n    <metadata key="name" value={quoteattr(namn)}/>\n'
            f'    <metadata key="extruder" value="{fp}"/>\n{extra}    <metadata face_count="{len(m.faces)}"/>\n'
            f'    <part id="{mid}" subtype="normal_part" uuid="{_uuid(f"part{mid}")}">\n'
            f'      <metadata key="name" value={quoteattr(namn)}/>\n'
            '      <metadata key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>\n'
            f'      <metadata key="source_file" value={quoteattr(d["export"])}/>\n'
            '      <metadata key="source_object_id" value="0"/>\n      <metadata key="source_volume_id" value="0"/>\n'
            f'      <mesh_stat face_count="{len(m.faces)}" edges_fixed="0" degenerate_facets="0" facets_removed="0" '
            'facets_reversed="0" backwards_edges="0"/>\n    </part>\n  </object>\n')
        cfg_plat.setdefault(pl, []).append(f'    <model_instance>\n      <metadata key="object_id" value="{wid}"/>\n'
                        f'      <metadata key="instance_id" value="0"/>\n'
                        f'      <metadata key="identify_id" value="{100 + i}"/>\n    </model_instance>\n')

    modell = (f'<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" xmlns="{NS}" '
              'xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" '
              'xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">\n'
              f' <metadata name="Application">BambuStudio-{VERSION}</metadata>\n'
              ' <metadata name="BambuStudio:3mfVersion">1</metadata>\n'
              f' <metadata name="Title">{prj.name.replace("&", "&amp;").replace("<", "&lt;")}</metadata>\n'
              ' <resources>\n' + "".join(res) + f' </resources>\n <build p:UUID="{_uuid("build")}">\n'
              + "".join(build) + ' </build>\n</model>\n')
    model_cfg = ('<?xml version="1.0" encoding="UTF-8"?>\n<config>\n' + "".join(cfg_obj)
                 + "".join(
                     '  <plate>\n    <metadata key="plater_id" value="%d"/>\n' % (pl + 1)
                     + f'    <metadata key="plater_name" value={quoteattr(prj.name if nplattor == 1 else f"{prj.name} {pl + 1}")}/>\n'
                     '    <metadata key="locked" value="false"/>\n'
                     '    <metadata key="filament_map_mode" value="Auto For Flush"/>\n'
                     f'    <metadata key="filament_maps" value="{" ".join(["1"] * len(profiler))}"/>\n'
                     f'    <metadata key="filament_volume_maps" value="{" ".join(["0"] * len(profiler))}"/>\n'
                     + "".join(cfg_plat[pl]) + '  </plate>\n' for pl in sorted(cfg_plat))
                 + '</config>\n')
    ctypes = ('<?xml version="1.0" encoding="UTF-8"?>\n'
              '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
              ' <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n'
              ' <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\n'
              '</Types>\n')
    toprels = ('<?xml version="1.0" encoding="UTF-8"?>\n'
               '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
               ' <Relationship Target="/3D/3dmodel.model" Id="rel-1" '
               'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\n</Relationships>\n')
    modelrels = ('<?xml version="1.0" encoding="UTF-8"?>\n'
                 '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
                 + "".join(rels) + '</Relationships>\n')
    slice_info = ('<?xml version="1.0" encoding="UTF-8"?>\n<config>\n  <header>\n'
                  '    <header_item key="X-BBL-Client-Type" value="slicer"/>\n'
                  f'    <header_item key="X-BBL-Client-Version" value="{VERSION}"/>\n  </header>\n</config>\n')
    ut = Path(ut)
    ut.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(ut, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ctypes)
        z.writestr("_rels/.rels", toprels)
        z.writestr("3D/3dmodel.model", modell)
        z.writestr("3D/_rels/3dmodel.model.rels", modelrels)
        for n, x in filer.items():
            z.writestr(n, x)
        z.writestr("Metadata/model_settings.config", model_cfg)
        z.writestr("Metadata/project_settings.config", inst)
        z.writestr("Metadata/slice_info.config", slice_info)
    print(f"{len(val)} delar på {nplattor} platta/plattor: "
          + ", ".join(f"{d['id']} ({p})" for d, (p, _) in zip(val, inst_per_del)), file=sys.stderr)
    return ut


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("projekt", nargs="?")
    ap.add_argument("--delar", default="")
    ap.add_argument("--material", default=STANDARDPLAST, help="plast för delar utan egen (PLA, PETG, PETG-CF …)")
    ap.add_argument("--ut")
    ap.add_argument("--bygg-mall", action="store_true")
    ap.add_argument("--stl-mapp")
    ap.add_argument("--namn-tillagg", default="")
    a = ap.parse_args()
    if a.bygg_mall:
        print(bygg_mall(a.material))
        return 0
    if not a.projekt:
        ap.error("projekt saknas")
    prj = Path(a.projekt).expanduser().resolve()
    ut = Path(a.ut) if a.ut else prj / "cad" / f"{prj.name}-bambu.3mf"
    ids = {s.strip() for s in a.delar.split(",") if s.strip()}
    ut = bygg_3mf(prj, ids, a.material, ut, stl_mapp=a.stl_mapp, namn_tillagg=a.namn_tillagg)
    print(ut)
    return 0


if __name__ == "__main__":
    sys.exit(main())
