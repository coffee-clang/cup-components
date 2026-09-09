# Documentation

This directory documents the current `cup-components` repository as a standalone producer of tool packages for `cup`.

A reader does not need prior knowledge of the repository. The documents first explain the product model in plain terms and then introduce the implementation details needed to understand builds, package contents and validation.

## Repository model

The complete path from a requested tool to a distributable package is:

```text
select tool, version and platform
        ↓
obtain the upstream source release
        ↓
configure and build the selected tool
        ↓
install into a temporary staging tree
        ↓
keep the files that belong to the package
        ↓
add required non-system host runtime dependencies
        ↓
write tool metadata and finish the selected package payload
        ↓
normalize the package tree and validate info.txt
        ↓
generate manifest.txt
        ↓
create and semantically verify tar.xz, tar.gz and zip archives
        ↓
write SHA256SUMS
        ↓
run the tool-specific product test and verify archive checksums
        ↓
optionally publish the finished archives
```

The main design rule is that a build tree is not automatically a package. Upstream projects can install development headers, static libraries, helper files and other material that is useful while building but is not part of the distributed command-line tool. Each tool builder therefore defines the package-selection roots that belong to its product, while common package code handles the shared archive, manifest and runtime-closure rules.

## Terms used throughout the documentation

**Tool.** The program distributed by one package, such as GCC, GDB, Clang or Valgrind.

**Upstream source release.** The official versioned source archive published by the project that develops the tool.

**Sysroot.** A directory tree containing the headers and libraries for a compiler's target platform. A cross compiler can run on one host while using a sysroot for a different target.

**LTO.** Link-time optimization: compiler optimization that continues across object files during the link step.

**CRT.** C runtime: the low-level runtime files and startup objects needed by C programs on a target platform.

**Host platform.** The platform on which the packaged tool itself runs.

**Target platform.** The platform for which a compiler or linker produces code. Most packages are native, so host and target are the same.

**Staging tree.** The temporary installation produced by the upstream build before the final package is selected and normalized.

**Package root.** The final directory tree that becomes the content of the archives installed by `cup`.

**Package-selection roots.** The public commands, runtime data, target files and required helpers deliberately chosen by a tool builder as the starting content of a package before runtime closure. They are not the same as the final package root directory.

**Package contract.** The common rules a completed package must satisfy so that `cup` can identify, validate and install it consistently.

**Self-contained.** All required non-system host runtime files are either included in the package or deliberately provided by the operating system.

**Relocatable.** The package continues to work after `cup` extracts it to a different directory; it must not depend on the temporary build location.

**Runtime closure.** The process that starts from the selected package content, follows its runtime dependencies and adds required non-system dependencies until the package is complete.

**Package revision.** A composition number used when the same main tool version can be packaged with different independently versioned logical components. GCC currently uses this mechanism; the revision identifies a chosen composition but does not select its component versions.

**Executable format.** The operating-system format used to store executable programs and shared libraries. Linux uses ELF, Windows uses PE, and macOS uses Mach-O.

**Shared library / DLL.** Code loaded by a program at runtime instead of being copied permanently into the executable at link time. Windows normally calls these files DLLs.

**ELF.** The executable and shared-library format used by Linux.

**PE.** Portable Executable, the executable and DLL format used by Windows.

**Mach-O.** The executable and dynamic-library format used by macOS.

**Runtime search path.** Information stored in an executable or library that helps the operating system find its runtime libraries. Linux commonly uses RPATH/RUNPATH-style entries; macOS uses load paths such as `@rpath` and `@loader_path`.

**MinGW-w64.** The headers, runtime and GNU-style toolchain support used here to build Windows x64 programs.

**MSYS2.** The Windows build environment used by the workflows to install GCC/MinGW or Clang-based build tools and their dependencies.

**Configure / CMake / Ninja.** Build-system tools used by upstream projects. GNU projects commonly use a `configure` script followed by `make`; LLVM uses CMake to generate a Ninja build.

## Documents

- [Specification](SPECIFICATION.md) — product scope, supported tools and platforms, version selection, package identity and revision rules.
- [Packages](PACKAGES.md) — common package format, `info.txt`, `manifest.txt`, archive representation, relocatability and runtime closure.
- [Tool packages](TOOLS.md) — what belongs to the GCC, GNU ld, GDB, LLVM-family and Valgrind packages.
- [Build](BUILD.md) — workflows, direct builder commands, source acquisition, build environments, package finalization, outputs and publication.
- [Dependencies](DEPENDENCIES.md) — dependency categories, Docker/MSYS2/Homebrew build environments and upstream source inputs.
- [Testing](TESTING.md) — common package validation, tool-specific package checks and repository regression checks.
- [Build records](BUILD_RECORDS.md) — information saved for every workflow run so a success or failure can be inspected without changing package contents.

For a first reading, use this order:

```text
Specification
→ Packages
→ Tool packages
→ Build
→ Dependencies
→ Testing
→ Build records
```
