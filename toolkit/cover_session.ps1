# Internal testable ownership gate; production supplies only held-root/NativeOM operations.
function Keep-CoverRcw($value) {
    if ($null -ne $value) {
        $seen = $false
        foreach ($held in $rcws) { if ([object]::ReferenceEquals($held,$value)) { $seen=$true; break } }
        if (-not $seen) { $rcws.Add($value) }
    }
    return ,$value
}
function Assert-NoCoverWordProcess {
    param([scriptblock]$Enumerate)
    $foreign = @(& $Enumerate)
    try { if ($foreign.Count) { throw 'existing_winword_refused' } }
    finally { foreach ($item in $foreign) { $item.Dispose() } }
}
function Get-CoverReadinessFailureEvidence($Owner, [scriptblock]$Capture) {
    # One class-only snapshot BEFORE own stop. Missing diagnostics never replace the primary failure.
    try {
        $Owner.Guard()
        $snapshot = & $Capture $Owner.OriginalProcessId
        $Owner.Guard()
        return @{snapshot=$snapshot}
    } catch { return @{error='readiness_capture_unavailable'} }
}
function ConvertTo-CoverHandle($Value, [Collections.IDictionary]$Evidence, [string]$Key) {
    $entry = @{shape='null';type='null'}
    $Evidence[$Key] = $entry
    if ($null -eq $Value) { throw 'identity_handle_null' }
    if ($Value -is [array]) {
        $entry.shape='array';$entry.type=$Value.GetType().FullName;$entry.length=$Value.Length
        throw 'identity_handle_array'
    }
    $integer = $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
    if (-not $integer) {
        $entry.shape='unsupported';$entry.type='non_integer_object'
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal] -or $Value -is [string] -or
            $Value -is [IntPtr] -or $Value -is [UIntPtr]) { $entry.type=$Value.GetType().FullName }
        throw 'identity_handle_not_integer'
    }
    $entry.shape='scalar';$entry.type=$Value.GetType().FullName;$entry.value=$Value
    # Keep signed values exactly as supplied; no speculative Int32/64 reinterpretation.
    return [long]$Value
}
function Assert-CoverTrackedScalar($Original, $Tracked, [Collections.IDictionary]$Evidence, [string]$Key) {
    $Evidence[$Key]=@{
        original_shape=$(if($null -eq $Original){'null'}elseif($Original -is [array]){'array'}else{'scalar'})
        tracked_shape=$(if($null -eq $Tracked){'null'}elseif($Tracked -is [array]){'array'}else{'scalar'})
        same_reference=[object]::ReferenceEquals($Original,$Tracked)
    }
    if ($null -eq $Original -or $Original -is [array] -or $null -eq $Tracked -or $Tracked -is [array] -or
        -not [object]::ReferenceEquals($Original,$Tracked)) { throw 'identity_track_not_original_scalar' }
}
function Set-CoverIdentityError([Collections.IDictionary]$Evidence, $Exception) {
    # Safe primitive provenance only, never serialize exception/COM object or its message.
    try {
        $Evidence.error_component=$Evidence.substep
        $Evidence.error_hresult=[int]$Exception.HResult
        for ($i=0;$i -lt 8 -and $null -ne $Exception;$i++) {
            $Evidence.error_inner_hresult=[int]$Exception.HResult
            if ($Exception -is [ComponentModel.Win32Exception]) { $Evidence.native_error=[int]$Exception.NativeErrorCode; break }
            $Exception=$Exception.InnerException
        }
    } catch { } # Provenance cannot replace the primary failure.
}
function Invoke-CoverSession {
    param($Owner, [scriptblock]$FindPane, [scriptblock]$Bind, [scriptblock]$WindowPid,
          [scriptblock]$Track, [scriptblock]$Document, [int]$PaneTimeoutSec,
          [Collections.IDictionary]$IdentityEvidence = @{})
    try {
    $IdentityEvidence.original_pid=$Owner.OriginalProcessId
    $IdentityEvidence.substep='selector'
    $clock = [Diagnostics.Stopwatch]::StartNew(); $paneHwnd = 0
    while ($paneHwnd -eq 0) {
        $Owner.Guard()
        if ($clock.Elapsed.TotalSeconds -ge $PaneTimeoutSec) { throw 'owned_pane_timeout' }
        $selected = & $FindPane $Owner.OriginalProcessId
        $paneHwnd = ConvertTo-CoverHandle $selected $IdentityEvidence 'pane_hwnd'
        if ($paneHwnd -eq 0) { Start-Sleep -Milliseconds 20 }
    }
    $Owner.Guard()
    $IdentityEvidence.substep='pane_pid_lookup'
    $panePid = & $WindowPid $paneHwnd
    if ($panePid -isnot [uint32] -and $panePid -isnot [int32] -and $panePid -isnot [int64]) { throw 'identity_pid_not_scalar_integer' }
    $IdentityEvidence.pane_pid=$panePid
    $IdentityEvidence.pane_pid_matches_original=($panePid -eq $Owner.OriginalProcessId)
    if ($panePid -ne $Owner.OriginalProcessId) { throw 'pane_foreign_pid' }
    $IdentityEvidence.substep='bind'
    $bound = & $Bind $paneHwnd $Owner.OriginalProcessId
    $IdentityEvidence.bind_returned=$true
    $IdentityEvidence.substep='pane_track'
    $pane = & $Track $bound
    Assert-CoverTrackedScalar $bound $pane $IdentityEvidence 'pane_tracking'
    $IdentityEvidence.substep='application_access'
    $IdentityEvidence.application_member_state='getter_not_returned'
    $appProperty = $pane.PSObject.Properties['Application']
    if ($null -eq $appProperty) { $IdentityEvidence.application_member_state='missing'; throw 'identity_application_member_missing' }
    $untrackedApplication = $appProperty.get_Value()
    $IdentityEvidence.application_member_state=if($null -eq $untrackedApplication){'null'}else{'returned'}
    $IdentityEvidence.substep='application_track'
    $application = & $Track $untrackedApplication
    Assert-CoverTrackedScalar $untrackedApplication $application $IdentityEvidence 'application_tracking'
    $Owner.Guard()
    $IdentityEvidence.substep='application_hwnd_get'
    $IdentityEvidence.application_hwnd=@{shape='getter_not_returned';type='unknown'}
    $hwndProperty = $application.PSObject.Properties['Hwnd']
    if ($null -eq $hwndProperty) { $IdentityEvidence.application_hwnd.shape='missing';throw 'identity_hwnd_member_missing' }
    $rawHwnd = $hwndProperty.get_Value()
    $IdentityEvidence.substep='application_hwnd_validate'
    $applicationHwnd = ConvertTo-CoverHandle $rawHwnd $IdentityEvidence 'application_hwnd'
    if ($applicationHwnd -eq 0) { throw 'identity_application_hwnd_zero' }
    $IdentityEvidence.substep='application_pid_lookup'
    $appPid = & $WindowPid $applicationHwnd
    if ($appPid -isnot [uint32] -and $appPid -isnot [int32] -and $appPid -isnot [int64]) { throw 'identity_pid_not_scalar_integer' }
    $IdentityEvidence.application_pid=$appPid
    $IdentityEvidence.application_pid_matches_original=($appPid -eq $Owner.OriginalProcessId)
    if ($appPid -ne $Owner.OriginalProcessId) { throw 'application_hwnd_foreign' }
    $Owner.Guard()
    $IdentityEvidence.substep='document'
    $documentResult = & $Document $application
    @{document=$documentResult; ownership=@{identity_verified=$true; original_pid=$Owner.OriginalProcessId;
        pane_hwnd=$paneHwnd; application_hwnd=$applicationHwnd; method='direct_original_root_nativeom'}}
    } catch { Set-CoverIdentityError $IdentityEvidence $_.Exception; throw }
}
