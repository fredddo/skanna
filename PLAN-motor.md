# Plan: Skanna-motorn (lokal tjänst) och webbgränssnitt

Beslut 2026-11-24 (efter granskningen i GRANSKNING-2026-11-24, som ligger utanför repot): Skanna delas på sikt i tre delar.
Målet är att så mycket som möjligt ska gå att använda i en webbläsare (Mac, surfplatta, mobil), att allt körs lokalt
och att projekten kan ligga i valfri synkad molnmapp. Rå skanningsdata stannar lokalt om användaren inte väljer annat.

```
 Skanna Capture (Mac)        Skanna-motorn (Python, lokalt)              Webbläsare / Skanna Beta
 skanna-CLI: video/foton ──► projektmappar, lås, byggkö, chatt, ◄──HTTP── 3D-vy, mått, chatt, utskrift
 → modell-mm.obj             Bambu-export, git-historik                  (i dag: Mac-appen)
                                  ▲
                                  └── Claude (meddela.py / bevaka.sh i dag, MCP mot motorn senare)
```

## Delarna
- **Capture:** Object Capture finns bara hos Apple, så rekonstruktionen förblir native (`skanna`-CLI:t). Motorn kan starta
  CLI:t; foton/video kan på sikt skickas in från mobilens webbläsare.
- **Motorn** (`motor/`, ren stdlib-Python, startas med projektets `.venv/bin/python -m motor`): den enda vägen som ändrar
  delade projektfiler från gränssnittet. Bygger med `bygg_projekt.sh` i en kö per projekt, skriver atomiskt och under
  lås (`cad/lagring.py`), delar ut unika tider till meddelanden och kan vänta på nya meddelanden (long-poll).
  Lyssnar bara på 127.0.0.1 och kräver en nyckel i `X-Skanna-Nyckel` (skydd mot att andra webbsidor anropar den).
- **Webbgränssnittet** (senare steg): three.js-vy över `<id>-ytor.json`, chatten, mått, utskrift. Serveras av motorn.

## Lås och skrivregler (gäller alla som skriver i ett projekt)
- Alla delade JSON-filer i `cad/` skrivs atomiskt (temporär fil + `os.replace`) under projektets skrivlås
  `<projekt>/.skanna/skriv.las` (`fcntl.flock`). Läs–ändra–skriv sker inom samma lås (`lagring.uppdatera_json`).
- Ett helt bygge håller byggläset `<projekt>/.skanna/bygg.las` (`bygg_projekt.sh` tar det själv). Två byggen av samma
  projekt – appens och Claudes – går efter varandra i stället för samtidigt.
- En fil som finns men inte går att tolka är **trasig**, inte tom: den skrivs aldrig över med ett standardvärde.
- Tider (`tid`) har millisekunder och är unika i sin fil; de jämförs som tidpunkter, inte som text.
- `<projekt>/.skanna/` versioneras inte (projektets `.gitignore` släpper bara igenom `cad/` och `projekt.json`).

## Motorns API (v1)
Alla anrop: JSON, header `X-Skanna-Nyckel`. `projekt` = projektmappens sökväg.

| Anrop | Gör |
|---|---|
| `GET /v1/halsa` | `{"ok": true, "version": …}` |
| `GET /v1/projekt?projekt=` | geometri, delar, claude, svar (trasiga poster hoppas över) |
| `POST /v1/svar` `{projekt, post}` | lägger till ett meddelande i `cad/svar.json` (motorn sätter unik `tid`); okända fält bevaras |
| `POST /v1/parameter` `{projekt, namn, varde}` | sätter (tal) eller tar bort (`null`) ett användarmått i `parametrar-anvandare.json` |
| `POST /v1/kantbehandling` `{projekt, post}` | ersätter/lägger till fillet/fas för (del, kant) i `kantbehandling.json` |
| `POST /v1/json` `{projekt, fil, nyckel, varde}` | sätter en toppnyckel i en tillåten fil (t.ex. `utskrift.json` → `delar`) |
| `POST /v1/fil` `{projekt, fil, data}` | ersätter (base64) eller tar bort (`null`) en tillåten fil – för ångra |
| `POST /v1/bygg` `{projekt}` | köar ett bygge → `{"begaran": n}`; begäranden under ett pågående bygge slås ihop |
| `GET /v1/bygg?projekt=` | `{"kor", "klar_till", "kod", "logg"}`; begäran n är klar när `klar_till ≥ n` |
| `GET /v1/vanta?projekt=&sedan=&sek=` | väntar (högst `sek`) på användarmeddelanden nyare än `sedan` |

## Steg
1. **Motorn under dagens Mac-app** (detta steg, 2026-11-24): `cad/lagring.py`, `motor/`, appen startar motorn som
   barnprocess (slumpad port, dör med appen) och skickar meddelanden, mått, kantbehandling, utskriftsinställningar,
   ångra och byggen genom den. Samtidigt rättat: trådstatus, `meddela.py --svar` utan `--svar-pa`, `bevaka.sh` som
   missade meddelanden, `foralder` som försvann ur `delar.json`, dubblerade mått vid flera grupper, tidkrockar,
   måttinmatning ("−", ° och decimaler), testinstansen som såg de riktiga skanningarna, död kod.
2. **Webbvy** med visning, mätning och chatt (fungerar på surfplattan), serverad av motorn på en fast port med nyckel.
3. **Redigering i webben** (mått, handtag, utskrift, import); Claude via MCP mot motorn i stället för filbevakning.
4. **Mac-appen bantas** till Capture om webben räcker; annars lever båda gränssnitten på samma motor.

## Inte gjort i steg 1
- Gamla Skanna.app (`../fotoskanning`) skriver fortfarande om `svar.json` utan trådfälten när den används på samma
  projekt (HiKOKI). Använd Beta för de projekten, eller låt motorn ta över även där.
- Appens egna visningsfiler (`objekt.json`, `vyer.json`, `snittvyer.json`, `stangda-*.json`, ritningar) skrivs fortfarande
  direkt av appen – bara appen skriver dem.
- Claude använder fortfarande `meddela.py`/`bevaka.sh` (nu med lås och innehållsbaserad bevakning), inte motorns API.
