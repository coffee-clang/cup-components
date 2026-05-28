param(
    [Parameter(Mandatory = $true)]
    [string] $Tool
)

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

function Invoke-NativeCaptureAllowFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    Write-Host "==> $FilePath $($ArgumentList -join ' ')"
    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    $output | ForEach-Object { Write-Host $_ }

    return @{ Output = $output; ExitCode = $exitCode }
}

function Get-InfoValue {
    param([Parameter(Mandatory = $true)][string] $Key)

    $line = Get-Content "$root\info.txt" | Where-Object { $_ -like "$Key=*" } | Select-Object -Last 1
    if (-not $line) { return '' }
    return ($line -replace "^$([regex]::Escape($Key))=", '')
}

function Test-InfoBool {
    param([Parameter(Mandatory = $true)][string] $Key)
    return (Get-InfoValue $Key) -eq 'true'
}

function Show-PEImports {
    param([Parameter(Mandatory = $true)][string] $FilePath)

    Write-Host "==> PE imports for $FilePath"
    $objdump = Get-Command llvm-objdump.exe -ErrorAction SilentlyContinue
    if (-not $objdump) {
        $objdump = Get-Command objdump.exe -ErrorAction SilentlyContinue
    }

    if (-not $objdump) {
        Write-Host 'warning: objdump not available for PE import diagnostics'
        return
    }

    & $objdump.Source -p $FilePath 2>&1 | Select-String -Pattern 'DLL Name|Delay|delay' | ForEach-Object {
        Write-Host $_.Line
    }
}

