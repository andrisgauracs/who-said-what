#!/bin/zsh
# Builds WhoSaidWhat.app next to this script.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=WhoSaidWhat.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/WhoSaidWhat $APP/Contents/MacOS/
# SwiftPM resource bundles from dependencies, if any
for b in .build/release/*.bundle(N); do cp -R "$b" $APP/Contents/Resources/; done
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Who Said What</string>
  <key>CFBundleDisplayName</key><string>Who Said What</string>
  <key>CFBundleIdentifier</key><string>com.andrisgauracs.whosaidwhat</string>
  <key>CFBundleExecutable</key><string>WhoSaidWhat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSpeechRecognitionUsageDescription</key><string>Transcribes the recording on this Mac.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - $APP
echo "Built $(pwd)/$APP"
