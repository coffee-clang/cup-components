# Packages

A `cup-components` package is the complete tool distribution consumed by `cup`. It combines the built tool, the runtime files it needs on its host platform, semantic metadata, an exact physical manifest and three equivalent archive representations.

For package identity and supported host/target combinations, see [Specification](SPECIFICATION.md).

## Package root

Every archive contains one top-level directory named after the package identity:

```text
<package-base>/
  info.txt
  manifest.txt
  ... tool payload ...
```

Tool payload commonly uses directories such as:

```text
bin/
include/
lib/
libexec/
share/
<target-specific directories>/
```

The exact tree depends on the tool. A package is a usable tool distribution, not a requirement to reproduce every development file installed by an upstream monorepo.

## Object model

The physical object model is platform-specific.

POSIX packages may contain:

- directories;
- regular files;
- relative internal symbolic links whose finite resolution chain stays inside the package and ends at a regular file.

Windows packages may contain:

- directories;
- regular files.

POSIX symbolic links are rejected if they are absolute, escape the package, are dangling, are cyclic or resolve to a directory. Link-target text must also satisfy the shared package path grammar.

Hardlink identity is not part of the package contract. Hardlinked source paths are normalized into independent regular files. FIFOs, sockets, device nodes and other special filesystem objects are rejected.

Before the manifest is written, directory and executable-file modes are normalized to `0755`; non-executable regular files are normalized to `0644`.

## Semantic metadata

`info.txt` uses strict `key=value` records. It describes what the package is and what capabilities it exposes; it is not the physical file inventory.

Required common fields are:

```text
package.component
package.tool
package.version
package.mode
package.formats
platform.host
platform.target
platform.host_triple
platform.target_triple
platform.family
platform.runtime
platform.thread_model
build.environment
build.source_policy
source.primary.name
source.primary.version
source.primary.url
```

`package.revision` is required for revision-bearing GCC packages and absent from revisionless packages.

At least one executable entry is described with `entry.*`. Other tool-specific metadata is grouped under:

```text
entry.*
features.*
contents.*
config.*
```

### Entries

`entry.*` maps a public command to a path relative to the package root. Examples include:

```text
entry.gcc=bin/gcc
entry.g++=bin/g++
entry.clang=bin/clang
entry.lld=bin/ld.lld
entry.gdb=bin/gdb
```

### Features

`features.*` describes capabilities that were built and detected in the staged package, for example:

```text
features.c=true
features.cpp=true
features.openmp=true
features.sanitizers=true
features.gdbserver=true
features.link_coff=true
features.background_index=true
```

### Contents and configuration

`contents.*` describes notable payload groups or runtime characteristics, while `config.*` records relevant build choices. These fields remain semantic summaries; `manifest.txt` is the exact physical inventory.

Examples include:

```text
contents.includes_lld=true
contents.includes_mingw=true
contents.libstdcxx=true
contents.runtime_dir=libexec/valgrind

config.languages=c,c++,lto
config.multilib=false
config.nls=false
config.llvm_projects=clang;lld
config.llvm_targets=X86
```

## Exact manifest

`manifest.txt` is written after the package tree and `info.txt` are final.

The current format is:

```text
format=2
d\t0755\t-\t<relative-path>
f\t0644\t<lowercase-sha256>\t<relative-path>
f\t0755\t<lowercase-sha256>\t<relative-path>
l\t-\t<lowercase-sha256-of-link-target-text>\t<relative-path>
```

Records are sorted by bytewise relative path and inventory every descendant except `manifest.txt` itself.

- `d` records a directory and its normalized mode.
- `f` records a regular file, normalized mode and SHA-256 digest.
- `l` records an admitted symbolic link and the SHA-256 digest of its exact link-target text.

The regular file reached by a symbolic link is present as its own manifest record. Package paths are constrained by the shared CUP path grammar, including collision checks. The producer regenerates and verifies the manifest before archive creation.

The manifest is the package's exact local ownership/drift baseline. It does not claim protection against a process with the same user permissions that can rewrite both payload and metadata.

## Archive formats

