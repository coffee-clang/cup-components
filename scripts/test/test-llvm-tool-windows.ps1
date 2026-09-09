param(
    [Parameter(Mandatory = $true)]
    [string] $Tool
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

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

    $line = $script:InfoLines | Where-Object { $_ -like "$Key=*" } | Select-Object -Last 1
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

    foreach ($pattern in @(
        'libLTO.dll', 'libLTO-*.dll', 'libLTO.*.dll',
        'libRemarks.dll', 'libRemarks-*.dll', 'libRemarks.*.dll',
        'libclang.dll', 'libclang-*.dll', 'libclang.*.dll',
        'libclang-cpp.dll', 'libclang-cpp-*.dll', 'libclang-cpp.*.dll',
        'libClangdXPCLib.dll', 'libClangdXPCLib-*.dll', 'libClangdXPCLib.*.dll'
    )) {
        $leak = Get-ChildItem -Path (Join-Path $root 'bin') -File -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($leak) {
            throw "LLVM shared development API leaked into package: $($leak.FullName)"
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
        '-p', $projectDir, '-j', '1', '-checks=-*,clang-analyzer-core.NullDereference', 'main[.]c$'
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

function Assert-FileMagic {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Hex
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    $needed = [int]($Hex.Length / 2)
    if ($bytes.Length -lt $needed) { throw "File is too short for magic check: $Path" }
    $actual = -join ($bytes[0..($needed - 1)] | ForEach-Object { $_.ToString('x2') })
    if ($actual -ne $Hex.ToLowerInvariant()) {
        throw "Unexpected file magic for ${Path}: $actual (expected $Hex)"
    }
}

function Invoke-LldNativeProbe {
    param(
        [Parameter(Mandatory = $true)][string] $PackageRoot,
        [Parameter(Mandatory = $true)][string] $Label
    )
    if (-not (Test-InfoBool 'features.link_coff')) { throw 'Windows LLD does not declare native COFF linking' }
    foreach ($feature in @('link_elf', 'link_wasm', 'link_macho')) {
        if (Test-InfoBool "features.$feature") { throw "Windows LLD over-declares $feature" }
    }
    Invoke-Native -FilePath "$PackageRoot\bin\ld.lld.exe" -ArgumentList @('--version')
    Invoke-Native -FilePath "$PackageRoot\bin\lld-link.exe" -ArgumentList @('--version')
    Invoke-OptionalNative -FilePath "$PackageRoot\bin\wasm-ld.exe" -ArgumentList @('--version')
    Invoke-OptionalNative -FilePath "$PackageRoot\bin\ld64.lld.exe" -ArgumentList @('--version')

    if (-not $runnerClang) { throw 'runner clang.exe is required to produce an independent COFF object for the LLD test' }
    $work = Join-Path $testDir "lld-native-$Label"
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    $source = Join-Path $work 'main.c'
    $object = Join-Path $work 'main.obj'
    $exe = Join-Path $work 'lld-test.exe'
    'int main(void) { return 0; }' | Set-Content $source
    Invoke-Native -FilePath $runnerClang.Source -ArgumentList @(
        '-target', 'x86_64-pc-windows-msvc', '-c', $source, '-o', $object
    )
    Assert-FileExists $object
    Invoke-Native -FilePath "$PackageRoot\bin\lld-link.exe" -ArgumentList @(
        '/entry:main', '/subsystem:console', '/nodefaultlib', "/out:$exe", $object
    )
    Assert-FileExists $exe
    Assert-FileMagic -Path $exe -Hex '4d5a'
    Write-Host "LLD_NATIVE_$Label=PASS"
}

function Invoke-ClangAsanProbe {
    param([string] $PackageRoot, [string] $Label)
    if (-not (Test-InfoBool 'features.asan')) { throw 'required Clang ASan capability is not declared' }
    $work = Join-Path $testDir "clang-asan-$Label"
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    $source = Join-Path $work 'asan.c'
    $exe = Join-Path $work 'asan.exe'
    @'
#include <stdlib.h>
int main(void) { int *p=(int*)malloc(sizeof(int)); free(p); return *p; }
'@ | Set-Content $source
    Invoke-Native -FilePath "$PackageRoot\bin\clang.exe" -ArgumentList @('-g', '-O0', '-fsanitize=address', $source, '-o', $exe)
    $old = $env:ASAN_OPTIONS
    $env:ASAN_OPTIONS = 'abort_on_error=0:detect_leaks=0'
    try { $result = Invoke-NativeCaptureAllowFailure -FilePath $exe } finally { $env:ASAN_OPTIONS = $old }
    if ($result.ExitCode -eq 0) { throw "ASan test unexpectedly succeeded at relocation $Label" }
    Assert-OutputContains -Output $result.Output -Pattern 'AddressSanitizer|heap-use-after-free'
    Write-Host "CLANG_ASAN_$Label=PASS"
}

function Invoke-ClangUbsanProbe {
    param([string] $PackageRoot, [string] $Label)
    if (-not (Test-InfoBool 'features.ubsan')) { throw 'required Clang UBSan capability is not declared' }
    $work = Join-Path $testDir "clang-ubsan-$Label"
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    $source = Join-Path $work 'ubsan.c'
    $exe = Join-Path $work 'ubsan.exe'
    @'
#include <limits.h>
int main(void) { volatile int value=INT_MAX; return value + 1; }
'@ | Set-Content $source
    Invoke-Native -FilePath "$PackageRoot\bin\clang.exe" -ArgumentList @('-g', '-O0', '-fsanitize=undefined', '-fno-sanitize-recover=undefined', $source, '-o', $exe)
    $result = Invoke-NativeCaptureAllowFailure -FilePath $exe
    if ($result.ExitCode -eq 0) { throw "UBSan test unexpectedly succeeded at relocation $Label" }
    Assert-OutputContains -Output $result.Output -Pattern 'runtime error:.*signed integer overflow|UndefinedBehaviorSanitizer'
    Write-Host "CLANG_UBSAN_$Label=PASS"
}

function Invoke-ClangProfileProbe {
    param([string] $PackageRoot, [string] $Label)
    if (-not (Test-InfoBool 'features.profile_runtime')) { throw 'required Clang profile-runtime capability is not declared' }
    $work = Join-Path $testDir "clang-profile-$Label"
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    $source = Join-Path $work 'profile.c'
    $exe = Join-Path $work 'profile.exe'
    $profile = Join-Path $work 'cup-profile.profraw'
    'int main(void) { return 0; }' | Set-Content $source
    Invoke-Native -FilePath "$PackageRoot\bin\clang.exe" -ArgumentList @('-O0', '-fprofile-instr-generate', $source, '-o', $exe)
    $old = $env:LLVM_PROFILE_FILE
    $env:LLVM_PROFILE_FILE = $profile
    try { Invoke-Native -FilePath $exe } finally { $env:LLVM_PROFILE_FILE = $old }
    if (-not (Test-Path $profile) -or (Get-Item $profile).Length -eq 0) { throw "profile runtime did not write non-empty profraw at relocation $Label" }
    Write-Host "CLANG_PROFILE_RUNTIME_$Label=PASS"
}

function Invoke-ClangTidyReplacementsProbe {
    param([string] $PackageRoot, [string] $Label)
    if (-not (Test-InfoBool 'features.apply_replacements')) { throw 'clang-tidy apply-replacements capability is not declared' }
    $work = Join-Path $testDir "tidy-replacements-$Label"
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    $source = Join-Path $work 'main.c'
    $fixes = Join-Path $work 'fixes.yaml'
@'
int cup_tidy_value(int value) {
    if (value)
        return 42;
    return 0;
}
'@ | Set-Content $source
    Invoke-Native -FilePath "$PackageRoot\bin\clang-tidy.exe" -ArgumentList @(
        '-checks=-*,readability-braces-around-statements', "--export-fixes=$fixes", $source, '--', '-std=c11'
    )
    if (-not (Test-Path $fixes)) { throw "clang-tidy did not export fixes at relocation $Label" }
    if ((Get-Content $fixes -Raw) -notmatch 'Replacements:') { throw "clang-tidy fixes file has no replacements at relocation $Label" }
    Invoke-Native -FilePath "$PackageRoot\bin\clang-apply-replacements.exe" -ArgumentList @($work)
    if ((Get-Content $source -Raw) -notmatch 'if \(value\)\s*\{') { throw "clang-apply-replacements did not apply exported fix at relocation $Label" }
    Write-Host "CLANG_TIDY_APPLY_REPLACEMENTS_$Label=PASS"
}

function Start-FramedProcess {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [string] $WorkingDirectory = ''
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($arg in $ArgumentList) { [void]$psi.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start framed process: $FilePath" }
    $script:FramedPending = [Collections.Generic.List[object]]::new()
    return $process
}

function Send-FramedJson {
    param([Diagnostics.Process] $Process, [object] $Message)
    $body = $Message | ConvertTo-Json -Compress -Depth 20
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
    $headerBytes = [Text.Encoding]::ASCII.GetBytes("Content-Length: $($bodyBytes.Length)`r`n`r`n")
    $stream = $Process.StandardInput.BaseStream
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Flush()
}

function Read-FramedJson {
    param([Diagnostics.Process] $Process, [int] $TimeoutMilliseconds = 15000)
    $stream = $Process.StandardOutput.BaseStream
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    $header = [Collections.Generic.List[byte]]::new()
    $one = New-Object byte[] 1
    while ($true) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remaining -le 1 -and [DateTime]::UtcNow -ge $deadline) { throw 'framed protocol header timeout' }
        $task = $stream.ReadAsync($one, 0, 1)
        if (-not $task.Wait($remaining)) { throw 'framed protocol header timeout' }
        if ($task.Result -eq 0) { throw 'framed protocol EOF while reading header' }
        $header.Add($one[0])
        $n = $header.Count
        if ($n -ge 4 -and $header[$n-4] -eq 13 -and $header[$n-3] -eq 10 -and $header[$n-2] -eq 13 -and $header[$n-1] -eq 10) { break }
        if ($n -gt 8192) { throw 'framed protocol header too large' }
    }
    $headerText = [Text.Encoding]::ASCII.GetString($header.ToArray())
    if ($headerText -notmatch '(?im)^Content-Length:\s*([0-9]+)\s*$') { throw "framed protocol missing Content-Length: $headerText" }
    $length = [int]$Matches[1]
    $body = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($remaining -le 1 -and [DateTime]::UtcNow -ge $deadline) { throw 'framed protocol body timeout' }
        $task = $stream.ReadAsync($body, $offset, $length - $offset)
        if (-not $task.Wait($remaining)) { throw 'framed protocol body timeout' }
        if ($task.Result -eq 0) { throw 'framed protocol EOF while reading body' }
        $offset += $task.Result
    }
    $raw = [Text.Encoding]::UTF8.GetString($body)
    Write-Host "PROTO <= $raw"
    return [pscustomobject]@{ Raw = $raw; Message = ($raw | ConvertFrom-Json -Depth 30) }
}

function Wait-FramedJson {
    param(
        [Diagnostics.Process] $Process,
        [Parameter(Mandatory = $true)][string] $Description,
        [Parameter(Mandatory = $true)][scriptblock] $Predicate,
        [int] $TimeoutSeconds = 60
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    for ($i = 0; $i -lt $script:FramedPending.Count; $i++) {
        $item = $script:FramedPending[$i]
        if (& $Predicate $item.Message) {
            $script:FramedPending.RemoveAt($i)
            return $item
        }
    }

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process.HasExited) { throw "${Description}: process exited with code $($Process.ExitCode)" }
        try { $item = Read-FramedJson -Process $Process -TimeoutMilliseconds 10000 } catch {
            if ([DateTime]::UtcNow -ge $deadline) { break }
            continue
        }
        if (& $Predicate $item.Message) { return $item }
        $script:FramedPending.Add($item)
    }
    throw "Timed out waiting for framed protocol message: $Description"
}

