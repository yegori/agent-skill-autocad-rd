# End-to-end wrapper with inert bytes/fake owner and prebuilt dummy DLL. Never CAD.
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$root=Join-Path $env:TEMP ('rdci-rowdel-wrapper-'+[Guid]::NewGuid().ToString('N'))
$package=Split-Path $PSScriptRoot
New-Item -ItemType Directory -Path "$root/toolkit/spds_text","$root/work/bin" | Out-Null
foreach($name in @('run_txtfix.ps1','rowdel_plan.ps1','RowDeletion.cs','SpdsText.cs','SpdsDependencies.cs')){
 Copy-Item -LiteralPath (Join-Path $package "toolkit/spds_text/$name") -Destination "$root/toolkit/spds_text/$name"
}
[IO.File]::WriteAllText("$root/work/bin/SpdsText.dll",'dummy never loaded')
[IO.File]::SetLastWriteTimeUtc("$root/work/bin/SpdsText.dll",[DateTime]::UtcNow.AddDays(1))
[IO.File]::WriteAllText("$root/toolkit/common.ps1",@'
$Global:WorkRoot=Join-Path (Split-Path $PSScriptRoot) 'work';$Global:AcadExe='never-real-acad'
function Copy-DwgToWork($Files,$WorkDir){New-Item -ItemType Directory -Path $WorkDir | Out-Null;$w=Join-Path $WorkDir '001~1.dwg';Copy-Item -LiteralPath $Files[0] -Destination $w;[pscustomobject]@{Src=$Files[0];Work=$w;N=1}}
function Write-Scr($Path,$Text){[IO.File]::WriteAllText($Path,$Text)}
function Test-FileFree($Path){return $true}
'@)
[IO.File]::WriteAllText("$root/toolkit/spds_text/owned_acad.ps1",@'
function Invoke-OwnedTxtfixProcess {
 param($FilePath,$Arguments,$Log,$TimeoutSec)
 if($FilePath -ne 'never-real-acad'){throw 'native_forbidden'}
 if($env:TXT_ROWDEL -ne 'A:0=header'){throw 'rowdel_transport_failed'}
 $lines=@("FILE|$env:TXT_IN|dry=$env:TXT_DRY")
 if($env:ROWDEL_FAKE -eq 'error'){$lines+='ERROR|rowdel|guard_mismatch'}
 elseif($env:TXT_DRY -eq '1'){$lines+='ROWDEL_OK|dry=True|changed=0';$lines+='DONE|changed=0|mcs=1'}
 else{
  [IO.File]::WriteAllText($env:TXT_OUT,'fixed synthetic bytes')
  $lines+="SAVED|$env:TXT_OUT";$lines+='ROWDEL_OK|dry=False|changed=1';$lines+='DONE|changed=1|mcs=1'
  if($env:ROWDEL_FAKE -eq 'source_changed'){[IO.File]::WriteAllText($env:ROWDEL_SOURCE,'external edit')}
 }
 $lines+='ALLDONE';$lines | Set-Content -LiteralPath $Log -Encoding utf8
 [pscustomobject]@{AllDone=$true;TimedOut=$false;ElapsedSeconds=0.01}
}
'@)
$source=Join-Path $root '001 исходник.dwg'
$invoke=Join-Path $root 'toolkit/spds_text/run_txtfix.ps1'
$oldRow=$env:TXT_ROWDEL;$oldFake=$env:ROWDEL_FAKE;$oldSource=$env:ROWDEL_SOURCE
try{
 $env:TXT_ROWDEL='caller-sentinel';$env:ROWDEL_SOURCE=$source
 [IO.File]::WriteAllText($source,'original synthetic bytes')
 & $invoke -Files @($source) -Mode rowdel -RowDel 'A:0=header' -Dry | Out-Host
 if([IO.File]::ReadAllText($source) -ne 'original synthetic bytes' -or $env:TXT_ROWDEL -ne 'caller-sentinel'){throw 'dry_mutation_or_env_leak'}
 $env:ROWDEL_FAKE='error';$failed=$false
 try{& $invoke -Files @($source) -Mode rowdel -RowDel 'A:0=header' -Apply | Out-Host}catch{if($_.Exception.Message -like 'rowdel_failed*'){$failed=$true}else{throw}}
 if(-not $failed -or [IO.File]::ReadAllText($source) -ne 'original synthetic bytes'){throw 'error_applied'}
 $env:ROWDEL_FAKE='source_changed';$failed=$false
 try{& $invoke -Files @($source) -Mode rowdel -RowDel 'A:0=header' -Apply | Out-Host}catch{if($_.Exception.Message -eq 'rowdel_source_changed_before_apply'){$failed=$true}else{throw}}
 if(-not $failed -or [IO.File]::ReadAllText($source) -ne 'external edit'){throw 'concurrent_edit_overwritten'}
 $env:ROWDEL_FAKE='';[IO.File]::WriteAllText($source,'original synthetic bytes')
 & $invoke -Files @($source) -Mode rowdel -RowDel 'A:0=header' -Apply | Out-Host
 if([IO.File]::ReadAllText($source) -ne 'fixed synthetic bytes'){throw 'valid_fake_apply_failed'}
 $backups=@(Get-ChildItem "$root/work/backup" -Recurse -File)
 if($backups.Count -ne 1 -or [IO.File]::ReadAllText($backups[0].FullName) -ne 'original synthetic bytes'){throw 'backup_not_retained'}
 if(@(Get-ChildItem "$root/work" -Directory -Filter 'txtfix_rowdel_*').Count -ne 4 -or $env:TXT_ROWDEL -ne 'caller-sentinel'){throw 'work_reuse_or_env_leak'}
 'OK: fake wrapper dry/guard failure/concurrent-edit rejection/backup Apply; unique work and environment restoration, no CAD'
}finally{$env:TXT_ROWDEL=$oldRow;$env:ROWDEL_FAKE=$oldFake;$env:ROWDEL_SOURCE=$oldSource}
"Artifacts: $root"
