#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
SDK="${ANDROID_SDK_DIR:-/tmp/android-sdk}"
BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-$SDK/android-15}"
ANDROID_JAR="${ANDROID_JAR:-$SDK/android-35/android.jar}"
OUT_APK="${1:-$SCRIPT_DIR/wgksu-status.apk}"
KEYSTORE="$SCRIPT_DIR/wgksu-status.jks"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[ -x "$BUILD_TOOLS/aapt2" ] || { echo "ERROR: aapt2 not found in $BUILD_TOOLS" >&2; exit 1; }
[ -f "$ANDROID_JAR" ] || { echo "ERROR: android.jar not found at $ANDROID_JAR" >&2; exit 1; }

if [ ! -f "$KEYSTORE" ]; then
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" \
    -storepass wgksu123 -keypass wgksu123 \
    -alias wgksu \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=WireGuard-KSU, O=WireGuard-KSU, C=US" >/dev/null 2>&1
fi

mkdir -p "$WORK/res_flat" "$WORK/gen" "$WORK/classes" "$WORK/dex"

"$BUILD_TOOLS/aapt2" compile --dir "$SCRIPT_DIR/res" -o "$WORK/res_flat/res.zip"
"$BUILD_TOOLS/aapt2" link \
  -I "$ANDROID_JAR" \
  --manifest "$SCRIPT_DIR/AndroidManifest.xml" \
  --java "$WORK/gen" \
  -o "$WORK/unaligned.apk" \
  "$WORK/res_flat/res.zip"

javac -source 8 -target 8 -bootclasspath "$ANDROID_JAR" -classpath "$ANDROID_JAR" \
  -d "$WORK/classes" \
  "$WORK/gen/com/wireguard/ksu/status/R.java" \
  "$SCRIPT_DIR/src/com/wireguard/ksu/status/"*.java

"$BUILD_TOOLS/d8" --min-api 28 --lib "$ANDROID_JAR" --output "$WORK/dex" \
  "$WORK/classes/com/wireguard/ksu/status/"*.class

(cd "$WORK/dex" && zip -q "$WORK/unaligned.apk" classes.dex)
"$BUILD_TOOLS/zipalign" -f -p 4 "$WORK/unaligned.apk" "$WORK/aligned.apk"
"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-key-alias wgksu \
  --ks-pass pass:wgksu123 \
  --key-pass pass:wgksu123 \
  --v1-signing-enabled true \
  --v2-signing-enabled true \
  --v3-signing-enabled true \
  --out "$OUT_APK" \
  "$WORK/aligned.apk"

"$BUILD_TOOLS/apksigner" verify --verbose "$OUT_APK"
ls -lh "$OUT_APK"
