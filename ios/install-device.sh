#!/bin/sh
# Builds the app and puts it on the connected iPhone.
#
# Voraussetzungen, einmalig:
#   1. Xcode → Settings → Accounts → Apple-ID hinzufügen
#   2. iPhone per Kabel anschließen, "Diesem Computer vertrauen"
#
# Danach reicht dieser Aufruf. Die Team-ID wird aus dem Zertifikat gelesen,
# das Xcode bei der Anmeldung angelegt hat; notfalls per Umgebungsvariable:
#   DEVELOPMENT_TEAM=XXXXXXXXXX ./install-device.sh
set -e

here=$(cd "$(dirname "$0")" && pwd)

# --- Gerät finden ---------------------------------------------------------
# Über JSON, nicht über die Tabelle: deren Spalten und Zustandsnamen ändern
# sich zwischen Xcode-Versionen.
list=$(mktemp)
xcrun devicectl list devices --json-output "$list" >/dev/null 2>&1 || true
device=$(python3 - "$list" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in d.get("result", {}).get("devices", []):
    props = dev.get("deviceProperties", {})
    hw = dev.get("hardwareProperties", {})
    if hw.get("platform") != "iOS":
        continue
    if dev.get("connectionProperties", {}).get("tunnelState") == "unavailable":
        continue
    print(dev.get("identifier", ""))
    print(props.get("name", "iPhone"), file=sys.stderr)
    break
PY
)
rm -f "$list"
if [ -z "$device" ]; then
  echo "Kein iPhone gefunden."
  echo "Kabel anschließen, auf dem iPhone \"Vertrauen\" bestätigen, dann erneut."
  exit 1
fi
echo "iPhone: $device"

# --- Team-ID ermitteln ----------------------------------------------------
team=${DEVELOPMENT_TEAM:-}
if [ -z "$team" ]; then
  # Die Team-ID steht als Organisationseinheit im Entwicklerzertifikat.
  team=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
fi
if [ -z "$team" ]; then
  echo "Keine Team-ID gefunden — ist die Apple-ID in Xcode hinterlegt?"
  echo "Xcode → Settings → Accounts → +, danach diesen Aufruf wiederholen."
  echo "Alternativ: DEVELOPMENT_TEAM=XXXXXXXXXX $0"
  exit 1
fi
echo "Team: $team"

# --- Bauen und aufspielen -------------------------------------------------
out="$here/build"
xcodebuild -project "$here/Training.xcodeproj" -scheme Training \
  -configuration Release -destination "id=$device" \
  -derivedDataPath "$out" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build

app="$out/Build/Products/Release-iphoneos/Training.app"
xcrun devicectl device install app --device "$device" "$app"

echo
echo "Fertig. Die App liegt jetzt auf dem iPhone."
echo "Beim ersten Start ggf. Einstellungen → Allgemein → VPN & Geräteverwaltung"
echo "→ dem Entwickler vertrauen."
