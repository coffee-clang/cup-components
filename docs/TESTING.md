# Testing

Testing in `cup-components` has three separate responsibilities:

1. validate the common package format and shared package mechanics;
2. validate the finished package produced for a specific tool;
3. protect repository build/package behavior with focused regression checks.

These checks are part of the repository itself. They are not a substitute for actually building each supported package on its target runner, but they keep the package rules and build interfaces consistent before and during those builds.

## Common package validation

The shared package contract is checked by:

```text
scripts/test/test-package-contract.sh
```

Each GitHub workflow runs this script once in its Ubuntu `select` job, before any host-specific build job starts. The synthetic fixtures therefore validate the abstract package contract in one predictable POSIX environment; finished-package checks remain native to the platform that built the tool.

It checks common behavior such as:

- source acquisition success and failure propagation;
- package identity and revision rules;
- `info.txt` field/path compatibility;
- `manifest.txt` format and regeneration;
- final archive stored-mode and object parity across `tar.xz`, `tar.gz` and `zip`;
- checksum generation and checksum tamper rejection;
- admissible POSIX symbolic-link behavior;
- rejection of unsupported filesystem objects and unsafe paths;
- runtime-dependency name safety;
- recursive Linux and macOS runtime closure;
- runtime search-path rewriting;
- package-owned versus operating-system-provided runtime dependency rules;
- Windows Python path-file ownership;
- removal of non-relocatable libtool metadata;
- explicit numeric version preservation.

Some common checks use small local package trees or locally built sample objects so one mechanism can be checked without building an entire compiler or debugger first.

## Tool-specific package checks

After a real package is built and finalized, the corresponding tool package script checks the actual result.

| Package family | POSIX check | Windows check |
| --- | --- | --- |
| GCC | `scripts/test/test-gcc.sh` | `scripts/test/test-gcc-windows.ps1` |
| GNU ld | `scripts/test/test-ld.sh` | `scripts/test/test-ld-windows.ps1` |
| GDB | `scripts/test/test-gdb.sh` | `scripts/test/test-gdb-windows.ps1` |
| LLVM family | `scripts/test/test-llvm-tool.sh` | `scripts/test/test-llvm-tool-windows.ps1` |
| Valgrind | `scripts/test/test-valgrind.sh` | not applicable |

The Windows scripts are executed with PowerShell. POSIX scripts are executed with Bash.

### GCC checks

Depending on host and target, the GCC package check validates capabilities such as:

- required compiler entries;
- C and C++ compilation;
- target-prefixed compiler/binutils entries;
- package-owned `lto-wrapper` and its adjacent LTO plugin, followed by a real LTO compile/link;
- OpenMP;
- pthread support;
- native Linux sanitizer use when declared;
- Windows-target PE output;
- target sysroot/runtime availability;
- physical package relocation.

The native Linux relocation checks move the package through multiple physical roots and ensure previous roots are unavailable, so a successful command cannot silently depend on the original staging location.

### GNU ld checks

The GNU ld package check verifies:

- linker metadata and public entry paths;
- ELF or PE target capability according to the selected target;
- creation of a real linker output;
- the absence of unrelated Binutils command payload;
- target-prefixed linker behavior for the cross-target package.

### GDB checks

The GDB package check verifies:

- `gdb` and `gdbserver` package entries;
- required Python support;
- GDB data-directory ownership;
- package-owned Python identity and runtime-version provenance;
- isolated Python search paths where the platform provides packaged path configuration;
- declared debugger feature metadata;
- packaged `gdbserver` remote debugging over loopback;
- relocation through multiple physical package roots, including paths with spaces and with the previous root unavailable.

### LLVM-family checks

`scripts/test/test-llvm-tool.sh` selects checks according to the requested package.

Clang checks include:

- `clang` and `clang++`;
- package-owned resource-directory discovery;
- C and C++ compilation/linking;
- packaged libc++ as an explicit capability;
- LTO through packaged LLD where declared;
- sanitizer/runtime capabilities where declared;
- Linux and macOS relocation behavior;
- Windows sysroot/driver behavior on the Windows path.

LLD performs a real native-format link for the package host: ELF on Linux, PE/COFF on Windows and Mach-O on macOS. Additional upstream frontends can remain package contents, but their presence alone is not a CUP capability claim.

LLDB checks include:

