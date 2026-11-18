#!/bin/bash
# Inspect the distributable products without installing or launching them.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
version=${VERSION:-0.5.0}
case "$version" in ''|*[!0-9.]*) echo 'VERSION must contain digits and dots' >&2; exit 2;; esac
output=$(cd "${1:-dist}" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/shad-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() { echo "Verification failed: $*" >&2; exit 1; }
equal() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', found '$1')"; }
xml_value() { /usr/bin/xmllint --nonet --xpath "$1" "$2"; }
plist_value() { /usr/bin/plutil -extract "$1" raw -o - "$2"; }

names=('Shad Tools' 'Shad Search' 'Shad Audio' 'Shad Eject' 'Shad Color' 'Shad Windows' 'Shad Capture' 'Shad Clipboard' 'Shad Mouse')
editions=(suite search audio drives color windows capture clipboard mouse)
packages=()
for name in "${names[@]}"; do packages+=("${name// /-}-$version.pkg"); done
manifest="$output/SHA256SUMS-$version.txt"
[[ -f "$manifest" ]] || fail "missing $(basename "$manifest")"
(cd "$output" && /usr/bin/shasum -a 256 "${packages[@]}") > "$work/observed.txt"
# Check the exact set before trusting filenames in the supplied manifest.
sort "$work/observed.txt" > "$work/observed-sorted.txt"
sort "$manifest" > "$work/expected-sorted.txt"
cmp -s "$work/observed-sorted.txt" "$work/expected-sorted.txt" || fail 'checksum mismatch or incorrect manifest entries'

for i in "${!editions[@]}"; do
    edition=${editions[$i]}
    name=${names[$i]}
    pkg="$output/${packages[$i]}"
    id="io.github.syedshad.shadtools.$edition"
    expanded="$work/$edition"
    /usr/sbin/pkgutil --expand-full "$pkg" "$expanded"
    distribution="$expanded/Distribution"
    component="$expanded/App.pkg"
    metadata="$component/PackageInfo"
    payload="$component/Payload"
    app="$payload/$name.app"
    plist="$app/Contents/Info.plist"
    [[ -f "$distribution" && -f "$metadata" && -f "$plist" ]] || fail "$name package structure"
    members=("$expanded"/*.pkg)
    equal "${#members[@]}" 1 "$name component count"
    # A standalone package contains just its own .app and has no sibling prerequisites.
    shopt -s dotglob nullglob
    items=("$payload"/*)
    shopt -u dotglob nullglob
    equal "${#items[@]}" 1 "$name payload count"
    equal "${items[0]}" "$app" "$name payload"
    equal "$(xml_value "count(//pkg-ref[not(@id='$id.pkg')])" "$distribution")" 0 "$name package references"
    equal "$(xml_value "count(/installer-gui-script/pkg-ref[@id='$id.pkg' and (normalize-space(text())='#App.pkg' or normalize-space(text())='App.pkg')])" "$distribution")" 1 "$name embedded package"
    equal "$(xml_value 'string(/pkg-info/@identifier)' "$metadata")" "$id.pkg" "$name package identifier"
    equal "$(xml_value 'string(/pkg-info/@install-location)' "$metadata")" /Applications "$name install location"
    equal "$(xml_value 'string(/pkg-info/@version)' "$metadata")" "$version" "$name package version"
    equal "$(xml_value 'count(/pkg-info/scripts/*)' "$metadata")" 0 "$name install scripts"
    equal "$(xml_value 'count(/pkg-info/relocate/bundle)' "$metadata")" 0 "$name relocatable bundles"
    /usr/bin/plutil -lint "$plist" >/dev/null
    equal "$(plist_value CFBundleIdentifier "$plist")" "$id" "$name bundle identifier"
    equal "$(plist_value ShadEdition "$plist")" "$edition" "$name feature selection"
    equal "$(plist_value CFBundleName "$plist")" "$name" "$name display name"
    equal "$(plist_value CFBundlePackageType "$plist")" APPL "$name bundle type"
    equal "$(plist_value CFBundleVersion "$plist")" "$version" "$name build version"
    equal "$(plist_value CFBundleShortVersionString "$plist")" "$version" "$name version"
    equal "$(plist_value LSMinimumSystemVersion "$plist")" 13.0 "$name deployment target"
    binary="$app/Contents/MacOS/$(plist_value CFBundleExecutable "$plist")"
    [[ -x "$binary" ]] || fail "$name app executable"
    [[ -f "$app/Contents/Resources/$(plist_value CFBundleIconFile "$plist")" ]] || fail "$name app icon"
    for architecture in arm64 x86_64; do
        /usr/bin/lipo "$binary" -verify_arch "$architecture" || fail "$name $architecture executable"
        minimum=$(/usr/bin/vtool -arch "$architecture" -show-build "$binary" | awk '$1=="minos" {print $2}')
        equal "$minimum" 13.0 "$name $architecture deployment target"
    done
    dependencies=$(/usr/bin/otool -arch all -L "$binary" | awk '/compatibility version/ && $1 !~ /^\/(usr\/lib|System\/Library)\// {print $1}')
    [[ -z "$dependencies" ]] || fail "$name references an external runtime ($dependencies)"
    /usr/bin/codesign --verify --strict --all-architectures "$app" || fail "$name app signature"
    case "$edition" in
        suite|capture)
            helper="$app/Contents/Helpers/macshot.app"
            equal "$(plist_value CFBundleIdentifier "$helper/Contents/Info.plist")" com.sw33tlie.macshot.macshot "$name capture engine"
            equal "$(plist_value CFBundleShortVersionString "$helper/Contents/Info.plist")" 4.4.0 "$name capture engine version"
            requirement='anchor apple generic and identifier "com.sw33tlie.macshot.macshot" and certificate leaf[subject.OU] = "J4XGH8RFS8"'
            /usr/bin/codesign --verify --deep --strict --all-architectures -R="$requirement" "$helper" || fail "$name bundled engine signature"
            sources="$app/Contents/Resources/CaptureSources"
            [[ -s "$sources/COPYING" && -s "$sources/NOTICE.md" ]] || fail "$name capture engine licenses"
            tar -tzf "$sources/macshot-4.4.0-source.tar.gz" > "$work/archive-files"
            grep -q '/macshot/AppDelegate.swift$' "$work/archive-files" || fail "$name capture engine implementation"
            grep -q '/macshot.xcodeproj/project.pbxproj$' "$work/archive-files" || fail "$name capture engine Xcode project"
            /usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null > "$work/entitlements.plist"
            for entitlement in com.apple.security.device.camera com.apple.security.device.audio-input; do
                [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$work/entitlements.plist")" == true ]] || fail "$name $entitlement"
            done
            for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
                [[ -n "$(plist_value "$key" "$plist")" ]] || fail "$name $key"
            done
            ;;
        *)
            [[ ! -e "$app/Contents/Helpers/macshot.app" ]] || fail "unexpected capture engine in $name"
            ;;
    esac
    app_signature=$(/usr/bin/codesign -dvv "$app" 2>&1)
    if [[ "$app_signature" == *"Signature=adhoc"* ]]; then app_signing='ad hoc'
    elif [[ "$app_signature" == *"Authority=Developer ID Application:"* ]]; then app_signing='Developer ID'
    else fail "$name unrecognized signature issuer"
    fi
    if installer_signature=$(/usr/sbin/pkgutil --check-signature "$pkg" 2>&1) && [[ "$installer_signature" == *"Developer ID Installer:"* ]]; then
        pkg_signing='Developer ID'
    elif [[ "$installer_signature" == *"Status: no signature"* ]]; then
        pkg_signing='unsigned'
    else
        fail "$name installer signature ($installer_signature)"
    fi
    if [[ "${REQUIRE_DISTRIBUTION_SIGNING:-0}" == 1 ]]; then
        equal "$app_signing" 'Developer ID' "$name release app signing"
        equal "$pkg_signing" 'Developer ID' "$name release package signing"
        xcrun stapler validate "$pkg" || fail "$name notarization ticket"
    fi
    echo "$name $version | arm64 + x86_64 | app: $app_signing | pkg: $pkg_signing | checksum OK"
done
