# One explicitly authorized THREE-map SaveAs on a NEW copy. Offline candidate, NOT native accepted.
param([Parameter(Mandatory)][string]$Spec,
      [Parameter(Mandatory)][string]$HostDwg, [Parameter(Mandatory)][string]$HostSha256,
      [Parameter(Mandatory)][string]$EvidenceDir, [ValidateRange(1,300)][int]$TimeoutSec = 120)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$helper = Join-Path $PSScriptRoot 'prepare_xref_copy.py'
# Fail-before preflight does not load vendor assemblies or launch/compile CAD code.
& python -I $helper preflight $Spec --host $HostDwg --host-sha $HostSha256 --evidence $EvidenceDir
if ($LASTEXITCODE -ne 0) { throw 'prepare_preflight_failed' }
$evidence = [IO.Path]::GetFullPath($EvidenceDir)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'spds_text/owned_acad.ps1')
$previous = $env:RDCI_PREPARE_REQUEST
$owned = $null
try {
    $dll = Join-Path $evidence 'PrepareXrefCopy.dll'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $code = Join-Path $PSScriptRoot 'dependencies/PrepareXrefCopy.cs'
    $references = @('AcDbMgd.dll','AcMgd.dll','AcCoreMgd.dll') | ForEach-Object { '/r:' + (Join-Path $AcadDir $_) }
    & $csc /nologo /target:library "/out:$dll" @references /r:System.Web.Extensions.dll $code 2>&1 | Set-Content -LiteralPath (Join-Path $evidence 'build.txt') -Encoding utf8
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll)) { throw 'prepare_build_failed' }
    $env:RDCI_PREPARE_REQUEST = Join-Path $evidence 'request.json'
    # No user xref strings in Lisp; JSON only. Restore SECURELOAD BEFORE the write command.
    $lisp = $LispHead + @"

(progn
  (setq rd_prepare_sl (getvar "SECURELOAD"))
  (setq rd_prepare_dll "$($dll.Replace('\','/'))")
  (setvar "SECURELOAD" 0)
  (setq rd_prepare_load (vl-catch-all-apply '(lambda () (command "_.NETLOAD" rd_prepare_dll)) nil))
  (setvar "SECURELOAD" rd_prepare_sl)
  (if (and (not (vl-catch-all-error-p rd_prepare_load)) (= (getvar "SECURELOAD") rd_prepare_sl))
    (command "RDPREPAREXREFCOPY")))
"@
    $scr = Join-Path $evidence 'prepare.scr'
    Write-Scr $scr $lisp
    $owned = Invoke-OwnedTxtfixProcess -FilePath $AccCore -Arguments @('/i',(Join-Path $evidence 'host.dwg'),'/s',$scr,'/l','ru-RU') -Log (Join-Path $evidence 'native.complete') -TimeoutSec $TimeoutSec
    # Preserve helper fields as-is, including nullable held-handle root exit and exceptions.
    $owned | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'owned.json') -Encoding utf8
    & python -I $helper finish --evidence $evidence
    if ($LASTEXITCODE -ne 0) { throw 'prepare_postflight_failed' }
} catch {
    @{status='failed';execution_authorized=$false;error=$_.Exception.Message;owned=$owned} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'failure.json') -Encoding utf8
    throw
} finally { $env:RDCI_PREPARE_REQUEST = $previous }
