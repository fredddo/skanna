# Skanna (Beta) – protokoll för en AI-agent

Skanna Beta (`~/Applications/Skanna Beta.app`, källkod `app/*.swift`, hem `~/git/worldforge/local/skanna-v2/`) gör
skanning → mesh i mm, och visar/redigerar CAD-delar. Agenten (Claude) ritar delarna och pratar med användaren via filer
som appen visar och skriver. Allt UI och all text till användaren är på svenska.

## Projekt
Ett projekt är en mapp. Två slags projekt, samma struktur:

```
<projekt>/
  projekt.json            {"namn", "typ": "modell" | "skanning", "skapad", "kalla": "video|guidad|foton|mall", "beskrivning", "plan"}
                          (saknas i äldre video-skanningar – de känns igen på namnet *.modell*)
  bilder/                 (skanning) bildrutor ur video, eller stillbilder från guidad skanning: o<omgång>_h<höjd>_v<vinkel>.heic
  modell/modell-mm.obj    (skanning) mesh i mm, X = längsta, Z = kortaste axeln, centrerad på omslutande låda
  cad/
    skript/NN-<id>.py     del-skript (build123d) – körs i namnordning av bygg_projekt.sh
    delar.json            delarna i objektträdet (skrivs av skripten)
    <id>-ytor.json        varje dels ytor (appens 3D-vy, val av yta)
    <id>.step / .3mf / .stl   CAD resp. utskriftsfiler (3mf i utskriftsläge: z ≥ 0, platt sida ner)
    geometri.json         status, beskrivning, mått (parametrar) och frågor
    parametrar-anvandare.json  användarens egna värden {"Grupp: namn": värde} – går alltid före
    utskrift.json         utskriftsinställningar per del (plast, vägglager, infill …) – går före skriptets bambu={…}
    svar.json             användarens meddelanden/svar till agenten
    claude.json           agentens status och svar (cad/meddela.py)
    stangda-fragor.json, bilagor/, foton.json, poser.json …
```

- **Modellprojekt** (utan skanning) skapas i appen (⌘N) i `~/Documents/Skanna/<namn>/`, tomma eller från en mall.
- **Video-skanningar** hamnar bredvid klippet som `<klipp>.modell/`; **guidade skanningar** och importerade foton i `~/Documents/Skanna/<namn>/`.
- Ram: mm. I modellprojekt är Z upp och delen står på z = 0 (som i Bambu Studio). I skanningar gäller skanningens ram.

## Del-skript (så ritar du en del)
Lägg ett skript i `<projekt>/cad/skript/NN-<id>.py` (NN = ordning: referensdelar 10–40, konstruktionsdelar 50–90).
Mallar att utgå från: `mallar/*.py` (låda med lock, distans, vinkelfäste, vridskiva). Skelett:

```python
# mall: Fäste för X          ← bara i mallar/ (headern gör den valbar i appen)
import os, sys
sys.path.insert(0, os.path.join(os.environ.get("SKANNA_HEM", os.path.expanduser("~/git/worldforge/local/skanna-v2")), "cad"))
from projekt import Projekt
from build123d import *

prj = Projekt(sys.argv[1])
P = prj.parametrar("Fäste", {                 # grupp → "Fäste: bredd" i appens måttlista
    "bredd": (30.0, "mm"),                    # källa "mall"
    "hål": (4.5, "mm", "standard"),           # (värde, enhet, källa[, osäkerhet]); källor: uppmätt|skanning|standard|antagande|mall
    "antal hål": (2, "st"),                   # heltal → int(round(P["antal hål"]))
})
d = prj.matt("Nederskal: längd ytter", 140.0) # mått som ett annat skript skrivit (t.ex. en referensdel ur skanningen)
solid = ...
prj.del_("faste", "Fäste", solid, roll="design", farg="#2E7DD7", beskrivning="…", utskrift_solid=solid.rotate(Axis.X, 180))
prj.spara(beskrivning="…", fragor=[{"id": "faste-hal", "text": "…", "markering": [...]}])
```

- Bygg allt: `bygg_projekt.sh <projekt>` (sätter `SKANNA_HEM`, kör skripten med `.venv/bin/python`). Appen kör samma skript
  när användaren ändrar ett mått eller trycker ⌘B, och visar felutskriften om bygget misslyckas.
- Alla mått användaren ska kunna ändra ska ligga i `prj.parametrar(...)`. Appen skriver ändringar till
  `parametrar-anvandare.json` (källa blir `användare`) och skickar ett svar med `fraga_id: "parameter"`.
