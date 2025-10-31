# macSandbox

> Status: Experimental — This project is under active exploration for macOS Tablecloth sandbox compatibility. Interfaces, behaviors, and artifacts may change without notice. Not production‑ready.

macSandbox is an experimental macOS–targeted, Windows Sandbox–compatible implementation intended to support the macOS edition of the Tablecloth project. In short: it provides building blocks and a compatibility layer on macOS so Tablecloth can offer Windows Sandbox–like workflows on Apple platforms.

## What this repo provides

- A Swift Package that discovers and downloads macOS IPSW/restore images suitable for virtualization on Apple Silicon and Intel Macs.
- A CLI tool (`macosdownloader`) to list and fetch compatible restore images with progress reporting.
- A pure C dynamic library (`libMacOSDownloaderLib.dylib`) with a stable C ABI plus a public header (`macosdownloader.h`) for easy interop from C/C++ and .NET (P/Invoke).
- A small .NET sample (`MacOSDownloaderTest`) showing how to call the library from managed code.
- Shell scripts to build, sign (with entitlements), and package the CLI and the dynamic library.

Ultimately, this enables Tablecloth’s macOS version to acquire official macOS recovery images and prepare VM assets in a way analogous to Windows Sandbox scenarios.

## Why this exists

Tablecloth aims to deliver a consistent “sandboxed” app execution experience. On Windows this leans on Windows Sandbox; on macOS we rely on Apple Virtualization and official restore images. This repository focuses on the macOS side: discovering, validating, and downloading the correct IPSW/restore image and exposing it through a portable API that other Tablecloth components can consume.

## Repository layout

- `src/ipswDownloaderPrototype/`
  - `Package.swift` — Swift Package manifest for the CLI and library.
  - `Sources/CLI/` — `macosdownloader` command (Swift ArgumentParser based).
  - `Sources/Core/` — shared core (system info, fetchers, utilities).
  - `Sources/CLib/` — C-ABI dynamic library target and `include/macosdownloader.h`.
  - `build.sh` — builds and signs the CLI with entitlements.
  - `build-dylib.sh` — builds and signs the dynamic library; produces `dist/`.
  - `VIRTUALIZATION_SETUP.md` — notes about entitlements and Virtualization framework.
  - `DYLIB_README.md` — additional notes for the C dynamic library usage.
  - `MacOSDownloaderTest/` — .NET P/Invoke sample.

## Requirements

- macOS 13.0 or later
- Swift 5.9 or later (Xcode 15+ recommended)
- Apple Virtualization framework entitlements when fetching official restore images

Note: Some Virtualization APIs require codesigning with appropriate entitlements. Ad‑hoc signing is sufficient for local development; see “Entitlements” below.

## Quick start

### 1) Build and run the CLI (Swift)

```bash
cd src/ipswDownloaderPrototype
./build.sh

# Examples
.build/release/macosdownloader --help
.build/release/macosdownloader --list
.build/release/macosdownloader --list --verbose
.build/release/macosdownloader -o ~/Downloads
```

The build script compiles with SwiftPM and applies the entitlements required to access Virtualization APIs.

### 2) Build the C dynamic library

```bash
cd src/ipswDownloaderPrototype
./build-dylib.sh

# Outputs
# dist/libMacOSDownloaderLib.dylib
# dist/include/macosdownloader.h
```

You can link against the dylib from C/C++ or import it via P/Invoke in .NET. The library exports a stable C ABI (no Swift name mangling).

### 3) Run the .NET interop sample (optional)

```bash
cd src/ipswDownloaderPrototype/MacOSDownloaderTest
dotnet run
```

If you need Virtualization access from the managed host, sign the produced executable with the same entitlements used by the Swift artifacts.

## Entitlements and Virtualization

To pull official macOS restore images using Apple’s Virtualization framework, the executable must be signed with at least:

- `com.apple.security.virtualization`
- `com.apple.security.network.client`
- `com.apple.security.app-sandbox`
- (and, for file access in the CLI) `com.apple.security.files.user-selected.read-write`

This repository includes `macosdownloader.entitlements` and scripts that apply it. See `src/ipswDownloaderPrototype/VIRTUALIZATION_SETUP.md` for details, alternatives (Xcode project), and troubleshooting.

When these entitlements are not available, the downloader will gracefully fall back to sample data so you can still exercise the CLI and API flows.

## C API surface (for embedding)

Provided by `libMacOSDownloaderLib.dylib` and declared in `dist/include/macosdownloader.h`:

- `int32_t macosdownloader_get_latest_image(char** outVersion, char** outBuild, char** outURL, int64_t* outSize)`
- `int32_t macosdownloader_get_system_info(char** outModel, char** outArch, char** outBoard)`
- `int32_t macosdownloader_download(const char* url, const char* outputPath)`
- `char* macosdownloader_get_version(void)`
- `void macosdownloader_free_string(char* str)`

Return codes are `0` for success, negative values for error conditions. Returned strings are heap‑allocated; callers must free them using `macosdownloader_free_string`.

## Limitations and roadmap

- Virtualization-backed image discovery requires entitlements and proper codesigning.
- The CLI provides a guided, interactive workflow; non‑interactive flags will be expanded.
- Additional host integrations (e.g., VM creation, image caching policy) are planned as the Tablecloth macOS work progresses.

## License

This project is licensed under the Apache License. See `LICENSE` for details.

## Acknowledgements

- Uses Apple’s Virtualization framework and official software catalogs when entitlements are present.
- Built with Swift ArgumentParser for the CLI.
