# Internal testable ownership gate; production supplies only held-root/NativeOM operations.
function Assert-NoCoverWordProcess {
    param([scriptblock]$Enumerate)
    $foreign = @(& $Enumerate)
    try { if ($foreign.Count) { throw 'existing_winword_refused' } }
    finally { foreach ($item in $foreign) { $item.Dispose() } }
}
function Invoke-CoverSession {
    param($Owner, [scriptblock]$FindPane, [scriptblock]$Bind, [scriptblock]$WindowPid,
          [scriptblock]$Track, [scriptblock]$Document, [int]$PaneTimeoutSec)
    $clock = [Diagnostics.Stopwatch]::StartNew(); $paneHwnd = 0
    while ($paneHwnd -eq 0) {
        $Owner.Guard()
        if ($clock.Elapsed.TotalSeconds -ge $PaneTimeoutSec) { throw 'owned_pane_timeout' }
        $paneHwnd = & $FindPane $Owner.OriginalProcessId
        if ($paneHwnd -eq 0) { Start-Sleep -Milliseconds 20 }
    }
    $Owner.Guard()
    if ((& $WindowPid $paneHwnd) -ne $Owner.OriginalProcessId) { throw 'pane_foreign_pid' }
    $pane = & $Track (& $Bind $paneHwnd $Owner.OriginalProcessId)
    $application = & $Track $pane.Application
    $Owner.Guard()
    $applicationHwnd = [long]$application.Hwnd
    if ((& $WindowPid $applicationHwnd) -ne $Owner.OriginalProcessId) { throw 'application_hwnd_foreign' }
    $Owner.Guard()
    $documentResult = & $Document $application
    @{document=$documentResult; ownership=@{identity_verified=$true; original_pid=$Owner.OriginalProcessId;
        pane_hwnd=$paneHwnd; application_hwnd=$applicationHwnd; method='direct_original_root_nativeom'}}
}
