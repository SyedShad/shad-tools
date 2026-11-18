#!/bin/bash
# Inspect the distributable products without installing or launching them.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
version=${VERSION:-0.6.0}
case "$version" in ''|*[!0-9.]*) echo 'VERSION must contain digits and dots' >&2; exit 2;; esac
output=$(cd "${1:-dist}" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/shad-verify.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail() { echo "Verification failed: $*" >&2; exit 1; }
equal() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', found '$1')"; }
xml_value() { /usr/bin/xmllint --nonet --xpath "$1" "$2"; }
plist_value() { /usr/bin/plutil -extract "$1" raw -o - "$2"; }

selection=${2:-all}
names=()
editions=()
feature_names=()
feature_ids=()
packages=()
while IFS=$'\t' read -r edition product feature name; do
    if [[ "$edition" != suite ]]; then feature_names+=("$feature"); feature_ids+=("$edition"); fi
    [[ "$selection" == all || "$selection" == "$edition" ]] || continue
    names+=("$name")
    editions+=("$edition")
    packages+=("${name// /-}-$version.pkg")
done < Packaging/Editions.tsv
[[ ${#packages[@]} -gt 0 ]] || fail "unknown edition $selection"
manifest="$output/SHA256SUMS-$version.txt"
if [[ "$selection" != all ]]; then manifest="$output/SHA256SUMS-$version-$selection.txt"; fi
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
    equal "$(xml_value 'string(/installer-gui-script/options/@require-scripts)' "$distribution")" false "$name scripted distribution"
    equal "$(xml_value 'count(//script|//installation-check)' "$distribution")" 0 "$name installer JavaScript"
    [[ ! -e "$component/Scripts" ]] || fail "$name unexpected installer scripts"
    unsafe_mode=$(find "$app" \( -type f -o -type d \) \( -perm -0002 -o -perm -4000 -o -perm -2000 \) -print -quit)
    [[ -z "$unsafe_mode" ]] || fail "$name unexpected writable or privileged payload: $unsafe_mode"
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
        # Each Swift feature target has its own module in the linked symbol table. Checking each
        # Mach-O slice catches a universal binary accidentally assembled from different editions.
        /usr/bin/nm -arch "$architecture" -j "$binary" > "$work/symbols.txt"
        for f in "${!feature_names[@]}"; do
            module="Shad${feature_names[$f]}Feature"
            if [[ "$edition" == suite || "$edition" == "${feature_ids[$f]}" ]]; then
                grep -Fq "$module" "$work/symbols.txt" || fail "$name $architecture missing $module"
            elif grep -Fq "$module" "$work/symbols.txt"; then
                fail "$name $architecture contains sibling $module"
            fi
        done
    done
    dependencies=$(/usr/bin/otool -arch all -L "$binary" | awk '/compatibility version/ && $1 !~ /^\/(usr\/lib|System\/Library)\// {print $1}')
    [[ -z "$dependencies" ]] || fail "$name references an external runtime ($dependencies)"
    /usr/bin/codesign --verify --strict --all-architectures "$app" || fail "$name app signature"
    case "$edition" in
        suite|windows|mouse|clipboard)
            [[ -n "$(plist_value NSAccessibilityUsageDescription "$plist")" ]] || fail "$name Accessibility purpose";;
        *)
            if plist_value NSAccessibilityUsageDescription "$plist" >/dev/null 2>&1; then fail "$name unexpected Accessibility purpose"; fi;;
    esac
    case "$edition" in
        suite|capture)
            helper="$app/Contents/Helpers/macshot.app"
            helper_plist="$helper/Contents/Info.plist"
            equal "$(plist_value CFBundleIdentifier "$helper_plist")" io.github.syedshad.shadtools.captureengine "$name embedded capture engine"
            equal "$(plist_value CFBundleShortVersionString "$helper_plist")" 4.4.0 "$name capture engine version"
            /usr/bin/codesign --verify --deep --strict --all-architectures "$helper" || fail "$name embedded engine signature"
            # The embedded build is signed with the app. Its updater and installer services are removed.
            for code in "$app" "$helper"; do
                details=$(/usr/bin/codesign -dvv "$code" 2>&1)
                [[ "$details" == *"runtime)"* || "$details" == *"runtime,"* ]] || fail "$code hardened runtime"
                signer=$(awk -F= '$1=="TeamIdentifier" {print $2}' <<< "$details")
                [[ -n "$signer" ]] || fail "$code missing signer information"
                if [[ "$code" == "$app" ]]; then app_team=$signer
                else equal "$signer" "$app_team" "$name helper signing team"
                fi
            done
            nested=$(find "$helper/Contents" \( -name '*.xpc' -o -name '*.framework' -o -name '*.app' \) -print -quit)
            [[ -z "$nested" ]] || fail "$name unexpected nested helper component: $nested"
            equal "$(xml_value 'count(/plist/dict/key[starts-with(text(),"SU")])' "$helper_plist")" 0 "$name helper updater configuration"
            helper_binary="$helper/Contents/MacOS/$(plist_value CFBundleExecutable "$helper_plist")"
            helper_dependencies=$(/usr/bin/otool -arch all -L "$helper_binary" | awk '/compatibility version/ && $1 !~ /^\/(usr\/lib|System\/Library)\// {print $1}')
            [[ -z "$helper_dependencies" ]] || fail "$name unexpected helper dependency ($helper_dependencies)"
            for architecture in arm64 x86_64; do
                /usr/bin/lipo "$helper_binary" -verify_arch "$architecture" || fail "$name helper $architecture"
                /usr/bin/codesign -d --arch "$architecture" --entitlements - --xml "$helper" 2>/dev/null > "$work/helper-entitlements.plist"
                helper_entitlements="$work/helper-entitlements.plist"
                for key in app-sandbox network.client files.user-selected.read-write files.bookmarks.app-scope device.audio-input device.camera; do
                    equal "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.$key" "$helper_entitlements")" true "$name helper $key"
                done
                for scope in global local; do
                    key="com.apple.security.temporary-exception.mach-lookup.$scope-name"
                    equal "$(xml_value "count(/plist/dict/key[text()='$key']/following-sibling::*[1]/string)" "$helper_entitlements")" 1 "$name helper Mach services"
                    equal "$(/usr/libexec/PlistBuddy -c "Print :$key:0" "$helper_entitlements")" com.apple.axserver "$name helper accessibility service"
                done
                equal "$(xml_value 'count(/plist/dict/key)' "$helper_entitlements")" 8 "$name unexpected helper entitlement"
            done
            sources="$app/Contents/Resources/CaptureSources"
            [[ -s "$sources/COPYING" && -s "$sources/NOTICE.md" ]] || fail "$name capture engine licenses"
            tar -tzf "$sources/macshot-4.4.0-source.tar.gz" > "$work/archive-files"
            grep -q '/macshot/AppDelegate.swift$' "$work/archive-files" || fail "$name capture engine implementation"
            grep -q '/Package.swift$' "$work/archive-files" || fail "$name embedded engine build manifest"
            grep -q '/libwebp/src/dec/webp_dec.c$' "$work/archive-files" || fail "$name embedded WebP source"
            /usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null > "$work/entitlements.plist"
            equal "$(xml_value 'count(/plist/dict/key)' "$work/entitlements.plist")" 2 "$name unexpected capture host entitlement"
            for entitlement in com.apple.security.device.camera com.apple.security.device.audio-input; do
                [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$work/entitlements.plist")" == true ]] || fail "$name $entitlement"
            done
            for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
                [[ -n "$(plist_value "$key" "$plist")" ]] || fail "$name $key"
            done
            ;;
        *)
            [[ ! -e "$app/Contents/Helpers" ]] || fail "unexpected helpers in $name"
            nested=$(find "$app/Contents" \( -name '*.xpc' -o -name '*.framework' -o -name '*.app' \) -print -quit)
            [[ -z "$nested" ]] || fail "$name unexpected nested component: $nested"
            [[ ! -e "$app/Contents/Resources/CaptureSources" ]] || fail "unexpected capture sources in $name"
            for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSCameraUseContinuityCameraDeviceType; do
                if plist_value "$key" "$plist" >/dev/null 2>&1; then fail "$name unexpected $key"; fi
            done
            /usr/bin/codesign -d --entitlements - --xml "$app" 2>/dev/null > "$work/entitlements.plist"
            if [[ -s "$work/entitlements.plist" ]]; then
                equal "$(xml_value 'count(/plist/dict/key)' "$work/entitlements.plist")" 0 "$name unexpected entitlements"
            fi
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
if [[ "$selection" == all ]]; then
    suite_helper="$work/suite/App.pkg/Payload/Shad Tools.app/Contents/Helpers/macshot.app"
    capture_helper="$work/capture/App.pkg/Payload/Shad Capture.app/Contents/Helpers/macshot.app"
    /usr/bin/diff -qr "$suite_helper" "$capture_helper" >/dev/null || fail 'suite and standalone capture helpers differ'
    echo "Suite and Capture contain the identical signed helper"
fi
