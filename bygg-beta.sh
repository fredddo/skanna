#!/bin/zsh
# Bygger "Skanna Beta.app" (med skanna-cli inuti) i ~/Applications. Rör inte den vanliga Skanna.app.
set -e
cd "$(dirname "$0")"
HEM="$(pwd)"
APP="$HOME/Applications/Skanna Beta.app"
NAMN="Skanna Beta"; BID="local.skanna.beta"; ENV=""
# --test: en separat instans (test/Skanna Beta Test.app) som arbetar på kopior i ~/Downloads/skanna-test/kopia.
# Rör inte Skanna Beta som användaren jobbar i, och startas om direkt så att den nya koden syns.
if [[ "$1" == "--test" ]]; then
  APP="$HEM/test/Skanna Beta Test.app"; NAMN="Skanna Beta Test"; BID="local.skanna.beta.test"
  ENV="<key>LSEnvironment</key><dict><key>SKANNA_PROJEKTROT</key><string>$HOME/Downloads/skanna-test/kopia</string></dict>"
  mkdir -p "$HEM/test"
fi
# Den riktiga Beta byggs bara om när hela testsviten går igenom (tester/testa.sh); --utan-test hoppar över det.
if [[ -z "$ENV" && "${1:-}" != "--utan-test" ]]; then
  if ! tester/testa.sh; then
    echo "Testerna gick inte igenom – Skanna Beta byggs inte om (rätta felen, eller: bygg-beta.sh --utan-test)." >&2
    exit 1
  fi
fi
if [[ -z "$ENV" ]] && pgrep -f "Skanna Beta.app/Contents/MacOS/skanna-cli" >/dev/null; then
  echo "En skanning pågår i Skanna Beta – bygger inte om nu." >&2
  exit 1
fi
BUILD=$(mktemp -d)
swiftc -O -parse-as-library -o "$BUILD/skanna-cli" main.swift
swiftc -O -parse-as-library -o "$BUILD/Skanna Beta" app/*.swift
[[ -z "$ENV" ]] && cp "$BUILD/skanna-cli" "$HEM/skanna"
# Bygg den nya appen bredvid och byt plats – en Beta som körs stängs inte (den fortsätter med den gamla koden tills omstart).
NEW="$APP.ny"
rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp "$BUILD/Skanna Beta" "$NEW/Contents/MacOS/$NAMN"; cp "$BUILD/skanna-cli" "$NEW/Contents/MacOS/"
cp referensark.pdf "$NEW/Contents/Resources/"
[[ -f app/AppIcon.icns ]] && cp app/AppIcon.icns "$NEW/Contents/Resources/"
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$NAMN</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>$NAMN</string>
  <key>CFBundleDisplayName</key><string>$NAMN</string>
  $ENV
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleDevelopmentRegion</key><string>sv</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SkannaHem</key><string>$HEM</string>
  <key>SkannaProjektmapp</key><string>Skanna</string>
  <key>NSCameraUsageDescription</key><string>Skanna Beta använder iPhonen (Continuity Camera) eller en annan kamera för att ta stillbilder till skanningen.</string>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Håll mellanslag i chattrutan för att prata in det du vill skriva till Claude.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Det du pratar in i chattrutan görs om till text – på Macen när det går.</string>
</dict></plist>
PLIST
# Signering: med ett eget certifikat "Skanna lokal" (Nyckelhanterare → Certifikatassistent → Skapa ett certifikat …,
# typ Kodsignering) behåller appen samma identitet mellan byggen, så macOS kommer ihåg mapp- och mikrofongodkännanden.
# Utan det blir det ad hoc-signering och macOS frågar igen efter varje ombygge.
if security find-certificate -c "Skanna lokal" >/dev/null 2>&1 && codesign --force --deep -s "Skanna lokal" "$NEW" >/dev/null 2>&1; then
  echo "Signerad med certifikatet Skanna lokal"
else
  codesign --force --deep -s - "$NEW" >/dev/null 2>&1
  echo "Ad hoc-signerad (inget certifikat 'Skanna lokal') – macOS frågar om mappar/mikrofon igen efter ombygget"
fi
if [[ -n "$ENV" ]]; then
  pkill -f "test/Skanna Beta Test.app/Contents/MacOS/Skanna Beta Test" 2>/dev/null && sleep 1
  rm -rf "$APP"; mv "$NEW" "$APP"; rm -rf "$BUILD"
  open "$APP"
  echo "Startade testinstansen: $APP (projekt: ~/Downloads/skanna-test/kopia)"
  exit 0
fi
OLD="$BUILD/gammal.app"
[[ -d "$APP" ]] && mv "$APP" "$OLD"
mv "$NEW" "$APP"
if pgrep -f "Skanna Beta.app/Contents/MacOS/Skanna Beta" >/dev/null; then
  echo "OBS: Skanna Beta körs – starta om den för att få den nya versionen."
else
  rm -rf "$BUILD"
fi
echo "Byggt: $APP (hem: $HEM)"
