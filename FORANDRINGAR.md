# Skanna Beta – vad som är nytt

`~/Applications/Skanna Beta.app` (bundle-id `local.skanna.beta`) körs bredvid den vanliga Skanna.app. All kod, alla skript
och mallar ligger i `~/git/worldforge/local/skanna-v2/`. Den vanliga appen, `local/fotoskanning/` och dina skanningar i
`~/Downloads/IMG_907*.modell` är inte ändrade. Alla tester har gjorts på kopior (`~/Downloads/skanna-test/`) och i en
tillfällig mapp.

## Kort
- Sparade vyer fungerar även i fotoläget: vyn minns bildrutan, och ett klick på miniatyren går tillbaka till samma foto (med lager och opacitet).
- **Sparade vyer (20 nov):** plusknappen till vänster om vykuben sparar hela viewporten – kamera, synliga lager,
  flytt/explode, opacitet, färgschema och snitt – med en miniatyr av canvasen. Klicka en miniatyr för att gå tillbaka dit;
  högerklick byter namn eller tar bort. Sparas i `cad/vyer.json` och `cad/vyer/`.
- **Explode (E)** drar bara isär de delar som syns, och avståndet anpassas efter hur stora de synliga delarna är.
- **Importera delar (19 nov):** *Lägg till del → Importera fil …* (objektträdets +, Projekt-menyn ⌥⌘I) eller dra in filen
  på 3D-vyn. **STEP** från Fusion och andra CAD-program blir en del med riktiga ytor och kanter: välj, mät,
  fasa/runda kanter, och Claude kan bygga vidare på den. **STL, 3MF och OBJ** blir trianglar. Stora plana partier går att
  välja och mäta mot, och delen kan skrivas ut. Kryssa i *Som referens* för en köpt detalj som inte ska skrivas ut. Filen
  kopieras till `cad/import/`, och placeringen ändras med måtten *flytta x/y/z, vrid x/y/z, skala* (25,4 för tum,
  1000 för meter). Fusions egna parametrar följer inte med i STEP; be Claude skriva om delen som skript om du vill ha
  redigerbara mått.
- **Chatten (19 nov):** större och justerbar text (A−/A+), hela texten i varje meddelande, allt i en rullning.
  Klara trådar och Claudes lösa meddelanden hamnar i *Historik*, grupperad per dag och sökbar. Varje meddelande visar tid.
  Svar i en tråd kan ha bilaga och pekpunkter. "Claude arbetar" visas bara medan Claude faktiskt arbetar;
  har claude.json stått still i 30 min visas en varning i stället.
- **Flytta projekt:** högerklick i projektlistan → *Flytta till …* / *Flytta till projektmappen*, eller Projekt-menyn.
  Hela mappen flyttas. Det gamla repot får en commit för flytten och det nya en första commit. Byter du projektmapp i
  Inställningar erbjuder appen att flytta projekten dit.
- **Tooltips** ritas nu av appen själv. **Paneler av/på (⇥)** kompenseras i samma layoutpass, så modellen ska inte darra.
  **Kortkommandon** (⌘/) är grupperade. **Objektlistan:** vald rad visar hela beskrivningen, och tooltipen visar den alltid.
- **Var filerna sparas + historik i git:** i Inställningar (⌘,) väljer du projektmappen, och appen rekommenderar starkt
  ett git-repo (knappen *Gör projektmappen till git-repo*). Nya videoskanningar hamnar också där om du vill.
  I ett repo gör appen en commit när en ändring har satt sig – Claude har byggt färdigt, ett mått, ett namn,
  projektbyte, när appen stängs. Bara `cad/` och `projekt.json` versioneras; bilder, video och mesh hålls utanför.
  *Historik* (klockan i toppraden, ⌘Y) visar versionerna. *Gå tillbaka hit* gör en ny version, så inget skrivs över,
  och samtalet med Claude ligger kvar. ⌘Z fungerar som förut för enskilda steg medan appen är öppen. Appen pushar aldrig.
- **Modellera utan skanning:** *Nytt modellprojekt* (⌘N) från en mall (låda med lock, distans, vinkelfäste, vridskiva)
  eller tomt med en beskrivning till Claude. Det är samma objektträd, samma redigerbara mått, samma export till Bambu Studio och samma
  Claude-dialog som för skanningar.
