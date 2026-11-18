# MacShot 4.4.0

Shad Tools distributes the original signed MacShot application by sw33tLie and contributors as a separate executable. The Shad launcher communicates with it through documented macOS URLs and files. MacShot, its interface and its bundled artwork retain their upstream licenses. Shad Tools' MIT license covers the Shad code.

MacShot is licensed under GNU GPL version 3. See `COPYING`. Shad Capture and the suite carry a snapshot of its build sources in `Contents/Resources/CaptureSources/macshot-4.4.0-source.tar.gz`. Extract it, open `macshot.xcodeproj` in Xcode and build the macshot scheme. The archive includes the app, project, tests, CI build scripts and dependency pins. The public upstream archive also includes the project website and promotional images. [Pinned upstream tree](https://github.com/sw33tLie/macshot/tree/6370d0d23da3f5f73bc8074624a424a7102fcfa6) · [Original release](https://github.com/sw33tLie/macshot/releases/tag/v4.4.0)

## MacShot dependencies

The upstream Xcode project records these revisions in `Package.resolved`. Xcode resolves them when building from source.

| Component | Source revision | License text |
| --- | --- | --- |
| Sparkle 2.9.0 | [21d8df8](https://github.com/sparkle-project/Sparkle/tree/21d8df80440b1ca3b65fa82e40782f1e5a9e6ba2) | `Sparkle-LICENSE`, including bundled components |
| Swift-WebP 0.5.0 | [3f58957](https://github.com/ainame/Swift-WebP/tree/3f5895711566ee862e7cff7694867c6f77adf452) | `Swift-WebP-LICENSE` |
| libwebp-Xcode 1.5.0 | [0d60654](https://github.com/SDWebImage/libwebp-Xcode/tree/0d60654eeefd5d7d2bef3835804892c40225e8b2) | Xcode packaging for libwebp |
| libwebp | [a4d7a71](https://github.com/webmproject/libwebp/tree/a4d7a715337ded4451fec90ff8ce79728e04126c) | `libwebp-COPYING` and `libwebp-PATENTS` |
