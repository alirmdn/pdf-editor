#!/usr/bin/env bash
# Prepare the App Store project on a Mac: the app icon catalog, the Info.plist (ios/Info.plist
# plus the keys Xcode and App Review need), then the Xcode project (XcodeGen).
# Needs APPLE_TEAM_ID, APP_VERSION and BUILD_NUMBER in the environment.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}" "${APP_VERSION:?set APP_VERSION}" "${BUILD_NUMBER:?set BUILD_NUMBER}"

# App icon: one 1024 x 1024 image, no transparency (ios/Resources/AppIcon.png).
ICONSET=Assets.xcassets/AppIcon.appiconset
rm -rf Assets.xcassets
mkdir -p "$ICONSET"
cp ../Resources/AppIcon.png "$ICONSET/AppIcon.png"
cat > Assets.xcassets/Contents.json <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON
cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [ { "filename" : "AppIcon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

PLIST=Info.plist
cp ../Info.plist "$PLIST"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST" >/dev/null 2>&1 || true; }
set_key() { pb "Delete :$1"; /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"; }
set_key CFBundleIdentifier string '$(PRODUCT_BUNDLE_IDENTIFIER)'
set_key CFBundleExecutable string '$(EXECUTABLE_NAME)'
set_key CFBundleName string 'PDF Editor'
set_key CFBundlePackageType string APPL
set_key CFBundleInfoDictionaryVersion string 6.0
set_key CFBundleDevelopmentRegion string en
set_key CFBundleShortVersionString string '$(MARKETING_VERSION)'
set_key CFBundleVersion string '$(CURRENT_PROJECT_VERSION)'
set_key LSRequiresIPhoneOS bool true
# Export compliance is answered in App Store Connect (TestFlight asks once per build): declaring
# non-exempt encryption here would need a compliance code Apple issues for documented encryption.
pb "Delete :ITSAppUsesNonExemptEncryption"
# A launch screen (else the app runs letterboxed and App Review rejects the iPad build).
pb "Delete :UILaunchScreen"
/usr/libexec/PlistBuddy -c "Add :UILaunchScreen dict" "$PLIST"
# iPad multitasking needs every orientation.
pb "Delete :UISupportedInterfaceOrientations~ipad"
/usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad array" "$PLIST"
for o in Portrait PortraitUpsideDown LandscapeLeft LandscapeRight; do
  /usr/libexec/PlistBuddy -c "Add :UISupportedInterfaceOrientations~ipad: string UIInterfaceOrientation$o" "$PLIST"
done
plutil -lint "$PLIST"

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --spec project.yml
echo "Project ready: ios/AppStore/PDFEditor.xcodeproj"