- **Guidad skanning** (⌥⌘N): iPhonen på stativ används som kamera för Macen (Continuity Camera). Appen visar vilken vinkel
  som är nästa (N lägen × M höjder, och en omgång till med delen vänd), tar stillbilden direkt till projektets mapp och
  kontrollerar skärpa, ljus och reflexer. Sedan kör *Bygg 3D-modell* fotogrammetrin med inställningar för vridskiva.
- **Vridskiva:** två utskrivna delar, inga köpdelar, 24 snäpplägen. Knappen *Skriv ut vridskivan* i guidad skanning
  öppnar den direkt i Bambu Studio. *Ändra måtten …* skapar ett eget projekt där alla mått går att redigera.
- **Ny layout:** projektlista till vänster, startsida med tre vägar in, och en arbetsyta med objektträd, 3D och
  Claude/mått. Fotolägets reglage syns bara när det finns foton. Appen har nu kortkommandon, byggfel visas med logg, och
  tomma lägen förklarar vad man ska göra.

- **Snitt** (knappen *Snitt*, ⌥⌘X): appen väljer det huvudplan (X, Y eller Z) som ligger mest tvärs blicken och lägger det
  genom mitten av det som syns. Reglaget bredvid flyttar planet längs axeln. Allt på kamerans sida klipps bort, och snittytorna fylls i varje dels färg. Skanningen och delar
  som inte är slutna får bara snittlinjer. Planet ligger kvar när du vrider, och raden visar t.ex. *Snitt: Y = −2,2*.
  Slår du av och på väljs ett nytt plan efter vyn.
- **Opacitet per del:** klicka på en del i 3D-vyn eller på namnet i objektträdet för att välja den. Ögat visar och döljer
  som förut. Reglaget i verktygsraden gäller vald del ("Opacitet: Distansring"). Värdet sparas per del och projekt, med ett
  värde i 3D-vyn och ett i fotoläget. Klick i tomrummet avmarkerar. I fotoläget utan vald del styr reglaget fotots
  opacitet ("Opacitet: foto"). Under 100 % tonar fotot mot vald bakgrundsfärg, som i v1.

## Nytt modellera-gränssnitt (2026-11-18)
Arbetsytan är omgjord från grunden. Planen finns i `PLAN-modellera.md`.
- **Layout:** 3D-vyn fyller fönstret. Ovanpå svävar en verktygsrad (överst), objektträdet (vänster) och en inspektör
  (nere till vänster). Till höger finns flikarna **Samtal** och **Mått**. *Skriv ut* ligger i toppraden.
- **Verktyg:** Välj (V), Mät (M), Rita (D), Flytta (G) och Peka (P). E = explode, R = lägg tillbaka, X = snitt, Esc = avmarkera.
  - **Välj:** klick på en del visar längd × bredd × höjd och volym. Klickar du igen på samma del väljs ytan, och du får
    area, Ø och längd för cylindrar, och tjocklek. På en kant får du längd, radie och Ø. Klick i tomrummet avmarkerar.
  - **Mät:** två klick. Punkterna fäster mot hörn, kantmitt, cirkelcentrum och ytcentrum. Mellan parallella ytor mäts
    det vinkelräta avståndet. Mätlinjen ritas genom modellen, och resultatet kan kopieras eller skickas till Claude.
  - **Flytta:** dra en del eller kropp dit du vill (⌥-dra flyttar hela delen). Dubbelklick eller R lägger tillbaka.
    Explode drar isär allt, och ett reglage styr hur mycket. Inget av detta ändrar modellen, skripten eller måtten.
  - **Rita:** markören blir en penna. Ytan under spetsen lyses upp, och inom ~16 px från en kant syns en blå fyrkant
    som följer kanten exakt i 3D. Kanten lyses upp och fyrkanten håller fast vid den kant den följer. Hörn fäster inom
    8 px. Tryck ned där strecket ska börja (i fyrkanten om den syns) och rita med knappen nedhållen, som på en
    utskrift: modellen står still och inget fäster. ⇧ ger en rak linje, även mitt i ett streck. Med mellanslag
    nedhållet vrider du i stället. Skrollhjulet zoomar som vanligt.
    - När du släpper hamnar ritningen i skrivfältet i Samtal (med miniatyr), och fältet får fokus. Fler streck från samma
      vy blir samma ritning. ⌘Z tar bort senaste strecket, och Esc eller krysset kastar ritningen (går att ångra).
      Ritar du efter att ha vridit vyn börjar en ny ritning.
    - När du skickar blir det en ny tråd med ritningen som referens. `cad/ritningar/<id>.png` är vyn med strecken och
      `<id>.json` har kameran, strecken som strålar och vad varje stråle träffar (del, yta, punkt i mm). Det står i
      AGENT.md hur Claude ska läsa den. Nålen sätts där strecket började.
    - Strecken ligger i ett plan genom kamerans mål. Från ritvyn ser de ut exakt som ritat, och vrider du bort vyn
      tonas de ut (borta vid ~10°). Klicka på miniatyren i tråden så går kameran tillbaka och strecken syns igen.
      *Dölj* släcker dem.
    - Det går att rita i fotoläget, ovanpå fotot. Ritningen kommer då ihåg fotot och går tillbaka till det.
  - **Peka:** klicka där något ska ändras. Skrivfältet i Samtal får då ett förankrings-chip, och meddelandet blir en ny
    tråd om just den platsen.
