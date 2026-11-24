# Plan: Webbvisare och delningslänk

Beslut 2026-11-24. Mål: dela en länk till en modell så att någon annan kan öppna den i en webbläsare **utan att logga
in** och vrida, spränga isär, mäta, flytta delar och tända/släcka i objektpanelen. Bonus: besökaren kan peka och
kommentera till ägaren (inte till Claude). Besökaren kan aldrig ändra något i projektet.

Detta är också första biten av steg 2 i `PLAN-motor.md` (webbvy): visaren är samma kod som senare kan visa ett lokalt
projekt direkt från motorn.

## Upplägg

```
 Skanna Beta ──► motorn: POST /v1/dela ──► cad/dela.py
                                            │  läser delar.json, <id>-ytor.json, objekt.json
                                            │  packar → gzip → krypterar
                                            ▼
                         <delat>/d/<id>.skd   (krypterat paket, en fil per delning)
                         <delat>/visare/      (statisk webbsida, samma för alla delningar)
                                            │
                    publiceras som statiska filer (GitHub Pages eller valfri webbplats)
                                            ▼
        https://<värd>/visare/#d=<id>&k=<nyckel>      ← länken som delas
```

- **Hemlig länk utan inloggning:** paketet krypteras på ägarens dator. Nyckeln ligger i länkens `#`-del, som
  webbläsaren aldrig skickar till servern. Värden (också ett publikt GitHub-repo) ser bara oläsbara filer; bara den som
  har hela länken kan läsa modellen. `<id>` är slumpat (128 bitar) och går inte att gissa.
- **Bara läsning:** allt är statiska filer. Det besökaren tänder/släcker, flyttar och mäter finns bara i hens webbläsare.
- **Sluta dela:** ta bort `d/<id>.skd` och publicera igen. Länken slutar då fungera (redan nedladdade kopior finns kvar
  hos den som öppnat länken).
- **Inga externa beroenden vid körning:** visaren hämtar inget från andra webbplatser (inga CDN:er, typsnitt, statistik).

## Vad som delas
- CAD-delarna i `cad/delar.json` som har en `<id>-ytor.json` (namn, färg, `foralder`, kroppar med namn/färg/grupp).
- Läget i appen följer med som startläge: vilka delar som är släckta (`objekt.json` → `dolda`), ordningen och namnbyten.
- **Rå skanningsdata delas inte.** Skanningsnätet och nätdelar (delar vars `fil` är `.stl`/`.obj`/`.3mf`, t.ex.
  "Överdel (skanning)") tas bara med när de väljs uttryckligen (`--med` / kryssruta i appen).
- Inget annat: inga skript, inga mått/parametrar, ingen chatt, inga foton, inga sökvägar från ägarens dator.

## Paketformat (version 1)

Klartext = gzip av JSON (UTF-8):

```json
{
  "version": 1,
  "namn": "Batterihållare",            // projektets visningsnamn
  "skapad": "2026-11-24T12:00:00.000+01:00",
  "enhet": "mm",
  "fran": "Fredrik",                    // valfritt: vem som delar (visas i visaren), null om inte angivet
  "brevlada": "https://…/b/<id>",       // dit visaren skickar kommentarer; null = bara svarslänk
  "delar": [
    {
      "id": "cellbadd", "namn": "Cellbädd", "farg": "#3A7BD5", "foralder": null, "roll": "del",
      "beskrivning": "…",               // valfri
      "dold": false,                    // startläge
      "ytor": [ … ], "kanter": [ … ], "kroppar": [ … ]   // som i <id>-ytor.json (cad/ytor.py: export_faces)
    },
    { "id": "skanning", "namn": "Skanning", "farg": "#9AA4AE", "nat": {"v": [x,y,z,…], "t": [i,j,k,…]}, "dold": true }
  ]
}
```

- En del har antingen `ytor`/`kanter`/`kroppar` (CAD) eller `nat` (triangelnät utan ytor; kan inte ytväljas).
- Ordningen i `delar` är objektpanelens ordning.

Fil `d/<id>.skd`:

```
"SKD1" (4 byte) | iv (16 byte) | chiffertext (AES-256-CBC, PKCS#7) | mac (32 byte)
k_enc = SHA-256(nyckel ‖ "skanna-enc"),  k_mac = SHA-256(nyckel ‖ "skanna-mac")
mac   = HMAC-SHA-256(k_mac, "SKD1" ‖ iv ‖ chiffertext)   – kontrolleras före avkryptering
```

- `nyckel` = 32 slumpade byte, base64url utan `=` i länken. `id` = 16 slumpade byte, base64url.
- Skälet till CBC+HMAC i stället för GCM: Python-sidan krypterar med systemets `/usr/bin/openssl` (ingen ny
  Python-modul behövs), och webbläsarens WebCrypto har både AES-CBC och HMAC. Kryptera-sedan-MAC ger samma skydd.
  `openssl enc -K` tar nyckeln som argument, så den syns i den egna datorns processlista under den korta körningen
  (godtagbart på en enanvändardator; byt till en Python-modul om det ska köras på en delad server).
