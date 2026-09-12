# Packages

A `cup-components` package is the complete directory tree that `cup` downloads and installs for one tool identity.

This document describes the rules shared by every package. The files and capabilities specific to GCC, GNU ld, GDB, the LLVM-family tools and Valgrind are documented in [Tool packages](TOOLS.md).

## Package root

Every archive contains one top-level directory named after the package identity:

```text
<package-base>/
  info.txt
  manifest.txt
  ... tool payload ...
```

Typical payload directories include:

```text
bin/
include/
lib/
libexec/
share/
<target-specific directories>/
```

Not every package uses every directory.

The final package is selected from the upstream installation according to the responsibilities of the requested tool. Files are not included merely because an upstream `make install` or CMake install step produced them.

## What can be included

A file or directory belongs in the final package when it has a concrete package responsibility, for example:

- a public executable;
- a helper required by a public executable;
- a required non-system runtime library;
- runtime data used by the tool;
- a target sysroot or target runtime that is part of the toolchain;
- public headers deliberately distributed by the tool package;
- package metadata.

Build-only material is removed when it is not required by the distributed tool. Examples can include development CMake files, static development archives, internal headers and build-tree metadata.

## Filesystem object model

The admitted filesystem objects depend on the host platform.

POSIX packages can contain:

- directories;
- regular files;
- relative symbolic links that stay inside the package and eventually resolve to a regular file.

Windows packages contain:

- directories;
- regular files.

A POSIX symbolic link is rejected if it:

- is absolute;
- escapes the package root;
- is dangling;
- forms a cycle;
- resolves to a directory;
- uses a path that violates the shared package path grammar.

Hardlink inode sharing is not part of package identity. Two package paths can contain the same bytes regardless of whether the temporary staging tree happened to store them in one inode. If a pathname needs a different runtime rewrite, the packager can materialize that pathname as an independent regular file before changing it.

FIFOs, sockets, device nodes and other special filesystem objects are rejected.

Before archive creation:

- directories use mode `0755`;
- executable regular files use mode `0755`;
- non-executable regular files use mode `0644`.

For Windows package archives, PE command/loadable files (`.exe`, `.com`, `.dll`,
`.pyd`), command scripts (`.bat`, `.cmd`) and files beginning with a shebang use
the `0755` archive mode class. Other regular files use `0644`. The shebang rule
matches the executable-file semantics exposed by MSYS2 even when native Windows
permissions do not carry a POSIX execute bit. These are archive/manifest modes;
Windows does not use the POSIX execute bit as its native execution permission model.

## Package paths

Every path stored inside a package is relative to the package root and must satisfy one cross-platform grammar. This prevents an archive produced on one operating system from containing names that are unsafe or ambiguous on another.

A package path:

- cannot be absolute;
- cannot end with `/`;
- cannot contain empty, `.` or `..` path segments;
- cannot contain newlines, backslashes, colons or Windows-reserved punctuation such as `*`, `?`, `"`, `<`, `>` or `|`;
- cannot use a segment ending in `.`;
- cannot use Windows reserved device names such as `CON`, `PRN`, `AUX`, `NUL`, `COM1` or `LPT1`;
- uses printable ASCII package-name characters without whitespace inside each segment;
- must be shorter than the shared CUP package-path limit of 1024 bytes.

The final package also rejects case-insensitive path collisions. For example, `bin/Tool` and `bin/tool` cannot both exist even if the current build filesystem would allow them.

The directory in which `cup` installs the package is not subject to this internal-path rule. The package root itself can therefore be relocated below a parent path that contains spaces; only the relative paths stored inside the package follow the package grammar.

## `info.txt`

`info.txt` contains semantic package metadata as strict `key=value` records.

It answers questions such as:

- Which tool is this?
- Which version is it?
- On which platform does it run?
- Which platform does it target?
- Which public commands exist?
- Which capabilities were included?
- Which source archive was built?

Each metadata line contains exactly one non-empty value in the form:

```text
key=value
```

Keys can contain letters, digits, `_`, `.`, `+` and `-`. Empty values and duplicate keys are rejected.