- `prj.spara` skriver bara den egna gruppens mått och frågor (fältet `grupp`) – flera skript samsas om `geometri.json`.
- Äldre skanningar med `modell-cad.step` byggs först med `bygg_alla.sh` (HiKOKI-projektet), därefter körs ev. del-skript i
  `cad/skript/` (t.ex. en mall eller import som användaren lagt till).
  Flytta gärna sådana skript in i `cad/skript/` när du ändå arbetar med dem.

### Importerade delar (`cad/import/`, `cad/skript/50-import-<id>.py`)
Användaren kan importera STEP/STL/3MF/OBJ i appen. Filen kopieras till `cad/import/` och appen skriver ett del-skript
som anropar `importera(prj, id, namn, "import/<fil>", roll=…)` ur `cad/importera.py`. Placeringen ligger som mått i
gruppen `<namn>` (flytta x/y/z, vrid x/y/z, skala).
- **STEP** blir en B-rep-del (ytor, kanter, kantbehandling). Bygg vidare i ett eget skript med
  `from importera import las_step; s = las_step(prj, "import/<fil>")` (utan placering). Använd inte importdelens id.
- **Mesh** (STL/3MF/OBJ) blir `ytor.json` med `"kalla": "mesh"`. Stora plana partier blir `plan`-ytor, och resten blir en
  `nät`-yta per kropp. Den har inga kanter och ingen kantbehandling. Läs filen med trimesh om du behöver geometrin.
- Ändra inte originalfilen. Vill användaren ha redigerbara mått: skriv en ny del som skript (mät STEP-delen) och fråga
  om importdelen ska tas bort.

## geometri.json
```json
{"status": "utkast | väntar på svar | klar",
 "beskrivning": "…",
 "avvikelse": "median 0.51 mm, 90 % < 2.8 mm",
 "last_svar": "<tid för senaste svar i svar.json som agenten har läst>",
 "parametrar": [{"namn": "Fäste: bredd", "varde": 30, "enhet": "mm", "kalla": "mall", "osakerhet": null, "grupp": "Fäste"}],
 "fragor": [{"id": "faste-hal", "text": "Mät …", "besvarad": false,
             "markering": [{"typ": "matt", "fran": [x,y,z], "till": [x,y,z], "text": "3,8 mm?"},
                           {"typ": "punkt", "pos": [x,y,z], "text": "…"},
                           {"typ": "omrade", "min": [x,y,z], "max": [x,y,z], "text": "…"}]}]}
```
Appen laddar om automatiskt när filerna ändras. När användaren väljer en fråga ritas dess `markering` i 3D-vyn – ge
alltid varje fråga en markering som visar exakt vad som ska mätas.

## claude.json (via `cad/meddela.py`)
```json
{"status": "arbetar", "status_text": "…", "mottaget": "<tid>",
 "meddelanden": [{"tid": "…", "text": "…", "svar_pa": "<tid för ett meddelande i tråden>"}],
 "tradar": {"<rot-tid | fråge-id>": {"status": "arbetar | fraga | klar", "titel": "Hål i locket"}}}
```
Kvittera med `.venv/bin/python cad/meddela.py <projekt> --mottaget` så fort du vaknar; svara med `--svar "…" --svar-pa TID`;
sätt trådens läge med `--trad TID --status arbetar|fraga|klar [--titel "…"]` (se "Chatt och trådar"); avsluta med `--klar "…"`. Meddelanden utan `svar_pa` (t.ex. en första hälsning) visas fristående i appen.

## Chatt och trådar
Chattpanelen i appen är uppdelad i **trådar**. Flera kan vara aktiva samtidigt; behandla dem som parallella uppdrag.

- **Läsa.** I `cad/svar.json` startar varje användarmeddelande utan `trad` en tråd: rotens id är meddelandets `tid`. Svar i
  samma tråd har `trad` = rotens `tid`. Frågor i `geometri.json → fragor` är också trådar (id = fråge-id; användarens svar
  har `fraga_id` = fråge-id). Poster med `fraga_id: "parameter"` är mått som ändrats i appen, inte en tråd. Ett meddelande
  med `plats`/`yta`/`kant`/`foto` hör till en plats i modellen – titta där. Användaren kan stänga en tråd (lokalt, i
  `cad/stangda-tradar.json`); en stängd tråd kräver ingen åtgärd tills den öppnas igen med ett nytt meddelande.
