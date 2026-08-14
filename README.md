# cup-components

`cup-components` builds the prebuilt C development tool packages consumed by [`cup`](https://github.com/coffee-clang/cup).

It keeps the expensive compiler, debugger and tooling builds separate from the `cup` installer. The repository builds upstream tools, packages the files they need at runtime, validates the result and can publish the finished archives.

## Tools

- GCC
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

## Packages

The repository produces relocatable packages for `cup`. Each package has a defined tool/version/host/target identity and includes the non-system runtime dependencies required by its tool while leaving the platform base ABI external. The version is selected when a build is run, so separately published versions of the same tool can coexist.

Packages are emitted as `tar.xz`, `tar.gz` and `zip` archives with metadata, an exact package manifest and archive checksums.

## Documentation

See [docs/SUMMARY.md](docs/SUMMARY.md) for the complete technical documentation.
