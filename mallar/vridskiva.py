# mall: Vridskiva
# beskrivning: Tvådelad utskrivbar vridskiva för fotoskanning med 24 gradmarkeringar och snäpplägen, inga köpdelar.
# id: vridskiva
"""Vridskiva för fotoskanning: två utskrivna delar, bas och topp, inga köpdelar.

- Basen har en tapp i mitten som centrerar toppen och en låg glidring som toppen vilar och glider på (glidringen tar
  vikten och håller toppen plan; tappen styr bara i sidled).
- Toppens kant har ett V-hack per läge (24 → var 15°). En fjädrande tunga (flexure) i basen, bak (+Y), har en knopp
  som klickar i hacken. Tungan är en tunn böjd vägg som står fritt i ett fönster i basplattan – utskriven i basen.
- Pekaren sitter fram (−Y). Graderingar och siffror (0/90/180/270) är graverade i toppens ovansida.

Ram: mm, Z uppåt, basens undersida i z = 0, vridaxeln längs Z. Delarna ritas sammansatta (toppen på glidringen, i
läge 0) så att appen visar hela vridskivan; toppens utskriftsfil vänds med ovansidan nedåt.

Körs: python mallar/vridskiva.py <projektmapp>
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
from projekt import Projekt  # noqa: E402

from build123d import Align, Axis, Box, Cone, Cylinder, Face, Pos, Rot, Text, Vector, Wire, extrude  # noqa: E402

STANDARD = {
    "antal lägen": (24, "st"),                  # hack och gradmarkeringar (24 → var 15°)
    "snäpplägen": (1, "st"),                    # 1 = fjädrande tunga i basen som klickar i hacken, 0 = fritt
    "bas diameter": (176.0, "mm"),
    "bas tjocklek": (5.0, "mm"),
    "topp diameter": (160.0, "mm"),
    "topp tjocklek": (6.0, "mm"),
    "tapp diameter": (16.0, "mm"),              # basens mitttapp
    "tappspel": (0.3, "mm"),                    # hålet i toppen = tapp diameter + spel
    "glidring diameter": (100.0, "mm"),         # toppen vilar på den här ringen
    "glidring bredd": (2.4, "mm"),
    "glidring höjd": (2.0, "mm"),
    "fjäder längd": (35.0, "mm"),
    "fjäder tjocklek": (1.4, "mm"),
    "hack djup": (0.9, "mm"),                   # så långt knoppen griper in i hacket
    "knopp förspänning": (0.2, "mm"),           # knoppen trycker så här mycket djupare än hacket (centrerar läget)
    "graderingsdjup": (0.6, "mm"),
    "gummifot diameter": (10.0, "mm"),
    "gummifot djup": (1.0, "mm"),
}

FARG = {"bas": "#8A939E", "topp": "#3C3C3C"}


# ---- hjälp ---------------------------------------------------------------------------------------------------------
def cyl(r, z0, z1, x=0.0, y=0.0):
    return Pos(x, y, z0) * Cylinder(r, z1 - z0, align=(Align.CENTER, Align.CENTER, Align.MIN))


def prisma(punkter, z0, z1):
    """Rak prisma av en sluten 2D-polygon (x, y) mellan z0 och z1."""
    w = Wire.make_polygon([Vector(x, y, z0) for x, y in punkter], close=True)
    return extrude(Face(w), amount=z1 - z0, dir=(0, 0, 1))


def sektor(r0, r1, v0, v1, z0, z1, n=48):
    """Ringsektor r0..r1 mellan vinklarna v0..v1 (grader) som prisma."""
    vs = [math.radians(v0 + (v1 - v0) * i / n) for i in range(n + 1)]
    pts = [(r1 * math.cos(v), r1 * math.sin(v)) for v in vs] + [(r0 * math.cos(v), r0 * math.sin(v)) for v in reversed(vs)]
    return prisma(pts, z0, z1)


def en_solid(shape, namn):
    s = shape.solids()
    if len(s) != 1:
        raise RuntimeError(f"{namn}: {len(s)} solids, väntade 1")
    return s[0]


# ---- geometri ------------------------------------------------------------------------------------------------------
def bygg(P):
    """Returnera ({id: solid} i sammansatt läge, härledda mått)."""
    N = int(round(P["antal lägen"]))
    snapp = int(round(P["snäpplägen"])) == 1
    Rb, tb = P["bas diameter"] / 2, P["bas tjocklek"]
    Rt, tt = P["topp diameter"] / 2, P["topp tjocklek"]
    hdj, gd = P["hack djup"], P["graderingsdjup"]
    z_u = tb + P["glidring höjd"]                       # toppens undersida vilar på glidringen
    z_top = z_u + tt
    r_tapp = P["tapp diameter"] / 2
    r_hal = r_tapp + P["tappspel"] / 2
    hal_djup = tt - 1.2                                 # blint hål, 1,2 mm tak kvar i toppen
    hd = {"z_topp_undersida": z_u, "z_topp_ovansida": z_top}

    # ---- TOPP ----------------------------------------------------------------------------------------------------
    topp = cyl(Rt, z_u, z_top)
    topp -= cyl(r_hal, z_u - 1, z_u + hal_djup)
    topp -= Pos(0, 0, z_u - 0.01) * Cone(r_hal + 0.6, r_hal, 0.6, align=(Align.CENTER, Align.CENTER, Align.MIN))
    # V-hack i kanten, ett per läge; läge 0 har sitt hack vid pekaren (−Y) och ett mitt emot vid tungan (+Y)
    hack = None
    for k in range(N):
        h = Rot(0, 0, -90 + 360 * k / N) * prisma([(Rt - hdj, 0), (Rt + 2, -(hdj + 2)), (Rt + 2, hdj + 2)],
                                                  z_u - 1, z_top + 1)
        hack = h if hack is None else hack + h
    topp -= hack

    # graderingar: var 360/N grader, längre/bredare var 90°, siffror vid de långa. 0 vid pekaren (−Y);
    # siffran anger hur långt toppen vridits moturs (sett ovanifrån).
    r_ut = Rt - hdj - 1.5
    grav = None
    for k in range(N):
        vinkel = 360 * k / N
        lang = abs(vinkel / 90 - round(vinkel / 90)) < 1e-9
        langd, bredd = (12.0, 1.2) if lang else (6.0, 0.8)
        v = -90 - vinkel
        g = Rot(0, 0, v) * Pos(r_ut - langd / 2, 0, z_top - gd) * Box(langd, bredd, gd + 1,
                                                                      align=(Align.CENTER, Align.CENTER, Align.MIN))
        if lang:
            txt = Text(str(int(round(vinkel))), font_size=7, align=(Align.CENTER, Align.CENTER))
            vr = math.radians(v)
            rt = r_ut - langd - 6
            g += extrude(Pos(rt * math.cos(vr), rt * math.sin(vr), z_top - gd) * Rot(0, 0, v + 90) * txt,
                         amount=gd + 1)
        grav = g if grav is None else grav + g
    # centrering: grunt kors och ringar (Ø 40/80/120)
    cd = 0.4
    for r in (20.0, 40.0, 60.0):
        grav += cyl(r + 0.3, z_top - cd, z_top + 1) - cyl(r - 0.3, z_top - cd - 1, z_top + 2)
    for vr in (0, 90):
        grav += Rot(0, 0, vr) * Pos(0, 0, z_top - cd) * Box(2 * (r_ut - 22), 0.6, cd + 1,
                                                            align=(Align.CENTER, Align.CENTER, Align.MIN))
    topp = en_solid(topp - grav, "topp")

    # ---- BAS -----------------------------------------------------------------------------------------------------
    bas = cyl(Rb, 0, tb)
    rg, bg = P["glidring diameter"] / 2, P["glidring bredd"] / 2
    bas += cyl(rg + bg, tb - 0.01, z_u) - cyl(rg - bg, tb - 1, z_u + 1)            # glidring
    z_tapp = z_u + hal_djup - 0.5
    bas += cyl(r_tapp, tb - 0.01, z_tapp - 0.8)
    bas += Pos(0, 0, z_tapp - 0.8) * Cone(r_tapp, r_tapp - 0.8, 0.8, align=(Align.CENTER, Align.CENTER, Align.MIN))

    # pekare fram (−Y): trekantig stolpe upp till toppens ovansida, spetsen 0,8 mm från toppens kant
    r_spets = Rt + 0.8
    bas += prisma([(0, -r_spets), (3, -r_spets - 3), (3, -Rb + 0.01), (-3, -Rb + 0.01), (-3, -r_spets - 3)],
                  0, z_top)

    if snapp:
        # fjädrande tunga bak: en böjd vägg koncentrisk med toppen, fri i ett fönster genom plattan,
        # fast i en rot i ena änden; knoppen i den fria änden (vid +Y) pekar inåt mot hacken i toppens kant
        L, t = P["fjäder längd"], P["fjäder tjocklek"]
        glipa, w = 1.0, 1.5
        ingrepp = hdj + P["knopp förspänning"]
        r_in, r_ytt = Rt + glipa, Rt + glipa + t
        spann = math.degrees(L / (r_in + t / 2))
        v_knopp = 90.0
        v_fri = v_knopp - math.degrees((w + 1.0) / Rt)
        r_spets_k = Rt - ingrepp
        h = z_top
        bas -= sektor(r_spets_k - 0.8, r_ytt + 1.0, v_fri, v_knopp + spann, -1, tb + 1)        # fönster
        bas += sektor(r_in, Rb - 0.01, v_knopp + spann - 0.3, v_knopp + spann + 5, 0, h)       # rot
        bas += sektor(r_in, r_ytt, v_knopp - math.degrees(w / Rt), v_knopp + spann, 0, h)       # tungan
        knopp = prisma([(r_in + 0.1, -w), (r_in + 0.1, w), (r_spets_k + w, w), (r_spets_k, 0), (r_spets_k + w, -w)],
                       0, h)
        bas += Rot(0, 0, v_knopp) * knopp
        hd.update(knopp_spets=[0.0, round(r_spets_k, 3), round((z_u + z_top) / 2, 3)], fjader_vinkel=round(spann, 2))

    # gummifötter (urtag på undersidan)
    rf = P["gummifot diameter"] / 2
    for v in (45, 135, 225, 315):
        bas -= cyl(rf, -1, P["gummifot djup"], 70 * math.cos(math.radians(v)), 70 * math.sin(math.radians(v)))
    bas = en_solid(bas, "bas")
    return {"bas": bas, "topp": topp}, hd


# ---- körning -------------------------------------------------------------------------------------------------------
def main():
    prj = Projekt(sys.argv[1])
    P = prj.parametrar("Vridskiva", STANDARD)
    delar, hd = bygg(P)
    snapp = int(round(P["snäpplägen"])) == 1

    prj.del_("bas", "Vridskiva – bas", delar["bas"], farg=FARG["bas"],
             beskrivning="Bas med mitttapp, glidring och pekare" + (" och fjädrande snäpptunga" if snapp else ""),
             bambu={"wall_loops": 3, "sparse_infill_density": "20%", "enable_support": 0, "brim_type": "no_brim"})
    prj.del_("topp", "Vridskiva – topp", delar["topp"], farg=FARG["topp"],
             utskrift_solid=lambda s: s.rotate(Axis.X, 180),
             bambu={"wall_loops": 2, "sparse_infill_density": "15%", "enable_support": 0, "top_shell_layers": 5,
                    "brim_type": "no_brim"},   # ovansidan nedåt: gradskalan blir matt yta mot plattan
             beskrivning="Skivan; skrivs ut med ovansidan nedåt (matt yta från plattan)")

    hal = P["tapp diameter"] + P["tappspel"]
    zu = hd["z_topp_undersida"]
    fragor = [{
        "id": "vridskiva-tapp",
        "text": f"Snurrar toppen lätt utan att glappa (hål Ø {hal:.2f} mm på tapp Ø {P['tapp diameter']:.2f} mm)? "
                "Kärvar den: öka 'tappspel'; glappar den: minska det.",
        "besvarad": False,
        "markering": [{"typ": "matt", "fran": [-hal / 2, 0, zu], "till": [hal / 2, 0, zu], "text": f"Ø {hal:.2f}"}],
    }]
    if snapp:
        fragor.append({
            "id": "vridskiva-snapp",
            "text": "Klickar snäppet lagom? För hårt: tunnare 'fjäder tjocklek' eller mindre 'knopp förspänning'; "
                    "för löst: tvärtom.",
            "besvarad": False,
            "markering": [{"typ": "punkt", "pos": hd["knopp_spets"], "text": "knoppen"}],
        })
    N = int(round(P["antal lägen"]))
    beskr = (f"Tvådelad vridskiva Ø {P['topp diameter']:.0f} mm med {N} lägen (var {360 / N:.1f}°)"
             + (" och snäpp" if snapp else "") + "; inga köpdelar.")
    prj.spara(beskrivning=beskr, fragor=fragor)
    print(json.dumps(hd, ensure_ascii=False))


if __name__ == "__main__":
    main()
