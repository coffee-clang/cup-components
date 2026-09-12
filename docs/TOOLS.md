# Tool packages

This document describes the package policy owned by each tool-family builder.

The common archive, metadata, manifest and runtime-closure rules are defined in [Packages](PACKAGES.md). Supported host/target combinations and version rules are defined in [Specification](SPECIFICATION.md).

## General package-selection rule

Each upstream project can install more files than the final command-line package needs. The tool builder therefore selects a deliberate set of package roots before common runtime closure.

A package-selection root is kept because it is one of the following:

- a public command;
- a helper required by a public command;
- required runtime data;
- a required target runtime or sysroot;
- a deliberate public header or metadata file;
- a library required at runtime by one of those roots.

Runtime closure can add a required non-system library, but it does not turn unrelated files from the upstream staging tree into package content.

## GCC

GCC packages are compiler toolchains rather than a single executable.

### Package composition

The GCC package composition is:

```text
selected GCC
selected Binutils
selected MinGW-w64 for Windows targets
selected package revision
```

The component versions are independent workflow selections rather than a GCC-version mapping. The revision identifies the selected logical composition. Current defaults and the revision rule are documented in [GCC composition revision](SPECIFICATION.md#gcc-composition-revision).

### Native Linux GCC

A native Linux GCC package is required to provide:

- C compilation;
- C++ compilation;
- the public `cpp` preprocessor and `gcov` utility when produced by the selected GCC layout;
- link-time optimization (LTO);
- libstdc++;
- OpenMP;
- pthread support;
- the sanitizer runtime used by the native package checks;
- the Binutils layout required by GCC;
- the package-owned compiler helpers and libraries resolved by GCC itself.

The package can also expose target-prefixed driver or Binutils aliases when the upstream installation provides them.

The current recipe disables multilib (building multiple ABI variants from one compiler installation) and NLS (translated program messages).

GCC can internally use an upstream canonical target triple such as `x86_64-pc-linux-gnu` even when the package platform is `linux-x64`. `config.gcc_target_triple` records that GCC-specific value when needed.

### Windows-target GCC

A Windows-target GCC package contains the compiler and target toolchain needed to produce Windows x64 programs:

- Binutils for `x86_64-w64-mingw32`;
- MinGW-w64 headers and C runtime (CRT);
- winpthreads;
- target-prefixed compiler drivers;
- target-prefixed Binutils commands;
- the target sysroot/runtime layout used by the compiler;
- OpenMP support.

Sanitizer capability is recorded and checked when the selected Windows-target build provides it.

A Linux x64 host can therefore run the package while the compiler emits Windows x64 binaries.

### GCC metadata

The package separates public commands, retained payload and behavioral capabilities. `entry.*` records commands such as `cpp`, `gcov` and target-prefixed public tools; `contents.*` records retained LTO/Binutils/runtime layout; `features.*` is reserved for behavior CUP deliberately qualifies, including C/C++, LTO, OpenMP, pthread support, sanitizers and the target sysroot where applicable.

## GNU ld

The standalone GNU ld package is intentionally smaller than a full Binutils installation.

The required public root is:

```text
bin/ld
```

If the installed `ld.bfd` is equivalent to `ld`, the package keeps an `ld.bfd` compatibility entry. For a Linux x64 to Windows x64 cross package, it also exposes the target-prefixed linker entry:

```text
bin/x86_64-w64-mingw32-ld
```

Unrelated Binutils commands are not included merely because they were produced by the Binutils build.

The package records whether it links ELF or PE targets, whether `ld.bfd` is present and whether the target-prefixed cross entry is present.

## GDB

GDB is a native debugger package on Linux x64, Linux arm64 and Windows x64.

### Required package roots

The package is rooted in:

- `gdb`;
- `gdbserver`;
- `share/gdb` runtime data;
- locale data used by GDB;
- the package-owned Python runtime;
- optional installed runtime helpers required by the selected GDB build.

Development headers and static build material are not included simply because the upstream install created them. The `libinproctrace.so` in-process agent used by GDB fast-tracepoint workflows is also not shipped: fast tracepoints are outside the deliberate CUP debugger contract, so that specialized helper has no production package responsibility.

### Python

Python support is a required GDB product capability in the current recipe. The selected build interpreter and its required standard library are copied into the package so GDB does not depend on a separately installed Python runtime on the destination machine. `info.txt` records the version of the runtime that was actually copied. The package checks exercise Python from an isolated environment and verify that its search paths remain package-owned after relocation.

### TUI and terminal support

The current GDB recipe requires the text user interface (TUI) capability and uses the terminal/readline support available in the selected platform builder.

### Optional GDB integrations

Upstream GDB releases can expose optional integrations such as:

- Expat;
- zlib, LZMA and Zstandard support;
- debuginfod;
- GNU Source Highlight;
- xxHash;
- Babeltrace;
- Intel Processor Trace on supported Linux x64 builds.

The builder enables an integration only when the selected GDB source release exposes the corresponding configure control and the platform environment provides the required build input. The completed package records those optional integrations as build configuration and runtime contents. They are not promoted to separate `features.*` promises merely because the integration was compiled in.

### GNU Source Highlight data

When the selected Linux GDB build uses GNU Source Highlight, its language-definition data belongs to the package runtime. The producer places those files under:

```text
share/gdb/source-highlight
```

If the selected GDB source layout contains the recognized Source Highlight integration, the builder adapts that integration so the data directory is derived from GDB's relocatable `gdb_datadir` instead of the temporary build machine path.

A GDB release without that integration does not require this adaptation.

### Runtime closure

After the deliberate GDB roots are selected, the normal platform runtime closure adds only the non-system libraries required by those roots.

The Windows package similarly keeps `gdb.exe`, `gdbserver.exe`, GDB data, locale data, package-owned Python and required non-system DLLs.

## LLVM-family packages

The LLVM project source release is shared, but `cup-components` emits six separate packages:

```text
clang
clang-format
clang-tidy
clangd
lld
lldb
```

Each package has its own identity, public commands, payload policy and validation.

### LLVM project selection

The projects configured for each package are:

```text
clang        -> clang;lld
clang-format -> clang
clang-tidy   -> clang;clang-tools-extra
clangd       -> clang;clang-tools-extra
lld          -> lld
lldb         -> clang;lldb
```

Building a project does not automatically make all of its installed files part of the final package.

### Clang

The required public commands are:

```text
clang
clang++
```

The package also carries the Clang resource directory containing built-in headers and the runtime material required by the declared compiler capabilities.

Clang runtime construction includes deliberate LLVM runtime stages for:

```text
compiler-rt builtins
libunwind + libc++abi + libc++
compiler-rt sanitizers/profile runtime
```

Bundled libc++ is an available package capability. It is not forced as the default C++ standard library on every host. On macOS the static libc++/ABI/unwind build uses hidden/hermetic symbols so a package-owned static runtime can coexist with the Apple C++ runtime already present in system processes.

On Linux, `clang++.cfg` adds only the package-relative library search path needed to use the bundled runtime explicitly. It does not add `-stdlib=libc++` globally.

The package keeps only the native LLD frontend required by the declared linker/LTO integration: `ld.lld` on Linux and Windows/MinGW, and `ld64.lld` on macOS. Its private `lld` backing executable is retained on POSIX only when required by the installed symlink. This integration payload does not turn the compiler package into a second standalone linker package.

Windows Clang also carries the MinGW target sysroot and its package-relative driver configuration. `info.txt` records that sysroot's MSYS2 provider plus the exact headers, CRT and winpthreads package versions actually copied. Linux deliberately uses the platform's native development environment for the default C/C++ headers, startup/runtime material, default C++ standard library and platform linker; that external prerequisite is explicit as `requires.system_development_environment=true`. macOS similarly keeps its Apple developer-tools/SDK prerequisites explicit. The compiler is built with xcselect SDK discovery enabled so ordinary native compilation consumes the active Apple SDK without a test-only `-isysroot` injection.

LLVM utility commands used while constructing compiler runtimes are build tools, not final Clang package commands. They are pruned together with non-native LLD frontends and unrelated Clang sibling tools.

The standalone Clang package does not enable the Clang static analyzer as an additional product surface; analyzer checks are owned by the `clang-tidy` package. Optional libpfm discovery is disabled for all LLVM-family builds so runner-installed performance-counter libraries cannot change package build identity.

### LLD

The standalone LLD package exposes only the native frontend for its host:

```text
Linux    -> ld.lld
Windows  -> lld-link.exe
macOS    -> ld64.lld
```

On Linux and macOS the installed frontend can be a symlink to a private `lld` backing executable; the backing file is package implementation rather than another public entry. CUP qualifies ELF linking on Linux, PE/COFF linking on Windows and Mach-O linking on macOS. Cross-format frontends such as `wasm-ld` and non-native ELF/COFF/Mach-O frontends are pruned instead of being shipped as unowned upstream convenience payload.

### LLDB

LLDB is a native debugger package for all five LLVM platforms in the current matrix.

The required public commands on every LLDB platform are:

```text
bin/lldb
bin/lldb-dap
```

Linux and Windows additionally expose:

```text
bin/lldb-server
```

because those packages deliberately provide package-owned platform-server remote debugging. The macOS package does not retain `lldb-server`: local process launch and `lldb-dap` use Apple's system `debugserver`, matching upstream's supported `LLDB_USE_SYSTEM_DEBUGSERVER=ON` model. That concrete runtime prerequisite is explicit as `requires.system_debugserver=true`. CUP does not declare macOS remote debugging because a deployable remote `debugserver` is not part of the package contract.

The Linux package seed additionally keeps:

- the package-owned Python executable selected by the build;
- the LLDB Python module;
- the runtime `liblldb` objects actually required by LLDB;
- the matching installed Clang resource directory.

Other platforms apply the same product-ownership rule to their pruned staged installation before platform runtime closure.

LLDB enables Python. The Python executable path is derived from the interpreter selected by the build rather than from a fixed Python major/minor version, and `info.txt` records the version of the runtime that was actually copied. On POSIX, LLDB uses a package-relative Python home. On Windows, the producer explicitly avoids embedding the build-machine Python home and the packaged path configuration keeps Python module discovery inside the relocated package.

If the LLDB installation does not already contain the generated Clang built-in headers it needs, the producer copies the single matching resource directory produced by that LLVM build. The path is derived from the selected build rather than assuming a fixed `lib/clang/<major>` directory.

`lldb-vscode` is not a deliberate package command. On macOS, `lldb-argdumper` is retained as a private runtime helper because native evidence shows that the normal LLDB `run` path uses it for argument expansion. It is not a public `entry.*` command. Linux and Windows do not retain it because their qualified normal launch paths do not require it. The installed Python-side companion is pruned on every platform because the packaged runtime does not consume that alias.

### clangd

The required public command is:

```text
clangd
```

The package deliberately exposes and qualifies clangd's LSP behavior. `clangd-indexer`, development-only `dexp`, the Darwin XPC transport and embedded clang-tidy checks are not part of this package contract and are pruned if upstream installs them.

Clangd embeds the Clang parser but still requires its matching built-in headers. The package therefore keeps the corresponding package-relative Clang resource directory and requires a representative built-in header such as `stddef.h` to be present.

Unrelated `share/clang` integration scripts are not part of the standalone clangd package.

System C/C++ standard-library headers remain a platform/toolchain responsibility and are not copied into clangd merely because it parses C++.

### clang-format

The required public command is:

```text
clang-format
```

The CUP package deliberately exposes `clang-format` itself. `git-clang-format` is not packaged: the upstream integration helper requires a separate Git runtime, while CUP's formatter package is self-contained and does not make Git a formatter dependency. This also avoids carrying Python solely for that optional integration helper. Compiler builtin resource headers are removed as well because formatting does not consume the Clang resource directory.

### clang-tidy

The package requires these deliberate command roots:

```text
clang-tidy
clang-apply-replacements
run-clang-tidy
clang-tidy-diff
```

Some LLVM releases install `clang-tidy-diff.py` as shared Clang data rather than as a direct executable. The producer normalizes the helper into the package's command/helper layout before pruning unrelated clang-tools-extra development, analyzer, documentation and editor-integration payload.

Python helper commands execute through the package-owned Python runtime. The common Python copier excludes builder `site-packages`/`dist-packages`, development `config-*` directories, `Tools`, `__phello__`, caches, CPython test suites and GUI/demo modules on every platform. Pre-existing package-owned LLDB `site-packages` are preserved rather than replaced by the builder environment. macOS framework Python packages additionally preserve the `Resources/Python.app` companion required by the framework launcher after relocation.

## Valgrind

Valgrind packages are native Linux packages for x64 and arm64.

The public command is:

```text
bin/valgrind
```

The package keeps the runtime tool directory produced by the selected Valgrind release and wraps the public command so `VALGRIND_LIB` is derived from the relocated package root.

The package can retain the core tools actually installed by the selected release, including common tools such as:

```text
memcheck
cachegrind
callgrind
massif
helgrind
drd
dhat
lackey
```

`vgdb` is retained when present because it belongs to Valgrind's core debugger-server functionality.

The package also keeps the public client-request headers used by programs that integrate with Valgrind and `valgrind.pc`, whose prefix is rewritten so it remains valid after relocation.

The following are intentionally outside the package:

- MPI wrapping;
- the optional GDB Python front-end;
- the internal SDK used to develop new Valgrind tools, including internal VEX/VKI headers and core development static archives.

`contents.tools` records which Valgrind runtimes are actually retained, while `contents.vgdb` records the optional debugger-server command. CUP deliberately exposes Memcheck as the behavioral `features.memcheck` capability and exercises it in the product test; the mere presence of the other upstream runtimes does not create separate CUP feature promises.
