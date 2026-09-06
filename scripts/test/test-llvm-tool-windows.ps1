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
    $prevEap = $ErrorActionPreference
    $prevNativeEap = if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference } else { $null }
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        } else {
            "$_"
        }
    })
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    $ErrorActionPreference = $prevEap
    if ($null -ne $prevNativeEap) { $PSNativeCommandUseErrorActionPreference = $prevNativeEap }

    $output | ForEach-Object { Write-Host $_ }
    Write-Host "exit code: $exitCode"

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

function Assert-NoLlvmDevelopmentPayload {
    $forbiddenDirectories = @(
        'include\llvm', 'include\llvm-c', 'include\clang', 'include\clang-c', 'include\clang-tidy',
        'include\lld', 'include\lldb', 'include\mach-o', 'lib\cmake', 'lib64\cmake'
    )

    foreach ($relative in $forbiddenDirectories) {
        if (Test-Path (Join-Path $root $relative)) {
            throw "LLVM development payload leaked into package: $relative"
        }
    }

    foreach ($libRelative in @('lib', 'lib64')) {
        $libDir = Join-Path $root $libRelative
        if (-not (Test-Path $libDir)) { continue }

        foreach ($pattern in @(
            'libLTO.*', 'libRemarks.*', 'libclang.*', 'libclang-cpp.*'
        )) {
            $leak = Get-ChildItem -Path $libDir -File -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($leak) {
                throw "LLVM shared development API leaked into package: $($leak.FullName)"
            }
        }

        foreach ($archive in Get-ChildItem -Path $libDir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like '*.a' -or $_.Name -like '*.lib'
        }) {
            if ($archive.Name -match '^(libc\+\+|libc\+\+abi|libc\+\+experimental|libunwind)(\.a|\.lib)$' -or
                $archive.Name -like 'libclang_rt.*') {
                continue
            }
            throw "LLVM static development archive leaked into package: $($archive.FullName)"
        }
    }
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
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Output,

        [Parameter(Mandatory = $true)]
        [string] $Pattern
    )

    if ($null -eq $Output) {
        $text = ''
    } else {
        $text = (($Output | Out-String) -replace "`r", '')
    }

    if ($text -notmatch $Pattern) {
        throw "Expected output to match pattern: $Pattern"
    }
}

function To-ForwardSlashPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return $Path.Replace('\', '/')
}

function Invoke-ClangTidyHelperProbe {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $Label
    )

    $projectDir = Join-Path $testDir "tidy-helper-$Label"
    Remove-Item -Recurse -Force $projectDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $projectDir | Out-Null
    $sourcePath = Join-Path $projectDir 'main.c'
    @'
int main(void) {
    return *(int *)0;
}
'@ | Set-Content $sourcePath
    $projectJson = To-ForwardSlashPath $projectDir
    $sourceJson = To-ForwardSlashPath $sourcePath
    @"
[
  {
    "directory": "$projectJson",
    "command": "clang -std=c11 -c main.c",
    "file": "$sourceJson"
  }
]
"@ | Set-Content (Join-Path $projectDir 'compile_commands.json')

    $runOutput = Invoke-NativeCapture -FilePath (Join-Path $PackageRoot 'bin\run-clang-tidy.bat') -ArgumentList @(
        '-p', $projectDir, '-j', '1', '-checks=-*,clang-analyzer-core.NullDereference', $sourcePath
    )
    Assert-OutputContains -Output $runOutput -Pattern 'clang-analyzer-core.NullDereference'

    $diffText = @'
diff --git a/main.c b/main.c
--- a/main.c
+++ b/main.c
@@ -1,2 +1,3 @@
 int main(void) {
+    return *(int *)0;
 }
