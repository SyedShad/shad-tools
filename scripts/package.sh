#!/bin/bash
# Build independent macOS app bundles and product archives using Apple tools.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${VERSION:-0.6.0}
case "$version" in *[!0-9.]*|'') echo 'VERSION must be numeric with dots' >&2; exit 2;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/shad-pack.XXXXXX")
lock=""
promoted=()
finish() {
    local status=$? path
    if [[ "$status" != 0 && -n "$lock" ]]; then
        # Restore the exact previous release if a file move failed during promotion.
        for path in "${promoted[@]+"${promoted[@]}"}"; do
            if [[ -e "$output/$path" ]]; then mv "$output/$path" "$staged/$path"; fi
            if [[ -e "$work/previous/$path" ]]; then mv "$work/previous/$path" "$output/$path"; fi
        done
    fi
    if [[ -n "$lock" ]]; then rm -f "$lock"; fi
    rm -rf "$work"
}
trap finish EXIT
# An optional edition builds just its dependencies, without fetching other tools' resources.
selection=${1:-all}
[[ $# -le 1 ]] || { echo "usage: $0 [suite|search|audio|drives|color|windows|capture|clipboard|mouse]" >&2; exit 2; }
editions=()
products=()
names=()
needs_capture=false
while IFS=$'\t' read -r edition product feature name; do
    [[ "$selection" == all || "$selection" == "$edition" ]] || continue
    editions+=("$edition")
    products+=("$product")
    names+=("$name")
    if [[ "$edition" == suite || "$edition" == capture ]]; then needs_capture=true; fi
done < Packaging/Editions.tsv
[[ ${#editions[@]} -gt 0 ]] || { echo "Unknown edition: $selection" >&2; exit 2; }
output="$PWD/dist"
if [[ "$selection" != all ]]; then output="$output/standalone/$selection"; fi
staged="$work/products"
mkdir -p "$staged/apps"
for arch in arm64 x86_64; do
    options=(--scratch-path ".build/package-$arch" -c release --triple "$arch-apple-macosx13.0")
    if [[ "$selection" == all ]]; then swift build "${options[@]}"
    else swift build "${options[@]}" --product "${products[0]}"
    fi
    bindir=$(swift build "${options[@]}" --show-bin-path)
    for product in "${products[@]}"; do cp "$bindir/$product" "$work/$product-$arch"; done
done
swift scripts/icon.swift "$work/Shad.iconset"
iconutil -c icns "$work/Shad.iconset" -o "$work/Shad.icns"
if [[ "$needs_capture" == true ]]; then ./scripts/prepare-capture-engine.sh "$work/capture-engine"; fi
packages=()
for i in "${!editions[@]}"; do
    edition=${editions[$i]}
    product=${products[$i]}
    name=${names[$i]}
    id="io.github.syedshad.shadtools.$edition"
    dir="$work/$edition-edition"
    app="$dir/root/$name.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    lipo -create "$work/$product-arm64" "$work/$product-x86_64" -output "$app/Contents/MacOS/ShadTools"
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
<key>ShadEdition</key><string>$edition</string>
</dict></plist>
PLIST
    case "$edition" in
        suite|capture)
            ditto "$work/capture-engine/Helpers" "$app/Contents/Helpers"
            ditto "$work/capture-engine/Resources" "$app/Contents/Resources"
            /usr/bin/plutil -insert NSCameraUsageDescription -string "Show your camera as an overlay when you record your screen." "$app/Contents/Info.plist"
            /usr/bin/plutil -insert NSCameraUseContinuityCameraDeviceType -bool true "$app/Contents/Info.plist"
            /usr/bin/plutil -insert NSMicrophoneUsageDescription -string "Record your narration when you enable the microphone in Screen Capture." "$app/Contents/Info.plist"
            ;;
    esac
    case "$edition" in
        windows) /usr/bin/plutil -insert NSAccessibilityUsageDescription -string "Move and resize the windows you arrange." "$app/Contents/Info.plist";;
        suite) /usr/bin/plutil -insert NSAccessibilityUsageDescription -string "Arrange windows, paste selected clipboard entries and run mouse shortcuts in the active app." "$app/Contents/Info.plist";;
        mouse) /usr/bin/plutil -insert NSAccessibilityUsageDescription -string "Recognize your assigned mouse buttons and run the dial or gesture shortcut you select." "$app/Contents/Info.plist";;
        clipboard) /usr/bin/plutil -insert NSAccessibilityUsageDescription -string "Paste the entry you select in Clipboard History into the active app." "$app/Contents/Info.plist";;
    esac
    sign_args=(--force --options runtime --sign "${APP_SIGN_IDENTITY:--}")
    if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then sign_args+=(--timestamp); fi
    case "$edition" in
        suite|capture) sign_args+=(--entitlements scripts/capture.entitlements);;
    esac
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
    mv "$pkg" "$staged/"
    packages+=("$(basename "$pkg")")
    mv "$app" "$staged/apps/"
done
manifest="SHA256SUMS-$version.txt"
if [[ "$selection" != all ]]; then manifest="SHA256SUMS-$version-$selection.txt"; fi
(cd "$staged" && shasum -a 256 "${packages[@]}" > "$manifest")
./scripts/verify-packages.sh "$staged" "$selection"

# Publish only once every requested product passes. Promote the checksum manifest last.
mkdir -p "$output/apps" "$work/previous/apps"
/usr/bin/shlock -p $$ -f "$output/.package.lock" || { echo "Another build is finalizing $output." >&2; exit 1; }
lock="$output/.package.lock"
paths=("${packages[@]}")
for name in "${names[@]}"; do paths+=("apps/$name.app"); done
paths+=("$manifest")
for path in "${paths[@]}"; do
    if [[ -e "$output/$path" ]]; then mv "$output/$path" "$work/previous/$path"; fi
    promoted+=("$path")
    mv "$staged/$path" "$output/$path"
done
