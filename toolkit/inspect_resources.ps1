# Bounded read-only wrapper of the existing check_papers method. No Add/plot/GUI/source replacement.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputRoot,
    [Parameter(Mandatory)][string[]]$Files,
    [Parameter(Mandatory)][string]$ResultFile,
    [string]$PmpPath = '',
    [ValidateRange(1,900)][int]$BudgetSeconds = 900,
    [ValidateRange(1,300)][int]$PerFileTimeoutSec = 300
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$baseWork = $WorkRoot
$root = [IO.Path]::GetFullPath($InputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$prefix = $root + [IO.Path]::DirectorySeparatorChar
function Test-InRoot([string]$Path) { $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }
if (-not (Test-Path -LiteralPath $root -PathType Container) -or $Files.Count -lt 1 -or $Files.Count -gt 3) { throw 'resource_probe_requires_one_to_three_inputs' }
$target = [IO.Path]::GetFullPath($ResultFile)
if ((Test-InRoot $target) -or (Test-InRoot ([IO.Path]::GetFullPath($baseWork))) -or
    [IO.Path]::GetFullPath($baseWork).Equals($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'resource_output_or_work_inside_input' }
if ($baseWork -notmatch '^[\x20-\x7E]+$') { throw 'resource_work_requires_ascii_path' }
$resolved = @(); $seen = @{}
foreach ($file in $Files) {
    $path = [IO.Path]::GetFullPath($file)
    if (-not (Test-InRoot $path) -or [IO.Path]::GetExtension($path) -ine '.dwg' -or $seen.ContainsKey($path)) { throw 'invalid_resource_input' }
    $seen[$path] = $true
    $item = Get-Item -LiteralPath $path
    if ($item.PSIsContainer) { throw 'invalid_resource_input' }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'resource_input_reparse_point' }
    $directory = $item.Directory
    while ($directory -and $directory.FullName.Length -ge $root.Length) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'resource_input_reparse_point' }
        $directory = $directory.Parent
    }
    $resolved += [IO.Path]::GetFullPath($file)
}
# Reserve new output before CAD; never replace an existing report.
$stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
$originalWork = $env:RDCI_WORK
$probeWork = Join-Path $baseWork ('resource-probe-' + [guid]::NewGuid().ToString('N'))
$records = @(); $failure = $null; $pmpInfo = $null; $clock = [Diagnostics.Stopwatch]::StartNew()
try {
    . "$PSScriptRoot/pmp_paths.ps1"
    $pmpInfo = Get-PmpCatalog -Path $PmpPath -Inspect
    $selectedPmp = if ($pmpInfo.status -eq 'found') { $pmpInfo.path } else { '' }
    foreach ($source in $resolved) {
        $remaining = [int][Math]::Floor($BudgetSeconds - $clock.Elapsed.TotalSeconds)
        if ($remaining -lt 1) { $failure = 'resource_budget_exhausted'; break }
        $perWork = Join-Path $probeWork ('file-' + $records.Count)
        $env:RDCI_WORK = $perWork
        $sha = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $Global:AccCoreLastRun = $null
        & "$PSScriptRoot/check_papers.ps1" -Files @($source) -PmpPath $selectedPmp -TimeoutSec ([Math]::Min($PerFileTimeoutSec, $remaining)) -ControlledRead | Out-Host
        $elapsed.Stop()
        if (-not $Global:AccCoreLastRun -or $Global:AccCoreLastRun.Status -ne 'completed_controlled' -or
            -not $Global:AccCoreLastRun.CleanupVerified -or -not $Global:AccCoreLastRun.RootAliveBeforeStop) { throw 'resource_native_execution_failed' }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) { throw 'resource_input_changed' }
        $raw = Join-Path $perWork 'papers/p1.txt'; $log = $Global:AccCoreLastRun.CompletionMarker
        if (-not (Test-Path -LiteralPath $raw) -or -not (Test-Path -LiteralPath $log)) { throw 'resource_metadata_missing' }
        $layouts = @(); $names = @{}
        foreach ($line in [IO.File]::ReadAllLines($raw, [Text.Encoding]::UTF8)) {
            $parts = $line.Split('|')
            if ($parts.Count -ne 3 -or [string]::IsNullOrWhiteSpace($parts[0]) -or $names.ContainsKey($parts[0])) { throw 'resource_metadata_ambiguous' }
            $names[$parts[0]] = $true
            $paper = $parts[1]; $device = $parts[2]
            $format = if ($paper -like 'UserDefined*') {
                          if ($pmpInfo.status -ne 'found') { 'unknown' }
                          else { switch (Get-PmpPaperMatch $pmpInfo $paper) {
                            'exact_name' { 'custom_configured_unverified' }
                            'dimensions_only' { 'unknown' }
                            default { 'custom_missing' }
                          } }
                      }
                      elseif ($paper -match '^(ISO|ANSI|ARCH)_') { 'standard_unverified' } else { 'unknown' }
            $layouts += @{ name = $parts[0]; paper = $paper; device = $device; paper_status = $format }
        }
        if ($layouts.Count -eq 0) { throw 'resource_no_paper_layouts' }
        $records += @{ path = [IO.Path]::GetRelativePath($root, $source).Replace([char]92, [char]47);
                       sha256 = $sha; size_bytes = (Get-Item -LiteralPath $source).Length;
                       layout_count = $layouts.Count; layouts = @($layouts); cad_starts = 1;
                       elapsed_seconds = $elapsed.Elapsed.TotalSeconds; exit_code = $null; status = 'observed';
                       completion_mode = 'owned_job_after_metadata'; controlled_cleanup_verified = $true; root_alive_before_stop = $true;
                       raw_metadata = $raw; raw_metadata_sha256 = (Get-FileHash -LiteralPath $raw -Algorithm SHA256).Hash.ToLowerInvariant();
                       raw_log = $log; raw_log_sha256 = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
} catch { $failure = if ($_.Exception.Message -match '^resource_[a-z_]+$') { $_.Exception.Message } else { 'resource_probe_failed' } }
finally {
    $env:RDCI_WORK = $originalWork; $Global:WorkRoot = $baseWork
    try {
        $result = @{ schema_version = 1; kind = 'paper_resource_probe'; status = $(if ($failure) { 'failed' } else { 'observed' });
                     files = @($records); requested_files = $resolved.Count; budget_seconds = $BudgetSeconds;
                     elapsed_seconds = $clock.Elapsed.TotalSeconds; error = $failure;
                     last_native_run = $Global:AccCoreLastRun; pmp_resolution = $pmpInfo; execution_authorized = $false }
        $writer.WriteLine(($result | ConvertTo-Json -Depth 12)); $writer.Flush()
    } finally { $writer.Dispose() }
}
if ($failure) { throw $failure }
