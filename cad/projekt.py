"""Gemensam hjälp för del-skript i ett Skanna-projekt (med eller utan skanning).

Ett del-skript ligger i <projekt>/cad/skript/NN-<id>.py och körs som `python skript.py <projekt>` av
`bygg_projekt.sh`. Det ritar en eller flera delar med build123d och lämnar över dem hit:

    import os, sys
    sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
    from projekt import Projekt

    prj = Projekt(sys.argv[1])
    P = prj.parametrar("Låda", {                    # grupp = prefix i appens måttlista ("Låda: bredd")
        "bredd": (60.0, "mm"),                      # (värde, enhet) – källa blir "mall"
        "höjd": (30.0, "mm", "antagande", 0.5),     # (värde, enhet, källa, osäkerhet)
        "antal fack": (3, "st"),                    # heltal: läs med int(P["antal fack"])
    })
    solid = Box(P["bredd"], ...)
    prj.del_("lada", "Låda", solid, farg="#2E7DD7", beskrivning="…")   # step + ytor.json + 3mf/stl + delar.json
    prj.spara(beskrivning="…", fragor=[...])                          # geometri.json (bara den här gruppens mått)

Användarens värden från appen (cad/parametrar-anvandare.json, nyckel "Grupp: namn") går alltid före.
Allt är i mm, samma ram som skanningen (om det finns en): X = längsta, Z = kortaste axeln.
"""
import json
from pathlib import Path

from ytor import export_faces, register_part

KALLOR = ("användare", "uppmätt", "skanning", "standard", "antagande", "mall")


