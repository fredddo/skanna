# Skanna Beta (v2)

Nyheter, hur man provar och hur det förs över: se `FORANDRINGAR.md`. Appen byggs med `./bygg-beta.sh`.
Nedan: den ursprungliga guiden för video-skanning med CLI:t.

# skanna – video från mobilen → 3D-modell i mm

## En gång
- Skriv ut `referensark.pdf` i **100 %** (inte "anpassa till sida"). Kontrollera 100 mm-strecket.
- iPhone: Inställningar → Kamera → Spela in video → **4K, 60 bps** (eller 30). Stäng av **HDR-video**.
- iPhone: Inställningar → Bilder → Överför till Mac eller PC → **Behåll original**.

## Varje del
1. **Matta ytan** om den är blank/svart: tunt lager scanningspray, torrschampo eller fotpuder.
2. Lägg referensarket på bordet, delen mitt på. Jämnt, mjukt ljus, inga hårda skuggor.
3. Kameraappen → Video. Håll fingret på delen tills **AE/AF-LÅS** visas.
4. **Klipp 1:** gå långsamt tre varv runt (lågt, mellan, högt), delen fyller större delen av bilden. ~60–90 s.
5. Vänd delen upp och ner. **Klipp 2:** samma sak.
6. Mät delens **längsta mått** med skjutmått (t.ex. 142,3 mm).
7. Koppla in telefonen med sladd → öppna **Bildinsamling** (Image Capture) → välj iPhone → markera de två klippen →
   "Importera till": t.ex. Skrivbordet → Importera. (Lås upp telefonen och tryck "Lita på" första gången.)
8. Terminal:

   ```bash
   skanna ~/Desktop/IMG_0001.MOV ~/Desktop/IMG_0002.MOV --langd 142.3
   ```

   Ca 1–5 min. Resultat i `~/Desktop/IMG_0001.modell/`:
   - `modell/modell-mm.obj` – i **millimeter**, X = längsta, Z = kortaste axeln, centrerad.
   - `modell.usdz` – snabb förhandsvisning (mellanslag i Finder).
9. Fusion: Insert → Insert Mesh → `modell-mm.obj`, enhet **mm**.

Kontrollera ett av de andra två utskrivna måtten med skjutmåttet. Stämmer det, stämmer skalan.

## Flaggor
- `--detalj raw` – ingen ytförenkling (mest detalj, större fil, ingen usdz).
- `--bilder 200` – fler bildrutor per klipp (standard 150).
- `--maskning off` – om bakgrunden kommer med eller delar av objektet försvinner.
- `--ut MAPP` – egen utmapp.
- Fotomapp i stället för video: `skanna ~/Desktop/foton --langd 142.3`.
- Nytt referensark: `skanna ark ~/Desktop/ark.pdf`.

Bygga om CLI:t: `swiftc -O -parse-as-library -o skanna main.swift` (görs också av `./bygg-beta.sh`).
