#!/usr/bin/env bash
# install-befahl.sh — build the befahl fork and install it over the running AeroSpace.
#
# Builds a release AeroSpace.app + `aerospace` CLI from the current checkout (arm64 only,
# no man pages / shell completion), signs both with the local Apple Development identity,
# installs to /Applications/AeroSpace.app and /opt/homebrew/bin/aerospace, and restarts
# the server. The signing identity stays the same between builds, so the Accessibility
# permission survives reinstalls.
#
# Requires: swiftly (Swift per .swift-version), Xcode.app, Homebrew bash 5.
# Usage:    ./install-befahl.sh
# Rollback: brew install --cask aerospace   (after deleting /Applications/AeroSpace.app)
cd "$(dirname "$0")"
set -euo pipefail

IDENTITY="Apple Development: befahl@ethz.ch (SF7B7N5MSD)"
VERSION="0.21.3-befahl"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/opt/homebrew/bin:$PATH"
# shellcheck disable=SC1091
source "$HOME/.swiftly/env.sh"

/opt/homebrew/bin/bash -c "
    source ./script/setup.sh
    set -e
    ./generate.sh --build-version '$VERSION' --codesign-identity '$IDENTITY' --generate-git-hash
    swift build -c release --arch arm64 --product aerospace
    cli_bin_path=\$(swift build -c release --arch arm64 --product aerospace --show-bin-path)
    rm -rf .release && mkdir .release
    (cd xcode && xcodebuild clean build -scheme AeroSpace -destination 'generic/platform=macOS' \
        -configuration Release -derivedDataPath .xcode-build > ../.release/xcodebuild.log 2>&1)
    cp -r xcode/.xcode-build/Build/Products/Release/AeroSpace.app .release
    cp \"\$cli_bin_path/aerospace\" .release
    codesign -s '$IDENTITY' .release/aerospace
"
# generate.sh rewrites tracked files with release values; restore them
git checkout Sources/Common/gitHashGenerated.swift Sources/Common/versionGenerated.swift xcode/AeroSpace.xcodeproj/project.pbxproj

osascript -e 'quit app id "bobko.aerospace"' || true
while pgrep -x AeroSpace > /dev/null; do sleep 0.2; done
rm -rf /Applications/AeroSpace.app
cp -R .release/AeroSpace.app /Applications/
cp .release/aerospace /opt/homebrew/bin/aerospace
open /Applications/AeroSpace.app
sleep 2
aerospace --version
