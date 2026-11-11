# Explicit guarded draft candidate; NOT native accepted/engineering-approved. See docs/19_safe_cover.md.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Template,
    [Parameter(Mandatory)][string]$TemplateSha256,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$Pdf,
    [Parameter(Mandatory)][string]$WordExe,
    [Parameter(Mandatory)][string]$WordSha256,
    [Parameter(Mandatory)][string]$WorkParent,
    [Parameter(Mandatory)][int]$ExpectedPages,
    [Collections.IDictionary]$Replace = @{},
    [Collections.IDictionary]$ExpectedCounts = @{},
    [switch]$PassthroughDraft,
    [int]$TimeoutSec = 120,
    [int]$PaneTimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
$request = @{
    template=$Template; template_sha256=$TemplateSha256; out=$Out; pdf=$Pdf
    word_exe=$WordExe; word_sha256=$WordSha256; work_parent=$WorkParent; expected_pages=$ExpectedPages
    replace=$Replace; expected_counts=$ExpectedCounts; passthrough_draft=[bool]$PassthroughDraft
    timeout_sec=$TimeoutSec; pane_timeout_sec=$PaneTimeoutSec
} | ConvertTo-Json -Depth 10 -Compress
# Script-local UTF-8 wire encoding; never alter OS/console/profile encoding.
$previousOutputEncoding = $OutputEncoding
try {
    $OutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $lines = $request | & python -I (Join-Path $PSScriptRoot 'cover_draft.py')
    $cliExitCode = $LASTEXITCODE
} finally { $OutputEncoding = $previousOutputEncoding }
if ($cliExitCode -ne 0) { throw "cover_draft_failed (partials retained): $($lines -join [Environment]::NewLine)" }
$lines
