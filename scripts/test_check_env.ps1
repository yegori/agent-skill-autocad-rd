# Isolated diagnostics tests: no AutoCAD/COM, filesystem configuration or real dependencies.
$ErrorActionPreference = 'Stop'
$source = Get-Content (Join-Path $PSScriptRoot '../toolkit/check_env.ps1') -Raw -Encoding utf8
$definition = [regex]::Match($source, '(?ms)^function Row\(.*?^\}').Value
if (-not $definition) { throw 'Row definition missing' }
. ([scriptblock]::Create($definition))

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$script:ok = $true
$output = Row 'required' $true 'present' | Out-String
Assert ($script:ok -and $output.StartsWith('OK ')) 'Present required dependency must pass'

$script:ok = $true
$output = Row 'optional' $false 'absent' 'scope-specific guidance' -Optional | Out-String
Assert ($script:ok -and $output.StartsWith('-- ') -and $output.Contains('scope-specific guidance')) 'Missing optional dependency must warn, not fail'

$script:ok = $true
$output = Row 'required' $false 'absent' | Out-String
Assert (-not $script:ok -and $output.StartsWith('!! ')) 'Missing required dependency must fail'

$script:ok = $false
$null = Row 'optional' $false 'absent' -Optional
Assert (-not $script:ok) 'Optional warning must not erase an earlier failure'

Assert ([regex]::IsMatch($source, '(?m)^Row "PMP .* -Optional\s*$')) 'PMP row must be optional for standard paper'
Assert ($source.Contains('check_papers.ps1 без -Add')) 'PMP guidance must not authorize changing paper configuration'
Write-Output 'OK: 6 isolated check_env assertions; no CAD/configuration changes'
