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

function Assert-TextDoesNotContain {
    param([object[]] $Output, [string] $Pattern)
    $text = ($Output | Out-String)
    if ($text -match $Pattern) {
        throw "Unexpected output matched pattern: $Pattern"
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

function Build-TestExecutable {
    param(
        [Parameter(Mandatory = $true)][string] $Compiler,
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Exe
    )

    $compileAttempts = @(
        @($Source, '-g', '-O0', '-fno-omit-frame-pointer', '-static', '-o', $Exe),
        @($Source, '-g', '-O0', '-fno-omit-frame-pointer', '-o', $Exe),
        @($Source, '-O0', '-o', $Exe)
    )

    foreach ($arguments in $compileAttempts) {
        Remove-Item -Force $Exe -ErrorAction SilentlyContinue
        $result = Invoke-NativeCaptureAllowFailure -FilePath $Compiler -ArgumentList $arguments
        if ($result.ExitCode -eq 0 -and (Test-Path $Exe)) {
            return
        }
    }

    throw 'failed to compile Dr. Memory test executable'
}

function Get-DrMemoryRuntimePath {
    param([Parameter(Mandatory = $true)][string] $Root)

    $paths = @(
        (Join-Path $Root 'bin'),
        (Join-Path $env:SystemRoot 'System32'),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32\Wbem'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
    )

    return ($paths | Where-Object { $_ -and (Test-Path $_) }) -join ';'
}

function Invoke-DrMemory {
    param(
        [Parameter(Mandatory = $true)][string] $DrMemory,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $LogDir,
        [Parameter(Mandatory = $true)][string] $TargetExe
    )

    Remove-Item -Recurse -Force $LogDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $LogDir | Out-Null

    $originalPath = $env:Path
    $runtimePath = Get-DrMemoryRuntimePath -Root $Root

    Write-Host '==> Dr. Memory runtime PATH'
    Write-Host $runtimePath

    $env:Path = $runtimePath
    try {
        return Invoke-NativeCaptureAllowFailure -FilePath $DrMemory -ArgumentList @('-batch', '-brief', '-logdir', $LogDir, '--', $TargetExe)
    } finally {
        $env:Path = $originalPath
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

Write-Host '==> dbghelp.dll candidates'
Get-ChildItem -Recurse $root -Filter dbghelp.dll -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.FullName }
Get-ChildItem "$env:SystemRoot\System32\dbghelp.dll" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.FullName }

$testDir = Join-Path $env:TEMP 'cup-drmemory-test'
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null

$source = Join-Path $testDir 'clean.c'
$exe = Join-Path $testDir 'clean.exe'
@'
#include <stdlib.h>

int main(void) {
    void *p = malloc(64);
    if (p == NULL) {
        return 1;
    }
    free(p);
    return 0;
}
'@ | Set-Content $source

$compiler = Find-CCompiler
if (-not $compiler) {
    throw 'no Windows C compiler found for Dr. Memory functional test'
}

Write-Host "==> using C compiler: $compiler"
Build-TestExecutable -Compiler $compiler -Source $source -Exe $exe

$normalRun = Invoke-NativeCaptureAllowFailure -FilePath $exe
if ($normalRun.ExitCode -ne 0) {
    throw "test executable failed without Dr. Memory, exit code $($normalRun.ExitCode)"
}

$logDir = Join-Path $testDir 'drmemory-clean-logs'
$result = Invoke-DrMemory -DrMemory $drmemory -Root $root -LogDir $logDir -TargetExe $exe

Assert-TextContains -Output $result.Output -Pattern 'Dr\. Memory|Dr\.Memory|DrMemory'
Assert-TextDoesNotContain -Output $result.Output -Pattern 'Unable to load client library|library initializer failed|Could not create result file|Unable to locate results file|failed to start the target application'

if ($result.ExitCode -ne 0) {
    throw "Dr. Memory clean functional test failed with exit code $($result.ExitCode)"
}

Assert-TextContains -Output $result.Output -Pattern 'NO ERRORS FOUND|ERRORS IGNORED|ERRORS FOUND'

Write-Host 'OK: Dr. Memory package test completed'
