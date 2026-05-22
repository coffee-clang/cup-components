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

$releaseEnv = Get-Content dist/release.env
$packageBase = ($releaseEnv | Where-Object { $_ -like 'package_base=*' }) -replace '^package_base=', ''
if (-not $packageBase) { throw 'package_base not found in dist/release.env' }

Remove-Item -Recurse -Force dist/package-test -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force dist/package-test | Out-Null
Expand-Archive -Force "dist/$packageBase.zip" dist/package-test

$root = Join-Path (Resolve-Path dist/package-test) $packageBase
Get-Content "$root\info.txt"

$env:Path = "$root\bin;$env:SystemRoot\System32;$env:SystemRoot"

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
'@ | Set-Content "$env:TEMP\cup-gcc-windows-c-test.c"
Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
    '-static',
    "$env:TEMP\cup-gcc-windows-c-test.c",
    '-o',
    "$env:TEMP\cup-gcc-windows-c-test.exe"
)
Assert-FileExists "$env:TEMP\cup-gcc-windows-c-test.exe"
$output = Invoke-NativeCapture -FilePath "$env:TEMP\cup-gcc-windows-c-test.exe"
Assert-OutputContains -Output $output -Pattern 'hello gcc windows c'

@'
#include <iostream>
#include <vector>

int main() {
    std::vector<int> values = {20, 22};
    std::cout << (values[0] + values[1]) << "\n";
    return 0;
}
'@ | Set-Content "$env:TEMP\cup-gcc-windows-cpp-test.cpp"
Invoke-NativeCapture -FilePath "$root\bin\g++.exe" -ArgumentList @(
    '-static',
    "$env:TEMP\cup-gcc-windows-cpp-test.cpp",
    '-o',
    "$env:TEMP\cup-gcc-windows-cpp-test.exe"
)
Assert-FileExists "$env:TEMP\cup-gcc-windows-cpp-test.exe"
$output = Invoke-NativeCapture -FilePath "$env:TEMP\cup-gcc-windows-cpp-test.exe"
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
'@ | Set-Content "$env:TEMP\cup-gcc-windows-pthread-test.c"
Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
    '-static',
    "$env:TEMP\cup-gcc-windows-pthread-test.c",
    '-o',
    "$env:TEMP\cup-gcc-windows-pthread-test.exe",
    '-pthread'
)
Assert-FileExists "$env:TEMP\cup-gcc-windows-pthread-test.exe"
$output = Invoke-NativeCapture -FilePath "$env:TEMP\cup-gcc-windows-pthread-test.exe"
Assert-OutputContains -Output $output -Pattern 'pthread 42'

@'
static int add(int a, int b) {
    return a + b;
}

int main(void) {
    return add(20, 22) == 42 ? 0 : 1;
}
'@ | Set-Content "$env:TEMP\cup-gcc-windows-lto-test.c"
Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
    '-static',
    '-flto',
    "$env:TEMP\cup-gcc-windows-lto-test.c",
    '-o',
    "$env:TEMP\cup-gcc-windows-lto-test.exe"
)
Assert-FileExists "$env:TEMP\cup-gcc-windows-lto-test.exe"
Invoke-Native -FilePath "$env:TEMP\cup-gcc-windows-lto-test.exe"

if (Test-FeatureEnabled -Root $root -Key 'contents.openmp') {
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
'@ | Set-Content "$env:TEMP\cup-gcc-windows-openmp-test.c"
    Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
        '-static',
        '-fopenmp',
        "$env:TEMP\cup-gcc-windows-openmp-test.c",
        '-o',
        "$env:TEMP\cup-gcc-windows-openmp-test.exe"
    )
    Assert-FileExists "$env:TEMP\cup-gcc-windows-openmp-test.exe"
    $output = Invoke-NativeCapture -FilePath "$env:TEMP\cup-gcc-windows-openmp-test.exe"
    Assert-OutputContains -Output $output -Pattern 'openmp'
} else {
    Write-Host 'optional feature not enabled: OpenMP'
}

if (Test-FeatureEnabled -Root $root -Key 'contents.sanitizers') {
    Write-Host 'optional feature enabled: sanitizers'
    @'
int main(void) {
    int x = 1;
    return x == 1 ? 0 : 1;
}
'@ | Set-Content "$env:TEMP\cup-gcc-windows-sanitizer-test.c"
    Invoke-NativeCapture -FilePath "$root\bin\gcc.exe" -ArgumentList @(
        '-fsanitize=undefined',
        "$env:TEMP\cup-gcc-windows-sanitizer-test.c",
        '-o',
        "$env:TEMP\cup-gcc-windows-sanitizer-test.exe"
    )
    Assert-FileExists "$env:TEMP\cup-gcc-windows-sanitizer-test.exe"
} else {
    Write-Host 'optional feature not enabled: sanitizers'
}
