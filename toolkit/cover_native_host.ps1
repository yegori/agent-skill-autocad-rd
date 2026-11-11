# INTERNAL host. Launched by cover_draft.py in an explicit interactive Windows STA process.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$result = @{status='failed'; native_accepted=$false; draft=$true; phase='prerequisites'; cleanup_verified=$false}
$owner = $null; $rcws = [Collections.Generic.List[object]]::new(); $failure = $null
function Keep-CoverRcw($value) {
    if ($null -ne $value) {
        $seen = $false
        foreach ($held in $rcws) { if ([object]::ReferenceEquals($held,$value)) { $seen=$true; break } }
        if (-not $seen) { $rcws.Add($value) }
    }
    return ,$value
}
function Write-CoverPhase([string]$value) {
    $result.phase = $value
    [IO.File]::AppendAllText($config.audit, "$value`n")
}
try {
    if (-not $IsWindows -or -not [Environment]::UserInteractive -or
        [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -or
        [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { throw 'interactive_windows_sta_required' }
    . (Join-Path $PSScriptRoot 'cover_session.ps1')
    # Enumeration errors fail. No COM factory/global ROT adoption.
    Assert-NoCoverWordProcess { [Diagnostics.Process]::GetProcessesByName('WINWORD') }
    if ((Get-FileHash -LiteralPath $config.word_exe -Algorithm SHA256).Hash -ne $config.word_sha256) { throw 'word_binary_hash_mismatch' }
    if ((Get-FileHash -LiteralPath $config.snapshot -Algorithm SHA256).Hash -ne $config.template_sha256) { throw 'snapshot_hash_mismatch' }
    foreach ($path in @($config.doc,$config.pdf)) { if (Test-Path -LiteralPath $path) { throw 'private_output_exists' } }
    Add-Type -Path @((Join-Path $PSScriptRoot 'spds_text/OwnedCadProcess.cs'),
        (Join-Path $PSScriptRoot 'cover_owner.cs'), (Join-Path $PSScriptRoot 'cover_native_window.cs'))
    . (Join-Path $PSScriptRoot 'cover_document.ps1')
    Write-CoverPhase 'launch'
    $owner = [AutocadRd.CoverOwner]::Start($config.word_exe, $config.timeout_sec, $config.audit)
    $result.original_pid = $owner.OriginalProcessId
    Write-CoverPhase 'pane'
    $documentResult = Invoke-CoverSession $owner `
        { param($original) [AutocadRd.CoverWindow]::FindPane($original) } `
        { param($hwnd,$original) [AutocadRd.CoverWindow]::Bind($hwnd,$original) } `
        { param($hwnd) [AutocadRd.CoverWindow]::ProcessId($hwnd) } `
        ${function:Keep-CoverRcw} `
        { param($application) Invoke-CoverDocument $application $config { $owner.Guard() } ${function:Keep-CoverRcw} ${function:Write-CoverPhase} } `
        $config.pane_timeout_sec
    $result.document = $documentResult.document
    $result.ownership = $documentResult.ownership
    Write-CoverPhase 'release'
} catch {
    $failure = $_; $result.error = $_.ToString()
    $result.failure_phase = if ($_.Exception.Data['cover_phase']) { $_.Exception.Data['cover_phase'] } else { $result.phase }
}
finally {
    # Release only references obtained through our verified original root. Never Word.Quit on a foreign instance.
    for ($i=$rcws.Count-1; $i -ge 0; $i--) {
        try {
            if ([Runtime.InteropServices.Marshal]::IsComObject($rcws[$i])) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($rcws[$i])
            }
        } catch { if (-not $failure) { $failure = $_; $result.error = $_.ToString() } }
    }
    if ($owner) {
        try {
            if (-not $failure) {
                Write-CoverPhase 'closed_postflight'
                $owner.Guard()
                foreach ($unchanged in @($config.template,$config.snapshot)) {
                    if ((Get-FileHash -LiteralPath $unchanged -Algorithm SHA256).Hash -ne $config.template_sha256) { throw 'source_or_snapshot_changed' }
                }
                $closedHashes = @{}
                foreach ($kind in @('doc','pdf')) {
                    if ((Get-Item -LiteralPath $config[$kind]).Length -le 0) { throw 'empty_closed_output' }
                    $closedHashes[$kind] = (Get-FileHash -LiteralPath $config[$kind] -Algorithm SHA256).Hash.ToLowerInvariant()
                }
                # Installed PyMuPDF only, closed PDF; no layout/engineering acceptance.
                & python -I -c 'import sys,fitz; d=fitz.open(sys.argv[1]); n=int(sys.argv[2]); ok=not d.needs_pass and d.page_count==n and n>0 and all(not p.rect.is_empty and not p.rect.is_infinite for p in d); d.close(); sys.exit(0 if ok else 2)' $config.pdf $config.expected_pages
                if ($LASTEXITCODE -ne 0) { throw 'closed_pdf_validation_failed' }
                $result.closed_artifact_sha256 = $closedHashes
                $owner.Guard()
                $owner.Complete()
            } else { $owner.Dispose() }
        } catch { $failure = $_; $result.error = $_.ToString() }
        finally {
            try { $owner.Dispose() } catch { $failure = $_; $result.error = $_.ToString() }
            $result.cleanup_verified = $owner.CleanupVerified
            $result.root_live_before_stop = $owner.RootLiveBeforeStop
            $result.root_exitcode_before_stop = $owner.RootExitCodeBeforeStop
            $result.timed_out = $owner.TimedOut
            $result.cleanup_error = $owner.CleanupError
        }
    }
}
if (-not $failure -and $result.cleanup_verified -and $result.root_live_before_stop -and -not $result.timed_out) {
    $result.status = 'controlled_draft_closed_and_stopped'
}
# Exclusive evidence creation; raw phase log/private artifacts survive every failure.
$stream = [IO.File]::Open($config.native_result, 'CreateNew', 'Write', 'None')
try { $bytes = [Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Depth 20)); $stream.Write($bytes,0,$bytes.Length) }
finally { $stream.Dispose() }
if ($result.status -ne 'controlled_draft_closed_and_stopped') { exit 1 }
