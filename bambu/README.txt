Bambu Studio-export (cad/bambu.py)

x2d-referens-project_settings.json  skelett: project_settings.config ur en riktig X2D-export (Bambu Studio 02.08.02.61, 581 nycklar).
x2d-<plast>-project_settings.json   färdiga mallar (en filamentplats per plast: PLA, PETG, PETG-CF …), byggda med
                                    `cad/bambu.py --bygg-mall --material <plast>` (exporten bygger saknade mallar själv):
  - process = "0.20mm Standard @BBL X2D" (inherits upplöst, lagd över skelettet; skrivsätt som "100" / "100%" behålls),
  - filament = plastens profil, t.ex. "Bambu PETG-CF @BBL X2D 0.4 nozzle" (inherits upplöst och utbredd per variant som Studio
    gör: skelettets per-filament-block är len/2 av arrayen; filament_extruder_variant = skelettets sex varianter, som i en
    riktig Studio-export – profilens egen lista har bara "Direct Drive Standard"),
  - maskin (g-kod, nozzle-arrayer) oförändrat från skelettet = X2D 0.4,
  - different_settings_to_system = ["", "", ""] (inget avviker från systemprofilerna), print_settings_id = processnamnet.
Skillnader mot referens-3MF:en: en filamentplats i stället för två (filament_*-arrayer halverade, flush_volumes_matrix ["0"],
filament_map/volume_map/nozzle_map ["1"]/["0"]/["0"]); inga tumnaglar, plate_N.png/json, pick/top-bilder, cut_information,
filament_sequence, process_settings_1.config eller <assemble>-block (genereras av Bambu Studio); objektinställningar ligger som
<metadata key=… value=…/> under <object> i Metadata/model_settings.config; mesh i Objects/object_<2i>.model (id 2i-1) med
wrapper-objekt 2i i 3dmodel.model, centrerad kring origo och placerad via <item transform>.

Flera plattor: delar radpackas på platta 1, och det som inte ryms läggs på nästa platta (en del större än 256 × 256 får en egen platta
och en varning). Plattornas origo i 3dmodel.model: rutnät med ceil(sqrt(n)) kolumner, rad för rad nedåt (−Y), avstånd 1,2 × 256 mm
(= 307,2 mm). Härlett ur referens-3MF:en (platta 2 vid x +307,2, platta 3 vid y −307,2 med n = 3) och Studios kända plattgap 1/5;
antagande för n ≥ 5 (kolumnantalet) är inte verifierat. <plate> i model_settings.config har plater_id 1, 2, …

Flera plaster i samma projekt (cad/utskrift.json, se cad/utskrift.py): en filamentplats per plast. Plats-mallarna slås ihop
(`kombinera`): per-filament-nycklar = de vars lista i skelettet (två filament) är dubbelt så lång som i en enplatsmall, och de
läggs efter varandra; filament_self_index 1…n per variant, flush_volumes_matrix 2 munstycken × n×n (0 på diagonalen, annars 152
som i skelettet), filament_map/volume_map/nozzle_map en per plats, different_settings_to_system n+2 tomma, och platserna får
olika färger. Kontroll: PETG + PETG ger samma längd på alla nycklar som skelettet och samma värden utom färgerna och två
profilvärden (filament_preheat_temperature_delta, long_retractions_when_ec) som skiljde redan i enplatsmallen. Varje objekt
får <metadata key="extruder" value="<plats>"/>, plattan filament_maps "1 1 …". Att Bambu Studio öppnar en flerplastfil är inte
provat (Studio startas aldrig härifrån).