- **Objekt:** delar som består av flera sammanhängande kroppar delas upp, t.ex. fem celler. Varje kropp kan tändas och
  släckas, med en egen ljushet av delens färg. Klick på raden väljer, och ögat tänder eller släcker. Delarna får
  färger ur ett färgschema som skiljer sig mellan projekt (palettknappen). "Allt grått" och "Delarnas egna färger" finns också.
- **Snitt** ligger överst i objektträdet:
  - Slå på det med X eller ögat och klicka i modellen. Planet vänds **mot dig** (huvudplanet närmast skärmens plan) genom
    punkten, 0,1 mm in i materialet, och kamerans sida tas bort. Med ⌥-klick går planet lodrätt (på skärmen) tvärs
    igenom punkten i stället.
  - Varje sparad snittvy har ett **öga**: tänd det snittet (planet och kameran) eller släck det. Ett i taget är tänt.
  - Snittytorna är **snedstreckade**, med olika vinkel per del. Reglaget flyttar planet.
  - *Spara vyn* lägger snittet med kameraläge under Snitt (`cad/snittvyer.json`). Klick visar det igen, och
    högerklick byter namn eller tar bort.
- **Kanter:** välj en kant och skriv fillet- eller fasmått i inspektören. Har delen ett del-skript byggs den om direkt
  (`cad/kantbehandling.json` → `projekt.py`). Claude får alltid veta. Saknas skript gör Claude ändringen.
- **Samtal med trådar:**
  - Varje meddelande startar en tråd. Aktiva trådar (Claude arbetar, väntar på Claude, fråga till dig) ligger fast
    överst, med svarsfält i tråden. Avslutade fälls ihop under "Avslutade". Frågor om mått är också trådar.
  - Flera trådar kan pågå samtidigt, och du kan stänga en tråd själv. Mått som du ändrar visas som en hopfälld logg.
  - Nålar i 3D visas bara för aktiva trådar.
- **Skriv ut → Bambu Studio-projekt:**
  - Synliga konstruktionsdelar packas i en projekt-3MF för **X2D 0,4 mm** (`cad/bambu.py`). Inställningarna kommer
    från dina installerade Bambu-profiler: 0,20 mm Standard och PLA Basic.
  - Delarnas egna inställningar (väggar, fyllnad, stöd) läggs per objekt. Det som inte ryms läggs på platta 2, 3 …
  - *Öppna delarnas 3MF-filer var för sig* finns kvar i menyn.
- **Ångra/gör om:** knapparna i toppraden och ⌘Z/⇧⌘Z (i ett textfält gäller textens egen ångra). Allt du ändrar i
  appen går att ångra: mått, fillet/fas, tillagda delar, visa/dölj, flytt, explode, opacitet, färgschema och snitt på/av.
  Ett drag eller en reglagerörelse räknas som ett steg. Ångrar du en modelländring skrivs filerna tillbaka och delen
  byggs om, och Claude får en rad i loggen. Meddelanden till Claude går inte att ångra.
- **Objektträdet (2026-11-19):**
  - Släckta lager sparas i `cad/objekt.json` och finns kvar när du öppnar projektet igen eller när Claude har byggt om.
  - Skanningens lager (referensdelarna) ligger under *Skanning*, som går att fälla ihop.
  - Dra en del för att flytta den i listan. Dubbelklicka på namnet (eller högerklicka → *Byt namn …*) för att byta namn.
    Namnet används också i exporten och i Bambu Studio, och Claude får en rad i loggen.
  - Ögat står längst till höger. Pilen överst fäller ihop hela trädet (O).
