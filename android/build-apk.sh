#!/usr/bin/env bash
# CI/local Linux build (no Android Studio). Output: build/commander.apk
# Release signing: set KEYSTORE_B64 (+ KEY_ALIAS/KEYSTORE_PASS/KEY_PASS), else dev key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?set ANDROID_HOME}}"
BT="$SDK/build-tools/36.1.0"
PLAT="$SDK/platforms/android-36.1/android.jar"
OUT="$ROOT/build"
mkdir -p "$OUT"
MAN="$ROOT/AndroidManifest.xml"
SRC="$ROOT/src"
UNSIGNED="$OUT/commander-unsigned.apk"
ALIGNED="$OUT/commander.apk"

"$BT/aapt2" link -o "$UNSIGNED" -I "$PLAT" --manifest "$MAN" \
  --version-code 1 --version-name '0.1.0' --min-sdk-version 24 --target-sdk-version 36
rm -rf "$OUT/classes" && mkdir -p "$OUT/classes"
find "$SRC" -name '*.java' > "$OUT/sources.txt"
javac -encoding UTF-8 -source 8 -target 8 -cp "$PLAT" -d "$OUT/classes" @"$OUT/sources.txt"
mkdir -p "$OUT/dex"
find "$OUT/classes" -name '*.class' > "$OUT/classes.txt"
"$BT/d8" --lib "$PLAT" --min-api 24 --output "$OUT/dex" @"$OUT/classes.txt"
python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'a',zipfile.ZIP_DEFLATED); z.write(sys.argv[2],'classes.dex'); z.close()" "$UNSIGNED" "$OUT/dex/classes.dex"
if [[ -n "${KEYSTORE_B64:-}" ]]; then
  echo "$KEYSTORE_B64" | base64 -d > "$OUT/release.keystore"
  KS="$OUT/release.keystore"; ALIAS="${KEY_ALIAS:?}"; KSPASS="${KEYSTORE_PASS:?}"; KPASS="${KEY_PASS:-$KSPASS}"
else
  KS="$OUT/dev.keystore"; ALIAS=dev; KSPASS=devdev123; KPASS=devdev123
  [[ -f "$KS" ]] || keytool -genkeypair -keystore "$KS" -alias dev -keyalg RSA -keysize 2048 \
    -validity 3650 -storepass "$KSPASS" -keypass "$KPASS" -dname 'CN=dev'
fi
"$BT/zipalign" -f 4 "$UNSIGNED" "$ALIGNED"
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$KSPASS" --key-pass "pass:$KPASS" "$ALIGNED"
"$BT/apksigner" verify "$ALIGNED" && echo "APK_OK $ALIGNED"
