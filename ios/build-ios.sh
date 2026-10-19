#!/usr/bin/env bash
# Build PDF Editor for iPhone/iPad and install it with xtool. Runs inside WSL (Ubuntu), where
# xtool lives; "Build iOS.bat" in the project folder starts it for you.
#
#   ios/build-ios.sh            build the engine and the app, then install on the connected iPhone
#   ios/build-ios.sh --ipa      build a signed .ipa in ios/ instead of installing
#   ios/build-ios.sh --build    compile only (no iPhone needed): the first thing to try
#   ios/build-ios.sh --engine   only rebuild the Rust engine
#
# Build files go to ~/.cache/pdf-editor (inside WSL, fast), never to the OneDrive folder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="${PDF_EDITOR_CACHE:-$HOME/.cache/pdf-editor}"
FONTS_REF=3d9ab3a132ed0eff457e424226a435a901da30d3
TARGET=aarch64-apple-ios
MODE="${1:-}"

step() { printf '\n==> %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

mkdir -p "$CACHE"

step "Checking tools"
# xtool and Swift come from swiftly, as for The Auditor.
# shellcheck disable=SC1091
[ -f "$HOME/.local/share/swiftly/env.sh" ] && . "$HOME/.local/share/swiftly/env.sh"
if ! command -v cargo >/dev/null; then
  [ -x "$HOME/.cargo/bin/cargo" ] || { echo "Installing Rust (rustup)…"; curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; }
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
rustup target add "$TARGET" >/dev/null
command -v git >/dev/null || die "git is missing: sudo apt install git"
command -v cc >/dev/null || die "no C compiler in WSL (needed by Rust build scripts): sudo apt-get install build-essential"
if [ "$MODE" != "--engine" ]; then
  command -v xtool >/dev/null || die "xtool was not found in WSL. Install it (https://xtool.sh) and run 'xtool setup' once, then try again."
  command -v rsync >/dev/null || die "rsync is missing: sudo apt-get install rsync"
fi

step "Fonts for Arabic and Japanese text (craft-fonts, pinned)"
if [ ! -d "$CACHE/craft-fonts/.git" ]; then
  git clone --filter=blob:none https://github.com/storytold/craft-fonts.git "$CACHE/craft-fonts"
fi
git -C "$CACHE/craft-fonts" fetch -q origin "$FONTS_REF" 2>/dev/null || true
git -C "$CACHE/craft-fonts" checkout -q "$FONTS_REF"

step "Building the PDF engine for iPhone (first time: 10-30 minutes)"
export CRAFT_FONTS_DIR="$CACHE/craft-fonts" CRAFT_FONTS_REQUIRED=1
export CARGO_TARGET_DIR="$CACHE/target" IPHONEOS_DEPLOYMENT_TARGET=17.0
# The engine is a static library: nothing is linked for iPhone here (xtool links the app).
# A few dependencies (rten, boa_engine) also ask for a dynamic library of themselves, which
# needs Apple's linker; nothing uses those, so a stand-in "linker" just writes an empty file.
FAKE_LD="$CACHE/ios-no-link.sh"
cat > "$FAKE_LD" <<'LD'
#!/bin/sh
# Stand-in linker for iOS dynamic libraries nobody uses: create the output file and succeed.
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then shift; : > "$1"; fi
  shift
done
exit 0
LD
chmod +x "$FAKE_LD"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$FAKE_LD"
(cd "$ROOT" && cargo build --release --locked -p pdfcraft-mobile --target "$TARGET")
mkdir -p "$HERE/Vendor/ios-arm64"
cp "$CARGO_TARGET_DIR/$TARGET/release/libpdfeditor_core.a" "$HERE/Vendor/ios-arm64/"
ls -lh "$HERE/Vendor/ios-arm64/libpdfeditor_core.a"

step "Text recognition models (OCR: English and Arabic)"
(cd "$ROOT" && CARGO_TARGET_DIR="$CACHE/host" cargo run -q -p xtask -- models "$HERE/Resources/Models")
[ "$MODE" = "--engine" ] && { echo "Engine ready."; exit 0; }

# xtool builds in a copy inside WSL (~/PDFEditor): much faster than OneDrive, and its build
# files stay out of it. Same layout as The Auditor's scripts/wsl.sh.
APP="${PDF_EDITOR_APP:-$HOME/PDFEditor}"
mkdir -p "$APP"
rsync -a --delete --exclude .build --exclude "xtool/" --exclude "*.log" "$HERE/" "$APP/"
cd "$APP"

# Reach the iPhone through Apple's Windows service when WSL has no local usbmuxd (set up by
# The Auditor's scripts/4b-relay-iphone.bat).
if [ -z "${USBMUXD_SOCKET_ADDRESS:-}" ] && [ ! -S /var/run/usbmuxd ]; then
  export USBMUXD_SOCKET_ADDRESS="$(ip route list default | awk '{print $3}'):27015"
  echo "Using iPhone relay at $USBMUXD_SOCKET_ADDRESS"
fi

case "$MODE" in
  --ipa)
    step "Building a signed PDFEditor.ipa"
    xtool dev build -c release --sign --ipa
    ipa="$(ls -t "$APP"/xtool/*.ipa 2>/dev/null | head -1 || true)"
    [ -n "$ipa" ] || die "xtool did not produce an .ipa (see the messages above)"
    cp "$ipa" "$HERE/"
    echo "Done: ios/$(basename "$ipa")"
    ;;
  --build)
    step "Compiling the app (no iPhone needed)"
    xtool dev build
    ;;
  --xcode)
    step "Generating an Xcode project (for an App Store build on a Mac)"
    xtool dev generate-xcode-project
    ;;
  *)
    step "Building, signing and installing on your iPhone (keep it connected and unlocked)"
    xtool dev
    ;;
esac
