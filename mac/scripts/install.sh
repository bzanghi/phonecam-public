#!/bin/zsh
# Build PhoneCam (Release) and install it to /Applications, where macOS allows camera extensions to activate.
# Signing: create mac/Local.xcconfig (see Config.xcconfig) with your DEVELOPMENT_TEAM, or the build is ad hoc
# and the camera extension cannot be activated.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
extra=()
if [[ -f Local.xcconfig ]] && grep -q '^DEVELOPMENT_TEAM' Local.xcconfig; then
  extra=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
else
  echo "warning: no DEVELOPMENT_TEAM in mac/Local.xcconfig; building ad hoc (camera extension will not activate)"
fi
# A new app build number per install. sysextd replaces the running camera extension whenever its version changes, and
# a replacement can leave Phone Camera missing until a restart, so the extension keeps its version until its sources
# (or the shared package it links) change. build/ext-version holds "<source hash> <version>".
build_number=$(date +%Y%m%d%H%M)
# LC_ALL=C: sort order (and so the hash) otherwise depends on the shell's locale.
ext_hash=$(LC_ALL=C find PhoneCamExtension Packages/PhoneCamCore/Sources/PhoneCamShared Packages/PhoneCamCore/Package.swift -type f -print0 \
  | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
ext_version=$build_number
if [[ -f build/ext-version ]] && read -r old_hash old_version < build/ext-version && [[ $old_hash == "$ext_hash" ]]; then
  ext_version=$old_version
fi
# Same for the PhoneCam Mic driver: a new version makes the app offer "Update…" (password + Core Audio restart).
mic_hash=$(LC_ALL=C find PhoneCamMic -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
mic_version=$build_number
if [[ -f build/mic-version ]] && read -r old_hash old_version < build/mic-version && [[ $old_hash == "$mic_hash" ]]; then
  mic_version=$old_version
fi
xcodebuild -project PhoneCam.xcodeproj -scheme PhoneCam -configuration Release -derivedDataPath build/DerivedData "${extra[@]}" \
  CURRENT_PROJECT_VERSION="$build_number" PHONECAM_EXT_VERSION="$ext_version" PHONECAM_MIC_VERSION="$mic_version" build > build/install.log 2>&1 || { grep -E "error:" build/install.log | sort -u; echo "build failed; nothing installed (log: mac/build/install.log)"; exit 1; }
grep -E "warning: .*sign" build/install.log | sort -u || true
echo "$ext_hash $ext_version" > build/ext-version
echo "$mic_hash $mic_version" > build/mic-version
app=build/DerivedData/Build/Products/Release/PhoneCam.app
[[ -d $app ]] || { echo "build failed"; exit 1; }
codesign -dv "$app" 2>&1 | grep -E "TeamIdentifier|Signature" || true
# Copy next to the old app first, so a failed copy never leaves nothing installed; then swap.
rm -rf /Applications/.PhoneCam.app.new
ditto "$app" /Applications/.PhoneCam.app.new
pkill -x PhoneCam 2>/dev/null || true
for _ in {1..50}; do pgrep -x PhoneCam >/dev/null || break; sleep 0.1; done
rm -rf /Applications/PhoneCam.app
mv /Applications/.PhoneCam.app.new /Applications/PhoneCam.app
open /Applications/PhoneCam.app
if [[ $ext_version == "$build_number" ]]; then
  echo "Build $build_number with a new camera extension. If the menu offers Install or Update, click it; if Phone Camera then disappears from apps, restart the Mac."
else
  echo "Build $build_number; camera extension unchanged ($ext_version), so no extension update is needed."
fi
echo "Installed /Applications/PhoneCam.app. Click the camera icon in the menu bar, then Install."