- **Släck alla paneler:** knappen längst till höger i verktygsraden eller ⇥. Bara modellen och verktygsraden syns. Esc
  (eller ⇥ igen) tänder dem.
- **Zoom mot pekaren:** nyp och skrollhjul zoomar mot punkten under pekaren, inte mot mitten.
- **Tooltips** på knapparna nämner kortkommandot där det finns ett.
- **Mätetiketten** ritas som en bild, så rutan passar alltid texten.
- **Mallen Låda med lock** hade en bugg som mätverktygen hittade: läppen satt lös från locket. Den är rättad.

**Otestat i nya gränssnittet:**
- Riktiga musklick och drag. Allt är simulerat i harnessen: klick via koordinatorn, flytt via funktionsanrop.
  Ritläget är provat genom att anropa koordinatorns mus-funktioner: fäste mot kant och hörn, fritt streck, rakt streck
  med ⇧, ångra/gör om, skicka (filerna och tråden), uttoning från ovanvyn, tillbaka till ritvyn, och streck på
  skanningen och i fotoläget. Pennmarkören, mellanslag för att vrida och ⇧ mitt i ett streck med riktig mus är inte provade.
- Att Bambu Studio öppnar projekt-3MF:en. Filen är validerad mot en riktig X2D-projektfil (samma 581 inställningar,
  strukturen stämmer), men BS har inte startats. Om BS klagar: välj *Öppna delarnas 3MF-filer var för sig*.
- Kantval och tjocklek kräver att delen är byggd med nya `ytor.py`. HiKOKI-delarna byggs med v1:s skript och har
  därför bara yt-val, inte kant-val, tills de flyttas till `cad/skript/`.

## Utskriftsinställningar per del (2026-11-18)
- **I appen:** välj en konstruktionsdel (klick i 3D-vyn eller i objektträdet). Kortet **Utskrift** i inspektören har
  *Plast*, *Vägglager*, *Infill*, *Topplager*, *Bottenlager* och *Support* (av/på och typ: träd eller normal, auto eller
  manuell). Plasten skrivs in eller väljs i listan, som visar vanliga plaster och alla installerade X2D 0,4-profiler.
  Det du ändrar blir rosa. Högerklick på en etikett återställer fältet, och *Återställ* återställer hela delen till
  del-skriptets värden. Pilen fäller ihop kortet till en rad ("PETG-CF · 4 väggar · 25% infill · 6/5 lager · …").
- **Ångra:** varje ändring går att ångra och göra om (⌘Z / ⇧⌘Z). Snabba klick i följd blir ett steg.
- **Claude:** inställningarna ligger i `cad/utskrift.json`. Claude får ett meddelande i loggen, som när ett mått ändras.
  Claude kan själv ändra filen, t.ex. när du skriver "gör locket i PETG-CF med 4 väggar", med
  `cad/utskrift.py <projekt> lock plast=PETG-CF wall_loops=4`. Claude får också lägga till fler inställningar, t.ex.
  brim. De visas i kortet under *Fler inställningar*, och du kan ta bort dem. Värdena i `utskrift.json` går före det
  del-skriptet anger (`bambu={…}`).
- **Export (*Skriv ut*):** varje objekt får sina inställningar. Plasten står i namnet, t.ex. *Lock (PETG-CF)*, både i
  projektfilen och i Bambu Studio. Den syns också i objektträdet under delens namn. Plasten väljer filamentprofil
  ("Bambu PETG-CF @BBL X2D 0.4 nozzle"). Har delarna olika plast får projektet en filamentplats per plast, med olika
  färger, och varje objekt hamnar på rätt plats. Finns ingen installerad profil för en plast används närmaste (PETG-CF2
  ger PETG, annars PLA). Namnet behåller ändå din plast, och appen visar en varning.
- **Rättat i mallarna:** `filament_extruder_variant` i `bambu/x2d-PLA|PETG-project_settings.json` hade profilens enda
  variant ("Direct Drive Standard") sex gånger. Nu står de sex varianterna som i en riktig Studio-export. Inget annat i
  mallarna ändrades.
