param(
    [Parameter(Mandatory = $true)]
    [string] $Root,

    [Parameter(Mandatory = $true)]
    [string] $Tool
)

$ErrorActionPreference = 'Stop'

function Get-InfoValue {
    param([Parameter(Mandatory = $true)][string] $Key)
    $info = Join-Path $Root 'info.txt'
    if (-not (Test-Path $info)) { return '' }
    $line = Get-Content $info | Where-Object { $_ -like "$Key=*" } | Select-Object -Last 1
    if (-not $line) { return '' }
    return ($line -replace "^$([regex]::Escape($Key))=", '')
}

function Test-PackageExe {
    param([Parameter(Mandatory = $true)][string] $Name)
    $path = Join-Path (Join-Path $Root 'bin') $Name
    return (Test-Path $path)
}

function Show-Executable {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string] $DeclaredKey = ''
    )
    $present = Test-PackageExe $Name
    if ($present) { $line = ("  present  {0,-30}" -f $Name) } else { $line = ("  missing  {0,-30}" -f $Name) }
    if ($DeclaredKey) {
        $declared = Get-InfoValue $DeclaredKey
        $line += " declared:$DeclaredKey=$declared"
        if ($declared -eq 'true' -and -not $present) { $line += '  WARNING: declared true but executable missing' }
        elseif ($declared -ne 'true' -and $present) { $line += '  note: executable present but feature not declared true' }
    }
    Write-Host $line
}

function Show-Version {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string[]] $Args = @('--version')
    )
    $path = Join-Path (Join-Path $Root 'bin') $Name
    if (Test-Path $path) {
        Write-Host ""
        Write-Host "[version: $Name]"
        try { & $path @Args 2>&1 | Select-Object -First 8 | ForEach-Object { Write-Host $_ } }
        catch { Write-Host "  warning: version command failed: $_" }
    }
}

function Show-InfoContract {
    $info = Join-Path $Root 'info.txt'
    if (-not (Test-Path $info)) { Write-Host 'info.txt: missing'; return }

    Write-Host ""
    Write-Host '[package identity]'
    foreach ($key in @(
        'package.component','package.tool','package.version','package.revision','package.mode','package.formats',
        'platform.host','platform.target','platform.host_triple','platform.target_triple',
        'source.primary.name','source.primary.version','build.environment','build.source_policy'
    )) {
        $value = Get-InfoValue $key
        if ($value) { Write-Host ("  {0,-30} {1}" -f $key, $value) }
    }

    Write-Host ""
    Write-Host '[entry points declared in info.txt]'
    Get-Content $info | Where-Object { $_ -match '^entry\.' } | Sort-Object | ForEach-Object { Write-Host "  $_" }

    Write-Host ""
    Write-Host '[features declared in info.txt]'
    Get-Content $info | Where-Object { $_ -match '^features\.' } | Sort-Object | ForEach-Object { Write-Host "  $_" }

    Write-Host ""
    Write-Host '[contents/config/bundle metadata]'
    Get-Content $info | Where-Object { $_ -match '^(contents|config|bundle)\.' } | Sort-Object | ForEach-Object { Write-Host "  $_" }
}

Write-Host ""
Write-Host '============================================================'
Write-Host 'cup package capability contract'
Write-Host '============================================================'
Write-Host "package root: $Root"
Write-Host "tool: $Tool"

Show-InfoContract

Write-Host ""
Write-Host '[bin summary]'
$bin = Join-Path $Root 'bin'
if (Test-Path $bin) { Get-ChildItem $bin -File | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Name)" } }
else { Write-Host '  missing bin directory' }

switch ($Tool) {
    'gcc' {
        Write-Host ""
        Write-Host '[GCC capability probes]'
        Show-Executable 'gcc.exe' 'features.c'
        Show-Executable 'g++.exe' 'features.cpp'
        Show-Executable 'cpp.exe' 'features.preprocessor'
        Show-Executable 'gcov.exe' 'features.gcov'
        Show-Executable 'lto-dump.exe' 'features.lto_dump'
        foreach ($exe in @('as.exe','ld.exe','ar.exe','ranlib.exe','strip.exe','objdump.exe','readelf.exe')) { Show-Executable $exe 'features.binutils' }
        $triple = Get-InfoValue 'platform.target_triple'
        if ($triple) {
            Write-Host ""
            Write-Host "[target-prefixed probes: $triple]"
            foreach ($exe in @('gcc','g++','cpp','as','ld','ar','ranlib','strip','objdump','readelf')) { Show-Executable "$triple-$exe.exe" 'features.target_prefixed_tools' }
        }
        Show-Version 'gcc.exe'
        Show-Version 'g++.exe'
        if ($triple) { Show-Version "$triple-gcc.exe" }
    }
    'gdb' {
        Write-Host ""
        Write-Host '[GDB capability probes]'
        Show-Executable 'gdb.exe' 'features.debug_native'
        Show-Executable 'gdbserver.exe' 'features.gdbserver'
        Show-Version 'gdb.exe'
    }
    'clang' {
        Write-Host ""
        Write-Host '[LLVM-family capability probes]'
        Show-Executable 'clang.exe' 'features.c'
        Show-Executable 'clang++.exe' 'features.cpp'
        Show-Executable 'ld.lld.exe' 'features.lld_integration'
        Show-Executable 'llvm-ar.exe' 'features.llvm_ar'
        Show-Executable 'llvm-ranlib.exe' 'features.llvm_ranlib'
        Show-Executable 'llvm-objdump.exe' 'features.llvm_objdump'
        Show-Version 'clang.exe'
    }
    'lld' {
        Write-Host ""
        Write-Host '[LLVM-family capability probes]'
        Show-Executable 'ld.lld.exe' 'features.link_elf'
        Show-Executable 'lld-link.exe' 'features.link_coff'
        Show-Executable 'wasm-ld.exe' 'features.link_wasm'
        Show-Executable 'ld64.lld.exe' 'features.link_macho'
        Show-Version 'ld.lld.exe'
    }
    'lldb' {
        Write-Host ""
        Write-Host '[LLVM-family capability probes]'
        Show-Executable 'lldb.exe' 'features.target_create'
        Show-Executable 'lldb-server.exe' 'features.lldb_server'
        Show-Executable 'lldb-dap.exe' 'features.lldb_dap'
        Show-Version 'lldb.exe'
    }
    'clangd' {
        Show-Executable 'clangd.exe' 'features.check_compile_commands'
        Show-Executable 'clangd-indexer.exe' 'features.indexer'
        Show-Version 'clangd.exe'
    }
    'clang-format' {
        Show-Executable 'clang-format.exe' 'features.format_file'
        Show-Executable 'git-clang-format.exe' 'features.git_clang_format'
        Show-Version 'clang-format.exe'
    }
    'clang-tidy' {
        Show-Executable 'clang-tidy.exe' 'features.analyze_c'
        Show-Executable 'clang-apply-replacements.exe' 'features.apply_replacements'
        Show-Executable 'run-clang-tidy.exe' 'features.run_clang_tidy'
        Show-Executable 'clang-tidy-diff.exe' 'features.clang_tidy_diff'
        Show-Version 'clang-tidy.exe'
    }
}

Write-Host '============================================================'
Write-Host 'end of capability contract'
Write-Host '============================================================'
Write-Host ""
