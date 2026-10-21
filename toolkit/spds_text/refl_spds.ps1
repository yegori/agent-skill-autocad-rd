# Просмотр .NET API СПДС GraphiCS (MultiCAD): члены классов из mapimgd.dll / mapibasetypes.dll.
# Запускать в Windows PowerShell 5.1 (не pwsh): powershell.exe -File refl_spds.ps1 Multicad.Symbols.Tables.McTable Multicad.Symbols.McNotePosition
# Документация (неполная) — mg142x64\mapimgd.xml; классы объектов на чертеже: mcsDbObjectTable2 → McTable,
# mcsDbObjectNoteMultilayer → McNoteMultilayer, mcsDbObjectNotePosition → McNotePosition.
$dir = if ($env:RDCI_SPDS_DIR) { $env:RDCI_SPDS_DIR } else { "C:\Program Files\CSoft\СПДС GraphiCS 2023 x64\mg142x64" }
$acad = if ($env:RDCI_ACAD_DIR) { $env:RDCI_ACAD_DIR } else { "C:\Program Files\Autodesk\AutoCAD 2024" }
[AppDomain]::CurrentDomain.add_ReflectionOnlyAssemblyResolve({ param($s, $e)
  $n = (New-Object Reflection.AssemblyName $e.Name).Name
  foreach ($d in $dir, $acad) { $f = Join-Path $d "$n.dll"; if (Test-Path $f) { return [Reflection.Assembly]::ReflectionOnlyLoadFrom($f) } }
  try { return [Reflection.Assembly]::ReflectionOnlyLoad($e.Name) } catch { return $null } })
$types = @()
foreach ($x in "mapimgd.dll", "mapibasetypes.dll") {
  $a = [Reflection.Assembly]::ReflectionOnlyLoadFrom("$dir\$x")
  try { $types += $a.GetTypes() } catch [Reflection.ReflectionTypeLoadException] { $types += $_.Exception.Types | ? { $_ } } }
if (-not $args) { "Укажите полные имена типов. Пример поиска: типы с 'Note' в имени:"; $types | ? { $_.FullName -match "Note" } | % { $_.FullName }; return }
foreach ($tn in $args) {
  $t = $types | ? { $_.FullName -eq $tn } | Select -First 1; if (-not $t) { "НЕТ $tn"; continue }
  "===== $tn  base=" + [string]$t.BaseType.FullName
  $t.GetMembers([Reflection.BindingFlags]"Public,Instance,Static,DeclaredOnly") | % { try { "  " + $_.MemberType + " " + $_.ToString() } catch { "  ?" } } | Sort -Unique
}
