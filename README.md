# Skanna

macOS-app (SwiftUI + SceneKit) som skannar delar till mm-exakta 3D-modeller (iPhone-video eller stillbilder →
Apple Object Capture) och modellerar nya delar i build123d, med Claude som valfri agent via ett filprotokoll.

- **Bygga appen:** `./bygg-beta.sh` (lägger *Skanna Beta.app* i `~/Applications` och CLI:t `skanna` här).
- **Python-miljön:** `uv venv --python 3.12 .venv && uv pip install -r requirements.txt`
- **Skanna med CLI:t och guiden:** `LÄSMIG.md`
- **Vad appen kan, hur man provar, vad som är otestat:** `FORANDRINGAR.md`
- **Protokollet för agenten (Claude):** `AGENT.md`
- **Vridskivan att skriva ut:** `vridskiva/`

Kräver macOS 14+ (Object Capture på Apple silicon) och Xcode Command Line Tools (`swiftc`).
