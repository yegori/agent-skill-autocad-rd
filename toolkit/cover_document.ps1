# COM logic separated for offline inert-object tests. Never activates an Application.
function Open-CoverSnapshot($Documents, [string]$Snapshot) {
    # VT_ERROR/DISP_E_PARAMNOTFOUND preserves Word defaults without CLR Missing/default substitution.
    $missing = [Runtime.InteropServices.ErrorWrapper]::new(-2147352572)
    # Actual Office dispatch/return remains a separate native acceptance gate.
    return ,$Documents.Open($Snapshot, $false, $true, $false,
        'not-a-supplied-password', 'not-a-supplied-password', $false,
        'not-a-supplied-password', 'not-a-supplied-password', 0, $missing,
        $false, $false, $missing, $true, $missing)
}
function Assert-CoverStartupBlank($Blank, [scriptblock]$Track) {
    # Metadata only: Path='' alone also describes recovered/unsaved content. Never read Text/Name.
    if ($Blank.Path -ne '' -or $Blank.Saved -ne $true -or $Blank.Type -ne 0 -or
        $Blank.ReadOnly -ne $false -or $Blank.ProtectionType -ne -1) { throw 'startup_document_not_fresh_blank' }
    $content = & $Track $Blank.Content
    if ($content.Start -ne 0 -or $content.End -ne 1 -or $content.StoryType -ne 1) { throw 'startup_document_not_fresh_blank' }
    foreach ($key in @('Characters','Paragraphs','Sections','StoryRanges')) {
        $collection = & $Track $Blank.$key
        if ($collection.Count -ne 1) { throw 'startup_document_not_fresh_blank' }
    }
    foreach ($key in @('Fields','Shapes','InlineShapes','Tables','Frames','ContentControls','Hyperlinks',
                       'Comments','Revisions','Footnotes','Endnotes','Variables')) {
        $collection = & $Track $Blank.$key
        if ($collection.Count -ne 0) { throw 'startup_document_not_fresh_blank' }
    }
    $next = & $Track $content.NextStoryRange
    if ($null -ne $next) { throw 'startup_document_not_fresh_blank' }
}
function Invoke-CoverDocument {
    param($Application, $Config, [scriptblock]$Guard, [scriptblock]$Track, [scriptblock]$Phase)
    $document = $null; $closed = $false; $closeAttempted = $false; $saved = @{}; $optionSaved = @{}
    $options = $null; $failure = $null; $counts = @(); $operation = 'security'
    try {
        & $Guard; & $Phase 'security'
        foreach ($key in @('AutomationSecurity', 'DisplayAlerts')) { $saved[$key] = $Application.$key }
        $Application.AutomationSecurity = 3; $Application.DisplayAlerts = 0
        $options = & $Track $Application.Options
        foreach ($key in @('UpdateLinksAtOpen','UpdateFieldsAtPrint','UpdateLinksAtPrint','SaveNormalPrompt','ConfirmConversions')) {
            $optionSaved[$key] = $options.$key; $options.$key = $false
        }
        if ($Application.AutomationSecurity -ne 3 -or $options.UpdateLinksAtOpen -or
            $options.UpdateFieldsAtPrint -or $options.UpdateLinksAtPrint) { throw 'security_options_not_applied' }
        & $Guard
        $documents = & $Track $Application.Documents
        # Zero docs need no close; at most one demonstrably fresh own startup blank may close.
        if ($documents.Count -gt 1) { throw 'unexpected_startup_documents' }
        if ($documents.Count -eq 1) {
            $blank = & $Track $documents.Item(1)
            Assert-CoverStartupBlank $blank $Track
            & $Guard
            $blank.Close(0)
        }
        $operation = 'open'; & $Guard; & $Phase 'open'
        # No source on CLI; snapshot only, readonly/no MRU/no repair/no conversion or password prompts.
        $document = & $Track (Open-CoverSnapshot $documents $Config.snapshot)
        $operation = 'matches'; & $Guard; & $Phase 'matches'
        $signatures = & $Track $document.Signatures
        if ($signatures.Count -gt 0) { throw 'digitally_signed_source_not_supported' }
        if ($Config.replace.get_Count() -gt 0) {
            $main = & $Track $document.Content
            $fields = & $Track $main.Fields
            $shapes = & $Track $document.Shapes
            $inline = & $Track $document.InlineShapes
            if ($fields.Count -gt 0 -or $shapes.Count -gt 0 -or $inline.Count -gt 0) { throw 'replacement_fields_shapes_unsupported' }
            $stories = & $Track $document.StoryRanges
            for ($storyType = 2; $storyType -le 17; $storyType++) {
                # Word missing story is COM HRESULT 0x800A1735 (5941), not an arbitrary ignored COM error.
                $story = $null
                try { $story = & $Track $stories.Item($storyType) }
                catch [Runtime.InteropServices.COMException] {
                    if ($_.Exception.HResult -ne -2146822347) { throw }
                }
                while ($null -ne $story) {
                    $storyFields = & $Track $story.Fields
                    if ($storyFields.Count -gt 0 -or -not [string]::IsNullOrWhiteSpace([string]$story.Text)) { throw 'replacement_nonmain_story_unsupported' }
                    $story = & $Track $story.NextStoryRange
                }
            }
            $text = [string]$main.Text; $expectedText = $text; $edits = @()
            foreach ($old in $Config.replace.get_Keys()) {
                $positions = @(); $offset = 0
                while ($offset -le $text.Length - $old.Length) {
                    $position = $text.IndexOf($old, $offset, [StringComparison]::Ordinal)
                    if ($position -lt 0) { break }
                    $positions += $position; $offset = $position + $old.Length
                }
                if ($positions.Count -ne $Config.expected_counts[$old]) { throw 'literal_count_mismatch' }
                $counts += @{ old=$old; expected=$Config.expected_counts[$old]; observed=$positions.Count }
                foreach ($position in $positions) { $edits += @{start=$position; end=$position+$old.Length; old=$old; new=$Config.replace[$old]} }
            }
            $lastEnd = -1
            foreach ($change in ($edits | Sort-Object start)) {
                if ($change.start -lt $lastEnd) { throw 'overlapping_literal_matches' }
                $lastEnd = $change.end
            }
            foreach ($change in ($edits | Sort-Object start -Descending)) {
                & $Guard
                $range = & $Track $document.Range(($main.Start + $change.start), ($main.Start + $change.end))
                if (-not [string]::Equals([string]$range.Text, $change.old, [StringComparison]::Ordinal)) { throw 'matched_range_not_literal' }
                $range.Text = $change.new
                $expectedText = $expectedText.Remove($change.start, $change.end-$change.start).Insert($change.start, $change.new)
            }
            $after = & $Track $document.Content
            if (-not [string]::Equals([string]$after.Text, $expectedText, [StringComparison]::Ordinal)) { throw 'literal_postflight_mismatch' }
            foreach ($item in $counts) { $item.postflight = 'exact_main_text_transform_verified' }
        }
        $operation = 'save'; & $Guard; & $Phase 'save'
        if ([IO.File]::Exists($Config.doc) -or [IO.File]::Exists($Config.pdf)) { throw 'private_output_exists' }
        $format = if ([IO.Path]::GetExtension($Config.doc) -eq '.doc') { 0 } else { 16 }
        $document.SaveAs2($Config.doc, $format, $false, '', $false)
        $operation = 'export'; & $Guard; & $Phase 'export'
        $document.ExportAsFixedFormat($Config.pdf, 17, $false)
        if ($Config.replace.get_Count() -gt 0) {
            $exportedText = & $Track $document.Content
            if (-not [string]::Equals([string]$exportedText.Text, $expectedText, [StringComparison]::Ordinal)) { throw 'saved_exported_postflight_mismatch' }
        }
        $operation = 'close'; & $Phase 'close'
        $closeAttempted = $true; $document.Close(0); $closed = $true
    } catch { $failure = $_; $failure.Exception.Data['cover_phase'] = $operation }
    finally {
        if ($document -and -not $closeAttempted) {
            try { & $Phase 'cleanup_close'; & $Guard; $closeAttempted=$true; $document.Close(0); $closed=$true }
            catch { & $Phase 'cleanup_close_failed'; if (-not $failure) { $failure=$_; $failure.Exception.Data['cover_phase']='cleanup_close' } }
        }
        try {
            if ($options) { foreach ($key in $optionSaved.Keys) { $options.$key = $optionSaved[$key] } }
            foreach ($key in $saved.Keys) { $Application.$key = $saved[$key] }
        } catch { if (-not $failure) { $failure = $_; $failure.Exception.Data['cover_phase']='restore' } }
    }
    if ($failure) { throw $failure }
    if (-not $closed) { throw 'document_close_unproven' }
    return @{ document_closed=$true; replacement_counts=$counts; coverage=$(if ($counts.Count) {'main_story_only_no_fields_shapes'} else {'passthrough_no_story_acceptance'}) }
}
