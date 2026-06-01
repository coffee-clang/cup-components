# cup-components

`cup-components` builds the prebuilt C development tool packages installed by `cup`.

This repository does not implement the `cup` command-line installer. Its job is to build, test and publish self-contained component archives with a stable package layout and an `info.txt` metadata file that `cup` can validate during installation.

## Built tools

The current build workflows cover:

```text
gcc
clang
gdb
lld
lldb
clangd
clang-format
clang-tidy
valgrind
```

These tools map to the component names used by `cup`:

```text
compiler/gcc
compiler/clang
debugger/gdb
debugger/lldb
linker/lld
formatter/clang-format
linter/clang-tidy
language-server/clangd
analyzer/valgrind
```

## Build model

Builds are started manually through GitHub Actions workflows. Each workflow accepts a version, host platform, target platform, package revision and a `publish` flag.

The build scripts download upstream source releases, build the selected tool, stage the install tree, write package metadata, create archives and run package capability tests.

The produced archives are named like:

```text
<tool>-<version>[-revN]-<host_platform>-<target_platform>.tar.xz
<tool>-<version>[-revN]-<host_platform>-<target_platform>.tar.gz
<tool>-<version>[-revN]-<host_platform>-<target_platform>.zip
```

Release tags use the same base name without the archive extension:

```text
<tool>-<version>[-revN]-<host_platform>-<target_platform>
```

## Supported platform families

The scripts use these platform identifiers:

```text
linux-x64
linux-arm64
macos-x64
macos-arm64
windows-x64
```

The main combinations are:

```text
GCC:
  linux-x64   -> linux-x64
  linux-arm64 -> linux-arm64
  linux-x64   -> windows-x64
  windows-x64 -> windows-x64

GDB:
  linux-x64   -> linux-x64
  linux-arm64 -> linux-arm64
  windows-x64 -> windows-x64

LLVM tools:
  linux-x64   -> linux-x64
  linux-arm64 -> linux-arm64
  macos-x64   -> macos-x64
  macos-arm64 -> macos-arm64
  windows-x64 -> windows-x64

Valgrind:
  linux-x64   -> linux-x64
  linux-arm64 -> linux-arm64
```

LLVM tool packages are native host-target packages. GCC also supports the Linux-to-Windows target package because the package includes the MinGW-w64 target runtime and sysroot.

## Output contract

Every package root contains:

```text
info.txt
```

The metadata records package identity, host/target platforms, entry points, contents, feature flags and build configuration.

A package is expected to be self-contained for the selected host and target. Windows packages include the non-system runtime DLLs needed by packaged executables. GCC Windows packages include the MinGW-w64 target layout. Clang packages include the LLVM runtime files required by the selected tool package.

## Documentation

The full documentation is split into:

- [Specification](docs/specification.md): build model, package identity, supported tools, packaging contract, metadata and workflow behavior.
- [Dependencies](docs/dependencies.md): Docker images, MSYS2 environments, Homebrew setup, upstream sources and per-tool build dependencies.

The installer and runtime state model are documented in the separate [cup](https://github.com/coffee-clang/cup) repository.
