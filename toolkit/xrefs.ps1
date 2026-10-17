# Внешние ссылки DWG: список (имя, путь, найден ли файл), перепривязка и докопирование недостающих.
#   .\xrefs.ps1 -DwgDir "…\DWG"                       # отчёт (проверка S4)
#   .\xrefs.ps1 -Files a.dwg -Relativize [-Apply]      # пути -> .\Внешние_ссылки\<файл>.dwg (как в остальных листах)
#   .\xrefs.ps1 -DwgDir "…\DWG" -CopyMissingFrom "…\другая выдача\DWG\Внешние_ссылки" [-Apply]
# Статусы: OK (путь относительный .\Внешние_ссылки\… и файл есть) / НЕ ОТНОСИТЕЛЬНЫЙ / НЕТ ФАЙЛА.
# Перепривязка — на копии (рядом с копией папки ссылок), с -Apply исходник заменяется (резервная копия обязательна).
param([string[]]$Files = @(), [string]$DwgDir = "", [switch]$Relativize, [string]$CopyMissingFrom = "", [switch]$Apply,
      [string]$XrefFolder = "Внешние_ссылки", [string]$Exclude = '_recover')
. "$PSScriptRoot\common.ps1"
if ($DwgDir) { $Files += @(Get-ChildItem -LiteralPath $DwgDir -Filter *.dwg | Where-Object { -not ($Exclude -and $_.Name -match $Exclude) } | Sort-Object Name | ForEach-Object FullName) }
$bak = Join-Path $WorkRoot ("backup\xrefs_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
$w = Join-Path $WorkRoot "xrefs"; Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
$jobs = Copy-DwgToWork $Files $w
$listLsp = @'
(setq fo (open OUTF "w" "utf8") b (tblnext "BLOCK" T))
(while b
  (if (= 4 (logand 4 (cdr (assoc 70 b)))) (write-line (strcat (cdr (assoc 2 b)) "|" (cdr (assoc 1 b))) fo))
  (setq b (tblnext "BLOCK")))
(close fo)
'@
$rows = @(); $need = @{}
foreach ($j in $jobs) {
  $out = (Join-Path $w "x$($j.N).txt") -replace '\\', '/'
  $null = Invoke-AccCore $j.Work ($LispHead + "(setq OUTF `"$out`")`n" + $listLsp + $LispQuit) (Join-Path $w "x$($j.N).log") 600
  $dir = Split-Path $j.Src
  foreach ($l in (Get-Content ($out -replace '/', '\') -Encoding utf8 -ErrorAction SilentlyContinue)) {
    $name, $path = $l -split '\|', 2
    $leaf = Split-Path $path -Leaf
    $want = ".\$XrefFolder\$leaf"
    $abs = if ([IO.Path]::IsPathRooted($path)) { $path } else { [IO.Path]::GetFullPath((Join-Path $dir $path)) }
    $exists = Test-Path -LiteralPath $abs
    $st = if ($path -ieq $want -and $exists) { "OK" } elseif (-not $exists) { "НЕТ ФАЙЛА" } else { "НЕ ОТНОСИТЕЛЬНЫЙ" }
    $rows += [pscustomobject]@{ File = (Split-Path $j.Src -Leaf); Xref = $name; Path = $path; Status = $st }
    if ($st -ne "OK") { $need[$j.N] = @($need[$j.N]) + , @($name, $want) }
  }
}
$rows | Format-Table -AutoSize | Out-String -Width 260
# недостающие файлы ссылок в папке выдачи
if ($CopyMissingFrom) {
  $dirs = @($Files | ForEach-Object { Split-Path $_ } | Sort-Object -Unique)
  foreach ($d in $dirs) {
    $xd = Join-Path $d $XrefFolder
    $leafs = @($rows | Where-Object { $_.File -and (Test-Path -LiteralPath (Join-Path $d $_.File)) } | ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object -Unique)
    foreach ($lf in $leafs) {
      if (-not (Test-Path -LiteralPath (Join-Path $xd $lf)) -and (Test-Path -LiteralPath (Join-Path $CopyMissingFrom $lf))) {
        if ($Apply) { New-Item -ItemType Directory -Force $xd | Out-Null; Copy-Item -LiteralPath (Join-Path $CopyMissingFrom $lf) (Join-Path $xd $lf); "докопировано: $xd\$lf" }
        else { "будет докопировано (с -Apply): $xd\$lf" }
      }
    }
  }
}
# перепривязка на копиях
if ($Relativize) {
  foreach ($j in $jobs) {
    if (-not $need[$j.N]) { continue }
    $cmds = ($need[$j.N] | Where-Object { $_ } | ForEach-Object { "(command `"_.-XREF`" `"_P`" `"$($_[0])`" `"$($_[1] -replace '\\','\\')`")" }) -join "`n"
    $r = Invoke-AccCore $j.Work ($LispHead + $cmds + "`n(princ `"\nDONE-`")" + $LispSaveQuit) (Join-Path $w "r$($j.N).log") 600
    "{0}: перепривязано {1}" -f (Split-Path $j.Src -Leaf), @($need[$j.N] | Where-Object { $_ }).Count
    if ($Apply) {
      if (-not (Test-FileFree $j.Src)) { "   !!! открыт у пользователя — не заменён"; continue }
      New-Item -ItemType Directory -Force $bak | Out-Null
      try { Copy-Item -LiteralPath $j.Src "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)" -Force -ErrorAction Stop
          if ((Get-Item -LiteralPath "$bak\f$($j.N)_$(Split-Path $j.Src -Leaf)").Length -ne (Get-Item -LiteralPath $j.Src).Length) { throw "размер копии не совпадает с оригиналом" } }
      catch { "   !!! резервная копия не создана — исходник НЕ заменён: $($_.Exception.Message)"; continue }
      Copy-Item $j.Work -Destination $j.Src -Force; "   заменён (оригинал: $bak)"
    }
  }
  if (-not $Apply) { "(пробный прогон: исходники не тронуты; результат — $w)" }
}
