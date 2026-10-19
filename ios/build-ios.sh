#!/usr/bin/env bash
# Build PDF Editor for iPhone/iPad and install it with xtool. Runs inside WSL (Ubuntu), where
# xtool lives; "Build iOS.bat" in the project folder starts it for you.
#
#   ios/build-ios.sh            build the engine and the app, then install on the connected iPhone
#   ios/build-ios.sh --ipa      build a signed-for-testing .ipa in ios/ instead of installing
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
if ! command -v cargo >/dev/null; then
  [ -x "$HOME/.cargo/bin/cargo" ] || { echo "Installing Rust (rustup)…"; curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; }
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
fi
rustup target add "$TARGET" >/dev/null
command -v git >/dev/null || die "git is missing: sudo apt install git"
if [ "$MODE" != "--engine" ]; then
  command -v xtool >/dev/null || die "xtool was not found in WSL. Install it (https://xtool.sh) and run 'xtool setup' once, then try again."
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
(cd "$ROOT" && cargo build --release --locked -p pdfcraft-mobile --target "$TARGET")
mkdir -p "$HERE/Vendor/ios-arm64"
cp "$CARGO_TARGET_DIR/$TARGET/release/libpdfeditor_core.a" "$HERE/Vendor/ios-arm64/"
ls -lh "$HERE/Vendor/ios-arm64/libpdfeditor_core.a"

step "Text recognition models (OCR: English and Arabic)"
(cd "$ROOT" && CARGO_TARGET_DIR="$CACHE/host" cargo run -q -p xtask -- models "$HERE/Resources/Models")
[ "$MODE" = "--engine" ] && { echo "Engine ready."; exit 0; }

# xtool builds in a copy inside WSL: much faster than OneDrive, and its build files stay out of it.
APP="$CACHE/ios-app"
mkdir -p "$APP"
if command -v rsync >/dev/null; then
  rsync -a --delete --exclude .build --exclude xtool "$HERE/" "$APP/"
else
  find "$APP" -mindepth 1 -maxdepth 1 ! -name .build ! -name xtool -exec rm -rf {} +
  tar -C "$HERE" --exclude .build --exclude xtool -cf - . | tar -C "$APP" -xf -
fi
cd "$APP"
if [ "$MODE" = "--ipa" ]; then
  step "Building PDFEditor.ipa"
  xtool dev build --ipa
  ipa="$(ls -t "$APP"/xtool/*.ipa 2>/dev/null | head -1 || true)"
  [ -n "$ipa" ] || die "xtool did not produce an .ipa (see the messages above)"
  cp "$ipa" "$HERE/"
  echo "Done: ios/$(basename "$ipa")"
else
  step "Building, signing and installing on your iPhone (keep it connected and unlocked)"
  xtool dev
fi
