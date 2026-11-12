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
function Get-CoverIdentityMember($Target, [string]$Member, [Collections.IDictionary]$Evidence, [string]$Key) {
    $Evidence[$Key]='getter_not_returned'
    $property=$Target.PSObject.Properties[$Member]
    if ($null -eq $property) { $Evidence[$Key]='missing';throw 'identity_member_missing' }
    $value=$property.get_Value()
    $Evidence[$Key]=if($null -eq $value){'null'}else{'returned'}
    return ,$value
}
function Confirm-CoverWordWindow($Window, $Owner, [scriptblock]$WindowPid,
                                [Collections.IDictionary]$Evidence, [string]$Prefix) {
    $Owner.Guard()
    $key=$Prefix+'_hwnd'
    $Evidence.substep=$key+'_get'
    $Evidence[$key]=@{shape='getter_not_returned';type='unknown'}
    $property=$Window.PSObject.Properties['Hwnd']
    if ($null -eq $property) { $Evidence[$key].shape='missing';throw 'identity_hwnd_member_missing' }
    $raw=$property.get_Value()
    $Evidence.substep=$key+'_validate'
    $hwnd=ConvertTo-CoverHandle $raw $Evidence $key
    if ($hwnd -eq 0) { throw 'identity_word_window_hwnd_zero' }
    $Evidence.substep=$Prefix+'_pid_lookup'
    $observed=& $WindowPid $hwnd
    if ($observed -isnot [uint32] -and $observed -isnot [int32] -and $observed -isnot [int64]) { throw 'identity_pid_not_scalar_integer' }
    $Evidence[$Prefix+'_pid']=$observed
    $Evidence[$Prefix+'_pid_matches_original']=($observed -eq $Owner.OriginalProcessId)
    if ($observed -ne $Owner.OriginalProcessId) { throw 'word_window_foreign_pid' }
    return $hwnd
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
    $IdentityEvidence.substep='native_window_track'
    $nativeWindow = & $Track $bound
    Assert-CoverTrackedScalar $bound $nativeWindow $IdentityEvidence 'native_window_tracking'
    # Word.Window.Hwnd, not an assumed Word.Application.Hwnd. Child/frame numbers may differ.
    $nativeHwnd=Confirm-CoverWordWindow $nativeWindow $Owner $WindowPid $IdentityEvidence 'native_window'
    $Owner.Guard()
    $IdentityEvidence.substep='application_access'
    $untrackedApplication=Get-CoverIdentityMember $nativeWindow 'Application' $IdentityEvidence 'application_member_state'
    $IdentityEvidence.substep='application_track'
    $application = & $Track $untrackedApplication
    Assert-CoverTrackedScalar $untrackedApplication $application $IdentityEvidence 'application_tracking'
    $Owner.Guard()
    # ONLY ActiveWindow from the SAME verified bound application; never foreground/global lookup.
    $IdentityEvidence.substep='application_active_window_access'
    $untrackedActive=Get-CoverIdentityMember $application 'ActiveWindow' $IdentityEvidence 'application_active_window_member_state'
    $IdentityEvidence.substep='application_active_window_track'
    $activeWindow=& $Track $untrackedActive
    Assert-CoverTrackedScalar $untrackedActive $activeWindow $IdentityEvidence 'application_active_window_tracking'
    $activeHwnd=Confirm-CoverWordWindow $activeWindow $Owner $WindowPid $IdentityEvidence 'application_active_window'
    $Owner.Guard()
    $IdentityEvidence.substep='document'
    $documentResult = & $Document $application
    @{document=$documentResult; ownership=@{identity_verified=$true; original_pid=$Owner.OriginalProcessId;
        pane_hwnd=$paneHwnd; native_window_hwnd=$nativeHwnd; application_active_window_hwnd=$activeHwnd; method='direct_original_root_nativeom'}}
    } catch { Set-CoverIdentityError $IdentityEvidence $_.Exception; throw }
}
