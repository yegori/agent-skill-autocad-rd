# Подключить текущую рабочую копию к Pi без копирования и без запуска AutoCAD.
# pwsh -File scripts/install.ps1
# Старые источники удалить отдельно по docs/INSTALL.md, чтобы не менять чужие настройки молча.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$PackageRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
    throw 'Pi не найден в PATH. Сначала установите Pi.'
}
& pi install $PackageRoot
if ($LASTEXITCODE -ne 0) { throw "pi install завершился с кодом $LASTEXITCODE" }
Write-Host 'Пакет подключён. В активной сессии Pi выполните /reload.'
