# Offline fail-closed cover preflight; native Word execution is intentionally blocked.
# See ../docs/19_safe_cover.md. No COM activation, copies or output publication.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Template,
    [Parameter(Mandatory)][string]$Out,
    [System.Collections.IDictionary]$Replace = @{},
    [System.Collections.IDictionary]$ExpectedCounts = @{},
    [string]$TemplateSha256 = '',
    [string]$Pdf = '',
    [switch]$PassthroughDraft,
    [switch]$PreflightOnly,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
# Do not dot-source common.ps1: its work-root creation is unnecessary for this read-only check.
$request = @{
    template = $Template; out = $Out; pdf = $Pdf
    template_sha256 = $TemplateSha256; replace = $Replace; expected_counts = $ExpectedCounts
    passthrough_draft = [bool]$PassthroughDraft; force = [bool]$Force
} | ConvertTo-Json -Depth 10 -Compress
$lines = $request | & python -I (Join-Path $PSScriptRoot 'cover_preflight.py')
if ($LASTEXITCODE -ne 0) { throw "cover_preflight_failed: $($lines -join [Environment]::NewLine)" }
if (-not $PreflightOnly) {
    throw 'native_word_ownership_timeout_cleanup_not_implemented: no Word activated or outputs created; use -PreflightOnly for an offline contract/path check, not generation'
}
$lines
