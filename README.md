# DeviceSupport

A macOS app that downloads and installs Xcode **device-support folders** — the
symbol files Xcode needs to symbolicate crashes and debug a device running an OS
version it doesn't yet know about — without downloading the full multi-gigabyte
firmware.

Normally Xcode generates these by pairing with a physical device on that exact
build. DeviceSupport instead fetches just the device's `dyld_shared_cache`
straight from Apple's CDN, extracts the dylibs from it, and lays out the result
under `~/Library/Developer/Xcode/<OS> DeviceSupport/` exactly as Xcode expects.

## How it works

1. **Browse** — firmware catalogs and friendly device names come from
   [AppleDB](https://appledb.dev). Pick a platform (iOS, iPadOS, tvOS, watchOS,
   visionOS), a build, and a device.
2. **Locate the cache cheaply** — firmware archives (`.ipsw` / OTA `.zip`) are
   plain (ZIP64) zips often larger than 4 GB. The app reads only the central
   directory via HTTP range requests, parses the `BuildManifest.plist` to find
   the cache-bearing disk image, and downloads only that image in parallel
   chunks.
3. **Decrypt / extract** — modern images ship as encrypted `.dmg.aea`; the
   symmetric key is unwrapped via Apple's Web Key Management Service (HPKE). The
   decrypted disk image is attached read-only with `diskutil`. OTA-only
   platforms (watchOS, tvOS) instead stream their `pbzx` payload chunks directly
   into an AppleArchive extractor, never writing the reconstructed archive to
   disk.
4. **Extract dylibs** — Xcode's bundled `dsc_extractor.bundle` turns the
   `dyld_shared_cache` (and the DriverKit cache) into the per-dylib `Symbols`
   tree.
5. **Finalize** — writes the `Info.plist`, `.finalized`, and `.processed_*`
   markers Xcode looks for, naming the folder from the firmware's own
   `SystemVersion.plist`.

The main window lists installed device supports (with on-disk sizes) and any
in-flight downloads, and lets you add new ones or delete existing ones.

## Requirements

- macOS with Xcode installed (the app uses Xcode's `dsc_extractor.bundle`, found
  via `xcode-select`).
- Runs **unsandboxed** — it shells out to `diskutil` and writes into
  `~/Library/Developer/Xcode`.
- A network connection (Apple's CDN must honor HTTP `Range` requests, which it
  does).

## Project layout

- `DeviceSupportApp.swift` — SwiftUI app entry point.
- `ContentView.swift` — the UI: installed/downloading lists, the add sheet, and
  download progress.
- `SharedCache.swift` — all the machinery: AppleDB access, remote-zip / ZIP64
  parsing, range downloads, AEA decryption, pbzx/OTA handling, disk-image
  mounting, `dsc_extractor` invocation, and the `DeviceSupport.populate`
  pipeline that ties it together.

## Acknowledgements

Firmware metadata and device names are provided by the
[AppleDB](https://appledb.dev) project.