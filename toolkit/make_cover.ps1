# Обложка/титул комплекта из шаблона Word: копия .doc с заменой фраз + экспорт в PDF (Word COM, Word должен быть установлен).
#   .\make_cover.ps1 -Template "…\01_В590_110504_1_6_ИЗ11.doc" -Out "…\DWG\01_В590_110504_1_6_ИЗ2.doc" `
#                    -Replace ([ordered]@{ "ВОДОПРОПУСКНОЕ СООРУЖЕНИЕ В-5А-2" = "ВОДОПРОПУСКНОЕ СООРУЖЕНИЕ В-4А-2";
#                                         "ГОРНОЛЫЖНАЯ ТРАССА T5A" = "ГОРНОЛЫЖНАЯ ТРАССА T4A"; "01/B590.110504.1.6-ИЗ11" = "01/B590.110504.1.6-ИЗ2" }) `
#                    [-Pdf "…\PDF\01_В590_110504_1_6_ИЗ2.pdf"]
# Заменять фразы ЦЕЛИКОМ (напр. «T5A» встречается и в названии проекта). Порядок замен — как в [ordered]-таблице.
# Шифр в тексте — латинская B (01/B590…); имя файла обложки исторически с кириллической В.
# Проверка результата: python pdf_tools.py grep <pdf> "<новый шифр>"
param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][System.Collections.IDictionary]$Replace,
      [string]$Pdf = "", [switch]$Force)
if ((Test-Path -LiteralPath $Out) -and -not $Force) { throw "$Out уже есть (-Force — перезаписать)" }
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
Copy-Item -LiteralPath $Template $Out -Force
$wd = New-Object -ComObject Word.Application; $wd.Visible = $false; $wd.DisplayAlerts = 0
try {
  $d = $wd.Documents.Open($Out, $false, $false)
  foreach ($k in $Replace.Keys) {
    $f = $d.Content.Find
    # Execute(FindText, MatchCase, MatchWholeWord, MatchWildcards, MatchSoundsLike, MatchAllWordForms, Forward, Wrap, Format, ReplaceWith, Replace=2 (все))
    $ok = $f.Execute($k, $true, $false, $false, $false, $false, $true, 0, $false, $Replace[$k], 2)
    "{0} «{1}» → «{2}»" -f $(if ($ok) { "заменено" } else { "НЕ НАЙДЕНО" }), $k, $Replace[$k]
  }
  $d.Save()
  if ($Pdf) { New-Item -ItemType Directory -Force (Split-Path $Pdf) | Out-Null; $d.ExportAsFixedFormat($Pdf, 17); "PDF: $Pdf" }
  $d.Close($false)
} finally { $wd.Quit(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wd) }
