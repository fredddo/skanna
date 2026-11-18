# Plan: nytt Modellera-gränssnitt (Skanna Beta)

Användarens önskemål (2026-11-18): helt nytt grepp på modellera-gränssnittet. Behåll foto-overlay, opacitet per objekt,
tända/släcka, peka ut och beskriva ändringar, parametriska redigerbara mått. Nytt:
1. **Mäta** mellan två punkter/ytor/kanter.
2. **Info vid klick:** längd/bredd/höjd, diameter, tjocklek på ytor och objekt.
3. **Flytta tillfälligt** och **explode** (snabbknapp och reglage) – bara visning, ändrar aldrig kod, parametrar eller modell.
4. **Färger:** automatiskt olika färger ur ett färgschema, olika scheman per projekt, och ett val för allt grått.
5. **Allt är objekt:** delar som består av flera sammanhängande kroppar delas upp i under-objekt som kan tändas och släckas.
6. **Kant → fillet/fas** via inmatning eller agenten.
7. **Bättre chatt:** parallella trådar; aktiva trådar (agenten arbetar eller frågar) ligger sticky överst, avslutade
   kollapsar och försvinner uppåt. Agentens frågor om mått är trådar.
8. **Export till Bambu Studio** som projekt-3MF med inställningarna redan satta (X2D).

## Arkitektur och ägarskap (parallellt arbete – rör bara dina filer)
| Del | Ägare | Filer |
|---|---|---|
| Kontrakt: tillstånd och typer | huvudagenten (klart) | `app/Verktyg.swift`, fält i `app/Tillstand.swift`, `Svar.trad/kant`, `ClaudeInfo.tradar` |
| Ny arbetsyta: layout, verktygsrad, inspektör, objektträd, mått-flik, Bambu-knapp | huvudagenten | `app/Arbetsyta.swift` (ny), `app/Panel.swift`, `app/Vyer.swift` |
| 3D-verktyg: välj/info, mät, flytta, explode, under-objekt, kantval, färger i scenen | agent **3D** | `app/ModelView.swift`, `app/Snitt.swift`, nya `app/3D*.swift` |
| Chatt med trådar | agent **Chatt** | `app/Chatt.swift` (ny), `cad/meddela.py`, avsnittet "Chatt" i `AGENT.md` |
| CAD: kanter/kroppar i ytor.json, kantbehandling, Bambu-projektexport | agent **CAD** | `cad/ytor.py`, `cad/projekt.py`, `cad/bambu.py` (ny), `bambu/` (ny), `mallar/*.py` |

Kompilera alltid hela appen: `cd ~/git/worldforge/local/skanna-v2 && swiftc -parse-as-library -o /tmp/... app/*.swift`.
Får du fel i en fil du inte äger: vänta en stund och försök igen (någon annan håller på), ändra den inte.

## Filformat (kontrakt)
`cad/<del>-ytor.json` (skrivs av `ytor.export_faces`; gamla filer saknar de nya fälten – appen måste klara båda):
```json
{"ytor": [{"id": 0, "typ": "plan", "area": 12.3, "centrum": [x,y,z], "normal": [..]|null, "radie": r|null,
           "kropp": 0, "v": [...], "t": [...]}],
 "kanter": [{"id": 0, "typ": "linje|cirkel|båge|spline", "langd": 12.3, "radie": r|null, "centrum": [x,y,z]|null,
             "p": [x0,y0,z0, x1,y1,z1, …], "ytor": [3, 7]}],
 "kroppar": [{"id": 0, "namn": "Kropp 1", "volym": 1234.5, "min": [..], "max": [..]}]}
```
Kant-id = index i `solid.edges()`, yt-id = index i `solid.faces()`, kropp = index i `solid.solids()`.

`cad/kantbehandling.json` (skrivs av appen, läses av `projekt.py`):
`[{"del": "lada", "kant": 17, "mitt": [x,y,z], "typ": "fillet|fas", "matt": 1.0, "tid": "…", "status": "ok|fel: …"}]`.
`Projekt.del_()` letar upp kanten närmast `mitt` (inom 0,5 mm) och gör fillet/fas innan export. `status` skrivs tillbaka.

`cad/delar.json` får valfritt `"bambu": {"wall_loops": "3", "sparse_infill_density": "20%", "enable_support": "0", …}` per del.

Trådar (chatt): ett användarmeddelande utan `trad` startar en tråd (rot = dess `tid`); svar i tråden har `trad` = rotens
tid. Agenten svarar med `svar_pa` = rot-tid (eller ett meddelande i tråden) och sätter trådens läge i `claude.json`:
`"tradar": {"<rot-tid>": {"status": "arbetar|fraga|klar", "titel": "Hål i locket"}}` via
`meddela.py <projekt> --trad TID --status arbetar|fraga|klar [--titel "…"]`. Frågor i `geometri.json → fragor` är också
trådar (id = fråge-id). Användaren kan stänga en tråd lokalt (`cad/stangda-tradar.json`).

## Gränssnitt (huvudagenten)
- 3D-vyn fyller fönstret. Svävande paneler: objektträd (vänster), verktygsrad (överst: Välj/Mät/Flytta/Peka, Explode,
  Snitt, Foto, Stil, Färg, Hela vyn), inspektör (nere till vänster: mått på det valda, fillet/fas för kanter, "Säg något om
  det här"), högerpanel med flikarna **Samtal** (ChattPanel) och **Mått** (parametrar).
- Toppraden: projektnamn, mått, Bygg om, **Skriv ut i Bambu Studio** (projekt-3MF med inställningar).

## Klart när
- Allt ovan fungerar i offscreen-tester (harnessen i scratchpad) på modellprojekt (låda, vridskiva) och skanningskopian.
- Beta är ombyggd, FORANDRINGAR.md och AGENT.md är uppdaterade.