Every package is emitted as:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
```

All three archives represent the same logical object graph.

POSIX ZIP creation preserves admitted symbolic links rather than dereferencing them. Windows packages contain no symbolic links, so the Windows object graph is directory/regular-file only in every format.

The finalizer generates `SHA256SUMS` after all three archives exist. The file contains exactly one digest for each archive and is verified before upload or publication.

## Self-contained packages

`self-contained` describes the host-process runtime boundary.

A package includes non-base host runtime dependencies needed by its tool, while deliberately relying on the platform's base/system ABI. It does **not** mean that every operating-system library or every possible target sysroot is embedded.

The external base is:

| Host | Deliberate external base |
| --- | --- |
| Linux | glibc and loader facilities |
| macOS | Apple system libraries under `/usr/lib` and `/System/Library` |
| Windows | Windows system DLLs |

Target runtimes are a separate concern. GCC targeting Windows, for example, carries the MinGW-w64 target layout because that is compiler payload, not because Windows is the Linux host's runtime environment.

## Relocatability

Build and staging paths are temporary. A finished package must remain usable after extraction below the component root selected by `cup`.

Relocatability therefore requires both:

1. package-internal paths that do not encode the CI staging root;
2. host runtime dependencies that resolve from the relocated package or from the deliberate system/base ABI.

The exact mechanism differs by executable format.

## Runtime dependencies

Runtime closure starts from the dynamic objects inside the package, follows their host-process dependencies recursively, packages non-base dependencies and verifies the resulting graph.

### Linux

Dynamic ELF files are inspected recursively. glibc and loader facilities remain external. Other resolved shared-library dependencies are copied into package `lib/`.

Dynamic ELF objects receive package-relative `$ORIGIN` RUNPATHs. The dependency walk is then repeated and every non-base dependency must resolve inside the package.

Dependency discovery ignores ambient builder `LD_LIBRARY_PATH`, so a library available only because of the build environment cannot make an incomplete package appear valid.

Packaging uses tools such as `readelf`, `ldd`, `realpath` and `patchelf`; these are builder dependencies, not package revision inputs.

### macOS

Mach-O dependencies under `/usr/lib` and `/System/Library` remain external system dependencies. Other required dependencies are bundled into the package.

Package-owned `@rpath` dependencies and absolute non-system load paths are rewritten to deterministic package-relative `@loader_path` references. Bundled Mach-O install IDs are normalized as needed.

Mach-O files changed by install-name rewriting are ad-hoc signed before final verification. The current product deployment target is macOS 15.0 for both x64 and arm64.

### Windows

PE imports are inspected recursively. Windows system DLLs remain external. Required non-system MSYS2/MinGW runtime DLLs are copied from approved builder runtime locations and the dependency walk continues until the package is closed.

Windows packages do not use package symlinks. Python-based tools also carry their required Python runtime files where applicable.

## Python runtime

Python support in GDB and LLDB is part of those upstream tool capabilities. It is separate from repository automation.

GDB packages include the Python runtime/standard-library material required by the configured GDB build. LLDB packages similarly include the Python runtime pieces required by LLDB and configure package-relative discovery where supported by the platform.

The presence of runtime Python does not make Python a `cup-components` scripting language and does not make the Python version a package revision by itself.

## GCC packages

GCC packages include the compiler drivers, C/C++ frontend support, LTO, the target runtime layout and Binutils required by the package composition.

Native Linux GCC packages include:

- GCC C and C++ support;
- LTO;
- libstdc++;
- the OpenMP runtime required by the current recipe;
- sanitizer runtime files for native Linux targets;
- Binutils in the GCC target layout.

A native GCC target directory may use an upstream canonical triple such as `x86_64-pc-linux-gnu` even though the package target is `linux-x64`. That is an internal GCC/Binutils target name, not a second package platform.

Windows-target GCC packages include:

- Binutils for `x86_64-w64-mingw32`;
- MinGW-w64 headers and CRT;
- winpthreads;
- target-prefixed compiler and Binutils entry points;
- the target sysroot/runtime layout required to produce Windows programs.

## LLVM-family packages

The LLVM source release is shared, but the producer emits separate command-line product packages:

```text
clang
clang-format
clang-tidy
clangd
lld
lldb
```

Project selection is:

```text
clang        -> clang;lld
clang-format -> clang
clang-tidy   -> clang;clang-tools-extra
clangd       -> clang;clang-tools-extra
lld          -> lld
lldb         -> clang;lld;lldb
```

The upstream install can contain a broad LLVM development SDK. The producer removes development API headers, CMake package metadata, development static archives and embedding libraries that are not part of the selected command-line distribution. It retains the selected tools, runtime shared libraries required by them, `lib/clang` resources and tool-specific runtime payload.

Clang packages build compiler runtimes in explicit stages:

```text
compiler-rt builtins
libunwind + libc++abi + libc++
compiler-rt sanitizers/profile
```

Bundled libc++ is an available capability; it is not forced as the default C++ runtime on every host. On macOS, Clang retains the Mach-O LLD frontend needed by its declared linker/LTO capability. Windows Clang also carries its MinGW target sysroot and driver configuration.

LLDB enables Python and carries the runtime material required by that capability.

## GDB packages

GDB packages enable the supported native feature set, including Python, TUI/readline and the configured compression/XML support. Linux builds also enable the integrations provided by the controlled Linux builder; Intel PT is used for the supported Linux x64 combination.

Package metadata records the resulting features. Python execution is checked before packaging, and `gdbserver` is recorded when the built installation provides it.

## Valgrind packages

Valgrind packages are Linux-only. They retain the core Valgrind tools and use a small wrapper that derives `VALGRIND_LIB` from the relocated package root before launching the installed binary.

MPI wrapping is outside the core package and is configured off. Core `vgdb`/gdbserver functionality is retained, while the optional Python GDB front-end is not part of the package. If `valgrind.pc` is installed, its prefix is rewritten relative to `pcfiledir` rather than the build staging directory.