'@
    Push-Location $projectDir
    try {
        $prevEap = $ErrorActionPreference
        $prevNativeEap = if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference } else { $null }
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $diffOutput = @($diffText | & (Join-Path $PackageRoot 'bin\clang-tidy-diff.bat') `
            '-p1' '-path' $projectDir '-checks=-*,clang-analyzer-core.NullDereference' 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            })
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevNativeEap) { $PSNativeCommandUseErrorActionPreference = $prevNativeEap }
    } finally {
        Pop-Location
    }
    $diffOutput | ForEach-Object { Write-Host $_ }
    if ($exitCode -ne 0) { throw "clang-tidy-diff failed at relocation $Label with exit code $exitCode" }
    Assert-OutputContains -Output $diffOutput -Pattern 'clang-analyzer-core.NullDereference'
    Write-Host "CLANG_TIDY_RUN_HELPER_$Label=PASS"
    Write-Host "CLANG_TIDY_DIFF_HELPER_$Label=PASS"
}

function Assert-LldbPythonRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageRoot,

        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    $versionLine = Get-Content (Join-Path $PackageRoot 'info.txt') |
        Where-Object { $_ -like 'contents.python_runtime.version=*' } |
        Select-Object -Last 1
    if (-not $versionLine) {
        throw "LLDB package is missing Python runtime provenance: $PackageRoot\info.txt"
    }
    $expectedVersion = $versionLine -replace '^contents\.python_runtime\.version=', ''

    $output = Invoke-NativeCapture -FilePath (Join-Path $PackageRoot 'bin\lldb.exe') -ArgumentList @(
        '-b',
        '-o',
        'script import sys, lldb; print("python-isolated=" + str(sys.flags.isolated)); print("python-version=" + ".".join(map(str, sys.version_info[:3]))); [print("python-path=" + p) for p in sys.path]',
        '-o',
        'quit'
    )

    Assert-OutputContains -Output $output -Pattern '(?m)^python-isolated=1$'
    Assert-OutputContains -Output $output -Pattern ("(?m)^python-version=" + [regex]::Escape($expectedVersion) + '$')

    $packageFull = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    $pythonPaths = @($output | ForEach-Object { "$($_)" } | Where-Object { $_ -like 'python-path=*' })
    if ($pythonPaths.Count -eq 0) {
        throw "LLDB Python sys.path probe produced no entries at relocation $Label"
    }

    foreach ($line in $pythonPaths) {
        $path = $line -replace '^python-path=', ''
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "LLDB Python sys.path contains an ambient empty entry at relocation $Label"
        }
        $full = [IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($packageFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "LLDB Python sys.path escaped the package at relocation ${Label}: $path"
        }
    }

    Write-Host "python-package-owned=1 ($Label)"
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
    '-Tool', $Tool
)
Assert-NoLlvmDevelopmentPayload

# Capture build-runner compilers before isolating PATH. They are used only to
# create independent test inputs; packaged tools must resolve their own runtime.
$runnerClang = Get-Command clang.exe -ErrorAction SilentlyContinue
$runnerGcc = Get-Command gcc.exe -ErrorAction SilentlyContinue

# Do not let a developer/runner Python environment make LLDB appear relocatable.
Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:Path = "$root\bin;$env:SystemRoot\System32;$env:SystemRoot"

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
        $cExe = Join-Path $testDir 'clang-test.exe'
        'int add(int a, int b) { return a + b; } int main(void) { return add(20, 22) == 42 ? 0 : 1; }' | Set-Content $cSource
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @('-fsyntax-only', $cSource)
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @('-c', $cSource, '-o', $cObject)
        Assert-FileExists $cObject
        Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @('-fuse-ld=lld', $cSource, '-o', $cExe)
        Assert-FileExists $cExe
        Invoke-Native -FilePath $cExe

        $cppSource = Join-Path $testDir 'clang-cpp-test.cpp'
        $cppObject = Join-Path $testDir 'clang-cpp-test.o'
        $cppExe = Join-Path $testDir 'clang-cpp-test.exe'
        'int add(int a, int b) { return a + b; } int main() { return add(20, 22) == 42 ? 0 : 1; }' | Set-Content $cppSource
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @('-fsyntax-only', $cppSource)
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @('-c', $cppSource, '-o', $cppObject)
        Assert-FileExists $cppObject
        Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @('-fuse-ld=lld', $cppSource, '-o', $cppExe)
        Assert-FileExists $cppExe
        Invoke-Native -FilePath $cppExe

        if (Test-InfoBool 'features.cxx_runtime') {
            $libcxxExe = Join-Path $testDir 'clang-libcxx-test.exe'
            Invoke-Native -FilePath "$root\bin\clang++.exe" -ArgumentList @(
                '-stdlib=libc++', '-fuse-ld=lld', $cppSource, '-o', $libcxxExe
            )
            Assert-FileExists $libcxxExe
            Invoke-Native -FilePath $libcxxExe
        } else {
            throw 'required packaged Clang C++ runtime is not declared; libc++ test cannot run'
        }

        if (Test-InfoBool 'features.lto') {
            $ltoExe = Join-Path $testDir 'clang-lto-test.exe'
            Invoke-Native -FilePath "$root\bin\clang.exe" -ArgumentList @(
                '-flto', '-fuse-ld=lld', $cSource, '-o', $ltoExe
            )
            Assert-FileExists $ltoExe
            Invoke-Native -FilePath $ltoExe
        } else {
            throw 'required Clang LTO/LLD integration is not declared; LTO test cannot run'
        }

        if (Test-InfoBool 'features.asan') {
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
            $oldAsanOptions = $env:ASAN_OPTIONS
            $env:Path = "$root\bin;$oldPath"
            $env:ASAN_OPTIONS = "halt_on_error=1:abort_on_error=1"
            try {
                $result = Invoke-NativeCaptureAllowFailure -FilePath $asanExe
            } finally {
                $env:Path = $oldPath
                if ($null -eq $oldAsanOptions) {
                    Remove-Item Env:ASAN_OPTIONS -ErrorAction SilentlyContinue
                } else {
                    $env:ASAN_OPTIONS = $oldAsanOptions
                }
            }

            if ($result.ExitCode -eq 0) {
                throw 'ASan test unexpectedly succeeded'
            }

            $asanOutput = @($result.Output)
            if ($asanOutput.Count -eq 0) {
                Show-PEImports $asanExe
                Show-PEImports "$root\bin\libclang_rt.asan_dynamic-x86_64.dll"
                throw "ASan test failed with exit code $($result.ExitCode), but produced no console output"
            }

            Assert-OutputContains -Output $asanOutput -Pattern 'AddressSanitizer|heap-use-after-free'
        } else {
            throw 'required Clang ASan runtime is not declared; ASan test cannot run'
        }
    }

    'lld' {
        Invoke-Native -FilePath "$root\bin\ld.lld.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\lld-link.exe" -ArgumentList @('--version')
        Invoke-OptionalNative -FilePath "$root\bin\wasm-ld.exe" -ArgumentList @('--version')
        Invoke-OptionalNative -FilePath "$root\bin\ld64.lld.exe" -ArgumentList @('--version')

        if (-not $runnerClang) {
            throw 'runner clang.exe is required to produce an independent COFF object for the lld-link test'
        }
        $lldSource = Join-Path $testDir 'lld-link-test.c'
        $lldObject = Join-Path $testDir 'lld-link-test.obj'
        $lldExe = Join-Path $testDir 'lld-link-test.exe'
        'int main(void) { return 0; }' | Set-Content $lldSource
        Invoke-Native -FilePath $runnerClang.Source -ArgumentList @(
            '-target', 'x86_64-pc-windows-msvc', '-c', $lldSource, '-o', $lldObject
        )
        Assert-FileExists $lldObject
        Invoke-Native -FilePath "$root\bin\lld-link.exe" -ArgumentList @(
            '/entry:main', '/subsystem:console', '/nodefaultlib', "/out:$lldExe", $lldObject
        )
        Assert-FileExists $lldExe
    }

    'lldb' {
        Show-PEImports "$root\bin\lldb.exe"
        if (Test-Path "$root\bin\lldb-dap.exe") { Show-PEImports "$root\bin\lldb-dap.exe" }
        if (Test-Path "$root\bin\lldb-server.exe") { Show-PEImports "$root\bin\lldb-server.exe" }

        Invoke-Native -FilePath "$root\bin\lldb.exe" -ArgumentList @('--version')
        Assert-LldbPythonRuntime -PackageRoot $root -Label 'A'

        if ($runnerGcc) {
            $lldbFixtureCompiler = $runnerGcc.Source
        } elseif ($runnerClang) {
            $lldbFixtureCompiler = $runnerClang.Source
        } else {
            throw 'runner C compiler is required for the LLDB functional test'
        }

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
        Invoke-Native -FilePath $lldbFixtureCompiler -ArgumentList @('-g', '-O0', '-static', $source, '-o', $exe)
        Assert-FileExists $exe
        $exeForLldb = To-ForwardSlashPath $exe
        $output = Invoke-NativeCapture -FilePath "$root\bin\lldb.exe" -ArgumentList @(
            '-b',
            '-o',
            "target create $exeForLldb",
            '-o',
            'breakpoint set --name add',
            '-o',
            'run',
            '-o',
            'backtrace',
            '-o',
            'quit'
        )
        Assert-OutputContains -Output $output -Pattern 'Breakpoint|breakpoint'
        Assert-OutputContains -Output $output -Pattern 'add'
        Assert-OutputContains -Output $output -Pattern 'frame #0|#0'
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
        if (Test-InfoBool 'features.git_clang_format') { throw 'clang-format unexpectedly declares git-clang-format' }
        foreach ($gitHelper in @('git-clang-format', 'git-clang-format.exe', 'git-clang-format.cmd', 'git-clang-format.bat')) {
            if (Test-Path (Join-Path "$root\bin" $gitHelper)) {
                throw "clang-format retained external-Git helper: $gitHelper"
            }
        }
        if ((Get-InfoValue 'contents.python_runtime') -eq 'packaged') {
            throw 'clang-format retained Python solely for a removed Git helper'
        }
        foreach ($forbidden in @('include', 'share', 'libexec')) {
            if (Test-Path (Join-Path $root $forbidden)) { throw "clang-format retained non-runtime payload: $forbidden" }
        }

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
        foreach ($required in @(
            "$root\bin\clang-tidy.exe",
            "$root\bin\clang-apply-replacements.exe",
            "$root\bin\run-clang-tidy.bat",
            "$root\bin\clang-tidy-diff.bat",
            "$root\bin\cup-python3.exe",
            "$root\libexec\llvm-python-scripts\run-clang-tidy.py",
            "$root\libexec\llvm-python-scripts\clang-tidy-diff.py"
        )) {
            if (-not (Test-Path $required)) { throw "required clang-tidy package path missing: $required" }
        }
        if (Test-Path "$root\include") { throw 'development headers leaked into clang-tidy package' }
        if (Test-Path "$root\share") { throw 'non-deliberate share payload leaked into clang-tidy package' }
        foreach ($forbidden in @('analyze-cc', 'analyze-c++', 'intercept-cc', 'intercept-c++', 'ccc-analyzer', 'c++-analyzer')) {
            if (Test-Path (Join-Path "$root\libexec" $forbidden)) { throw "scan-build helper leaked into clang-tidy package: $forbidden" }
        }

        Invoke-Native -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @('--version')
        Invoke-Native -FilePath "$root\bin\clang-apply-replacements.exe" -ArgumentList @('--version')
        Invoke-ClangTidyHelperProbe -PackageRoot $root -Label 'A'

        $checksOutput = Invoke-NativeCapture -FilePath "$root\bin\clang-tidy.exe" -ArgumentList @(
            '--list-checks',
            '--checks=clang-analyzer-*'
        )
        Assert-OutputContains -Output $checksOutput -Pattern 'clang-analyzer-core'

        $source = Join-Path $testDir 'tidy-test.c'
        @'
#include <stddef.h>
int main(void) { return (int)sizeof(size_t); }
'@ | Set-Content $source
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

# Re-run a real operation from a copied package root. This is intentionally more
# than a path rename assertion: resource/Python/helper discovery must follow the
# relocated package without PYTHONHOME/PYTHONPATH or the original package on PATH.
$relocationParent = Join-Path $testDir 'relocation with spaces'
Remove-Item -Recurse -Force $relocationParent -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $relocationParent | Out-Null
Copy-Item -Recurse -Force $root $relocationParent
$relocatedRoot = Join-Path $relocationParent $packageBase
if (-not (Test-Path $relocatedRoot)) {
    throw "relocated package root was not created: $relocatedRoot"
}
$disabledRoot = Join-Path $testDir 'original-package-root-disabled'
Move-Item -Force $root $disabledRoot
if (Test-Path $root) {
    throw "original package root remained available during relocation: $root"
}
Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
$env:Path = "$relocatedRoot\bin;$env:SystemRoot\System32;$env:SystemRoot"

switch ($Tool) {
    'clang' {
        Invoke-Native -FilePath "$relocatedRoot\bin\clang.exe" -ArgumentList @('--version')
        $resourceOutput = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\clang.exe" -ArgumentList @('-print-resource-dir')
        $resourceDir = ($resourceOutput | Select-Object -Last 1).ToString().Trim()
        if (-not (Test-Path $resourceDir)) {
            throw "relocated clang resource directory does not exist: $resourceDir"
        }
        $resourceFull = [IO.Path]::GetFullPath($resourceDir)
        $relocatedFull = [IO.Path]::GetFullPath($relocatedRoot).TrimEnd('\') + '\'
        if (-not $resourceFull.StartsWith($relocatedFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "relocated clang still resolves resources outside its package: $resourceDir"
        }
        $relocatedExe = Join-Path $testDir 'relocated-clang-test.exe'
        Invoke-Native -FilePath "$relocatedRoot\bin\clang.exe" -ArgumentList @(
            '-fuse-ld=lld', $cSource, '-o', $relocatedExe
        )
        Assert-FileExists $relocatedExe
        Invoke-Native -FilePath $relocatedExe
    }
    'lld' {
        $relocatedExe = Join-Path $testDir 'relocated-lld-link-test.exe'
        Invoke-Native -FilePath "$relocatedRoot\bin\lld-link.exe" -ArgumentList @(
            '/entry:main', '/subsystem:console', '/nodefaultlib', "/out:$relocatedExe", $lldObject
        )
        Assert-FileExists $relocatedExe
    }
    'lldb' {
        Assert-LldbPythonRuntime -PackageRoot $relocatedRoot -Label 'B'
        $output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\lldb.exe" -ArgumentList @(
            '-b', '-o', "target create $exeForLldb", '-o', 'breakpoint set --name add',
            '-o', 'run', '-o', 'backtrace', '-o', 'quit'
        )
        Assert-OutputContains -Output $output -Pattern 'add'
        Assert-OutputContains -Output $output -Pattern 'frame #0|#0'
    }
    'clangd' {
        $output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\clangd.exe" -ArgumentList @("--check=$sourcePathForJson")
        Assert-OutputContains -Output $output -Pattern 'All checks completed|Testing on source file'
    }
    'clang-format' {
        $output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\clang-format.exe" -ArgumentList @($source)
        Assert-OutputContains -Output $output -Pattern 'int main\(void\)'
    }
    'clang-tidy' {
        Invoke-Native -FilePath "$relocatedRoot\bin\clang-tidy.exe" -ArgumentList @(
            '--checks=clang-analyzer-*', $source, '--', '-std=c11'
        )
        Invoke-Native -FilePath "$relocatedRoot\bin\clang-apply-replacements.exe" -ArgumentList @('--version')
        Invoke-ClangTidyHelperProbe -PackageRoot $relocatedRoot -Label 'B-spaces'
    }
}