- Visaren: hämtar filen, verifierar mac, avkrypterar (WebCrypto), packar upp (`DecompressionStream("gzip")`), tolkar JSON.

## Länkar
- Dela: `…/visare/#d=<id>&k=<nyckel>`
- Svarslänk med kommentarer: `…/visare/#d=<id>&k=<nyckel>&c=<base64url(gzip(JSON))>` där JSON är
  `{"fran": "Namn", "kommentarer": [{"id": "…", "tid": "…", "text": "…", "punkt": [x,y,z], "del": "cellbadd", "kropp": 0}]}`.
  `punkt` är i modellens koordinater (mm, utan spräng-/flyttförskjutning).

## Brevlådan: kommentarer direkt till ägaren (`brevlada/`)

Beslut 2026-11-24: besökaren ska kunna skicka kommentarer utan att skicka en länk tillbaka. En liten mottagartjänst,
samma API i två utföranden: **Cloudflare Worker** (`brevlada/worker.js`, lagrar i KV) eller **Python-tjänst**
(`brevlada/server.py`, ren stdlib, lagrar i en mapp) på en egen maskin bakom en omvänd tunnel. Tjänsten ser aldrig
innehållet: visaren krypterar kommentarerna med delningens nyckel (samma SKD1-format som paketet).

| Anrop | Vem | Gör |
|---|---|---|
| `PUT /b/<id>` + `X-Brevlada-Hemlig` | ägaren (dela.py) | öppnar en brevlåda för delningen |
| `POST /b/<id>` (kropp: SKD1-blob, högst 64 kB) | besökaren (visaren) | lägger ett brev; 404 om lådan inte finns, 429 efter 200 brev |
| `GET /b/<id>` + `X-Brevlada-Hemlig` | ägaren | `{"brev": [{"tid": "…", "data": "<base64>"}]}` |
| `DELETE /b/<id>` + `X-Brevlada-Hemlig` | ägaren | tar bort lådan och breven (vid "Sluta dela") |
| `OPTIONS` | webbläsaren | CORS: `Access-Control-Allow-Origin: *`, metoder POST/OPTIONS, header Content-Type |

- `<id>` = delningens id (base64url, 22 tecken); andra former ger 404. Hemligheten är en lång slumpad text som bara
  ägaren har (miljövariabel hos tjänsten, `brevlada_hemlig` i `~/.config/skanna/delning.json`).
- Ett brev i klartext = gzip av `{"fran": "Namn", "kommentarer": [ … ]}` (samma poster som i svarslänken).
- `dela.py` öppnar lådan när en delning skapas (om `brevlada_url` är inställd) och skriver adressen i paketet.
  `dela.py --hamta <projekt>` / motorns `POST /v1/kommentarer/hamta {projekt}` hämtar, avkrypterar och lägger nya
  kommentarer i `cad/kommentarer.json`. Appen hämtar när projektet öppnas och med en knapp.
- Utan brevlåda (ingen adress inställd) fungerar svarslänken som reserv.
- Att driftsätta tjänsten (Cloudflare-konto eller tunnel) gör användaren; `brevlada/LÄSMIG.md` beskriver båda vägarna.

## Visaren (`webb/visare/`, statisk)
- Vrid/panorera/zooma med mus och pekskärm; "Passa in"; standardvyer.
- **Objektpanel:** träd som i appen (del → barndelar via `foralder` → komponentgrupper via kroppens `grupp` → kroppar),
  öga per rad och per grupp, "Visa alla", klick markerar.
- **Spräng:** reglage 0–1 med samma regel som appen (`app/3DVerktyg.swift`: `explodeVector`, `placeLeaves`,
  `sprangGrupp`): bara synliga objekt, från deras gemensamma mitt, hopfälld del sprängs som en enhet.
- **Mät:** klicka två punkter → avstånd och dx/dy/dz; fäster mot hörn/kantändar; klick på en yta visar typ, area och
  radie/diameter för cylindrar (ur ytans metadata).
- **Flytta:** dra en del i skärmplanet; "Återställ läge".
- **Peka/kommentera:** klicka en punkt, skriv text → nål i modellen och rad i en kommentarslista. Sparas i webbläsaren
  (localStorage per delning). "Skicka kommentarer": finns `brevlada` i paketet krypteras kommentarerna och skickas dit
  (kvitto "Skickat till <fran>"); annars, eller om det misslyckas, ges en svarslänk att kopiera/dela (Web Share där
  det finns). En länk med `c=` visar nålarna direkt.
