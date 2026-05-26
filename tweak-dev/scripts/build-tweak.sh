#!/usr/bin/env bash
# build-tweak.sh — build an iOS tweak locally on Linux using clang cross-compile,
# then push to phone, sign, install, and (optionally) relaunch target app.
#
# Usage:
#   build-tweak.sh <project_dir> [--target-bundle jp.naver.line] [--restart]
#
# project_dir layout:
#   <project>/Tweak.m              # ObjC source (no Logos)
#   <project>/<Project>.plist      # binary plist with Filter.Bundles array
#
# Env overrides:
#   TWEAK_NAME       - dylib base name (default: project dir basename)
#   PHONE_HOST       - ssh alias (default: iphone-mobile)
#   PHONE_SUDO       - sudo prefix on phone (default: 'sudo ')
#   ON_PHONE_BUILD   - if "1", invoke clang on the phone (legacy path)
#   SDK              - SDK root  (default: ~/tweak-dev/sdk/iPhoneOS.sdk)
#   EXTRA_FRAMEWORKS - extra -framework args (default: "")
#
set -euo pipefail
PROJECT=${1:?project dir required}
shift || true
PROJECT=$(readlink -f "$PROJECT")
TWEAK_NAME=${TWEAK_NAME:-$(basename "$PROJECT")}
PHONE_HOST=${PHONE_HOST:-iphone-mobile}
SDK=${SDK:-$HOME/tweak-dev/sdk/iPhoneOS.sdk}
COMMON_INC=$HOME/tweak-dev/common-include
EXTRA_FRAMEWORKS=${EXTRA_FRAMEWORKS:-}
RESTART=0
TARGET_BID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart) RESTART=1 ;;
    --target-bundle) TARGET_BID="$2"; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

SRC="$PROJECT/Tweak.m"
PLIST="$PROJECT/${TWEAK_NAME}.plist"
[[ -f $SRC   ]] || { echo "missing $SRC"; exit 1; }
[[ -f $PLIST ]] || { echo "missing $PLIST"; exit 1; }

OUT="$PROJECT/build/${TWEAK_NAME}.dylib"
mkdir -p "$(dirname "$OUT")"

echo "=== Build $TWEAK_NAME on phone ($PHONE_HOST) ==="
scp -q "$SRC"   "$PHONE_HOST:/tmp/${TWEAK_NAME}.m"
scp -q "$PLIST" "$PHONE_HOST:/tmp/${TWEAK_NAME}.plist"

# Build remotely (proven path — local clang lacks Mach-O linker support reliably)
ssh "$PHONE_HOST" "sudo /var/jb/usr/bin/clang \
  -target arm64-apple-ios14.0 \
  -isysroot /var/jb/SDKs/iPhoneOS.sdk \
  -fobjc-arc \
  -dynamiclib -Wl,-fixup_chains \
  -I /var/jb/usr/include \
  -framework Foundation -framework CydiaSubstrate $EXTRA_FRAMEWORKS \
  -Xlinker -rpath -Xlinker /var/jb/Library/Frameworks \
  -Xlinker -rpath -Xlinker /var/jb/usr/lib \
  -install_name '@rpath/${TWEAK_NAME}.dylib' \
  /tmp/${TWEAK_NAME}.m -o /tmp/${TWEAK_NAME}.dylib"

echo "=== Sign + install ==="
RAND=$(printf '%08x' $RANDOM$RANDOM)
ssh "$PHONE_HOST" "sudo /var/jb/usr/bin/ldid -S -I${TWEAK_NAME}.dylib.${RAND}.unsigned -Hsha1 /tmp/${TWEAK_NAME}.dylib && \
  sudo install -m 755 -o root -g wheel /tmp/${TWEAK_NAME}.dylib /var/jb/usr/lib/TweakInject/ && \
  sudo install -m 644 -o root -g wheel /tmp/${TWEAK_NAME}.plist /var/jb/usr/lib/TweakInject/"

# Pull built dylib back for reference
scp -q "$PHONE_HOST:/tmp/${TWEAK_NAME}.dylib" "$OUT"
echo "built dylib copied to $OUT"

if [[ $RESTART -eq 1 ]]; then
  if [[ -z "$TARGET_BID" ]]; then
    TARGET_BID=$(grep -oE 'jp\.naver\.line|com\.apple\.springboard|[a-z]+\.[a-z]+\.[a-z]+' "$PLIST" | head -1 || true)
  fi
  echo "=== Restart target: $TARGET_BID ==="
  if [[ "$TARGET_BID" == "com.apple.springboard" ]]; then
    ssh "$PHONE_HOST" "sudo killall -9 SpringBoard"
  else
    ssh "$PHONE_HOST" "sudo killall -9 ${TARGET_BID##*.} 2>/dev/null || true; sleep 1; sudo /var/jb/usr/bin/uiopen --bundleid $TARGET_BID"
  fi
fi
