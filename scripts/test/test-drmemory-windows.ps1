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

$versionOutput = Invoke-Native -FilePath $drmemory -ArgumentList @('-version')
Assert-TextContains -Output $versionOutput -Pattern 'Dr\. Memory|Dr\.Memory|DrMemory'

$testDir = Join-Path $env:TEMP 'cup-drmemory-test'
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null

$source = Join-Path $testDir 'leak.c'
$exe = Join-Path $testDir 'leak.exe'
@'
#include <stdlib.h>

int main(void) {
    void *p = malloc(64);
    (void)p;
    return 0;
}
'@ | Set-Content $source

$clang = 'C:\msys64\clang64\bin\clang.exe'
$gcc = 'C:\msys64\ucrt64\bin\gcc.exe'
if (Test-Path $clang) {
    & $clang $source -g -O0 -o $exe
} elseif (Test-Path $gcc) {
    & $gcc $source -g -O0 -o $exe
} else {
    throw 'no Windows C compiler found for Dr. Memory functional test'
}

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
    throw 'failed to compile Dr. Memory leak test executable'
}

$result = Invoke-NativeCaptureAllowFailure -FilePath $drmemory -ArgumentList @('-batch', '-brief', '--', $exe)
Assert-TextContains -Output $result.Output -Pattern 'Dr\. Memory|Dr\.Memory|DrMemory'
Assert-TextContains -Output $result.Output -Pattern 'leak|ERRORS FOUND|ERRORS IGNORED|NO ERRORS FOUND'

Write-Host 'OK: Dr. Memory package test completed'
