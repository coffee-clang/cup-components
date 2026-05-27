$ErrorActionPreference = 'Stop'

function Invoke-NativeCaptureAllowFailure {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $PathOverride = $null
    )

    Write-Host "==> $FilePath $($ArgumentList -join ' ')"

    $oldPath = $env:Path
    if ($PathOverride) {
        $env:Path = $PathOverride
    }

    try {
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        if ($PathOverride) {
            $env:Path = $oldPath
        }
    }

    $output | ForEach-Object { Write-Host $_ }
    return @{ Output = $output; ExitCode = $exitCode }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $PathOverride = $null
    )

    $result = Invoke-NativeCaptureAllowFailure -FilePath $FilePath -ArgumentList $ArgumentList -PathOverride $PathOverride
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

function Assert-TextDoesNotContain {
    param([object[]] $Output, [string] $Pattern)
    $text = ($Output | Out-String)
    if ($text -match $Pattern) {
        throw "Expected output not to match pattern: $Pattern"
    }
}

function Find-CCompiler {
    $candidates = @(
        'C:\msys64\clang64\bin\clang.exe',
        'C:\msys64\ucrt64\bin\gcc.exe',
        'C:\msys64\mingw64\bin\gcc.exe',
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

function Build-DrMemoryRuntimePath {
    param([Parameter(Mandatory = $true)][string] $Root)

    $parts = @(
        (Join-Path $Root 'bin'),
        (Join-Path $env:SystemRoot 'System32'),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32\Wbem'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    )

    return ($parts | Where-Object { $_ -and (Test-Path $_) }) -join ';'
}

$releaseEnv = Get-Content dist/release.env
$packageBase = ($releaseEnv | Where-Object { $_ -like 'package_base=*' }) -replace '^package_base=', ''
if (-not $packageBase) { throw 'package_base not found in dist/release.env' }

Remove-Item -Recurse -Force dist/package-test -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force dist/package-test | Out-Null
Expand-Archive -Force "dist/$packageBase.zip" dist/package-test

$root = Join-Path (Resolve-Path dist/package-test) $packageBase
Get-Content "$root\info.txt"

$drmemory = Join-Path $root 'bin\drmemory.exe'
if (-not (Test-Path $drmemory)) { throw "missing drmemory.exe: $drmemory" }

$drmemoryRuntimePath = Build-DrMemoryRuntimePath -Root $root

$versionOutput = Invoke-Native -FilePath $drmemory -ArgumentList @('-version') -PathOverride $drmemoryRuntimePath
Assert-TextContains -Output $versionOutput -Pattern 'Dr\. Memory|Dr\.Memory|DrMemory'

$testDir = Join-Path $env:TEMP 'cup-drmemory-test'
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null

$source = Join-Path $testDir 'leak.c'
$exe = Join-Path $testDir 'leak.exe'
$logDir = Join-Path $testDir 'drmemory-logs'
New-Item -ItemType Directory -Force $logDir | Out-Null

@'
#include <stdlib.h>

int main(void) {
    void *p = malloc(64);
    (void)p;
    return 0;
}
'@ | Set-Content $source

$compiler = Find-CCompiler
if (-not $compiler) {
    throw 'no Windows C compiler found for Dr. Memory functional test'
}

Write-Host "==> using C compiler: $compiler"
& $compiler $source -g -O0 -o $exe

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
    throw 'failed to compile Dr. Memory leak test executable'
}

$result = Invoke-NativeCaptureAllowFailure -FilePath $drmemory -ArgumentList @('-batch', '-brief', '-logdir', $logDir, '--', $exe) -PathOverride $drmemoryRuntimePath
Assert-TextContains -Output $result.Output -Pattern 'Dr\. Memory|Dr\.Memory|DrMemory'
Assert-TextDoesNotContain -Output $result.Output -Pattern 'Unable to load client library|library initializer failed|Could not create result file|Unable to locate results file'
Assert-TextContains -Output $result.Output -Pattern 'leak|ERRORS FOUND|ERRORS IGNORED|NO ERRORS FOUND'

Write-Host 'OK: Dr. Memory package test completed'