function Stop-TestProcess {
    param([Diagnostics.Process] $Process)
    if ($null -eq $Process) { return }
    if (-not $Process.HasExited) {
        if (-not $Process.WaitForExit(5000)) {
            $Process.Kill($true)
            [void]$Process.WaitForExit(5000)
        }
    }
    $Process.Dispose()
}

function Invoke-ClangdLspProbe {
    param([string] $PackageRoot, [string] $Label)
    $project = Join-Path $testDir "clangd-lsp-$Label"
    Remove-Item -Recurse -Force $project -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $project | Out-Null
    $main = Join-Path $project 'main.c'
@'
int cup_lsp_value(void) { return 42; }
int main(void) { return cup_lsp_value() == 42 ? 0 : 1; }
'@ | Set-Content $main
    $db = @(
        @{ directory = $project; arguments = @('clang', '-std=c11', '-c', $main); file = $main }
    )
    $db | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $project 'compile_commands.json')
    $mainUri = ([Uri]$main).AbsoluteUri
    $rootUri = ([Uri]$project).AbsoluteUri
    $process = Start-FramedProcess -FilePath "$PackageRoot\bin\clangd.exe"
    try {
        Send-FramedJson $process @{ jsonrpc='2.0'; id=1; method='initialize'; params=@{ processId=$null; rootUri=$rootUri; capabilities=@{} } }
        $initialize = Wait-FramedJson $process 'clangd initialize response' { param($m) $m.id -eq 1 }
        if ($initialize.Raw -match '"error"' -or $initialize.Raw -notmatch '"capabilities"') {
            throw "clangd initialize did not return a valid server capability response at relocation $Label"
        }
        Send-FramedJson $process @{ jsonrpc='2.0'; method='initialized'; params=@{} }
        Send-FramedJson $process @{ jsonrpc='2.0'; method='textDocument/didOpen'; params=@{ textDocument=@{ uri=$mainUri; languageId='c'; version=1; text=(Get-Content $main -Raw) } } }
        Send-FramedJson $process @{ jsonrpc='2.0'; id=2; method='textDocument/documentSymbol'; params=@{ textDocument=@{ uri=$mainUri } } }
        $symbols = Wait-FramedJson $process 'clangd documentSymbol response' { param($m) $m.id -eq 2 }
        if ($symbols.Raw -notmatch 'cup_lsp_value' -or $symbols.Raw -notmatch '"main"') {
            throw "clangd documentSymbol response missed expected symbols at relocation $Label"
        }
        Send-FramedJson $process @{ jsonrpc='2.0'; id=3; method='shutdown'; params=$null }
        [void](Wait-FramedJson $process 'clangd shutdown response' { param($m) $m.id -eq 3 })
        Send-FramedJson $process @{ jsonrpc='2.0'; method='exit'; params=$null }
        $process.StandardInput.Close()
        Write-Host "CLANGD_LSP_$Label=PASS"
    } finally { Stop-TestProcess $process }
}

