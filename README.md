# SynologyPhotosManager

A native **macOS** app for *managing* (not backing up) a
[Synology Photos](https://www.synology.com/en-global/dsm/feature/photos) library —
a fast, keyboard-friendly desktop client focused on browsing, organizing, and
cleaning up your photos.

> ⚠️ **Not affiliated with, authorized, or endorsed by Synology Inc.**
> "Synology" and "Synology Photos" are trademarks of Synology Inc. This is an
> unofficial, personal project built against the DSM Photos web APIs
> (reverse-engineered from the official web client). Use at your own risk.

## Features

- **Justified timeline** — photos shown at their real aspect ratio, rows filled
  edge-to-edge (Google Photos / Apple "Aspect Ratio Grid" style), with year/month/
  day density and a right-edge year scrubber.
- **Similar-photo stacks** — bursts and near-duplicates fold into one cover with a
  count badge (Synology's stacking); click to expand the group.
- **People** — recognized-face clusters with tight face-crop covers; rename, merge
  same-named people, set a cover photo.
- **Albums / Folders / Recently added**, **Favorites** ❤️ and **star ratings** ⭐,
  full-text **search** and Synology-style **filters** (type, date, people, place,
  camera/lens/ISO/aperture).
- **Duplicate / similar cleanup** with a recommended keeper per group.
- **Video** playback via progressive byte-range streaming over the pinned session.
- **Mac-native**: multi-select, right-click menus, standard menu bar + shortcuts,
  **drag a photo out to Finder** to export the original, a floating info panel that
  appears on selection, a disk thumbnail cache, and LAN NAS auto-discovery.
- **System-Settings-styled** preferences (connection management, default view,
  cache).

## Architecture

- **App** (`App/`) — SwiftUI (macOS 14+), Observation (`@Observable`), no external
  UI dependencies.
- **FotoKit** (`FotoKit/`, local SPM package) — Synology Photos models + the
  `SYNO.Foto.*` service layer.
- **SynoKit** — shared transport/security core (TLS pinning, credential store,
  session handling). ⚠️ **Not included in this repo** — it's a sibling Swift
  package expected at `../SynoKit`. Without it the project will not build as-is.
- Headless verification: dependency-free `*Checks` executables
  (`swift run FotoKitChecks`) with stubbed responses; no live NAS needed.

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonyz/XcodeGen).

```sh
xcodegen generate          # regenerate SynologyPhotosManager.xcodeproj from project.yml
open SynologyPhotosManager.xcodeproj
```

Credentials are stored locally, encrypted (AES-GCM), under
`~/Library/Application Support/SynologyPhotosManager/` — never in the Keychain and
never committed.

## Credits

App-icon glyph derived from Material Design Icons (Apache-2.0) — see
[`CREDITS.md`](CREDITS.md). API structure cross-checked against the community
[`synology-api`](https://github.com/N4S4/synology-api) Python library.

## License

[MIT](LICENSE).
