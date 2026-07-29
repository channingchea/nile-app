#!/bin/sh
# Xcode Cloud: regenerate Flutter's ephemeral build inputs after clone.
#
# ios/Flutter/ephemeral/ (incl. FlutterGeneratedPluginSwiftPackage) and
# Generated.xcconfig are gitignored and produced by the Flutter tool, which
# isn't installed on Xcode Cloud runners. Without this script every build
# fails with "Could not resolve package dependencies".
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"

# Install Flutter (stable channel).
git clone https://github.com/flutter/flutter.git --depth 1 -b stable "$HOME/flutter"
export PATH="$PATH:$HOME/flutter/bin"

flutter config --enable-swift-package-manager
flutter precache --ios
flutter pub get

# Regenerate Generated.xcconfig + the ephemeral SwiftPM package for iOS.
flutter build ios --release --config-only --no-codesign

# CocoaPods deps (project is hybrid SwiftPM + CocoaPods).
HOMEBREW_NO_AUTO_UPDATE=1
brew install cocoapods
cd ios && pod install

exit 0
