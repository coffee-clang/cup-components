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

function Assert-FileMissing {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (Test-Path $Path) {
        throw "Unexpected file is present: $Path"
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

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
Invoke-Native -FilePath $pwsh -ArgumentList @(
    'scripts/test/package-capabilities-windows.ps1',
    '-Root', $root,
    '-Tool', 'gdb'
)

if (-not (Test-FeatureEnabled -Root $root -Key 'features.tui') -or
    -not (Test-FeatureEnabled -Root $root -Key 'config.tui')) {
    throw 'required GDB TUI capability is not fully declared in info.txt'
}
if (-not (Test-FeatureEnabled -Root $root -Key 'features.gdbserver') -or
    -not (Test-FeatureEnabled -Root $root -Key 'features.remote_debugging')) {
    throw 'required GDB remote-debugging capability is not fully declared in info.txt'
}
Assert-FileMissing (Join-Path $root 'bin\lldb._pth')
Assert-FileMissing (Join-Path $root 'bin\lldb-dap._pth')

$objdump = (Get-Command objdump.exe -ErrorAction Stop).Source
$gdbSections = Invoke-NativeCapture -FilePath $objdump -ArgumentList @('-h', "$root\bin\gdb.exe")
if (($gdbSections | Out-String) -match '(?m)\.debug_') {
    throw 'GDB Windows executable still contains debug-only sections after package stripping'
}

foreach ($developmentPath in @('include', 'lib\cmake', 'lib64\cmake')) {
    if (Test-Path (Join-Path $root $developmentPath)) {
        throw "GDB development payload leaked into Windows package: $developmentPath"
    }
}
$developmentArchives = Get-ChildItem -Path $root -Recurse -File | Where-Object {
    $_.Extension -in @('.a', '.la')
}
if ($developmentArchives) {
    throw "GDB static/libtool development payload leaked into Windows package: $($developmentArchives.FullName -join ', ')"
}

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

Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:Path = "$root\bin;$env:SystemRoot\System32;$env:SystemRoot"

Invoke-Native -FilePath "$root\bin\gdb.exe" -ArgumentList @('--version')
$configurationOutput = Invoke-NativeCapture -FilePath "$root\bin\gdb.exe" -ArgumentList @('--configuration')
Assert-OutputContains -Output $configurationOutput -Pattern '--enable-tui'
Invoke-Native -FilePath "$root\bin\gdbserver.exe" -ArgumentList @('--version')
$tuiOutput = Invoke-NativeCapture -FilePath "$root\bin\gdb.exe" -ArgumentList @('-q', '-batch', '-ex', 'help tui')
Assert-OutputContains -Output $tuiOutput -Pattern '(?im)text user interface|^tui\s+--'
if (($tuiOutput | Out-String) -match 'Undefined command') {
    throw 'packaged GDB does not provide the declared TUI command set'
}

# Python is a major user-facing GDB capability when declared by the package.
# We intentionally do not assert every configure-time library from info.txt.
if (-not (Test-FeatureEnabled -Root $root -Key 'features.python') -or
    -not (Test-FeatureEnabled -Root $root -Key 'config.python') -or
    -not (Test-FeatureEnabled -Root $root -Key 'contents.uses_python')) {
    throw 'required GDB Python capability is not fully declared in info.txt'
}
$output = Invoke-NativeCapture -FilePath "$root\bin\gdb.exe" -ArgumentList @(
    '-q',
    '-batch',
    '-ex',
    'python import sys, gdb; print("python-ok", sys.version_info[0], sys.version_info[1])'
)
Assert-OutputContains -Output $output -Pattern 'python-ok'

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

# Exercise the packaged gdbserver over loopback; no external network is used.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$remotePort = ([Net.IPEndPoint] $listener.LocalEndpoint).Port
$listener.Stop()
$serverOut = Join-Path $testDir 'gdbserver.out'
$serverErr = Join-Path $testDir 'gdbserver.err'
$server = Start-Process -FilePath "$root\bin\gdbserver.exe" `
    -ArgumentList @("127.0.0.1:$remotePort", "`"$testExe`"") `
    -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -PassThru -NoNewWindow
try {
    $serverReady = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($server.HasExited) { break }
        $serverText = @()
        if (Test-Path $serverOut) { $serverText += Get-Content $serverOut }
        if (Test-Path $serverErr) { $serverText += Get-Content $serverErr }
        if (($serverText | Out-String) -match '(?i)listening on port') {
            $serverReady = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $serverReady) {
        throw 'packaged gdbserver did not reach loopback listening state'
    }
    $remoteOutput = Invoke-NativeCapture -FilePath "$root\bin\gdb.exe" -ArgumentList @(
        '-q', '-batch',
        '-ex', "file $gdbTestExe",
        '-ex', "target remote 127.0.0.1:$remotePort",
        '-ex', 'break add',
        '-ex', 'continue',
        '-ex', 'print a',
        '-ex', 'print b',
        '-ex', 'backtrace'
    )
    Assert-OutputContains -Output $remoteOutput -Pattern '\$1 = 20'
    Assert-OutputContains -Output $remoteOutput -Pattern '\$2 = 22'
    Assert-OutputContains -Output $remoteOutput -Pattern '#0'
}
finally {
    if (-not $server.HasExited) { $server.Kill() }
    $server.WaitForExit()
    if (Test-Path $serverOut) { Get-Content $serverOut | ForEach-Object { Write-Host $_ } }
    if (Test-Path $serverErr) { Get-Content $serverErr | ForEach-Object { Write-Host $_ } }
}

$relocationParent = Join-Path $testDir 'relocated'
Remove-Item -Recurse -Force $relocationParent -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $relocationParent | Out-Null
Copy-Item -Recurse -Force $root $relocationParent
$relocatedRoot = Join-Path $relocationParent $packageBase
Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:Path = "$relocatedRoot\bin;$env:SystemRoot\System32;$env:SystemRoot"

Invoke-Native -FilePath "$relocatedRoot\bin\gdb.exe" -ArgumentList @('--version')
Invoke-Native -FilePath "$relocatedRoot\bin\gdbserver.exe" -ArgumentList @('--version')
$relocatedTuiOutput = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\gdb.exe" -ArgumentList @('-q', '-batch', '-ex', 'help tui')
Assert-OutputContains -Output $relocatedTuiOutput -Pattern '(?im)text user interface|^tui\s+--'
$output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\gdb.exe" -ArgumentList @(
    '-q', '-batch', '-ex', 'python import sys, gdb; print("python-reloc-ok", sys.version_info[0], sys.version_info[1])'
)
Assert-OutputContains -Output $output -Pattern 'python-reloc-ok'
$output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\gdb.exe" -ArgumentList @(
    '-q', '-batch', '-ex', "file $gdbTestExe", '-ex', 'break add', '-ex', 'run', '-ex', 'backtrace'
)
Assert-OutputContains -Output $output -Pattern '#0'