- **Provat:** kortet, ändringar, ångra och gör om, meddelanden, filer som Claude skriver, en plast utan profil och
  återställ är provade utanför skärmen med harnessen på Testlåda. Exporten är kontrollerad genom att packa upp 3MF:en:
  *Lock (PETG-CF)* på plats 1 och *Låda (PLA-CF)* på plats 2, med rätt `wall_loops`, `sparse_infill_density`,
  `top/bottom_shell_layers`, `enable_support`, `support_type` och `brim_type` per objekt. Ihopslagningen av två
  filamentplatser ger samma struktur som den riktiga X2D-exporten.
- **Otestat:** att Bambu Studio öppnar en fil med flera plaster, eftersom BS inte har startats. *Öppna delarnas 3MF-filer
  var för sig* ger fortfarande filerna utan inställningar och utan plast i namnet. Använd Bambu Studio-projektet.

## Hur man provar
1. Öppna **Skanna Beta** från `~/Applications`. Första gången frågar macOS om åtkomst till Hämtade filer, Dokument och
   Skrivbord, eftersom det är en ny app. Svara OK.
2. **Modellera:** ⌘N → välj *Låda med lock* → Skapa. Klicka på ett mått, t.ex. *antal fack* → 3 → ↩. Lådan byggs om på
   några sekunder. *Skriv ut* (⌘E) öppnar delarna i Bambu Studio.
3. **Claude i modellprojekt:** ⌘N → *Tomt – Claude ritar*, och beskriv delen. Tryck *Kopiera uppdrag till Claude* och
   klistra in i Claude Code. Claude läser `AGENT.md` i skanna-v2, ritar ett del-skript och svarar i appen.
4. **Vridskiva:** ⌥⌘N → *Skriv ut vridskivan* (bas + topp, matt svart PLA, inga stöd).
5. **Guidad skanning:** ⌥⌘N → fyll i namn och bildplan → *Skapa projekt och anslut kameran*. iPhonen ska vara låst och
   stå på stativet nära Macen, med samma Apple-konto och wifi/Bluetooth på. Du kan också koppla in den med sladd.
   Följ vinklarna. Ta bilden med mellanslag, ↩, en Bluetooth-avtryckare eller *Autofoto*. Avsluta med *Vidare: bygg 3D-modell*.
6. **Befintliga skanningar** syns i listan som förut. Fotoläget (⌘K), klick i modellen, frågor och svar fungerar som i
   den vanliga appen. Om du ändrar ett mått i HiKOKI-projektet bygger Beta med **samma skript som den vanliga appen**
   (`fotoskanning/cad/bygg_alla.sh`), så de två apparna bygger likadant.

## Otestat (viktigt)
- **Kameran och triggern är inte provade alls.** Jag har inte anslutit kameran, för att inte utlösa macOS behörighetsdialog.
  Koden är byggd mot macOS 26-SDK:n, och `Info.plist` har `NSCameraUsageDescription` och
  `NSCameraUseContinuityCameraDeviceType`, som Continuity Camera kräver. Första gången du trycker *Anslut* frågar macOS om
  kameratillstånd.
  - iPhone SE (3:e gen) stöds av Continuity Camera, som kräver iPhone XR/SE 2 eller senare och iOS 16. Desk View stöds inte
    på SE, men den behövs inte här. Sladd kräver iOS 17 och macOS 14.
  - **Upplösning:** appen väljer det kameraformat som ger störst stillbild och visar den faktiska upplösningen bredvid
    kameravalet. Jag räknar med upp till 12 MP (sensorns upplösning), men det är inte kontrollerat. Blir det bara ~2 MP
    (videoupplösning) har Continuity Camera tappat sin fördel. Då är importen bättre: fota med kameraappen och
    Bluetooth-avtryckaren och använd *Importera foton*.
  - Center Stage stängs av programmatiskt, eftersom den beskär bilden och förstör fotogrammetrin. Porträtt och
    Studioljus styrs i Kontrollcenter och ska vara **av**.
  - *Lås fokus/exponering* visas bara om kameran tillåter det. Det är okänt om Continuity Camera gör det.
  - Om Object Capture får brännvidd ur EXIF från Continuity Camera-bilderna är okänt. Utan EXIF skattar den själv, vilket
    oftast går bra.
  - **Bluetooth-avtryckare:** de vanliga billiga skickar "volym upp". Är avtryckaren parad med Macen fångar appen
    tangenten medan Beta är aktiv. Systemvolymen ändras troligen också, vilket är ofarligt. Det är otestat.
  - **Autofoto** (fota när skivan stått still i 0,8 s) är testat med simulerade rörelsevärden, inte med riktig kamera.
