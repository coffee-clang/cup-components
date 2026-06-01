# cup-components

`cup-components` is the build and packaging repository for the component archives consumed by `cup`.

The repository builds selected C development tools from upstream source releases, packages them into self-contained archives, writes `info.txt` metadata and publishes the resulting files as GitHub Release assets.

It is separate from the `cup` command-line installer. `cup-components` produces packages; `cup` downloads and installs them according to the manifest.

## Built tools

Current tool packages are:

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

They correspond to the `cup` component/tool pairs:

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

## Repository responsibilities

This repository is responsible for:

```text
selecting supported host/target combinations
downloading upstream source releases
building tools in controlled CI environments
staging package roots
copying required runtime files
writing info.txt metadata
creating tar.xz, tar.gz and zip archives
running package capability tests
publishing release assets when requested
```

It is not responsible for:

```text
installing packages on end-user machines
managing ~/.cup state
resolving cup commands
editing user PATH
uninstalling cup
```

Those behaviors belong to the `cup` repository.

## Package output

Build outputs are written to:

```text
dist/
```

A typical package base name is:

```text
<tool>-<version>[-revN]-<host_platform>-<target_platform>
```

Example:

```text
gcc-16.1.0-rev1-linux-x64-windows-x64
clang-22.1.5-macos-arm64-macos-arm64
```

For each package, the scripts create:

```text
.tar.xz
.tar.gz
.zip
release.env
```

When publishing is enabled, the archives are uploaded to a GitHub Release whose tag matches the package base name.

## Build workflows

The repository currently has workflows for:

```text
Build GCC
Build GDB
Build LLVM
Build Valgrind
```

Linux builds run inside Docker containers. Windows builds run inside MSYS2 environments. macOS LLVM builds run on GitHub-hosted macOS runners using Homebrew dependencies.

## Documentation sections

- [Specification](specification.md) describes the package contract, supported tools, platform matrix, build flow and metadata model.
- [Dependencies](dependencies.md) describes the Linux Docker images, Windows MSYS2 packages, macOS Homebrew setup, upstream source archives and test dependencies.
