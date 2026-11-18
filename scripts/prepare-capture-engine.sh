#!/bin/bash
# Build the sandboxed capture engine from verified sources without an independent updater.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=${1:?usage: prepare-capture-engine.sh /absolute/path/to/empty-staging-directory}
case "$stage" in /*) ;; *) echo 'Use an absolute staging path.' >&2; exit 2;; esac
version=4.4.0
revision=6370d0d23da3f5f73bc8074624a424a7102fcfa6
cache=${SHAD_CAPTURE_CACHE:-"$PWD/.build/capture-deps/assets"}
mkdir -p "$cache" "$stage/Helpers" "$stage/Resources"
if [[ -e "$stage/Helpers/macshot.app" || -e "$stage/Resources/CaptureSources" ]]; then
    echo 'Capture files already exist in the staging directory.' >&2
    exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/shad-capture.XXXXXX")
mounted=0
finish() {
    if [[ "$mounted" == 1 ]]; then hdiutil detach -quiet "$work/disk" || return; fi
    rm -rf "$work"
}
trap finish EXIT
get_asset() {
    local filename=$1 url=$2 digest=$3
    if [[ ! -f "$cache/$filename" ]]; then
        curl --proto '=https' --fail --show-error --silent --location --retry 2 --max-time 360 \
            "$url" -o "$work/$filename"
        printf '%s  %s\n' "$digest" "$work/$filename" | shasum -a 256 -c - >/dev/null
        cp "$work/$filename" "$cache/$filename.$$.tmp"
        mv "$cache/$filename.$$.tmp" "$cache/$filename"
    fi
    printf '%s  %s\n' "$digest" "$cache/$filename" | shasum -a 256 -c - >/dev/null
}
get_asset "MacShot-$version.dmg" "https://github.com/sw33tLie/macshot/releases/download/v$version/MacShot.dmg" \
    05262f41598031db256d27e6efb3052692b77bc78670b8554f286258cb917835
get_asset "macshot-$version-source.tar.gz" "https://codeload.github.com/sw33tLie/macshot/tar.gz/$revision" \
    e0e73d247ee3b2ab8e37f0db89ecd2d91745097edaa5d83a2ccd0a026f0dfe48

get_asset "Swift-WebP-3f58957.tar.gz" "https://codeload.github.com/ainame/Swift-WebP/tar.gz/3f5895711566ee862e7cff7694867c6f77adf452" \
    4eaa1f25cf79785a65c9e7fb6a4f8734fa22a1f011f5a88cb8f78e97e1c8fa5b
get_asset "libwebp-Xcode-0d60654.tar.gz" "https://codeload.github.com/SDWebImage/libwebp-Xcode/tar.gz/0d60654eeefd5d7d2bef3835804892c40225e8b2" \
    5508d2789a2ff10b9786c8d3167ee7961503dd4e5a4f9468aebd51117289e306
get_asset "libwebp-a4d7a71.tar.gz" "https://codeload.github.com/webmproject/libwebp/tar.gz/a4d7a715337ded4451fec90ff8ce79728e04126c" \
    e3a6189054f81e06a5fbadb0d5c5a4678018c6df6d37e17bd99a86f66c650a97

mkdir -p "$work/disk" "$work/CaptureSources" "$work/source"
hdiutil attach -readonly -nobrowse -noautoopen -quiet -mountpoint "$work/disk" "$cache/MacShot-$version.dmg"
mounted=1
upstream="$work/disk/macshot.app"
requirement='anchor apple generic and identifier "com.sw33tlie.macshot.macshot" and certificate leaf[subject.OU] = "J4XGH8RFS8"'
codesign --verify --strict --deep --all-architectures -R="$requirement" "$upstream"
test "$(plutil -extract CFBundleShortVersionString raw "$upstream/Contents/Info.plist")" = "$version"
# Reuse the signed release's asset catalog, localizations and storyboard. The
# Mach-O binary, updater, installer services and upstream signature are excluded.
app="$work/macshot.app"
mkdir -p "$app/Contents/MacOS"
ditto "$upstream/Contents/Resources" "$app/Contents/Resources"
cp "$upstream/Contents/Info.plist" "$app/Contents/Info.plist"
hdiutil detach -quiet "$work/disk"
mounted=0
plist="$app/Contents/Info.plist"
for key in SUFeedURL SUPublicEDKey SUScheduledCheckInterval SUEnableAutomaticChecks SUEnableInstallerLauncherService; do
    plutil -remove "$key" "$plist"
done
plutil -replace CFBundleIdentifier -string io.github.syedshad.shadtools.captureengine "$plist"
plutil -replace CFBundleDisplayName -string "Shad Capture Engine" "$plist"
plutil -replace LSMinimumSystemVersion -string 13.0 "$plist"
plutil -replace CFBundleURLTypes.1.CFBundleURLSchemes.0 -string shadcapture "$plist"

prefix="macshot-$revision"
source="$work/source/$prefix"
tar -xzf "$cache/macshot-$version-source.tar.gz" -C "$work/source" \
    --exclude="$prefix/website" --exclude="$prefix/assets"
tar -xzf "$cache/macshot-$version-source.tar.gz" -C "$work/source" "$prefix/assets/dmg-background.png"
mkdir -p "$source/swift-webp" "$source/libwebp-xcode/libwebp"
tar -xzf "$cache/Swift-WebP-3f58957.tar.gz" --strip-components 1 -C "$source/swift-webp"
tar -xzf "$cache/libwebp-Xcode-0d60654.tar.gz" --strip-components 1 -C "$source/libwebp-xcode"
tar -xzf "$cache/libwebp-a4d7a71.tar.gz" --strip-components 1 -C "$source/libwebp-xcode/libwebp"
cp ThirdParty/MacShot/EmbeddedPackage.swift "$source/Package.swift"
cp ThirdParty/MacShot/embedded.entitlements "$source/macshot/macshot.entitlements"
patch --batch -d "$source" -p1 < ThirdParty/MacShot/embedded.patch
cp "$0" "$work/CaptureSources/prepare-capture-engine.sh"
ditto ThirdParty/MacShot "$work/CaptureSources"
COPYFILE_DISABLE=1 tar -czf "$work/CaptureSources/macshot-$version-source.tar.gz" -C "$work/source" "$prefix"

for arch in arm64 x86_64; do
    options=(--package-path "$source" --scratch-path "$work/build" --build-system native -c release --triple "$arch-apple-macosx13.0")
    swift build "${options[@]}" --product macshot > "$work/build-$arch.log" 2>&1 || {
        tail -100 "$work/build-$arch.log" >&2
        exit 1
    }
    bindir=$(swift build "${options[@]}" --show-bin-path)
    cp "$bindir/macshot" "$work/$arch"
done
lipo -create "$work/arm64" "$work/x86_64" -output "$app/Contents/MacOS/macshot"
sign=(--force --options runtime --entitlements ThirdParty/MacShot/embedded.entitlements --sign "${APP_SIGN_IDENTITY:--}")
if [[ -n "${APP_SIGN_IDENTITY:-}" ]]; then sign+=(--timestamp); fi
codesign "${sign[@]}" "$app"
codesign --verify --strict --deep --all-architectures "$app"
mv "$app" "$stage/Helpers/macshot.app"
mv "$work/CaptureSources" "$stage/Resources/CaptureSources"