- **Vridskivan är inte utskriven.** Tappspel (0,3 mm) och snäppkraft är beräknade. Justera i projektet *Vridskiva* om
  den kärvar eller glappar.
- **Bygg 3D-modell från stillbilder** (`--ordning sekventiell`, utmapp = projektet) är provat med CLI:t på 150 bildrutor
  ur en befintlig skanning. Det tog några minuter och gav `modell/modell-mm.obj` i projektet: bordet bortplockat och skalat
  till 133,9 mm. Med riktiga vridskivebilder är det inte provat.
- **Snitt och opacitet** är provade utanför skärmen på låd-mallen och skanningskopian, med plan efter vy, fyllda snitt,
  linjer för öppna meshar och opacitet 25 % på en del. Klick-val av del i 3D-vyn är inte provat med riktig mus.
- Själva apppaketet har jag inte startat interaktivt, eftersom det skulle ge macOS-dialoger om filåtkomst. Alla vyer är
  däremot renderade och kontrollerade utanför skärmen med appens egen kod: start, ny skanning, guidad skanning, nytt
  projekt, kortkommandon, modellprojekt med mått som ändras och byggfel, vridskivan, skanningskopian i 3D- och fotoläge,
  och bygg-av-bilder. Bildkontrollen är provad på riktiga bildrutor: en suddig bild och en bild med reflexer flaggades.

## Rekommendation: trigger
1. **Continuity Camera först.** Iphonen ligger ändå still på stativet, vilket Continuity Camera kräver, och appen får
   bilden direkt med förhandsvisning och kontroll. Ingen import behövs, och inga sladdar om wifi fungerar. Med
   Autofoto vrider du bara skivan ett snäpp i taget, och appen tar bilden när skivan står still.
2. **Om upplösningen blir för låg eller anslutningen strular:** använd en Bluetooth-avtryckare (volym upp) parad med
   **iPhonen**, ta bilderna med kameraappen (HEIC, 12 MP, fokus låst med AE/AF-LÅS), och importera mappen med
   *Importera foton*. Appen kör samma bildkontroll och bygger på samma sätt.
3. iOS-genvägar som trigger valde jag bort. De kräver en upplåst telefon och ger sämre kontroll än kameraappen.

## Rekommendation: vridskiva
Skriv ut den som den är: bas och topp, 0,2 mm lagerhöjd, matt svart PLA (ovansidan får gärna vara mönstrad i två färger
om du har AMS – mönster som följer med runt hjälper fotogrammetrin). Lägg delen på toppen, gärna på en bit
referensark. Börja med 24 lägen × 3 höjder × 2 omgångar (144 bilder, ca 15 min). Är skivan trög: lite PTFE-spray eller
silikonolja på glidringen. Se `vridskiva/LÄSMIG.md`.

## Vad som ändrats i koden
- `app/SkannaApp.swift` (en fil, ~2000 rader) är uppdelad i: `SkannaApp.swift` (app, menyer, kortkommandon),
  `Modeller.swift` (filprotokollets typer, `Hem`, mallar), `Tillstand.swift` (projektets tillstånd, CAD/Claude-filer,
  bygg), `Korning.swift` (CLI-körning), `Projekthantering.swift` (projektlista, nya projekt, mallar, import),
  `Vyer.swift` (fönster, start, ny skanning, arbetsyta), `Panel.swift` (objektträd, Claude/mått),
  `ModelView.swift` (3D-vyn, oförändrad kamerastyrning), `GuidadSkanning.swift`, `Kamera.swift`, `Kvalitet.swift`,
  `Hjalp.swift`. Den gamla filen ligger kvar i `gammal/`.
- **3D-vyn:** fungerar utan skanning. I modellprojekt är Z upp som i Bambu Studio, och för skanningar gäller −Z som förut.
  Det kan ändras per projekt i kugghjulsmenyn. *Hela modellen* anpassas nu till både vyns höjd och bredd, så modellen
  hamnar inte utanför i smala fönster. Kontrollerna är som förut, plus ⌘0–⌘7 för vyerna och ⌘K för fotoläget.
