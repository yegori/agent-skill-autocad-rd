# Private per-CAD Job: CreateProcess suspended -> assign -> resume. No PID/tree enumeration or shell broker.
function Invoke-OwnedTxtfixProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Log,
        [ValidateRange(1, 86400)][int]$TimeoutSec = 3600
    )
    if (-not ('AutocadRd.OwnedCadProcess' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'OwnedCadProcess.cs') -ErrorAction Stop
    }
    $process = $null
    $allDone = $false
    $timedOut = $false
    $terminated = $false
    $rootExitedBeforeStop = $null
    $rootExitCodeBeforeStop = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [AutocadRd.OwnedCadProcess]::Start($FilePath, $Arguments)
        while ($true) {
            if ((Test-Path -LiteralPath $Log) -and
                (Select-String -LiteralPath $Log -Pattern '^ALLDONE$' -Quiet -ErrorAction Stop)) {
                $allDone = $true
                break
            }
            if ($process.HasExited) { break }
            $remaining = $TimeoutSec - $clock.Elapsed.TotalSeconds
            if ($remaining -le 0) { $timedOut = $true; break }
            $process.Wait([int][Math]::Min(1000, [Math]::Max(1, $remaining * 1000)))
        }
        if (-not $allDone -and -not $timedOut -and (Test-Path -LiteralPath $Log)) {
            $allDone = [bool](Select-String -LiteralPath $Log -Pattern '^ALLDONE$' -Quiet -ErrorAction Stop)
        }
    } finally {
        if ($process) {
            try {
                try {
                    $rootExitedBeforeStop = $process.HasExited
                    if ($rootExitedBeforeStop) { $rootExitCodeBeforeStop = $process.ExitCode }
                } finally { $terminated = $process.Stop() }
            }
            finally { $process.Dispose() }
        }
    }
    [pscustomobject]@{ AllDone = $allDone; TimedOut = $timedOut; Terminated = $terminated; RootExitedBeforeStop = $rootExitedBeforeStop;
                       RootExitCodeBeforeStop = $rootExitCodeBeforeStop; ElapsedSeconds = $clock.Elapsed.TotalSeconds }
}
