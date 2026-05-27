$ErrorActionPreference = 'Stop'

function Invoke-NativeCaptureAllowFailure {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    Write-Host "==> $FilePath $($ArgumentList -join ' ')"
    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    return @{ Output = $output; ExitCode = $exitCode }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    $result = Invoke-NativeCaptureAllowFailure -FilePath $FilePath -ArgumentList $ArgumentList
    if ($result.ExitCode -ne 0) {
        throw "Command failed with exit code $($result.ExitCode): $FilePath $($ArgumentList -join ' ')"
    }
    return $result.Output
}

function Assert-TextContains {
    param([object[]] $Output, [string] $Pattern)
    $text = ($Output | Out-String)
    if ($text -notmatch $Pattern) {
        throw "Expected output to match pattern: $Pattern"
    }
}

function Find-CCompiler {
    $candidates = @(
        'C:\msys64\clang64\bin\clang.exe',
        'clang.exe',
        'gcc.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }

        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    return $null
}

function Find-DrMemoryExecutable {
    param([Parameter(Mandatory = $true)][string] $Root)

    $candidates = @(
        (Join-Path $Root 'bin64\drmemory.exe'),
        (Join-Path $Root 'bin\drmemory.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "missing drmemory.exe under bin64/ or bin/: $Root"
}

function Show-DebugHelpCandidates {
    param([Parameter(Mandatory = $true)][string] $Root)

    Write-Host '==> dbghelp.dll candidates'
    Get-ChildItem -Recurse $Root -Filter dbghelp.dll -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host $_.FullName
    }

    $systemDbgHelp = Join-Path $env:SystemRoot 'System32\dbghelp.dll'
    if (Test-Path $systemDbgHelp) {
        Write-Host $systemDbgHelp
    }
}

$releaseEnv = Get-Content dist/release.env
$packageBase = ($releaseEnv | Where-Object { $_ -like 'package_base=*' }) -replace '^package_base=', ''
if (-not $packageBase) { throw 'package_base not found in dist/release.env' }

Remove-Item -Recurse -Force dist/package-test -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force dist/package-test | Out-Null
Expand-Archive -Force "dist/$packageBase.zip" dist/package-test

$root = Join-Path (Resolve-Path dist/package-test) $packageBase
Get-Content "$root\info.txt"

$drmemory = Find-DrMemoryExecutable -Root $root
$drmemoryBin = Split-Path $drmemory -Parent

$versionOutput = Invoke-Native -FilePath $drmemory -ArgumentList @('-version')
Assert-TextContains -Output $versionOutput -Pattern 'Dr\. Memory|Dr\.Memory|DrMemory'

$testDir = Join-Path $env:TEMP 'cup-drmemory-test'
$logDir = Join-Path $testDir 'drmemory-logs'
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null
New-Item -ItemType Directory -Force $logDir | Out-Null

$source = Join-Path $testDir 'clean.c'
$exe = Join-Path $testDir 'clean.exe'
@'
#include <stdlib.h>

int main(void) {
    void *p = malloc(64);
    free(p);
    return 0;
}
'@ | Set-Content $source

$compiler = Find-CCompiler
if (-not $compiler) {
    throw 'no Windows C compiler found for Dr. Memory functional test'
}

Write-Host "==> using C compiler: $compiler"
& $compiler $source -g -O0 -fno-omit-frame-pointer -o $exe

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
    throw 'failed to compile Dr. Memory clean test executable'
}

Invoke-Native -FilePath $exe | Out-Null
Show-DebugHelpCandidates -Root $root

$originalPath = $env:Path
$runtimePath = @(
    $drmemoryBin,
    (Join-Path $root 'bin64'),
    (Join-Path $root 'bin'),
    "$env:SystemRoot\System32",
    "$env:SystemRoot",
    "$env:SystemRoot\System32\Wbem",
    "$env:SystemRoot\System32\WindowsPowerShell\v1.0"
) -join ';'

Write-Host '==> Dr. Memory runtime PATH:'
Write-Host $runtimePath

$env:Path = $runtimePath
try {
    $result = Invoke-NativeCaptureAllowFailure -FilePath $drmemory -ArgumentList @('-batch', '-brief', '-logdir', $logDir, '--', $exe)
} finally {
    $env:Path = $originalPath
}

$text = ($result.Output | Out-String)
if ($text -match 'Unable to load client library|library initializer failed|Could not create result file|Unable to locate results file|failed to start the target application') {
    throw 'Dr. Memory failed before completing instrumentation of the clean test executable'
}

if ($result.ExitCode -ne 0) {
    throw "Dr. Memory clean functional test failed with exit code $($result.ExitCode)"
}

Assert-TextContains -Output $result.Output -Pattern 'Dr\. Memory|Dr\.Memory|DrMemory'
Assert-TextContains -Output $result.Output -Pattern 'NO ERRORS FOUND|ERRORS FOUND|ERRORS IGNORED'

Write-Host 'OK: Dr. Memory package test completed'