class Projekt:
    def __init__(self, path):
        self.dir = Path(path).expanduser().resolve()
        self.cad = self.dir / "cad"
        self.cad.mkdir(parents=True, exist_ok=True)
        self.grupp = None
        self._params = []          # [(namn, värde, enhet, källa, osäkerhet)]
        self._mattlinjer = []      # [{namn, fran, till, del, faktor, grupp}] – var måtten sitter (appens handtag)
        self.info = self._read(self.dir / "projekt.json", {})

    # ---- läsa ----------------------------------------------------------------------------------------------------
    @staticmethod
    def _read(path, default):
        try:
            return json.loads(Path(path).read_text())
        except (OSError, ValueError):
            return default

    @property
    def har_skanning(self):
        return (self.dir / "modell" / "modell-mm.obj").exists()

    @property
    def skanning(self):
        """modell/modell-mm.obj om projektet har en skalad skanning, annars None."""
        p = self.dir / "modell" / "modell-mm.obj"
        return p if p.exists() else None

    def geometri(self):
        return self._read(self.cad / "geometri.json", {"parametrar": [], "fragor": []})

    def matt(self, namn, standard=None):
        """Läs ett mått som ett annat skript (t.ex. en referensdel) har skrivit i geometri.json."""
        for p in self.geometri().get("parametrar", []):
            if p.get("namn") == namn and p.get("varde") is not None:
                return float(p["varde"])
        if standard is None:
            raise KeyError(f"måttet '{namn}' finns inte i geometri.json – bygg referensdelen först")
        return standard

    # ---- parametrar ----------------------------------------------------------------------------------------------
    def parametrar(self, grupp, spec):
        """Registrera gruppens mått och returnera {namn: värde} med användarens egna värden inlagda."""
        import unicodedata
        nfc = lambda t: unicodedata.normalize("NFC", t)   # macOS-filnamn (importerade delar) är NFD
        grupp = nfc(grupp)
        self.grupp = grupp
        overrides = {nfc(k): v for k, v in self._read(self.cad / "parametrar-anvandare.json", {}).items()}
        out = {}
        for namn, s in spec.items():
            s = s if isinstance(s, tuple) else (s,)
            varde = float(s[0])
            enhet = s[1] if len(s) > 1 else "mm"
            kalla = s[2] if len(s) > 2 else "mall"
            osak = s[3] if len(s) > 3 else None
            full = nfc(f"{grupp}: {namn}")
            if full in overrides:
                varde, kalla = float(overrides[full]), "användare"
            out[namn] = varde
            self._params.append((full, varde, enhet, kalla, osak))
        return out

    def mattlinje(self, namn, fran, till, del_=None, faktor=1.0):
        """Var ett mått sitter: en måttlinje från → till (mm, modellens ram, delen på sin plats). Appen ritar den med ett
        handtag i till-änden: dra handtaget längs linjen (längdändring × faktor = ändring av måttet) eller klicka för att
        skriva in ett värde. namn = kort namn i gruppen ("bredd") eller hela ("Låda: bredd"). faktor: t.ex. 2 om måttet är
        symmetriskt och linjen bara går till mitten. Märk alla mått som användaren rimligen vill dra i."""
        import unicodedata
        full = namn if (": " in namn or not getattr(self, "grupp", None)) else f"{self.grupp}: {namn}"
        self._mattlinjer.append({"namn": unicodedata.normalize("NFC", full),
                                 "fran": [round(float(x), 3) for x in fran], "till": [round(float(x), 3) for x in till],
                                 "del": del_, "faktor": float(faktor), "grupp": getattr(self, "grupp", None)})

    # ---- delar ---------------------------------------------------------------------------------------------------
    def _kantbehandla(self, pid, solid):
        """Läs cad/kantbehandling.json och gör fillet/fas på poster med del == pid (i filens ordning).
        Kanten = den i solid.edges() vars mittpunkt (position_at(0.5)) ligger närmast `mitt`, inom 0,5 mm.
        Varje post får status "ok" eller "fel: <orsak>" och filen skrivs tillbaka. Returnerar behandlad solid."""
        from build123d import chamfer, fillet
        path = self.cad / "kantbehandling.json"
        poster = self._read(path, None)
        if not isinstance(poster, list):
            return solid
        ändrad = False
        for post in poster:
            if post.get("del") != pid:
                continue
            try:
                mitt = post["mitt"]
                bästa, bd = None, 1e9
                for e in solid.edges():
                    c = e.position_at(0.5)
                    d = ((c.X - mitt[0]) ** 2 + (c.Y - mitt[1]) ** 2 + (c.Z - mitt[2]) ** 2) ** 0.5
                    if d < bd:
                        bästa, bd = e, d
                if bästa is None or bd > 0.5:
                    raise ValueError(f"ingen kant nära mitt (närmast {bd:.2f} mm)")
                matt = float(post["matt"])
                if post.get("typ") == "fillet":
                    ny = fillet(bästa, matt)
                elif post.get("typ") == "fas":
                    ny = chamfer(bästa, matt)
                else:
                    raise ValueError(f"okänd typ {post.get('typ')}")
                if ny is None or not ny.is_valid or ny.volume <= 0:
                    raise ValueError("ogiltigt resultat")
                solid = ny
                post["status"] = "ok"
            except Exception as ex:
                post["status"] = f"fel: {str(ex).splitlines()[0][:80] if str(ex) else type(ex).__name__}"
            ändrad = True
        if ändrad:
            path.write_text(json.dumps(poster, ensure_ascii=False, indent=2))
        return solid

    @staticmethod
    def _likadan_rotation(orig, ut):
        """Hitta en av de 24 axelrotationerna R så att R(orig) == ut (volym, tyngdpunkt och bbox). None om ingen."""
        from build123d import Axis
        import itertools
        def sig(s):
            bb = s.bounding_box()
            c = s.center()
            return (round(s.volume, 1), round(bb.size.X, 1), round(bb.size.Y, 1), round(bb.size.Z, 1),
                    round(c.X - bb.min.X, 1), round(c.Y - bb.min.Y, 1), round(c.Z - bb.min.Z, 1))
        mål = sig(ut)
        for ax, ay, az in itertools.product(range(4), repeat=3):
            r = orig
            for axis, n in ((Axis.X, ax), (Axis.Y, ay), (Axis.Z, az)):
                if n:
                    r = r.rotate(axis, 90 * n)
            if sig(r) == mål:
                return (ax, ay, az)
        return None

    def del_(self, pid, namn, solid, roll="design", farg="#2E7DD7", beskrivning=None, utskrift=True,
             utskrift_solid=None, bambu=None, kropp_namn=None, kropp_farger=None, kropp_grupper=None):
        """Exportera en del: <id>.step, <id>-ytor.json (appens 3D-vy), och om utskrift: <id>.3mf/.stl i utskriftsläge
        (lägsta z på plattan, centrerad).

        utskrift_solid = egen orientering för utskrift: antingen en funktion `lambda s: s.rotate(Axis.X, 180)` (bäst:
        tillämpas på den kantbehandlade soliden) eller en färdigroterad solid (då letas rotationen upp bland de 24
        axelrotationerna och tillämpas på den behandlade soliden; hittas ingen används den obehandlade).
        bambu = {"wall_loops": "4", "plast": "PETG", …}: Bambu Studio-inställningar för delen (skrivs till delar.json) –
        utgångsläget; cad/utskrift.json (appen/agenten) går före vid exporten, se cad/utskrift.py.
        Kantbehandling (cad/kantbehandling.json) görs först, så step/ytor/3mf alla får fillet/fas."""
        import os
        from build123d import Location, Mesher, export_step, export_stl
        snabb = bool(os.environ.get("SKANNA_SNABB"))   # känslighetsbygget (kanslighet.py) behöver bara ytorna
        orig = solid
        solid = self._kantbehandla(pid, solid)
        if not snabb:
            export_step(solid, str(self.cad / f"{pid}.step"))
        n = export_faces(solid, self.cad / f"{pid}-ytor.json", kropp_namn=kropp_namn, kropp_farger=kropp_farger, kropp_grupper=kropp_grupper)
        export = f"{pid}.3mf" if (utskrift and snabb) else None
        if utskrift and not snabb:
            if utskrift_solid is None:
                ps = solid
            elif callable(utskrift_solid):
                ps = utskrift_solid(solid)
            elif solid is orig:
                ps = utskrift_solid
            else:
                rot = self._likadan_rotation(orig, utskrift_solid)
                ps = utskrift_solid
                if rot is not None:
                    from build123d import Axis
                    ps = solid
                    for axis, k in ((Axis.X, rot[0]), (Axis.Y, rot[1]), (Axis.Z, rot[2])):
                        if k:
                            ps = ps.rotate(axis, 90 * k)
            bb = ps.bounding_box()
            printed = ps.moved(Location((-(bb.min.X + bb.max.X) / 2, -(bb.min.Y + bb.max.Y) / 2, -bb.min.Z)))
            export_stl(printed, str(self.cad / f"{pid}.stl"), tolerance=0.01, angular_tolerance=0.1)
            try:
                m = Mesher()
                m.add_shape(printed)
                m.write(str(self.cad / f"{pid}.3mf"))
            except AttributeError:
                # Någon yta gick inte att triangulera (händer i importerad STEP, t.ex. koner med spets/söm):
                # Mesher kraschar på den. Gör 3MF av STL:en i stället – den hoppar över ytan, vilket ger ett litet
                # hål i nätet som Bambu Studio lagar vid import.
                import trimesh
                t = trimesh.load(str(self.cad / f"{pid}.stl"))
                _skriv_3mf(t.vertices, t.faces, self.cad / f"{pid}.3mf")
                print(f"Varning: {pid}: någon yta gick inte att triangulera – 3MF gjord från STL:en "
                      f"(litet hål i nätet, Bambu Studio lagar det)", flush=True)
            export = f"{pid}.3mf"
        import sys
        from pathlib import Path as _P
        s = _P(sys.argv[0]).resolve() if sys.argv and sys.argv[0] else None
        skript = s.name if s and s.parent == (self.cad / "skript").resolve() else None
        register_part(self.cad, pid, namn, f"{pid}-ytor.json", roll, farg, export=export, beskrivning=beskrivning,
                      bambu=bambu, skript=skript)
        print(f"{pid}: {n} ytor")
        return n

    # ---- geometri.json -------------------------------------------------------------------------------------------
    def spara(self, beskrivning=None, fragor=None, status=None, avvikelse=None):
        """Skriv gruppens mått (och ev. frågor med id-prefix = grupp) till geometri.json utan att röra andras."""
        geo = self.geometri()
        g = self.grupp
        prefix = f"{g}: " if g else None
        params = [p for p in geo.get("parametrar", []) if not (prefix and p.get("namn", "").startswith(prefix))]
        for full, v, enhet, kalla, osak in self._params:
            v = int(round(v)) if enhet in ("st", "°") and abs(v - round(v)) < 1e-9 else round(v, 3)
            params.append({"namn": full, "varde": v, "enhet": enhet, "kalla": kalla, "osakerhet": osak, "grupp": g})
        geo["parametrar"] = params
        geo["mattlinjer"] = [m for m in geo.get("mattlinjer", []) if m.get("grupp") != g] + self._mattlinjer
        if fragor is not None:
            geo["fragor"] = [f for f in geo.get("fragor", []) if f.get("grupp") != g] + [dict(f, grupp=g) for f in fragor]
        if beskrivning and not geo.get("beskrivning"):
            geo["beskrivning"] = beskrivning
        if status:
            geo["status"] = status
        elif not geo.get("status"):
            geo["status"] = "utkast"
        if avvikelse:
            geo["avvikelse"] = avvikelse
        (self.cad / "geometri.json").write_text(json.dumps(geo, ensure_ascii=False, indent=2))
        return geo


def _skriv_3mf(verts, tris, path):
    """Minimal 3MF (mm, ett nät) utan lxml/lib3mf – reserv när build123d:s Mesher inte klarar formen."""
    import zipfile
    v = "".join(f'<vertex x="{x:.5f}" y="{y:.5f}" z="{z:.5f}"/>' for x, y, z in verts)
    t = "".join(f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in tris)
    model = ('<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" '
             'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>'
             f'<object id="1" type="model"><mesh><vertices>{v}</vertices><triangles>{t}</triangles></mesh></object>'
             '</resources><build><item objectid="1"/></build></model>')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                   '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                   '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>')
        z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   '<Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
        z.writestr("3D/3dmodel.model", model)
