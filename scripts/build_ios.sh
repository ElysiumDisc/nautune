#!/usr/bin/env bash
# Local release build on a Mac with Xcode (CI uses codemagic.yaml).
set -euo pipefail

cd "$(dirname "$0")/.."

flutter pub get
flutter analyze
flutter test
(cd ios && pod install)
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
