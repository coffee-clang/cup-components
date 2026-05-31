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


function To-ForwardSlashPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return $Path.Replace('\', '/')
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

function Assert-NoNativeWindowsPrefixedBinutilsDuplicates {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $targetTriple = Read-InfoValue -Root $Root -Key 'platform.target_triple'
    $hostPlatform = Read-InfoValue -Root $Root -Key 'platform.host'
    $targetPlatform = Read-InfoValue -Root $Root -Key 'platform.target'

    if ($hostPlatform -ne 'windows-x64' -or $targetPlatform -ne 'windows-x64') {
        return
    }

    if (-not $targetTriple) {
        throw 'platform.target_triple is missing from info.txt'
    }

    $binDir = Join-Path $Root 'bin'
    $targetBinDir = Join-Path $Root (Join-Path $targetTriple 'bin')
    $duplicateTools = @(
        'as', 'ld', 'ld.bfd', 'ar', 'ranlib', 'strip', 'dlltool', 'dllwrap',
        'windres', 'windmc', 'nm', 'objdump', 'objcopy', 'readelf', 'size',
        'strings', 'addr2line', 'c++filt', 'elfedit', 'gprof'
    )

    $duplicates = @()

    foreach ($tool in $duplicateTools) {
        $prefixed = Join-Path $binDir "$targetTriple-$tool.exe"
        $plain = Join-Path $binDir "$tool.exe"
        $targetLayout = Join-Path $targetBinDir "$tool.exe"

        if ((Test-Path $prefixed) -and ((Test-Path $plain) -or (Test-Path $targetLayout))) {
            $duplicates += $prefixed
        }
    }

    if ($duplicates.Count -gt 0) {
        $message = "Native Windows GCC package contains duplicate target-prefixed Binutils in bin/:`n" + ($duplicates -join "`n")
        throw $message
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

pwsh scripts/test/package-capabilities-windows.ps1 -Root $root -Tool 'gcc'
Assert-NoNativeWindowsPrefixedBinutilsDuplicates -Root $root

$env:Path = "$root\bin;$env:SystemRoot\System32;$env:SystemRoot"

$testDir = Join-Path $env:TEMP 'cup-gcc-windows-test'
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null
$cSource = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-c-test.c')
$cExe = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-c-test.exe')
$cppSource = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-cpp-test.cpp')
$cppExe = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-cpp-test.exe')
$pthreadSource = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-pthread-test.c')
$pthreadExe = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-pthread-test.exe')
$ltoSource = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-lto-test.c')
$ltoExe = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-lto-test.exe')
$openmpSource = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-openmp-test.c')
$openmpExe = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-openmp-test.exe')
$sanitizerSource = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-sanitizer-test.c')
$sanitizerExe = To-ForwardSlashPath (Join-Path $testDir 'cup-gcc-windows-sanitizer-test.exe')


Invoke-Native -FilePath "$root\bin\gcc.exe" -ArgumentList @('--version')
Invoke-Native -FilePath "$root\bin\g++.exe" -ArgumentList @('--version')
Invoke-Native -FilePath "$root\bin\x86_64-w64-mingw32-gcc.exe" -ArgumentList @('--version')
Invoke-Native -FilePath "$root\bin\x86_64-w64-mingw32-g++.exe" -ArgumentList @('--version')
Invoke-Native -FilePath "$root\bin\as.exe" -ArgumentList @('--version')
Invoke-Native -FilePath "$root\bin\ld.exe" -ArgumentList @('--version')

@'
#include <stdio.h>

int main(void) {
    printf("hello gcc windows c\n");
    return 0;
}
'@ | Set-Content $cSource
Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
    '-static',
    $cSource,
    '-o',
    $cExe
)
Assert-FileExists $cExe
$output = Invoke-NativeCapture -FilePath $cExe
Assert-OutputContains -Output $output -Pattern 'hello gcc windows c'

@'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
'@ | Set-Content $cppSource
Invoke-NativeCapture -FilePath "$root\bin\g++.exe" -ArgumentList @(
    '-static',
    $cppSource,
    '-o',
    $cppExe
)
Assert-FileExists $cppExe
$output = Invoke-NativeCapture -FilePath $cppExe
Assert-OutputContains -Output $output -Pattern '42'

@'
#include <pthread.h>
#include <stdio.h>

static void *worker(void *arg) {
    return arg;
}

int main(void) {
    pthread_t thread;
    void *result = 0;

    if (pthread_create(&thread, 0, worker, (void *)42) != 0) {
        return 1;
    }

    if (pthread_join(thread, &result) != 0) {
        return 1;
    }

    printf("pthread %ld\n", (long)result);
    return result == (void *)42 ? 0 : 1;
}
'@ | Set-Content $pthreadSource
Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
    '-static',
    $pthreadSource,
    '-o',
    $pthreadExe,
    '-pthread'
)
Assert-FileExists $pthreadExe
$output = Invoke-NativeCapture -FilePath $pthreadExe
Assert-OutputContains -Output $output -Pattern 'pthread 42'

@'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
'@ | Set-Content $ltoSource
Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
    '-static',
    '-flto',
    $ltoSource,
    '-o',
    $ltoExe
)
Assert-FileExists $ltoExe
Invoke-Native -FilePath $ltoExe

if (Test-FeatureEnabled -Root $root -Key 'features.openmp') {
    Write-Host 'optional feature enabled: OpenMP'
    @'
#include <omp.h>
#include <stdio.h>

int main(void) {
    int n = 0;
#pragma omp parallel reduction(+:n)
    n += 1;
    printf("openmp %d\n", n);
    return n > 0 ? 0 : 1;
}
'@ | Set-Content $openmpSource
    Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
        '-static',
        '-fopenmp',
        $openmpSource,
        '-o',
        $openmpExe
    )
    Assert-FileExists $openmpExe
    $output = Invoke-NativeCapture -FilePath $openmpExe
    Assert-OutputContains -Output $output -Pattern 'openmp'
} else {
    Write-Host 'optional feature not enabled: OpenMP'
}

if (Test-FeatureEnabled -Root $root -Key 'features.sanitizers') {
    Write-Host 'optional feature enabled: sanitizers'
    @'
int main(void) {
    int x = 1;
    return x == 1 ? 0 : 1;
}
'@ | Set-Content $sanitizerSource
    Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
        '-fsanitize=undefined',
        $sanitizerSource,
        '-o',
        $sanitizerExe
    )
    Assert-FileExists $sanitizerExe
} else {
    Write-Host 'optional feature not enabled: sanitizers'
}
