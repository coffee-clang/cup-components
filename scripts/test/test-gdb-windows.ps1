$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    Write-Host "==> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    Write-Host "==> $FilePath $($ArgumentList -join ' ')"
    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    $output | ForEach-Object { Write-Host $_ }

    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($ArgumentList -join ' ')"
    }

    return $output
}

function Assert-FileExists {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path $Path)) {
        throw "Expected file was not created: $Path"
    }
}

function Assert-OutputContains {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Output,

        [Parameter(Mandatory = $true)]
        [string] $Pattern
    )

    $text = ($Output | Out-String)
    if ($text -notmatch $Pattern) {
        throw "Expected output to match pattern: $Pattern"
    }
}

function Read-InfoValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $Key
    )

    $infoPath = Join-Path $Root 'info.txt'
    if (-not (Test-Path $infoPath)) {
        return ''
    }

    $line = Get-Content $infoPath | Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
    if (-not $line) {
        return ''
    }

    return ($line -replace "^$([regex]::Escape($Key))=", '')
}

function Test-FeatureEnabled {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [string] $Key
    )

    return (Read-InfoValue -Root $Root -Key $Key) -eq 'true'
}

function To-ForwardSlashPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return $Path.Replace('\', '/')
}

$releaseEnv = Get-Content dist/release.env
$packageBase = ($releaseEnv | Where-Object { $_ -like 'package_base=*' }) -replace '^package_base=', ''
if (-not $packageBase) { throw 'package_base not found in dist/release.env' }

Remove-Item -Recurse -Force dist/package-test -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force dist/package-test | Out-Null
Expand-Archive -Force "dist/$packageBase.zip" dist/package-test

$root = Join-Path (Resolve-Path dist/package-test) $packageBase
Get-Content "$root\info.txt"

pwsh scripts/test/package-capabilities-windows.ps1 -Root $root -Tool 'gdb'

$testDir = Join-Path $env:TEMP 'cup-gdb-windows-test'
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null

$testSource = Join-Path $testDir 'cup-gdb-test.c'
$testExe = Join-Path $testDir 'cup-gdb-test.exe'
@'
#include <stdio.h>

static int add(int a, int b) {
    return a + b;
}

int main(void) {
    int x = add(20, 22);
    printf("x = %d\n", x);
    return 0;
}
'@ | Set-Content $testSource

$gcc = (Get-Command gcc.exe -ErrorAction Stop).Source
Invoke-Native -FilePath $gcc -ArgumentList @(
    '-g',
    '-O0',
    '-static',
    $testSource,
    '-o',
    $testExe
)
Assert-FileExists $testExe

$gdbTestExe = To-ForwardSlashPath $testExe

$env:Path = "$root\bin;$env:SystemRoot\System32;$env:SystemRoot"

Invoke-Native -FilePath "$root\bin\gdb.exe" -ArgumentList @('--version')
Invoke-Native -FilePath "$root\bin\gdb.exe" -ArgumentList @('--configuration')

# Python is a major user-facing GDB capability when declared by the package.
# We intentionally do not assert every configure-time library from info.txt.
if ((Test-FeatureEnabled -Root $root -Key 'features.python') -or (Test-FeatureEnabled -Root $root -Key 'config.python') -or (Test-FeatureEnabled -Root $root -Key 'contents.uses_python')) {
    $output = Invoke-NativeCapture -FilePath "$root\bin\gdb.exe" -ArgumentList @(
        '-q',
        '-batch',
        '-ex',
        'python import sys, gdb; print("python-ok", sys.version_info[0], sys.version_info[1])'
    )
    Assert-OutputContains -Output $output -Pattern 'python-ok'
} else {
    Write-Host 'warning: GDB Python support not declared in info.txt'
}

$output = Invoke-NativeCapture -FilePath "$root\bin\gdb.exe" -ArgumentList @(
    '-q',
    '-batch',
    '-ex',
    "file $gdbTestExe",
    '-ex',
    'break add',
    '-ex',
    'run',
    '-ex',
    'print a',
    '-ex',
    'print b',
    '-ex',
    'backtrace'
)
Assert-OutputContains -Output $output -Pattern '\$1 = 20'
Assert-OutputContains -Output $output -Pattern '\$2 = 22'
Assert-OutputContains -Output $output -Pattern '#0'