- **Kvittera direkt.** För varje ny tråd, som allra första åtgärd:
  `.venv/bin/python cad/meddela.py <projekt> --mottaget` och
  `.venv/bin/python cad/meddela.py <projekt> --trad <ROT-TID> --status arbetar --titel "Hål i locket"`
  (titel = 2–4 ord som beskriver uppdraget). Titeln visas på trådkortet.
- **Svara i tråden.** `meddela.py <projekt> --svar "…" --svar-pa TID`, där TID är rotens `tid` eller `tid` för ett valfritt
  meddelande i tråden (användarens eller ditt eget). Svaret hamnar då i rätt tråd i appen. Utan `--svar-pa` blir det ett
  fristående meddelande utan tråd.
- **Fråga i en tråd.** Behöver du ett svar: ställ frågan som ett meddelande i tråden och sätt
  `--trad TID --status fraga`, eller lägg en fråga med markering i `geometri.json` (då är frågan en egen tråd) och sätt
  `besvarad: true` när du fått svar. Tråden visas för användaren som "fråga till dig" och är orange.
- **Avsluta.** När uppdraget är klart och verifierat: `--trad TID --status klar` (gärna med en kort sammanfattning via
  `--svar`). Klara trådar fälls ihop under "Avslutade". Kommer ett nytt användarmeddelande i tråden är den aktiv igen.
- **Status utan `--trad`** (`--status arbetar "text"`, `--klar "text"`) är den övergripande raden överst i chatten. Sätt
  den efter att alla trådar är hanterade, inte per tråd.
- **Flera trådar samtidigt.** Hantera alla tråd för tråd; sätt `arbetar` på dem du tagit tag i och låt övriga vara.
  Börja med trådar i status "fråga till dig" som nyss fått svar. Glöm inte att avsluta varje tråd för sig.

## Användaren skriver `cad/svar.json`
```json
{"svar": [{"fraga_id": "faste-hal | meddelande | plats | parameter", "fraga": "…", "svar": "2,1 mm", "trad": "<rot-tid>",
           "bilaga": "bilagor/IMG_1234.HEIC", "tid": "2026-11-17T13:40:00+01:00",
           "plats": [12.3, -4.0, -9.8], "pa": "skanning | <delnamn>", "yta": 17, "ytatyp": "plan", "del": "faste",
           "foto": "bilder/klipp1_0056.jpg", "foto_px": [812, 455]}]}
```
- Nytt modellprojekt med beskrivning: första posten är ett `meddelande` med vad användaren vill bygga – rita det.
- Klick i modellen → `fraga_id: "plats"` med `plats` (och `del`/`yta`/`ytatyp` om en CAD-yta valdes).
- Ritning i vyn → `fraga_id: "ritning"` med `ritning: "ritningar/<id>.json"`, bilden i `bilaga` och `plats` = där strecket
  började (se "Ritningar" nedan).
- Byggfel som användaren skickar vidare kommer som `meddelande` med loggen.

- `fler`: när användaren pekat på flera ställen (Peka, A/B/C …) ligger den första punkten i `plats`/`pa`/`yta`/… och resten i
  `fler: [{plats, pa, yta, ytatyp, del, foto, foto_px}]`, i samma ordning (B, C …). Behandla dem som en grupp i samma tråd.

## Skanningar: foton i kamerans perspektiv
`skanna poser <projekt>/bilder <projekt>/cad/poser.json` (≈1,5 min), sedan `.venv/bin/python cad/foton.py <projekt>`
→ `cad/foton.json`. Appens Foto-läge (⌘K) ritar delarna ovanpå bilderna i exakt kamerans perspektiv. Klickar användaren
där kommer svaret med `foto` och `foto_px`; titta på samma vy med `.venv/bin/python cad/visa.py <projekt> <foto> <u> <v>`.

