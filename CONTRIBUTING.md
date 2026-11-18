# Contributing to Shad Tools

Start with the [feature coverage](docs/feature-coverage.md) to see which workflows exist, how they compare with the reference apps, and where device testing is still needed.

## Where to make a change

| Location | Responsibility |
| --- | --- |
| `Sources/Features/<Feature>/` | Runtime, UI and persistence owned by one tool. Its `Module.swift` declares the tool's category, command namespace, default shortcuts and lifecycle. |
| `Sources/ShadCore/` | Shared command and module contracts, shortcut representation, foreground application and exclusive feature ownership. |
| `Sources/ShadShell/` | The palette, navigation, shortcut registration, settings and menu bar. It consumes modules passed by the product. |
| `Sources/ShadColorValues/`, `Sources/ShadFilePreview/` | Color conversion and Quick Look, respectively. Only products needing these libraries link them. |
| `Sources/Products/` | Small executable entry points. A standalone registers one module. The suite explicitly registers all of them. |
| `Packaging/Editions.tsv` | The edition ID, Swift product, feature directory and app name used by SwiftPM and packaging. |
| `Tests/ShadToolsTests/` | Module-level regression tests and tests of permissions, routing, persistence, exports and edition isolation. |

For an existing feature, change its module and exercise both its standalone and the suite. A command can expose additional actions through `ToolCommand.actions`. Search uses this to supply Quick Look, Show in Finder and Copy Path. Keep existing command IDs stable since hotkeys, favorites and recent selections reference them.

When adding a tool:

1. Add a feature directory with a `FeatureModule`. Keep commands within its registered namespace and use an unassigned launcher shortcut. Create system listeners when the module starts and release them when it stops.
2. Add its edition row, a standalone entry point and the registration in the suite entry point. Give shared logic a library target when two tools need it. A feature must build without importing an unrelated feature.
3. Declare any new permissions in packaging only for the editions that need them. Update installer verification and include a regression for the new command, data format or shortcut. Preserve existing preferences and database contents when changing storage.
4. If both editions observe one system event, decide which edition owns it or how they share the result. Mouse and Windows use a per-user lock. Clipboard claims each pasteboard change once in its shared database. Audio serializes edits to its device rankings.

## Check a change

On macOS, from the repository root:

```sh
./scripts/test.sh
swift build --product ShadEject
./scripts/package.sh drives
./scripts/verify-packages.sh dist/standalone/drives drives
```

Use the edition ID from the catalog for other tools. Independent builds place their verified outputs in `dist/standalone/<edition>/`. Before releasing, run the package and verification scripts without arguments to check every edition together. Verification expands the installers, inspects both CPU architectures, matches their linked features, and checks permissions, signatures and payloads. The macOS checks workflow runs these steps for pull requests.

For behavior involving the camera, microphones, Bluetooth devices, removable media or window control, include the hardware and macOS version you exercised. Use disposable files, windows or clipboard samples in PR evidence.