function Invoke-LldbDapProbe {
    param([string] $PackageRoot, [string] $Label, [string] $Program, [string] $Source)
    if (-not (Test-InfoBool 'features.lldb_dap')) { return }
    $line = (Select-String -Path $Source -Pattern '^static int add' | Select-Object -First 1).LineNumber
    if (-not $line) { throw 'Could not locate LLDB DAP breakpoint line' }
    $process = Start-FramedProcess -FilePath "$PackageRoot\bin\lldb-dap.exe"
    try {
        Send-FramedJson $process @{ seq=1; type='request'; command='initialize'; arguments=@{ clientID='cup-components'; adapterID='lldb'; linesStartAt1=$true; columnsStartAt1=$true } }
        [void](Wait-FramedJson $process 'lldb-dap initialize response' { param($m) $m.type -eq 'response' -and $m.request_seq -eq 1 -and $m.success -eq $true })
        Send-FramedJson $process @{ seq=2; type='request'; command='launch'; arguments=@{ program=$Program; cwd=(Split-Path $Program); stopOnEntry=$false; disableASLR=$false } }
        [void](Wait-FramedJson $process 'lldb-dap initialized event' { param($m) $m.type -eq 'event' -and $m.event -eq 'initialized' })
        Send-FramedJson $process @{ seq=3; type='request'; command='setBreakpoints'; arguments=@{ source=@{ path=$Source }; breakpoints=@(@{ line=$line }) } }
        [void](Wait-FramedJson $process 'lldb-dap setBreakpoints response' { param($m) $m.type -eq 'response' -and $m.request_seq -eq 3 -and $m.success -eq $true })
        Send-FramedJson $process @{ seq=4; type='request'; command='configurationDone'; arguments=@{} }
        # configurationDone and the pending launch response are not ordered by DAP.
        # A successful launch followed by a breakpoint stop proves configuration took effect.
        [void](Wait-FramedJson $process 'lldb-dap launch response' { param($m) $m.type -eq 'response' -and $m.request_seq -eq 2 -and $m.success -eq $true })
        [void](Wait-FramedJson $process 'lldb-dap breakpoint stop' { param($m) $m.type -eq 'event' -and $m.event -eq 'stopped' -and $m.body.reason -eq 'breakpoint' })
        Send-FramedJson $process @{ seq=5; type='request'; command='threads'; arguments=@{} }
        $threads = Wait-FramedJson $process 'lldb-dap threads response' { param($m) $m.type -eq 'response' -and $m.request_seq -eq 5 -and $m.success -eq $true }
        $threadId = $threads.Message.body.threads[0].id
        if (-not $threadId) { throw 'lldb-dap returned no thread id' }
        Send-FramedJson $process @{ seq=6; type='request'; command='stackTrace'; arguments=@{ threadId=$threadId; startFrame=0; levels=1 } }
        $stack = Wait-FramedJson $process 'lldb-dap stackTrace response' { param($m) $m.type -eq 'response' -and $m.request_seq -eq 6 -and $m.success -eq $true }
        $frameId = $stack.Message.body.stackFrames[0].id
        if ($null -eq $frameId) { throw 'lldb-dap returned no stack frame id' }
        Send-FramedJson $process @{ seq=7; type='request'; command='evaluate'; arguments=@{ expression='a + b'; frameId=$frameId; context='watch' } }
        $eval = Wait-FramedJson $process 'lldb-dap evaluate response' { param($m) $m.type -eq 'response' -and $m.request_seq -eq 7 -and $m.success -eq $true }
        if ("$($eval.Message.body.result)" -notmatch '42') { throw "lldb-dap evaluate did not return 42 at relocation $Label" }
        Send-FramedJson $process @{ seq=8; type='request'; command='continue'; arguments=@{ threadId=$threadId } }
        # A very short inferior can emit exited before the continue response.
        # Exit code 0 is the product oracle; do not require a transport ordering.
        $exited = Wait-FramedJson $process 'lldb-dap exited event' { param($m) $m.type -eq 'event' -and $m.event -eq 'exited' }
        if ($exited.Message.body.exitCode -ne 0) { throw "lldb-dap inferior exited with $($exited.Message.body.exitCode)" }
        Send-FramedJson $process @{ seq=9; type='request'; command='disconnect'; arguments=@{ terminateDebuggee=$false } }
        try { [void](Wait-FramedJson $process 'lldb-dap disconnect response' { param($m) $m.type -eq 'response' -and $m.request_seq -eq 9 } -TimeoutSeconds 15) } catch { Write-Host "warning: lldb-dap had already terminated after inferior exit: $_" }
        Write-Host "LLDB_DAP_$Label=PASS"
    } finally { Stop-TestProcess $process }
}