## Ritningar (`cad/ritningar/<id>.json` + `.png`)
Användaren ritar streck i 3D-vyn som på en utskrift och beskriver i tråden vad de ska bli ("ett avlångt hål längs
kurvan", "fas längs den här linjen"). Ett streck har ingen riktig 3D-form – det gäller från just den kamerapunkten.
Titta först på **bilden** (vyn med strecken, magenta), läs sedan JSON:en:
- `kamera` (4×4, kolumnvis), `kamera_pos`/`kamera_fram`/`kamera_upp`/`kamera_hoger`, `fov` (lodrätt, grader), `vy`
  (vyns storlek i punkter), `bild_skala` (bildpixlar per punkt), `foto` om det ritades ovanpå ett foto.
- `streck[]`: `rak` (ritat med ⇧), `start` (fäste mot en kant/ett hörn: `del`, `kant`-id i `<del>-ytor.json`, exakt
  `punkt` i mm) och `prov[]` var ~6:e punkt: `px` (vyn, origo uppe till vänster), `strale` (riktning från `kamera_pos`),
  `plan` (skärning med ritplanet `plan_punkt`/`plan_normal`, genom kamerans mål) och `traff` (första synliga yta:
  `del`, `yta`, `punkt` i mm, `normal`) eller `null` om strålen går ut i tomrummet.
- Så tolkar du: ligger strecket på en yta (träffar på samma `yta`) är `traff.punkt` den verkliga kurvan på ytan – projicera
  på ytans plan. Går det ut i luften: utgå från `start`/sista träffen och strålarna, och bestäm djupet utifrån
  beskrivningen eller fråga. `visning` säger om delar var dolda, flyttade (mm) eller isärdragna när bilden togs – då
  ligger träffpunkterna ändå i modellens ram (flytten är borträknad).
- Svara kort hur du tolkade strecket (t.ex. "spår 3 mm brett längs kurvan på yta 4, 2 mm djupt") så att användaren kan
  rätta. Användaren kan klicka på miniatyren i tråden för att se ritningen från samma kamera igen.

## Arbetsgång
1. Bevaka i bakgrunden: `bevaka.sh` (alla projekt) eller `bevaka.sh <projekt>` (Bash `run_in_background`); starta om efteråt.
2. Läs nya svar (`tid` > `last_svar`), titta på bilagor, uppdatera parametrar (källa → `uppmätt`), sätt `besvarad: true`.
3. Skriv/ändra del-skripten och kör `bygg_projekt.sh <projekt>`. I skanningar: räkna avvikelse mot `modell-mm.obj`.
4. Ställ nya frågor bara när svaret ändrar geometrin. Mät hellre i skanningen än att fråga.

Verktyg: `.venv` i hemmappen har build123d, trimesh, numpy, scipy, shapely, matplotlib, opencv, pillow(-heif).
CLI: `skanna` (video/fotomapp → modell; `--ordning sekventiell` för vridskiva, `--beskar off` om bordsplanet inte ska tas bort).

## Det användaren kan göra i appen (och vad som når dig)
- **Välj/Mät/Rita/Flytta/Peka** och **explode** är bara visning – ändrar aldrig skript, mått eller modell. Mätningar kan skickas
  som meddelande ("Jag mätte 43,70 mm …") med plats.
- **Ytor, kanter, kroppar:** `ytor.export_faces` (via `prj.del_`) skriver `kanter` (id = index i `solid.edges()`, `mitt`,
  polylinje `p`, `typ`, `radie`) och `kropp` per yta + `kroppar`. Appen låter användaren välja kanter och visar varje
  sammanhängande kropp som eget objekt. Använd alltid `prj.del_` (eller `export_faces`) så att detta följer med.
- **Fillet/fas på en kant:** appen skriver `cad/kantbehandling.json` (`del`, `kant`, `mitt`, `typ` fillet|fas, `matt`)
  och skickar samtidigt ett meddelande. Har delen ett del-skript gör `Projekt.del_()` behandlingen själv vid bygget och
  skriver `status` (ok | fel: …) – svara bara kort. Står det `fel` eller saknas del-skript: gör ändringen i skriptet själv.
- **Snittvyer:** `cad/snittvyer.json` – sparade snitt (`axel` 0/1/2 = X/Y/Z, `lage` mm, `tecken`, kamera). Hänvisar
  användaren till ett snitt ("se snittet Y = −2,2") finns planet där.
- **Utskrift:** *Skriv ut* kör `cad/bambu.py <projekt> --delar id,…` → Bambu Studio-projekt (X2D, 0,4 mm) med
  inställningar per objekt och plasten i objektnamnet. Se "Utskriftsinställningar per del" nedan. Ge varje
  konstruktionsdel en utskriftsorientering (`utskrift_solid`, gärna som funktion `lambda s: s.rotate(Axis.X, 180)`).

## Utskriftsinställningar per del (`cad/utskrift.json`)
Varje konstruktionsdel har egna utskriftsinställningar som användaren ändrar i appen (inspektören, när delen är vald) och
som du ändrar när användaren ber om det ("gör locket i PETG-CF med 4 väggar"):

```json
{"delar": {"lock": {"plast": "PETG-CF", "wall_loops": "4", "sparse_infill_density": "25%",
                    "top_shell_layers": "6", "bottom_shell_layers": "5",
                    "enable_support": "1", "support_type": "tree(auto)", "brim_type": "no_brim"}}}
```
- Nycklarna är Bambu Studios egna processnycklar plus `plast`; värden är strängar (som Bambu skriver dem). De här går
  alltid att redigera i appen: `plast`, `wall_loops` (vägglager), `sparse_infill_density` (infill, med %),
  `top_shell_layers`, `bottom_shell_layers`, `enable_support` (`"0"`/`"1"`) och `support_type`
  (`tree(auto)` | `normal(auto)` | `tree(manual)` | `normal(manual)`). Du får lägga till fler nycklar (t.ex. `brim_type`,
  `sparse_infill_pattern`, `layer_height`); appen visar dem under "Fler inställningar" och användaren kan ta bort dem.
- **Gällande värde:** processprofilen ("0.20mm Standard @BBL X2D") < delens `bambu` i `delar.json` (från
  `prj.del_(…, bambu={…})`, även `"plast"`) < `utskrift.json`. Skriptets värden är alltså utgångsläget; det användaren och
  du ändrar i efterhand ligger i `utskrift.json`. Ändra hellre `utskrift.json` än skriptet när användaren ber om en
  inställning – då syns det i appen och kan ångras. Ingen ombyggnad behövs.
- **Ändra:** `.venv/bin/python cad/utskrift.py <projekt> <del> plast=PETG-CF wall_loops=4 sparse_infill_density=25`
  (normaliserar värdena), `… <del> --ta-bort wall_loops` (tillbaka till skriptets värde), `cad/utskrift.py <projekt>`
  (visar alla delars gällande värden, varifrån de kommer och vilken filamentprofil plasten ger) och
  `cad/utskrift.py --plaster` (plaster med installerad X2D 0.4-profil). Redigera gärna JSON direkt, men behåll andra
  delars poster.
- **Plast:** `PLA`, `PLA Matte`, `PETG`, `PETG HF`, `PETG-CF`, `ABS`, `ASA`, `PC`, `PA6-CF`, `TPU 95A` … slås upp som
  "Bambu <plast>[ Basic] @BBL X2D 0.4 nozzle" (annars "Generic <plast>"). Saknas en installerad profil används
  basplasten (`PETG-CF2` → PETG) eller PLA, och exporten skriver en varning som appen visar. Plasten står alltid i
  objektnamnet: "Lock (PETG-CF)". Delar med olika plast får varsin filamentplats i projektet (mallar per plast byggs i
  `bambu/x2d-<plast>-project_settings.json` första gången). Utan plast: PLA.
- **När användaren ändrar** något i appen kommer ett svar med `fraga_id: "parameter"`, `fraga: "Utskrift: <delnamn>"`
  och t.ex. `"Utskrift för Lock (lock): Plast (plast) = PETG-CF, Vägglager (wall_loops) = 4 (ändrat i appen, …)"`.
  Det är ingen tråd; ta hänsyn till det (t.ex. väggtjocklek i PETG-CF, toleranser) och svara bara om det påverkar
  konstruktionen.
- **Objektträdet:** `cad/objekt.json` (`dolda`, `ordning`, `namn`) är användarens: släckta lager, ordning och egna namn
  på delar. Appen visar och exporterar delarna med de namnen (också i Bambu Studio). Byter användaren namn kommer en rad i
  loggen ("Bytte namn på delen …") – använd det namnet när du pratar om delen. Ändra inte filen själv.
- **Färger** sätts av appen (färgschema per projekt); `farg` i `delar.json` används bara med schemat "Delarnas egna färger".

## Historik i git (appen committar, inte du)
Om projektet ligger i ett git-repo gör appen automatiskt en commit av projektets `cad/` och `projekt.json` när en ändring
har satt sig (efter att du satt `status` till något annat än `arbetar`, när användaren ändrat något, vid projektbyte och när appen stängs).
Projektets `.gitignore` håller bilder, video och mesh utanför (och i projekt med del-skript även byggresultat: STEP/STL/3MF/`-ytor.json`).
Commit-rubriken tas från första raden i ditt senaste meddelande i `claude.json` – skriv den som en kort sammanfattning av ändringen.
Committa, pusha eller skriv om historiken inte själv. Går användaren tillbaka till en tidigare version får du ett `svar.json`-meddelande
("Historik"): filerna i `cad/` (utom samtalet) är då som i den versionen – läs om skripten innan du fortsätter.
