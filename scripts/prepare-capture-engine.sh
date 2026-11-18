#!/bin/bash
# Stage the signed capture application and the source corresponding to its release.
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

mkdir -p "$work/disk" "$work/CaptureSources" "$work/source"
hdiutil attach -readonly -nobrowse -noautoopen -quiet -mountpoint "$work/disk" "$cache/MacShot-$version.dmg"
mounted=1
ditto "$work/disk/macshot.app" "$work/macshot.app"
hdiutil detach -quiet "$work/disk"
mounted=0
requirement='anchor apple generic and identifier "com.sw33tlie.macshot.macshot" and certificate leaf[subject.OU] = "J4XGH8RFS8"'
codesign --verify --strict --deep --all-architectures -R="$requirement" "$work/macshot.app"
binary="$work/macshot.app/Contents/MacOS/macshot"
lipo -verify_arch arm64 "$binary"
lipo -verify_arch x86_64 "$binary"
test "$(plutil -extract CFBundleShortVersionString raw "$work/macshot.app/Contents/Info.plist")" = "$version"

# Keep all app sources, tests, project metadata and packaging scripts. The website and
# promotional screenshots are independent of the application build.
prefix="macshot-$revision"
tar -xzf "$cache/macshot-$version-source.tar.gz" -C "$work/source" \
    --exclude="$prefix/website" --exclude="$prefix/assets"
tar -xzf "$cache/macshot-$version-source.tar.gz" -C "$work/source" "$prefix/assets/dmg-background.png"
COPYFILE_DISABLE=1 tar -czf "$work/CaptureSources/macshot-$version-source.tar.gz" -C "$work/source" "$prefix"
ditto ThirdParty/MacShot "$work/CaptureSources"
mv "$work/macshot.app" "$stage/Helpers/macshot.app"
mv "$work/CaptureSources" "$stage/Resources/CaptureSources"
