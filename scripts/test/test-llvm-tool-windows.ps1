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

$releaseEnv = Get-Content dist/release.env
$packageBase = ($releaseEnv | Where-Object { $_ -like 'package_base=*' }) -replace '^package_base=', ''
if (-not $packageBase) { throw 'package_base not found in dist/release.env' }

Remove-Item -Recurse -Force dist/package-test -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force dist/package-test | Out-Null
Expand-Archive -Force "dist/$packageBase.zip" dist/package-test

$root = Join-Path (Resolve-Path dist/package-test) $packageBase
Get-Content "$root\info.txt"

$env:Path = "$root\bin;$env:SystemRoot\System32;$env:SystemRoot"

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

        'int add(int a, int b) { return a + b; } int main(void) { return add(20, 22) == 42 ? 0 : 1; }' | Set-Content "$env:TEMP\cup-clang-test.c"
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @(
            '-fsyntax-only',
            "$env:TEMP\cup-clang-test.c"
        )
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @(
            '-c',
            "$env:TEMP\cup-clang-test.c",
            '-o',
            "$env:TEMP\cup-clang-test.o"
        )
        Assert-FileExists "$env:TEMP\cup-clang-test.o"

        'int add(int a, int b) { return a + b; } int main() { return add(20, 22) == 42 ? 0 : 1; }' | Set-Content "$env:TEMP\cup-clang-cpp-test.cpp"
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @(
            '-fsyntax-only',
            "$env:TEMP\cup-clang-cpp-test.cpp"
        )
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @(
            '-c',
            "$env:TEMP\cup-clang-cpp-test.cpp",
            '-o',
            "$env:TEMP\cup-clang-cpp-test.o"
        )
        Assert-FileExists "$env:TEMP\cup-clang-cpp-test.o"
    }

    'lld' {
        Invoke-Native -FilePath "$root\bin\ld.lld.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\lld-link.exe" -ArgumentList @('--version')
        Invoke-OptionalNative -FilePath "$root\bin\wasm-ld.exe" -ArgumentList @('--version')
        Invoke-OptionalNative -FilePath "$root\bin\ld64.lld.exe" -ArgumentList @('--version')
    }

    'lldb' {
        Invoke-Native -FilePath "$root\bin\lldb.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\lldb.exe" -ArgumentList @(
            '-b',
            '-o',
            "script import sys; print('python-ok', sys.version_info[0], sys.version_info[1])",
            '-o',
            'quit'
        )
        Invoke-Native -FilePath "$root\bin\lldb.exe" -ArgumentList @('-b', '-o', 'help', '-o', 'quit')
    }

    'clangd' {
        Invoke-Native -FilePath "$root\bin\clangd.exe" -ArgumentList @('--version')

        $projectDir = Join-Path $env:TEMP 'cup-clangd-project'
        Remove-Item -Recurse -Force $projectDir -ErrorAction SilentlyContinue
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

        $source = Join-Path $env:TEMP 'cup-format-test.c'
        'int main( void ){return 0;}' | Set-Content $source
        $output = Invoke-NativeCapture -FilePath "$root\bin\clang-format.exe" -ArgumentList @($source)
        Assert-OutputContains -Output $output -Pattern 'int main\(void\)'

        $styleSource = Join-Path $env:TEMP 'cup-format-style-test.c'
@'
int main(void) {
return 0;
}
'@ | Set-Content $styleSource
        $styleOutput = Invoke-NativeCapture -FilePath "$root\bin\clang-format.exe" -ArgumentList @(
            '-style={BasedOnStyle: LLVM, IndentWidth: 4}',
            $styleSource
        )
        Assert-OutputContains -Output $styleOutput -Pattern '    return 0;'

        $projectDir = Join-Path $env:TEMP 'cup-format-project'
        Remove-Item -Recurse -Force $projectDir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $projectDir | Out-Null
@'
BasedOnStyle: LLVM
IndentWidth: 3
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

        $badSource = Join-Path $env:TEMP 'cup-format-bad.c'
        'int main( void ){return 0;}' | Set-Content $badSource
        & "$root\bin\clang-format.exe" --dry-run --Werror $badSource *> (Join-Path $env:TEMP 'cup-format-dryrun.txt')
        if ($LASTEXITCODE -eq 0) {
            throw 'clang-format dry-run unexpectedly succeeded on unformatted file'
        }

        Invoke-Native -FilePath "$root\bin\clang-format.exe" -ArgumentList @(
            '--assume-filename=test.cpp',
            $source
        )
    }

    'clang-tidy' {
        Invoke-Native -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @('--version')

        $checksOutput = Invoke-NativeCapture -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @(
            '--list-checks',
            '-checks=clang-analyzer-*'
        )
        Assert-OutputContains -Output $checksOutput -Pattern 'clang-analyzer-core'

        'int main(void) { return 0; }' | Set-Content "$env:TEMP\cup-tidy-test.c"
        Invoke-Native -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @(
            '-checks=clang-analyzer-*',
            "$env:TEMP\cup-tidy-test.c",
            '--',
            '-std=c11'
        )
    }

    default {
        throw "unsupported LLVM tool: $Tool"
    }
}