- **Bygg:** `bygg_projekt.sh <projekt>` kör projektets `cad/skript/*.py`. Äldre skanningar utan skript byggs med den vanliga
  appens `bygg_alla.sh`. Om bygget misslyckas visar appen sista raden, hela loggen och en knapp som skickar loggen till Claude.
- **Mått:** grupperas per del ("Låda: …"), heltal visas utan decimaler, källan *mall* är ny, och högerklick ger *Återställ*.
- **CLI (`main.swift`):** nya flaggor `--ordning sekventiell|oordnad` och `--beskar on|off`. Utmappen får vara ett projekt
  (`projekt.json`) som ännu inte har någon modell.
- **Prestanda:** måtten läses ur OBJ-filen utan att hela filen delas upp i strängar. Projektlistan uppdateras efter varje
  bygge. Stora meshar laddas som förut i bakgrunden; mer behövdes inte för dina skanningar (10 MB OBJ).
- **Nytt:** `cad/projekt.py` (hjälpklass för del-skript), `mallar/` (4 mallar), `vridskiva/` (färdiga filer och
  LÄSMIG), `bygg-beta.sh`, `bygg_projekt.sh`, en ny `AGENT.md` (projektstruktur med och utan skanning, del-skript) och
  `bevaka.sh`, som också bevakar `~/Documents/Skanna/*`.
- **Projektmapp:** nya projekt hamnar i `~/Documents/Skanna/<namn>/` med `projekt.json`. Video-skanningar hamnar som förut
  bredvid klippet (`*.modell`).

## Föra över till den vanliga appen
När du vill att Beta ska bli den vanliga Skanna:
1. Stäng Skanna.app (inget bygge eller skanning får pågå).
2. Kopiera över:
   `rsync -a --exclude .venv --exclude __pycache__ ~/git/worldforge/local/skanna-v2/{app,mallar,vridskiva,main.swift,bygg_projekt.sh,bevaka.sh,AGENT.md} ~/git/worldforge/local/fotoskanning/` och `cp ~/git/worldforge/local/skanna-v2/cad/projekt.py ~/git/worldforge/local/fotoskanning/cad/`
   Kör `uv pip install --python .venv/bin/python opencv-python-headless pillow pillow-heif` i fotoskanning om de
   saknas.
3. I `bygg-beta.sh`: byt `Skanna Beta` mot `Skanna`, `local.skanna.beta` mot `local.skanna` och `APP=` mot
   `~/Applications/Skanna.app`. Spara som `bygg-app.sh` och kör det. Info.plist-nyckeln `SkannaHem` pekar då på
   fotoskanning.
4. Uppdatera `~/.claude/skills/skanna/SKILL.md`: protokollet finns nu i nya `AGENT.md` (del-skript i `cad/skript/`,
   modellprojekt i `~/Documents/Skanna/`).
5. HiKOKI-projektets skript (`cad/nederskal.py`, `overskal.py`, `provring.py`, `distans.py`) kan ligga kvar. De byggs via
   `bygg_alla.sh` tills de flyttas in i projektets `cad/skript/`.
6. Snitt och opacitet per del finns i båda apparna och beter sig likadant: plan efter blickriktningen genom mitten av
   det som syns, ett reglage som flyttar planet, opacitet per del och läge (3D/foto) och fotot som tonar mot bakgrunden.
   Betas kod ligger i `app/Snitt.swift`, `ModelView.swift`, `Vyer.swift` och `Panel.swift`. När allt förs över ersätter
   den v1:s variant. Sparade opaciteter börjar då om från 100 %, eftersom nycklarna sparas på olika sätt.
7. v1 har fått nya saker efter kopian: `cad/distans.py` (kräver `lxml` i venv) och `bygg_alla.sh` som kör den. Beta
   bygger äldre projekt med v1:s `bygg_alla.sh`, så det fungerar redan. Det gäller även överdelens nya kant, som gjuts av
   underdelens kant (`avgjutning()` i v1:s `cad/ytor.py`). Skriv därför inte över v1:s `cad/ytor.py` med v2:s. Kopiera inte v2:s äldre `cad/nederskal.py` m.fl.
   över v1:s, utan bara `cad/projekt.py`.
Skanningarna och projektmapparna behöver inte ändras. Formatet är bakåtkompatibelt (nya fält som `grupp` ignoreras av
den gamla appen).