The common required fields are:

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
source.primary.sha256
```

GCC also carries `package.revision` because GCC is revision-bearing. Revisionless packages do not write that key.

A GCC package must also record the composition identified by that revision. Native GCC packages require `bundle.components=binutils` plus `bundle.binutils.version`, `bundle.binutils.url` and `bundle.binutils.sha256`. Windows-target GCC packages require `bundle.components=binutils,mingw-w64` and the corresponding `bundle.mingw-w64.*` fields as well. Component versions are numeric dotted versions and component digests are lowercase SHA-256 values. This metadata records the composition actually selected for the build; it is not reconstructed from the GCC version.

`package.mode` must be `self-contained`, `package.formats` must match the archive formats produced for the host, and `source.primary.sha256` must be a lowercase 64-character SHA-256 value.

The primary source metadata is also bound to the package being finalized. `source.primary.name` must identify the upstream project for the selected tool, and `source.primary.version` must equal the selected main package version. GCC therefore records the GCC source version without the package `revN` suffix; GNU ld records Binutils; every LLVM-family package records `llvm-project`.

When Python becomes package-owned runtime payload, `info.txt` also records:

```text
contents.python_runtime=packaged
contents.python_runtime.version=<major.minor.micro>
```

The version is derived from the interpreter whose runtime was actually copied. It is provenance for the payload, not a compatibility table or an additional version-selection input. The common finalizer rejects a packaged Python runtime without a numeric dotted runtime version, and it rejects runtime-version metadata when no packaged Python runtime is declared.

`package.component` is derived from the tool:

| Tool | Component |
| --- | --- |
| GCC, Clang | `compiler` |
| GDB, LLDB | `debugger` |
| GNU ld, LLD | `linker` |
| clang-format | `formatter` |
| clang-tidy | `linter` |
| clangd | `language-server` |
| Valgrind | `analyzer` |

Tool-specific metadata uses these namespaces:

```text
entry.*
features.*
requires.*
contents.*
config.*
```

### Entry metadata

`entry.*` maps a public command name to a path relative to the package root.

Examples:

```text
entry.gcc=bin/gcc
entry.g++=bin/g++
entry.clang=bin/clang
entry.ld=bin/ld
entry.ld_lld=bin/ld.lld
entry.gdb=bin/gdb
```

At least one executable entry is required. Every declared `entry.*` path must satisfy the package path grammar and point to a real package command. On POSIX it must also be executable; an admitted symbolic-link command is allowed only when its complete internal link chain resolves safely to a regular file.

### Capability metadata

`features.*` records behavioral capabilities deliberately exposed by the completed package. A command or payload being present is evidence for `entry.*` or `contents.*`; it does not by itself create a `features.*` promise. Positive feature claims therefore have a corresponding product-test oracle. Every `features.*` value is the literal boolean `true` or `false`; the exact keys depend on the tool.

`requires.*` records an explicit external platform prerequisite that is necessary for a declared capability but is not package payload. It is used only when the platform/toolchain environment owns that prerequisite, and its values are likewise literal `true` or `false`. Current examples are the Linux native development environment used by Clang's default C/C++ compilation path, the Apple developer tools/SDK used for macOS native compilation and Apple's system `debugserver` used by LLDB local process control. A requirement must never be inferred silently from the build runner.

Examples include:

```text
features.c=true
features.cpp=true
features.openmp=true
features.asan=true
features.remote_debugging=true
features.link_coff=true
features.format_file=true
```

### Content and configuration metadata

`contents.*` summarizes important payload groups. `config.*` describes build choices that are useful for interpreting the package.

These fields are summaries. The exact physical inventory is always `manifest.txt`.

## `manifest.txt`

`manifest.txt` is generated only after the package tree and `info.txt` have reached their final form.

The current format is `2`:

```text
format=2
d\t0755\t-\t<relative-path>
f\t0644\t<lowercase-sha256>\t<relative-path>
f\t0755\t<lowercase-sha256>\t<relative-path>
l\t-\t<lowercase-sha256-of-link-target-text>\t<relative-path>
```

The record types are:

- `d` — directory and normalized mode;
- `f` — regular file, normalized mode and SHA-256 of its bytes;
- `l` — admitted symbolic link and SHA-256 of the exact link-target text.

Records are sorted by relative path. Every descendant of the package root is listed except `manifest.txt` itself, because a file cannot include its own final digest without becoming self-referential.

A symbolic link's final regular-file target has its own separate manifest record.

The producer generates `manifest.txt` once from the finalized package tree before archive creation. After creating each advertised archive, the finalizer verifies the stored file/directory mode classes, extracts that archive, independently regenerates the manifest from the extracted tree and compares it with the finalized package manifest. This checks both the archive metadata consumed during installation and the package object graph described by `manifest.txt`.

The manifest is therefore the exact reference inventory for the installed package tree and can be used to detect missing, changed or unexpected package paths. It does not make the package immutable to a process that already has permission to rewrite both the payload and its metadata.

## Archive formats

Every package is emitted in three formats:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
```

The three archives must represent the same logical package:

- the same relative paths;
- the same directory/file/link semantics;
- the same regular-file bytes;
- the same relevant file modes;
- the same symbolic-link targets on POSIX;
- the same `manifest.txt` result.