function Invoke-LldbRemoteProbe {
    param([string] $PackageRoot, [string] $Label, [string] $Program)
    if (-not (Test-InfoBool 'features.remote_debugging')) { return }
    $serverExe = Join-Path $PackageRoot 'bin\lldb-server.exe'
    if (-not (Test-Path $serverExe)) { throw 'packaged lldb-server.exe is missing' }
    $work = Join-Path $testDir "lldb-remote-$Label"
    $remoteDir = Join-Path $work 'remote-root'
    New-Item -ItemType Directory -Force $remoteDir | Out-Null
    $portFile = Join-Path $work 'platform.port'
    Remove-Item $portFile -Force -ErrorAction SilentlyContinue
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $serverExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $remoteDir
    foreach ($arg in @('platform', '--server', '--listen', '127.0.0.1:0', '--socket-file', $portFile)) { [void]$psi.ArgumentList.Add($arg) }
    $server = [Diagnostics.Process]::new(); $server.StartInfo = $psi
    if (-not $server.Start()) { throw 'could not start packaged lldb-server platform mode' }
    try {
        for ($i=0; $i -lt 160; $i++) {
            if (Test-Path $portFile) { if ((Get-Item $portFile).Length -gt 0) { break } }
            if ($server.HasExited) { throw "lldb-server platform exited before publishing a port: $($server.ExitCode)" }
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path $portFile)) { throw 'lldb-server platform did not publish its port' }
        $port = ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($portFile))).Trim([char]0, [char]9, [char]10, [char]13, [char]32)
        if ($port -notmatch '^[0-9]+$' -or [int]$port -lt 1 -or [int]$port -gt 65535) { throw "invalid lldb-server platform port: $port" }
        $programForward = To-ForwardSlashPath $Program
        $remoteForward = To-ForwardSlashPath $remoteDir
        $output = Invoke-NativeCapture -FilePath "$PackageRoot\bin\lldb.exe" -ArgumentList @(
            '-b',
            '-o', 'platform select remote-windows',
            '-o', "platform connect connect://127.0.0.1:$port",
            '-o', "platform settings -w '$remoteForward'",
            '-o', "target create '$programForward'",
            '-o', 'breakpoint set --name add',
            '-o', 'run',
            '-o', 'expression -- (int)(a + b)',
            '-o', 'continue',
            '-o', 'platform disconnect',
            '-o', 'quit'
        )
        Assert-OutputContains -Output $output -Pattern '\(int\).*42|=\s*42'
        Assert-OutputContains -Output $output -Pattern 'exited with status\s*=\s*0|exited with status\s+0'
        Write-Host "LLDB_PLATFORM_REMOTE_$Label=PASS port=$port"
    } finally {
        if (-not $server.HasExited) { $server.Kill($true) }
        [void]$server.WaitForExit(5000)
        $server.Dispose()
    }
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
        'script import sys, lldb; print("python-isolated=" + str(sys.flags.isolated)); print("python-version=" + ".".join(map(str, sys.version_info[:3]))); print("lldb-file=" + str(lldb.__file__)); print("clang-resource=" + str(lldb.SBHostOS.GetLLDBPath(lldb.ePathTypeClangDir))); [print("python-path=" + p) for p in sys.path]',
        '-o',
        'quit'
    )

    Assert-OutputContains -Output $output -Pattern '(?m)^python-isolated=1$'
    Assert-OutputContains -Output $output -Pattern ("(?m)^python-version=" + [regex]::Escape($expectedVersion) + '$')

    $packageFull = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\') + '\'
    $lldbFileLine = @($output | ForEach-Object { "$($_)" } | Where-Object { $_ -like 'lldb-file=*' } | Select-Object -Last 1)
    if ($lldbFileLine.Count -ne 1) {
        throw "LLDB Python module identity probe produced no unique path at relocation $Label"
    }
    $lldbFile = $lldbFileLine[0] -replace '^lldb-file=', ''
    $lldbFileFull = [IO.Path]::GetFullPath($lldbFile)
    if (-not $lldbFileFull.StartsWith($packageFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "LLDB Python module escaped the package at relocation ${Label}: $lldbFile"
    }

    $clangLine = @($output | ForEach-Object { "$($_)" } | Where-Object { $_ -like 'clang-resource=*' } | Select-Object -Last 1)
    if ($clangLine.Count -ne 1) {
        throw "LLDB Clang resource probe produced no unique path at relocation $Label"
    }
    $clangResource = $clangLine[0] -replace '^clang-resource=', ''
    $clangFull = [IO.Path]::GetFullPath($clangResource)
    if (-not $clangFull.StartsWith($packageFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "LLDB Clang resource directory escaped the package at relocation ${Label}: $clangResource"
    }
    if (-not (Test-Path (Join-Path $clangFull 'include\stddef.h'))) {
        throw "LLDB package-owned Clang resource headers are missing at relocation ${Label}: $clangResource"
    }

    $pythonPaths = @($output | ForEach-Object { "$($_)" } | Where-Object { $_ -like 'python-path=*' })
    if ($pythonPaths.Count -eq 0) {
        throw "LLDB Python sys.path probe produced no entries at relocation $Label"
    }

    foreach ($line in $pythonPaths) {
        $path = $line -replace '^python-path=', ''
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "LLDB Python sys.path contains an ambient empty entry at relocation $Label"
        }
        if ($path -eq '.') {
            continue
        }
        if (-not [IO.Path]::IsPathRooted($path)) {
            throw "LLDB Python sys.path contains an unexpected relative entry at relocation ${Label}: $path"
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
$zipPackage = "dist/$packageBase.zip"
$tarXzPackage = "dist/$packageBase.tar.xz"
if (Test-Path $zipPackage) {
    Expand-Archive -Force $zipPackage dist/package-test
} elseif (Test-Path $tarXzPackage) {
    Invoke-Native -FilePath 'tar.exe' -ArgumentList @('-xJf', $tarXzPackage, '-C', 'dist/package-test')
} else {
    throw "No supported package archive found for product test: $packageBase"
}

$root = Join-Path (Resolve-Path dist/package-test) $packageBase
$script:InfoLines = @(Get-Content "$root\info.txt")
$script:InfoLines

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
        foreach ($requiredFeature in @(
            'features.c',
            'features.cpp',
            'features.resource_dir',
            'features.lld_integration',
            'features.lto',
            'features.sanitizers',
            'features.sysroot'
        )) {
            if (-not (Test-InfoBool $requiredFeature)) {
                throw "required Windows Clang capability is not declared: $requiredFeature"
            }
        }
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

        if (-not (Test-InfoBool 'features.cxx_runtime_default')) {
            throw 'Windows Clang package does not declare its configured bundled libc++ default'
        }
        Invoke-ClangAsanProbe -PackageRoot $root -Label 'A'
        Invoke-ClangUbsanProbe -PackageRoot $root -Label 'A'
        Invoke-ClangProfileProbe -PackageRoot $root -Label 'A'
    }

    'lld' {
        Invoke-LldNativeProbe -PackageRoot $root -Label 'A'
    }

    'lldb' {
        foreach ($requiredFeature in @(
            'features.python',
            'features.target_create',
            'features.breakpoints',
            'features.symbol_lookup',
            'features.process_launch',
            'features.lldb_dap',
            'features.remote_debugging'
        )) {
            if (-not (Test-InfoBool $requiredFeature)) {
                throw "Windows LLDB required capability is not declared: $requiredFeature"
            }
        }
        if ((Get-InfoValue 'contents.lldb_server') -ne 'true') {
            throw 'Windows LLDB remote-debugging package does not declare lldb-server contents'
        }
        foreach ($requiredEntry in @('lldb.exe', 'lldb-dap.exe', 'lldb-server.exe')) {
            if (-not (Test-Path (Join-Path "$root\bin" $requiredEntry))) {
                throw "Windows LLDB required public command is missing: $requiredEntry"
            }
        }
        if (Test-Path "$root\bin\lldb-argdumper.exe") {
            throw 'Windows LLDB package unexpectedly contains non-public lldb-argdumper.exe'
        }
        foreach ($forbiddenHelper in @('analyze-cc', 'analyze-c++', 'intercept-cc', 'intercept-c++', 'ccc-analyzer', 'c++-analyzer')) {
            foreach ($suffix in @('', '.exe', '.bat', '.cmd')) {
                if (Test-Path (Join-Path "$root\libexec" ($forbiddenHelper + $suffix))) {
                    throw "Windows LLDB package retained sibling analyzer helper: $forbiddenHelper$suffix"
                }
            }
        }
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
            'thread backtrace',
            '-o',
            'quit'
        )
        Assert-OutputContains -Output $output -Pattern 'Breakpoint|breakpoint'
        Assert-OutputContains -Output $output -Pattern 'add'
        Assert-OutputContains -Output $output -Pattern 'frame #0|#0'
        Invoke-LldbDapProbe -PackageRoot $root -Label 'A' -Program $exe -Source $source
        Invoke-LldbRemoteProbe -PackageRoot $root -Label 'A' -Program $exe
    }

    'clangd' {
        foreach ($requiredFeature in @('features.resource_dir', 'features.check_compile_commands')) {
            if (-not (Test-InfoBool $requiredFeature)) {
                throw "required clangd capability is not declared: $requiredFeature"
            }
        }
        if ((Get-InfoValue 'contents.clang_resources') -ne 'true') {
            throw 'clangd package does not declare package-owned Clang resources'
        }
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
        Invoke-ClangdLspProbe -PackageRoot $root -Label 'A'
    }

    'clang-format' {
        foreach ($requiredFeature in @('features.format_file', 'features.style_config', 'features.dry_run_werror')) {
            if (-not (Test-InfoBool $requiredFeature)) {
                throw "required clang-format capability is not declared: $requiredFeature"
            }
        }
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
        foreach ($requiredFeature in @(
            'features.list_checks',
            'features.analyze_c',
            'features.clang_analyzer',
            'features.apply_replacements',
            'features.run_clang_tidy',
            'features.clang_tidy_diff'
        )) {
            if (-not (Test-InfoBool $requiredFeature)) {
                throw "required clang-tidy capability is not declared: $requiredFeature"
            }
        }
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
        Invoke-ClangTidyReplacementsProbe -PackageRoot $root -Label 'A'

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
        $relocatedLibcxx = Join-Path $testDir 'relocated-clang-libcxx-test.exe'
        Invoke-Native -FilePath "$relocatedRoot\bin\clang++.exe" -ArgumentList @(
            '-stdlib=libc++', '-fuse-ld=lld', $cppSource, '-o', $relocatedLibcxx
        )
        Invoke-Native -FilePath $relocatedLibcxx
        $relocatedLto = Join-Path $testDir 'relocated-clang-lto-test.exe'
        Invoke-Native -FilePath "$relocatedRoot\bin\clang.exe" -ArgumentList @(
            '-flto', '-fuse-ld=lld', $cSource, '-o', $relocatedLto
        )
        Invoke-Native -FilePath $relocatedLto
        Invoke-ClangAsanProbe -PackageRoot $relocatedRoot -Label 'C-spaces'
        Invoke-ClangUbsanProbe -PackageRoot $relocatedRoot -Label 'C-spaces'
        Invoke-ClangProfileProbe -PackageRoot $relocatedRoot -Label 'C-spaces'
    }
    'lld' {
        Invoke-LldNativeProbe -PackageRoot $relocatedRoot -Label 'C-spaces'
    }
    'lldb' {
        Assert-LldbPythonRuntime -PackageRoot $relocatedRoot -Label 'C-spaces'
        $output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\lldb.exe" -ArgumentList @(
            '-b', '-o', "target create $exeForLldb", '-o', 'breakpoint set --name add',
            '-o', 'run', '-o', 'thread backtrace', '-o', 'quit'
        )
        Assert-OutputContains -Output $output -Pattern 'add'
        Assert-OutputContains -Output $output -Pattern 'frame #0|#0'
        Invoke-LldbDapProbe -PackageRoot $relocatedRoot -Label 'C-spaces' -Program $exe -Source $source
        Invoke-LldbRemoteProbe -PackageRoot $relocatedRoot -Label 'C-spaces' -Program $exe
    }
    'clangd' {
        $output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\clangd.exe" -ArgumentList @("--check=$sourcePathForJson")
        Assert-OutputContains -Output $output -Pattern 'All checks completed|Testing on source file'
        Invoke-ClangdLspProbe -PackageRoot $relocatedRoot -Label 'C-spaces'
    }
    'clang-format' {
        $output = Invoke-NativeCapture -FilePath "$relocatedRoot\bin\clang-format.exe" -ArgumentList @($source)
        Assert-OutputContains -Output $output -Pattern 'int main\(void\)'
    }
    'clang-tidy' {
        Invoke-Native -FilePath "$relocatedRoot\bin\clang-tidy.exe" -ArgumentList @(
            '--checks=clang-analyzer-*', $source, '--', '-std=c11'
        )
        Invoke-ClangTidyHelperProbe -PackageRoot $relocatedRoot -Label 'C-spaces'
        Invoke-ClangTidyReplacementsProbe -PackageRoot $relocatedRoot -Label 'C-spaces'
    }
}