- Svenska texter, fungerar på mobil och surfplatta, ljust/mörkt läge. Tydliga fel: fel nyckel, borttagen delning.
- Ritare: egen WebGL2-ritare utan externa bibliotek (inget laddas ner eller hämtas från andra webbplatser).
  Inga byggsteg (rena ES-moduler), så att katalogen kan publiceras som den är.

## Python och motorn
- `cad/dela.py` (bara stdlib + `openssl`):
  - `packa(projekt, med=(), fran=None) -> dict` – paketets JSON enligt ovan.
  - `kryptera(data: bytes, nyckel: bytes) -> bytes`, `dekryptera(blob, nyckel) -> bytes`.
  - `dela(projekt, delat_mapp, bas_url=None, med=(), fran=None) -> {"id", "nyckel", "fil", "lank"}` – skriver
    `d/<id>.skd`, kopierar/uppdaterar `visare/` i `delat_mapp`, och lägger en post i `<projekt>/cad/delningar.json`
    (`{"delningar": [{"id","nyckel","tid","lank","med","aterkallad"}]}`, via `lagring.uppdatera_json`).
  - `aterkalla(projekt, delat_mapp, id)` – tar bort filen och markerar posten.
  - `las_svarslank(lank) -> {"delning", "fran", "kommentarer"}` och `ta_emot(projekt, lank)` – lägger kommentarerna i
    `<projekt>/cad/kommentarer.json` (`{"kommentarer": [{…, "delning": id, "fran": …, "mottagen": tid}]}`), utan dubbletter.
  - CLI: `dela.py <projekt> [--med skanning,<delid>] [--fran Namn] [--mapp DIR] [--bas-url URL]`,
    `dela.py --aterkalla <id> <projekt>`, `dela.py --ta-emot <länk> <projekt>`.
  - Inställningar (mapp och bas-URL) i `~/.config/skanna/delning.json`; saknas de används
    `<Skanna-hem>/delat/` och motorns lokala adress (förhandsvisning).
  - **Publicering** är ett eget, uttryckligt steg (`dela.py --publicera`: en enda commit utan historik som tvingas
    upp i `delat_mapp` om den är ett git-repo – en återkallad delning ska inte ligga kvar i historiken).
    Med `"publicera_automatiskt": true` i `delning.json` (användarens eget val) publicerar `dela` och `aterkalla` direkt;
    annars publicerar användaren med knappen "Publicera nu" i dela-bladet (`POST /v1/dela/publicera`). Utan den inställningen körs det aldrig automatiskt, och aldrig av en agent utan användarens ja.
- Motorn (`motor/server.py`):
  - `POST /v1/dela {projekt, med, fran}` → `{id, lank, lokal_lank}`; `POST /v1/dela/aterkalla {projekt, id}`;
    `GET /v1/delningar?projekt=`; `POST /v1/kommentarer {projekt, lank}` (svarslänk);
    `POST /v1/kommentarer/hamta {projekt}` (brevlådan) → `{nya: n}`; `GET /v1/kommentarer?projekt=`.
  - `GET /delat/<sökväg>` **utan nyckel**: bara statiska filer under delat-mappen (visaren och krypterade paket), med
    skydd mot `..`. Det ger en lokal förhandsvisning: `http://127.0.0.1:<port>/delat/visare/#d=…&k=…`.

## Appen (Skanna Beta)
- Arkiv → "Dela modell …": väljer vad som ska med (CAD-delar förvalt; skanning och nätdelar som kryssrutor, avstängda),
  valfritt namn ("från"), skapar delningen via motorn, kopierar länken och visar den. Lista över projektets delningar
  med "Kopiera länk", "Öppna" och "Sluta dela".
- Kommentarer hämtas från brevlådan när projektet öppnas och med knappen "Hämta kommentarer".
  "Ta emot svarslänk …": klistra in en svarslänk → kommentarerna hamnar i `cad/kommentarer.json` och visas i
  samtalsfliken under en egen rubrik "Kommentarer från delning" (klick flyger till punkten). De skickas inte till Claude.

## Steg
1. **Paket och motor** (`cad/dela.py`, motorns anrop, `tester/test_dela.py`) och **brevlådan** (`brevlada/`,
   `tester/test_brevlada.py`).
2. **Visaren** (`webb/visare/`), provad lokalt mot ett riktigt paket.
3. **Appen** (dela-dialog, ta emot kommentarer), UI-scenarier.
4. **Publicering och drift** – görs av användaren: välj värd (antagande: eget publikt GitHub-repo med Pages), peka
   `delning.json` dit, kör `dela.py --publicera`; driftsätt brevlådan (Cloudflare Worker eller Ubuntu + tunnel).

## Inte med i den här omgången
- Svar från ägaren tillbaka till besökaren, och att besökare ser varandras kommentarer.
- Snittvy, mått/parametrar och ritningar i visaren.
- Binärt/kvantiserat paketformat (JSON+gzip räcker för dagens modeller, ~100–300 kB per del före gzip).