- required `lldb` and `lldb-dap` public commands, plus `lldb-server` on Linux/Windows; macOS additionally requires the private `lldb-argdumper` helper used by the normal `run` path, while Linux/Windows reject it as unused package payload;
- package-owned Python interpreter/module identity and runtime-version provenance;
- isolated package-owned Python search paths on Windows;
- Clang resource-directory ownership;
- target creation, breakpoint and symbol lookup behavior;
- process launch whenever `features.process_launch=true`; an environment restriction is an evidence failure rather than a package PASS;
- a real `lldb-dap` protocol session when DAP is declared;
- on Linux and Windows, a real packaged `lldb-server platform` session when remote debugging is declared, with native remote launch, breakpoint/expression and bounded cleanup;
- on macOS, the declared system `debugserver` prerequisite is exercised by real local process launch/DAP rather than by a separate filesystem lookup proxy, while remote debugging remains undeclared;
- POSIX relocation with previous roots unavailable; the final path contains real spaces and repeats the local process-launch oracle after relocation.

clangd checks the language-server entry, matching Clang resource headers, compile-command consumption and a real bounded LSP initialize/document-symbol/shutdown session. The LSP test requires a valid compilation database to be loaded and rejects fallback parsing. `clangd-indexer` remains optional payload when upstream installs it; background indexing is not a separate CUP capability claim.

clang-format checks formatting behavior, style-file discovery, dry-run failure semantics and relocation; `git-clang-format`, Python solely used by that helper and compiler builtin resource headers are deliberately absent from the standalone self-contained package.

clang-tidy checks the main analyzer command plus real `run-clang-tidy` and `clang-tidy-diff` operations, package-owned Python identity and relocation with previous roots unavailable.

### Valgrind checks

The Valgrind package check verifies:

- the public relocatable wrapper;
- installed core tool capabilities reported by metadata;
- `vgdb` when present;
- public client headers and representative client-request compilation;
- relocatable `valgrind.pc` metadata;
- operation after moving the package root;
- absence of intentionally excluded development/internal payload.

## Package capability reporters

Two helper scripts read `info.txt` and inspect package content in a platform-appropriate way:

```text
scripts/test/package-capabilities.sh
scripts/test/package-capabilities-windows.ps1
```

They are shared by tool-specific checks so package metadata and physical package capabilities are interpreted consistently. `entry.*` is interpreted as an exact package-relative command path, while boolean `features.*`/boolean content probes are compared with executable presence; the reporters remain diagnostic and the tool-specific acceptance tests own pass/fail behavior.

## Archive checksum check

The finished archive checksums can also be verified directly with:

```text
scripts/test/test-package-checksums.sh <package-base> <output-directory>
```

The workflows additionally call the common checksum verifier before upload or publication.

## Repository regression suite

Focused repository checks live in:

```text
tests/regression/
```

Run all of them with:

```text
tests/run.sh
```

The current suite covers:

```text
test-clang-bin-pruning.sh
test-clang-linux-package-policy.sh
test-clang-macos-package-policy.sh
test-gcc-package-ownership.sh
test-gdb-package-policy.sh
test-ld-builder-synthetic.sh
test-ld-product-model.sh
test-lldb-clang-resource-materialization.sh
test-lldb-package-policy.sh
test-llvm-auxiliary-package-policy.sh
test-llvm-capability-scope-policy.sh
test-package-capability-reporter.sh
test-producer-interfaces.sh
test-python-runtime-development-exclusion.sh
test-reproducible-archives.sh
test-source-acquisition.sh
```

These checks protect repository-level decisions that are easy to break without noticing, such as package pruning, version input handling, manifest/object behavior, Python runtime selection, source acquisition and workflow interfaces.

## What local checks cannot establish

A repository-level check can validate syntax, package algorithms and local fixtures, but it cannot replace a native upstream build that has not actually been run.

For example:

- a Linux machine cannot establish that a Windows-native compiler build completes successfully;
- parsing a PowerShell file does not establish that every Windows executable behaves correctly;
- a local Mach-O mechanism check does not replace a complete macOS LLVM build;
- a supported explicit upstream version can still expose a build-system change that requires a family-specific adjustment.

For that reason, the GitHub workflows combine repository checks with actual platform builds and then run the tool-specific package checks on the produced package.

When a workflow fails, [Build records](BUILD_RECORDS.md) describes the information saved for diagnosing the failed phase.
