#!/usr/bin/env bash
# CI/local Linux build (no Android Studio). Output: build/commander.apk
# Release signing: set KEYSTORE_B64 (+ KEY_ALIAS/KEYSTORE_PASS/KEY_PASS), else dev key.
#
# ⚠️ 签名密钥必须固定。以前这里没有 Secrets，每次 CI 都 keytool 现场生成一把新的
# dev key —— 于是每个 Release 的签名都不一样，用户装新版直接被系统拒
# （INSTALL_FAILED_UPDATE_INCOMPATIBLE），只能先卸载。打 tag 发版时若没配好密钥，
# 本脚本会直接失败，不再产出「装不上去的 Release」。
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

# 版本号走变量，别在两处硬编码（以前 version-name 写死 0.2.0，
# 结果 v0.2.1 的包对外还是报 0.2.0）
VERSION_NAME="${VERSION_NAME:-0.2.1}"
VERSION_NAME="${VERSION_NAME#v}"        # 允许直接传 tag 名（v0.2.1）
if [[ -z "${VERSION_CODE:-}" ]]; then
  _a="${VERSION_NAME%%.*}"; _rest="${VERSION_NAME#*.}"
  _b="${_rest%%.*}"; _c="${_rest#*.}"
  # 0.2.1 -> 201，保证每次发版 versionCode 递增
  VERSION_CODE=$(( 10#${_a:-0} * 10000 + 10#${_b:-0} * 100 + 10#${_c:-0} ))
fi

"$BT/aapt2" link -o "$UNSIGNED" -I "$PLAT" --manifest "$MAN" \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" --min-sdk-version 24 --target-sdk-version 36
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
  echo "== 用仓库 Secrets 里的固定密钥签名（APK 才能盖住旧版）"
elif [[ -n "${REQUIRE_RELEASE_KEY:-}" ]]; then
  echo "!! 这是发版构建，但没有稳定签名密钥。" >&2
  echo "!! 用临时密钥签出来的 APK 装不上旧版（签名不符），用户只能卸载重装。" >&2
  echo "!! 请在仓库 Secrets 配置：KEYSTORE_B64 / KEY_ALIAS / KEYSTORE_PASS / KEY_PASS" >&2
  exit 1
else
  echo "== ⚠️ 没有 KEYSTORE_B64，用本地 dev key（仅供自测；这种包盖不上正式版）" >&2
  KS="$OUT/dev.keystore"; ALIAS=dev; KSPASS=devdev123; KPASS=devdev123
  [[ -f "$KS" ]] || keytool -genkeypair -keystore "$KS" -alias dev -keyalg RSA -keysize 2048 \
    -validity 3650 -storepass "$KSPASS" -keypass "$KPASS" -dname 'CN=dev'
fi
"$BT/zipalign" -f 4 "$UNSIGNED" "$ALIGNED"
"$BT/apksigner" sign --ks "$KS" --ks-pass "pass:$KSPASS" --key-pass "pass:$KPASS" "$ALIGNED"
"$BT/apksigner" verify "$ALIGNED" && echo "APK_OK $ALIGNED (versionName=$VERSION_NAME code=$VERSION_CODE)"

