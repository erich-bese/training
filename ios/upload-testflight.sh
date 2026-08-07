#!/bin/sh
# Baut ein Archiv und lädt es nach App Store Connect. Von dort ist die App
# über TestFlight auf dem iPhone installierbar — ohne Kabel, ohne
# Entwicklermodus, 90 Tage je Build.
#
# Voraussetzungen, einmalig:
#   1. Apple Developer Program der GmbH freigeschaltet
#   2. App-Eintrag in App Store Connect mit der Bundle-ID de.besemedia.training
#   3. App-Store-Connect-API-Schlüssel:
#      App Store Connect → Users and Access → Integrations → App Store Connect API
#      → Schlüssel erzeugen, Rolle "Admin", .p8-Datei herunterladen.
#      "App Manager" reicht nicht: damit darf Apple keine Verteilungsprofile
#      anlegen, und der Export scheitert mit "Cloud signing permission error".
#      Die Datei gibt es nur ein einziges Mal zum Herunterladen.
#      Ablegen unter ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#
# Aufruf, wenn ios/.env gepflegt ist:
#   ./upload-testflight.sh
# Sonst:
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-... ./upload-testflight.sh
set -e

# Das Skript kennt keine Argumente. Sie stillschweigend zu ignorieren waere
# teuer: ein vermeintlicher Probelauf wuerde einen echten Build hochladen.
if [ $# -gt 0 ]; then
  echo "Dieses Skript nimmt keine Argumente. Jeder Aufruf laedt wirklich hoch."
  exit 2
fi

here=$(cd "$(dirname "$0")" && pwd)

# Kennungen aus einer lokalen Datei, falls vorhanden. Sie liegt ausserhalb des
# Repos, weil das Repo oeffentlich ist — und erspart es, bei jedem Aufruf drei
# Kennungen von Hand mitzugeben. Was schon in der Umgebung steht, gewinnt.
if [ -f "$here/.env" ]; then
  while IFS='=' read -r name wert; do
    case "$name" in ''|\#*) continue ;; esac
    eval "current=\${$name:-}"
    [ -z "$current" ] && export "$name=$wert"
  done < "$here/.env"
fi

# Team-ID aus der Umgebung, sonst aus dem Entwicklerzertifikat im Schluesselbund.
team=${DEVELOPMENT_TEAM:-}
if [ -z "$team" ]; then
  team=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)
fi
if [ -z "$team" ]; then
  echo "Keine Team-ID gefunden. Apple-ID in Xcode hinterlegen oder"
  echo "DEVELOPMENT_TEAM=XXXXXXXXXX $0"
  exit 1
fi

if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
  echo "ASC_KEY_ID und ASC_ISSUER_ID fehlen."
  echo "Beide stehen in App Store Connect unter Users and Access → Integrations."
  exit 1
fi

key="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
if [ ! -f "$key" ]; then
  echo "Schlüsseldatei nicht gefunden: $key"
  exit 1
fi

# Jeder Upload braucht eine eigene Buildnummer. Der Zeitstempel ist monoton
# und lesbar, und die Marketing-Version bleibt davon unberührt.
build=$(date +%Y%m%d%H%M)
archive="$here/build/Training.xcarchive"

echo "Buildnummer: $build"
rm -rf "$archive"

xcodebuild archive \
  -project "$here/Training.xcodeproj" -scheme Training \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$build" \
  -allowProvisioningUpdates

opts=$(mktemp -t exportoptions).plist
sed "s/__TEAM__/$team/" "$here/ExportOptions.plist" > "$opts"
trap 'rm -f "$opts"' EXIT

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$opts" \
  -exportPath "$here/build/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$key" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo
echo "Hochgeladen. Die Verarbeitung bei Apple dauert 5 bis 15 Minuten."
echo "Danach in App Store Connect → TestFlight den Build einer internen"
echo "Testgruppe zuweisen. Interne Tester brauchen keine Prüfung durch Apple."
