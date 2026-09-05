# cup-components

`cup-components` builds the prebuilt C development tools installed by `cup`.

The repository keeps the large upstream builds separate from the `cup` installer. For each supported tool and platform, it downloads the selected upstream source release, builds the tool, keeps the files required by the final distribution, closes the required host runtime dependencies, writes package metadata, validates the completed package and produces archives that `cup` can install.

## Tools

- GCC
- GNU ld
- GDB
- Clang
- clang-format
- clang-tidy
- clangd
- LLD
- LLDB
- Valgrind

## Platforms

- Linux x64
- Linux arm64
- Windows x64
- macOS x64
- macOS arm64

Not every tool is available on every platform. GCC and GNU ld also support the deliberate Linux x64 to Windows x64 cross-target configuration. The complete matrix is documented in [Specification](docs/SPECIFICATION.md#supported-combinations).

## What a build produces

A completed package contains the selected tool, its required package-owned runtime files, `info.txt` semantic metadata and an exact `manifest.txt` inventory. The same package tree is emitted as `tar.xz`, `tar.gz` and `zip`, with archive checksums in `SHA256SUMS`.

A build can use the configured `stable` version or an explicit numeric version. The current stable versions are defaults, not a closed version list.

## Documentation

Start with [docs/INDEX.md](docs/INDEX.md). It explains the repository model and links each technical document by responsibility.
