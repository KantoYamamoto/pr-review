#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

xcodebuild -quiet \
  -project PRReview.xcodeproj \
  -scheme PRReview \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/xcode \
  build

APP="$PWD/dist/PR Review.app"
mkdir -p "$PWD/dist"
# Copy the Xcode-built app, including its compiled resources.
ditto "$PWD/.build/xcode/Build/Products/Release/PR Review.app" "$APP"
codesign --force --sign - "$APP"
print "Built: $APP"