function Invoke-OptionalNative {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    if (Test-Path $FilePath) {
        Invoke-Native -FilePath $FilePath -ArgumentList $ArgumentList
    } else {
        Write-Host "warning: optional executable not present: $FilePath"
    }
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

$releaseEnv = Get-Content dist/release.env
$packageBase = ($releaseEnv | Where-Object { $_ -like 'package_base=*' }) -replace '^package_base=', ''
if (-not $packageBase) { throw 'package_base not found in dist/release.env' }

Remove-Item -Recurse -Force dist/package-test -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force dist/package-test | Out-Null
Expand-Archive -Force "dist/$packageBase.zip" dist/package-test

$root = Join-Path (Resolve-Path dist/package-test) $packageBase
Get-Content "$root\info.txt"

pwsh scripts/test/package-capabilities-windows.ps1 -Root $root -Tool $Tool

$env:Path = "$root\bin;$env:SystemRoot\System32;$env:SystemRoot"

$pythonDirs = Get-ChildItem -Directory -Path (Join-Path $root 'lib') -Filter 'python*' -ErrorAction SilentlyContinue
if ($pythonDirs) {
    $pythonDir = ($pythonDirs | Select-Object -First 1).FullName
    $pythonDynloadDir = Join-Path $pythonDir 'lib-dynload'
    $pythonSitePackagesDir = Join-Path $pythonDir 'site-packages'

    $env:PYTHONHOME = $root
    $pythonPathEntries = @($pythonDir)
    if (Test-Path $pythonDynloadDir) { $pythonPathEntries += $pythonDynloadDir }
    if (Test-Path $pythonSitePackagesDir) { $pythonPathEntries += $pythonSitePackagesDir }
    $env:PYTHONPATH = ($pythonPathEntries -join ';')

    Write-Host "PYTHONHOME=$env:PYTHONHOME"
    Write-Host "PYTHONPATH=$env:PYTHONPATH"
}

$testDir = Join-Path $env:TEMP "cup-llvm-$Tool-test"
Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $testDir | Out-Null

switch ($Tool) {
    'clang' {
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\ld.lld.exe" -ArgumentList @('--version')

        $resourceOutput = Invoke-NativeCapture -FilePath "$root\bin\clang.exe" -ArgumentList @('-print-resource-dir')
        $resourceDir = ($resourceOutput | Select-Object -Last 1).ToString().Trim()
        if (-not (Test-Path $resourceDir)) {
            throw "clang resource directory does not exist: $resourceDir"
        }

        $cSource = Join-Path $testDir 'clang-test.c'
        $cObject = Join-Path $testDir 'clang-test.o'
        'int add(int a, int b) { return a + b; } int main(void) { return add(20, 22) == 42 ? 0 : 1; }' | Set-Content $cSource
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @('-fsyntax-only', $cSource)
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @('-c', $cSource, '-o', $cObject)
        Assert-FileExists $cObject

        $cppSource = Join-Path $testDir 'clang-cpp-test.cpp'
        $cppObject = Join-Path $testDir 'clang-cpp-test.o'
        'int add(int a, int b) { return a + b; } int main() { return add(20, 22) == 42 ? 0 : 1; }' | Set-Content $cppSource
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @('-fsyntax-only', $cppSource)
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @('-c', $cppSource, '-o', $cppObject)
        Assert-FileExists $cppObject

        if ((Test-InfoBool 'features.asan') -or (Test-InfoBool 'features.sanitizers')) {
            $asanSource = Join-Path $testDir 'asan-test.c'
            $asanExe = Join-Path $testDir 'asan-test.exe'
@'
#include <stdlib.h>

int main(void) {
    int *value = (int *)malloc(sizeof(int));
    free(value);
    return *value;
}
'@ | Set-Content $asanSource

            Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @(
                '-g',
                '-O0',
                '-fsanitize=address',
                $asanSource,
                '-o',
                $asanExe
            )
            Assert-FileExists $asanExe

            $oldPath = $env:Path
            $env:Path = "$root\bin;$oldPath"
            try {
                $result = Invoke-NativeCaptureAllowFailure -FilePath $asanExe
            } finally {
                $env:Path = $oldPath
            }

            if ($result.ExitCode -eq 0) {
                throw 'ASan test unexpectedly succeeded'
            }

            Assert-OutputContains -Output $result.Output -Pattern 'AddressSanitizer|heap-use-after-free'
        } else {
            Write-Host 'warning: clang sanitizer runtime not enabled; skipping ASan test'
        }
    }

    'lld' {
        Invoke-Native -FilePath "$root\bin\ld.lld.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\lld-link.exe" -ArgumentList @('--version')
        Invoke-OptionalNative -FilePath "$root\bin\wasm-ld.exe" -ArgumentList @('--version')
        Invoke-OptionalNative -FilePath "$root\bin\ld64.lld.exe" -ArgumentList @('--version')
    }

    'lldb' {
        Show-PEImports "$root\bin\lldb.exe"
        if (Test-Path "$root\bin\lldb-dap.exe") { Show-PEImports "$root\bin\lldb-dap.exe" }
        if (Test-Path "$root\bin\lldb-server.exe") { Show-PEImports "$root\bin\lldb-server.exe" }

        Invoke-Native -FilePath "$root\bin\lldb.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\lldb.exe" -ArgumentList @(
            '-b',
            '-o',
            "script import sys; print('python-ok', sys.version_info[0], sys.version_info[1]); print('executable', sys.executable); print('prefix', sys.prefix); print('path', sys.path)",
            '-o',
            'quit'
        )

        $gcc = Get-Command gcc.exe -ErrorAction SilentlyContinue
        if ($gcc) {
            $source = Join-Path $testDir 'lldb-test.c'
            $exe = Join-Path $testDir 'lldb-test.exe'
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
'@ | Set-Content $source
            Invoke-Native -FilePath $gcc.Source -ArgumentList @('-g', '-O0', '-static', $source, '-o', $exe)
            Assert-FileExists $exe
            $exeForLldb = To-ForwardSlashPath $exe
            $output = Invoke-NativeCapture -FilePath "$root\bin\lldb.exe" -ArgumentList @(
                '-b',
                '-o',
                "target create $exeForLldb",
                '-o',
                'breakpoint set --name add',
                '-o',
                'image lookup -n add',
                '-o',
                'quit'
            )
            Assert-OutputContains -Output $output -Pattern 'Breakpoint|breakpoint'
            Assert-OutputContains -Output $output -Pattern 'add'
        } else {
            Write-Host 'warning: gcc.exe not available; skipping LLDB target creation test'
            Invoke-Native -FilePath "$root\bin\lldb.exe" -ArgumentList @('-b', '-o', 'help', '-o', 'quit')
        }
    }

    'clangd' {
        Invoke-Native -FilePath "$root\bin\clangd.exe" -ArgumentList @('--version')

        $projectDir = Join-Path $testDir 'clangd-project'
        New-Item -ItemType Directory -Force $projectDir | Out-Null
        $sourcePath = Join-Path $projectDir 'main.c'
        'int main(void) { return 0; }' | Set-Content $sourcePath
        $sourcePathForJson = To-ForwardSlashPath $sourcePath
        $projectDirForJson = To-ForwardSlashPath $projectDir
        @"
[
  {
    "directory": "$projectDirForJson",
    "command": "clang -std=c11 main.c",
    "file": "$sourcePathForJson"
  }
]
"@ | Set-Content (Join-Path $projectDir 'compile_commands.json')

        $output = Invoke-NativeCapture -FilePath "$root\bin\clangd.exe" -ArgumentList @("--check=$sourcePathForJson")
        Assert-OutputContains -Output $output -Pattern 'All checks completed|Testing on source file'
    }

    'clang-format' {
        Invoke-Native -FilePath "$root\bin\clang-format.exe" -ArgumentList @('--version')

        $source = Join-Path $testDir 'format-test.c'
        'int main( void ){return 0;}' | Set-Content $source
        $output = Invoke-NativeCapture -FilePath "$root\bin\clang-format.exe" -ArgumentList @($source)
        Assert-OutputContains -Output $output -Pattern 'int main\(void\)'

        $styleSource = Join-Path $testDir 'style-test.c'
@'
int main(void) {
return 0;
}
'@ | Set-Content $styleSource
        $styleOutput = Invoke-NativeCapture -FilePath "$root\bin\clang-format.exe" -ArgumentList @(
            '-style={BasedOnStyle: LLVM, IndentWidth: 4, AllowShortFunctionsOnASingleLine: None}',
            $styleSource
        )
        Assert-OutputContains -Output $styleOutput -Pattern '    return 0;'

        $projectDir = Join-Path $testDir 'format-project'
        New-Item -ItemType Directory -Force $projectDir | Out-Null
@'
BasedOnStyle: LLVM
IndentWidth: 3
AllowShortFunctionsOnASingleLine: None
'@ | Set-Content (Join-Path $projectDir '.clang-format')
@'
int main(void) {
return 0;
}
'@ | Set-Content (Join-Path $projectDir 'main.c')

        Push-Location $projectDir
        try {
            $projectOutput = Invoke-NativeCapture -FilePath "$root\bin\clang-format.exe" -ArgumentList @('main.c')
        } finally {
            Pop-Location
        }
        Assert-OutputContains -Output $projectOutput -Pattern '   return 0;'

        $badSource = Join-Path $testDir 'bad-format.c'
        'int main( void ){return 0;}' | Set-Content $badSource
        & "$root\bin\clang-format.exe" --dry-run --Werror $badSource *> (Join-Path $testDir 'format-dryrun.txt')
        if ($LASTEXITCODE -eq 0) {
            throw 'clang-format dry-run unexpectedly succeeded on unformatted file'
        }

        Invoke-Native -FilePath "$root\bin\clang-format.exe" -ArgumentList @('--assume-filename=test.cpp', $source)
    }

    'clang-tidy' {
        Invoke-Native -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @('--version')

        $checksOutput = Invoke-NativeCapture -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @(
            '--list-checks',
            '--checks=clang-analyzer-*'
        )
        Assert-OutputContains -Output $checksOutput -Pattern 'clang-analyzer-core'

        $source = Join-Path $testDir 'tidy-test.c'
        'int main(void) { return 0; }' | Set-Content $source
        Invoke-Native -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @(
            '--checks=clang-analyzer-*',
            $source,
            '--',
            '-std=c11'
        )
    }

    default {
        throw "unsupported LLVM tool: $Tool"
    }
}
