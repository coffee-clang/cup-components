$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    Write-Host "==> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Read-InfoValue {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Key
    )

    $line = Get-Content (Join-Path $Root 'info.txt') |
        Where-Object { $_ -like "$Key=*" } |
        Select-Object -First 1
    if (-not $line) { throw "Missing GNU ld metadata field: $Key" }
    return ($line -replace "^$([regex]::Escape($Key))=", '')
}

function Assert-InfoValue {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Key,
        [Parameter(Mandatory = $true)][string] $Expected
    )

    $actual = Read-InfoValue -Root $Root -Key $Key
    if ($actual -ne $Expected) {
        throw "Unexpected GNU ld metadata: $Key=$actual; expected $Expected"
    }
}

$releaseEnv = Get-Content dist/release.env
$packageBase = ($releaseEnv | Where-Object { $_ -like 'package_base=*' }) -replace '^package_base=', ''
if (-not $packageBase) { throw 'package_base not found in dist/release.env' }

Remove-Item -Recurse -Force dist/package-test -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force dist/package-test | Out-Null
Expand-Archive -Force "dist/$packageBase.zip" dist/package-test
$root = Join-Path (Resolve-Path dist/package-test) $packageBase

Assert-InfoValue -Root $root -Key 'package.component' -Expected 'linker'
Assert-InfoValue -Root $root -Key 'package.tool' -Expected 'ld'
Assert-InfoValue -Root $root -Key 'platform.host' -Expected 'windows-x64'
Assert-InfoValue -Root $root -Key 'platform.target' -Expected 'windows-x64'
Assert-InfoValue -Root $root -Key 'source.primary.name' -Expected 'binutils'
Assert-InfoValue -Root $root -Key 'config.plugins' -Expected 'true'
Assert-InfoValue -Root $root -Key 'contents.binutils_toolbox' -Expected 'false'
Assert-InfoValue -Root $root -Key 'contents.gcc_lto_plugin' -Expected 'false'
Assert-InfoValue -Root $root -Key 'features.link' -Expected 'true'
Assert-InfoValue -Root $root -Key 'features.link_pe' -Expected 'true'

if (Get-Content (Join-Path $root 'info.txt') | Where-Object { $_ -like 'package.revision=*' }) {
    throw 'Revisionless GNU ld package unexpectedly declares package.revision'
}

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
Invoke-Native -FilePath $pwsh -ArgumentList @(
    'scripts/test/package-capabilities-windows.ps1',
    '-Root', $root,
    '-Tool', 'ld'
)

$ld = Join-Path $root 'bin\ld.exe'
if (-not (Test-Path $ld)) { throw 'GNU ld package is missing bin\ld.exe' }
Invoke-Native -FilePath $ld -ArgumentList @('--version')

$testDir = Join-Path $env:TEMP 'cup-ld-windows-test'
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null
$payload = Join-Path $testDir 'payload.bin'
$output = Join-Path $testDir 'linked.o'
Set-Content -NoNewline -Path $payload -Value 'cup-gnu-ld-functional-payload'
Invoke-Native -FilePath $ld -ArgumentList @('-r', '-b', 'binary', $payload, '-o', $output)
if (-not (Test-Path $output) -or (Get-Item $output).Length -eq 0) {
    throw 'GNU ld did not produce a relocatable output'
}

$allowed = @('ld.exe', 'ld.bfd.exe')
Get-ChildItem (Join-Path $root 'bin') -File | ForEach-Object {
    if ($allowed -contains $_.Name) { return }
    if ($_.Extension -ieq '.dll') { return }
    throw "GNU ld package exposes non-linker Binutils payload in bin/: $($_.Name)"
}

if (Get-ChildItem $root -Recurse -File -Filter 'liblto_plugin*' | Select-Object -First 1) {
    throw 'GNU ld package incorrectly owns GCC liblto_plugin'
}

Write-Host 'GNU ld Windows package tests passed'
