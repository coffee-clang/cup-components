param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Phase,

    [Parameter(Mandatory = $true)]
    [string]$Script,

    [string[]]$Arguments = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$recordsDir = Join-Path $repoRoot '.cup-build/build-records'
New-Item -ItemType Directory -Force -Path $recordsDir | Out-Null

$environment = @(
    "captured_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    "runner_os=$($env:RUNNER_OS)"
    "runner_arch=$($env:RUNNER_ARCH)"
    "build_environment=$($env:CUP_BUILD_ENVIRONMENT)"
    "pwsh=$($PSVersionTable.PSVersion)"
    "os=$([Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    "process_arch=$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
)
Set-Content -LiteralPath (Join-Path $recordsDir "environment-$Phase.txt") -Value $environment -Encoding utf8NoBOM

$metaPath = Join-Path $recordsDir "$Phase.meta"
$logPath = Join-Path $recordsDir "$Phase.log"
Set-Content -LiteralPath $metaPath -Encoding utf8NoBOM -Value @(
    "phase=$Phase"
    "started_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    "command=pwsh -NoLogo -NoProfile -File $Script $($Arguments -join ' ')"
)

& pwsh -NoLogo -NoProfile -File $Script @Arguments *>&1 | Tee-Object -FilePath $logPath
$status = $LASTEXITCODE
if ($null -eq $status) {
    $status = if ($?) { 0 } else { 1 }
}

Add-Content -LiteralPath $metaPath -Encoding utf8NoBOM -Value @(
    "exit_code=$status"
    "finished_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
)
Add-Content -LiteralPath (Join-Path $recordsDir 'phases.txt') -Encoding utf8NoBOM -Value "phase.$Phase=$status"
exit $status
