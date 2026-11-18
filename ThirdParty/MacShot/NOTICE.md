# Shad Capture Engine

Shad Capture Engine is a modified build of MacShot 4.4.0 by sw33tLie and contributors. Shad Tools distributes this GPLv3 application as a separate executable. MacShot, its interface and its artwork retain their upstream licenses. The Shad launcher has its own MIT license. [Upstream source revision](https://github.com/sw33tLie/macshot/tree/6370d0d23da3f5f73bc8074624a424a7102fcfa6) · [Original release](https://github.com/sw33tLie/macshot/releases/tag/v4.4.0)

The Shad modifications from November 19, 2026 remove the independent Sparkle updater, update settings and the standalone application's move-to-Applications prompt. The engine uses its own bundle identifier, sandbox container and `shadcapture://` scheme. Its editor, recorder, Studio and optional upload providers come from the full upstream source. [Source changes](embedded.patch) · [Build manifest](EmbeddedPackage.swift) · [Sandbox entitlements](embedded.entitlements)

## Corresponding source

Both capture-enabled installers contain `Contents/Resources/CaptureSources/macshot-4.4.0-source.tar.gz`, the GPL text, the source patch and the build instructions. The archive contains the exact patched Swift sources, dependencies, Xcode project, app resources and original build scripts. To compile the embedded executable with Swift 6.2 or newer, extract the archive, enter its top-level directory and run `swift build --build-system native -c release --product macshot`. The Shad packager builds for Apple silicon and Intel, adds the compiled artwork and translated resources from the verified upstream disk image, and signs the resulting application. [Complete packaging script](../../scripts/prepare-capture-engine.sh)

| Embedded component | Source revision | License |
| --- | --- | --- |
| Swift-WebP 0.5.0 | [3f58957](https://github.com/ainame/Swift-WebP/tree/3f5895711566ee862e7cff7694867c6f77adf452) | `Swift-WebP-LICENSE` |
| libwebp-Xcode 1.5.0 | [0d60654](https://github.com/SDWebImage/libwebp-Xcode/tree/0d60654eeefd5d7d2bef3835804892c40225e8b2) | Packaging and public headers for libwebp |
| libwebp | [a4d7a71](https://github.com/webmproject/libwebp/tree/a4d7a715337ded4451fec90ff8ce79728e04126c) | `libwebp-COPYING` and `libwebp-PATENTS` |
