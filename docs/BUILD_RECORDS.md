# Build records

Every GitHub build saves a structured record of the run in addition to the package output.

The purpose is practical: if a selected tool version succeeds, the record identifies what was built and how. If it fails, the record preserves the first failing phase, its output and the build/configuration files that are useful for correcting the family recipe.

Build records are normal workflow output. They are not part of the package installed by `cup` and do not affect package identity.

## Location

During a run, records are written under:

```text
.cup-build/build-records
```

GitHub Actions uploads that directory with a run-specific artifact name. GCC, GNU ld, GDB and Valgrind use:

```text
build-records-<run-id>-<run-attempt>
```

The LLVM matrix includes the tool, requested version and platform identity as well so records from different matrix cells remain distinguishable:

```text
build-records-<tool>-<requested-version>-<host>-<target>-<run-id>-<run-attempt>
```

The upload step uses `always()`, so the records are saved after both successful and failed repository-controlled build phases.

## Run identity

`run.txt` records the overall build identity, including:

```text
format
tool
requested version
host platform
target platform
requested source SHA-256, when supplied
repository commit
GitHub workflow
GitHub run id
GitHub run attempt
GitHub ref
start time
final workflow status
finish time
```

For GCC, `run.txt` additionally records the requested Binutils version, requested MinGW-w64 version, requested GCC package revision and the optional SHA-256 values supplied for those bundled source archives. These values are captured before the build starts, so the intended composition remains visible even if source acquisition or configuration fails early.

This makes the record self-describing when it is downloaded separately from the workflow page.

## Phase records

Repository-controlled workflow phases are executed through:

```text
scripts/workflow/build-records.sh
```

Windows PowerShell package checks use:

```text
scripts/workflow/build-records-windows.ps1
```

For each reached phase, the record contains:

```text
<phase>.log
<phase>.meta
environment-<phase>.txt
```

`<phase>.log` contains the combined command output.

`<phase>.meta` records:

```text
phase name
start time
command
exit code
finish time
```

`phases.txt` provides a compact list of phase exit codes:

```text
phase.builder-setup=0
phase.package-contract=0
phase.build=1
```

The first non-zero phase is normally the first place to inspect.

## Environment information

The environment files record the tool versions that can materially affect a build, when they are available, including:

```text
runner OS and architecture
build environment identifier
shell
uname
Bash
Make
CMake
Ninja
GCC
Clang
ld
Python
PowerShell
```

Unavailable commands are recorded as unavailable rather than making record creation fail.

## Source information

Source acquisition appends one row per acquired source archive to:

```text
sources.tsv
```

Each row contains:

```text
source id
resolved version
archive filename
expected SHA-256, when known or supplied
actual SHA-256
acquisition status
source URL
```

Possible statuses include:

```text
ready-verified
ready-unverified
sha256-mismatch
download-failed
extraction-failed
```

This is especially useful when building an explicit version that does not yet have a built-in digest. The record still states exactly which source bytes were used if acquisition completed.

## Build-system files

When present, finalization copies common configure/CMake information from `.cup-build/build`, including:

```text
config.log
CMakeCache.txt
CMakeConfigureLog.yaml
CMakeError.log
CMakeOutput.log
```

These files help distinguish failures caused by missing build inputs, unsupported options, compiler checks and other configure-time decisions.

## Package information

If package finalization was reached, the build record copies:

```text
package/<package-base>/info.txt
package/<package-base>/manifest.txt
```

This allows the completed semantic metadata and exact package inventory to be inspected without extracting the package archive first.

It also copies, when available:

```text
release.env
SHA256SUMS
```

## Output and staging inventories

`outputs.txt` lists each file present in `dist/` together with its SHA-256 and byte size.

`staging-paths.txt` lists paths still present under the staging root when the build record is finalized. It is an inventory of names, not a second copy of the staging tree.

## Reading a failed build

A useful order is:

1. open `run.txt` and confirm the requested tool/version/platform;
2. open `phases.txt` and find the first non-zero phase;
3. read that phase's `.meta` and `.log` files;
4. inspect `sources.tsv` if the failure occurred near download/extraction;
5. inspect `diagnostics/` for configure or CMake failures;
6. inspect copied `info.txt` / `manifest.txt` if package finalization was reached;
7. inspect `outputs.txt` if archive generation or checksum handling was reached.

This keeps version-specific corrections local to the point where the selected upstream release differs from the current family recipe.

## Boundary

Repository code cannot create build records before the repository has been checked out. A failure in a GitHub-managed action that happens before checkout therefore remains available only in the normal GitHub Actions run log.

The common package-contract check deliberately runs once in the Ubuntu `select` job after checkout and before any platform build starts. It is a repository gate rather than a per-build phase, so its output remains in the `select` job log instead of a build-record artifact.

Once a platform build initializes its repository-controlled record, later repository-controlled phases preserve their status and output through the build-record mechanism.
