#!/bin/bash
# Build independent macOS app bundles and product archives using Apple tools.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${VERSION:-0.1.0}
case "$version" in *[!0-9.]*|'') echo 'VERSION must be numeric with dots' >&2; exit 2;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/shad-pack.XXXXXX")
trap 'rm -rf "$work"' EXIT
output="$PWD/dist"
mkdir -p "$output"
for arch in arm64 x86_64; do
    options=(-c release --triple "$arch-apple-macosx13.0")
    swift build "${options[@]}" --product ShadTools
    bindir=$(swift build "${options[@]}" --show-bin-path)
    cp "$bindir/ShadTools" "$work/$arch"
done
lipo -create "$work/arm64" "$work/x86_64" -output "$work/ShadTools"
swift scripts/icon.swift "$work/Shad.iconset"
iconutil -c icns "$work/Shad.iconset" -o "$work/Shad.icns"
for edition in suite search audio drives color windows; do
    case "$edition" in
        suite) name='Shad Tools';;
        search) name='Shad Search';;
        audio) name='Shad Audio';;
        drives) name='Shad Eject';;
        color) name='Shad Color';;
        windows) name='Shad Windows';;
    esac
    id="io.github.syedshad.shadtools.$edition"
    dir="$work/$edition-edition"
    app="$dir/root/$name.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$work/ShadTools" "$app/Contents/MacOS/ShadTools"
    cp "$work/Shad.icns" "$app/Contents/Resources/Shad.icns"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleExecutable</key><string>ShadTools</string>
<key>CFBundleIconFile</key><string>Shad.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAccessibilityUsageDescription</key><string>Shad Windows uses Accessibility to move and resize the windows you arrange.</string>
<key>ShadEdition</key><string>$edition</string>
</dict></plist>
PLIST
    sign_args=(--force --options runtime --sign "${APP_SIGN_IDENTITY:--}")
    if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then sign_args+=(--timestamp); fi
    codesign "${sign_args[@]}" "$app"
    codesign --verify --strict "$app"
    cat > "$dir/components.plist" <<COMPONENTS
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>$name.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
COMPONENTS
    pkgbuild --root "$dir/root" --component-plist "$dir/components.plist" --install-location /Applications --identifier "$id.pkg" --version "$version" "$dir/App.pkg"
    cat > "$dir/distribution.xml" <<XML
<?xml version="1.0"?>
<installer-gui-script minSpecVersion="2">
<title>$name</title>
<options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
<domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="true"/>
<volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
<choices-outline><line choice="app"/></choices-outline>
<choice id="app" visible="false"><pkg-ref id="$id.pkg"/></choice>
<pkg-ref id="$id.pkg" version="$version" onConclusion="none">App.pkg</pkg-ref>
</installer-gui-script>
XML
    pkg="$dir/${name// /-}-$version.pkg"
    installer_sign=()
    if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then installer_sign=(--sign "$INSTALLER_SIGN_IDENTITY"); fi
    productbuild --distribution "$dir/distribution.xml" --package-path "$dir" ${installer_sign[@]+"${installer_sign[@]}"} "$pkg"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$pkg"
    fi
    mv "$pkg" "$output/"
    mkdir -p "$output/apps"
    ditto "$app" "$output/apps/$name.app"
done
(cd "$output" && shasum -a 256 "Shad-Tools-$version.pkg" "Shad-Search-$version.pkg" "Shad-Audio-$version.pkg" "Shad-Eject-$version.pkg" "Shad-Color-$version.pkg" "Shad-Windows-$version.pkg" > "SHA256SUMS-$version.txt")