Hardlink inode sharing does not have to be identical between formats.

POSIX ZIP packages preserve admitted symbolic links instead of replacing them with the target bytes. Windows packages do not contain symbolic links.

After all three archives are created, the finalizer writes `SHA256SUMS` with exactly one SHA-256 entry for each archive. The workflow verifies that checksum file after the tool-specific product test and before upload or publication.

## Self-contained package boundary

Self-contained means that the packaged host process does not require undeclared non-system runtime files from the build machine.

The operating system still supplies its normal base runtime:

| Host | Operating-system-provided runtime |
| --- | --- |
| Linux | glibc and loader facilities |
| macOS | Apple system libraries in `/usr/lib` and `/System/Library` |
| Windows | Windows system DLLs |

A required runtime dependency outside that base must either:

- already belong to the selected package tree;
- be copied into the package by runtime closure; or
- be removed from the runtime graph by the tool-specific build/package design.

Target runtimes are a separate concept. For example, a GCC package that runs on Linux and targets Windows carries MinGW-w64 target files because those files belong to the compiler's target toolchain.

## Relocatability

A completed package must work after `cup` extracts it below the installation directory chosen for that package.

The temporary source, build and staging paths must therefore not become runtime requirements.

Relocatability has two parts:

1. internal configuration and data paths must refer to the package itself rather than the temporary build tree;
2. runtime libraries must resolve either from package-owned paths or from the operating-system-provided runtime boundary.

The implementation differs by executable format.

## Runtime closure

Runtime closure starts from the executable and library objects that already belong to the selected package. It follows their dynamic runtime dependencies recursively and adds only required non-system dependencies.

The closure does not decide what the product is. Tool-specific package-selection roots are selected first; closure only makes those roots complete.

### Linux ELF

Linux executables and shared libraries use the ELF format.

For each dynamic ELF object, `DT_NEEDED` entries define the direct dependency names. `ldd` is used only to resolve those names to files on the current build host. A dynamic ELF with no `DT_NEEDED` entries therefore has no dynamic-library edges to follow.

The closure:

1. reads the required dependency names;
2. resolves them without relying on an ambient `LD_LIBRARY_PATH`;
3. leaves glibc/loader dependencies to the operating system;
4. keeps dependencies that are already package-owned in their existing package layout;
5. copies other required non-base libraries into the package;
6. rewrites package runtime search paths to package-relative `$ORIGIN` locations when needed;
7. repeats the dependency walk until no new package-owned dependency is required;
8. verifies that every non-base dependency resolves inside the package.

Tools used by this process include `readelf`, `ldd`, `realpath` and `patchelf`. They are build tools, not package contents.

### macOS Mach-O

macOS executables and dynamic libraries use the Mach-O format.

Dependencies under `/usr/lib` and `/System/Library` are supplied by macOS. Other required dependencies are included in the package.

Package-owned `@rpath` dependencies and absolute non-system load paths are rewritten to deterministic package-relative `@loader_path` references. Bundled Mach-O install IDs are normalized when necessary.

Mach-O files changed by install-name rewriting are ad-hoc signed before final verification.

### Windows PE

Windows executables and DLLs use the PE format.

The closure follows PE imports recursively. Windows system DLLs remain supplied by the operating system. Required non-system MSYS2/MinGW runtime DLLs are copied into the package and inspected in turn until the dependency graph is complete.

Windows packages use regular files rather than package symbolic links.

## Python runtime

Python can be a genuine runtime capability of a distributed tool.

GDB and LLDB include Python support. The clang-tidy package also carries a package-owned Python runtime for the deliberate `run-clang-tidy` and `clang-tidy-diff` helpers. The standalone clang-format package does not include `git-clang-format`: that upstream integration helper requires an external Git runtime and would make the formatter package non-self-contained for a feature outside CUP's deliberate formatter surface.

When package-owned Python is required, the producer copies the interpreter and the standard-library/runtime material needed by the selected tool. Builder `site-packages`/`dist-packages`, development `config-*` directories, `Tools`, `__phello__`, caches, CPython tests and GUI/demo modules are excluded. Existing package-owned LLDB modules are preserved, so the runtime cannot inherit unrelated Clang/libxml2 Python packages from the builder.

For POSIX LLDB, the packaged interpreter path is derived from the Python version selected by the build, for example:

```text
bin/python3.12
```

The package does not rely on global `PYTHONHOME`, `PYTHONPATH` or `LD_LIBRARY_PATH` settings to make that runtime work.

Tool-specific Python ownership is documented in [Tool packages](TOOLS.md).
