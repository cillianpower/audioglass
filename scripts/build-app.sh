#!/bin/zsh
set -eu
cd "${0:A:h:h}"
cargo build --release --manifest-path Rust/Cargo.toml
swift build
binary_dir=$(swift build --show-bin-path)
app_dir="$PWD/build/Audioglass.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/Audioglass" "$app_dir/Contents/MacOS/Audioglass"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.cillianpower.audioglass.study</string>
<key>CFBundleName</key><string>Audioglass</string>
<key>CFBundleExecutable</key><string>Audioglass</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSMicrophoneUsageDescription</key><string>Audioglass analyzes your selected microphone or audio interface input to display live meters.</string>
<key>NSAudioCaptureUsageDescription</key><string>Audioglass analyzes audio playing on your Mac to display live audio meters.</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconName</key><string>Audioglass</string>
<key>CFBundleIconFile</key><string>Audioglass</string>
</dict></plist>
PLIST
mkdir -p "$app_dir/Contents/Resources"
xcrun actool "$PWD/Icon/Audioglass.icon" --compile "$app_dir/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon Audioglass \
  --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null
cp LICENSE "$app_dir/Contents/Resources/LICENSE.txt"
cp Rust/UPSTREAM.md "$app_dir/Contents/Resources/OpenMeters.md"
codesign --force --sign - "$app_dir"
print -r -- "$app_dir"
