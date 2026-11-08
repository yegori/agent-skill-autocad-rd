# Direct dependencies через side Database — эксперимент, native acceptance НЕ пройдена

08.11.2026. Продолжение explicit staging (`16_staging_plot.md`). Новые методы **не развёрнуты** в рабочем
пакете RYZENDT: там остаётся проверенный a8f1a54. Не включать печать/общий consumer по этой заготовке.

## Зачем отдельный side database reader

Нельзя доказывать полную dependency closure перечнем всех Fonts/Plotters: это envelope, не содержимое DWG.
Обычное открытие неизвестной DWG как документа может разрешать внешние ссылки. Новый reader использует один
**отдельно проверенный safe host**, source копирует и читает через Database.ReadDwgFile/CloseInput(true),
не делает source Document.Open/current database, ResolveXrefs, FindFile, SaveAs или print.
Это уменьшает неявную загрузку refs, но НЕ filesystem sandbox/гарантия изоляции системных брокеров AutoCAD.

## Что подготовлено

- `toolkit/dependencies/DependencyProbe.cs`: нативная команда RDDEPENDENCIES внутри accoreconsole;
  block-table xref paths/status, STYLE font filenames/big fonts/typeface, layout paper/device/style sheet,
  Image/PDF/DWF/DGN definition dictionaries. Source SHA до/после чтения. Лишь первый уровень/таблицы,
  не использованные glyphs/реальный GDI font substitution/полный graph/СПДС custom resources/material textures.
- `toolkit/inspect_dependencies.ps1`: ровно один CAD-start на safe host copy, fresh EvidenceDir, SDK compile,
  source/host/copy SHA, request/raw/probe evidence; native command пишет JSON, закрывает его, только потом ALLDONE.
  Lisp не пишет marker после команды: NETLOAD/command error не проскочит к фиктивному успешному маркеру.
  Root жив до cleanup private Job, mode=owned_job_after_side_database_read, exit_code=null, timeout<=300.
  DLL/SCR/host paths должны быть короткими ASCII (NETLOAD ограничение); managed source copy может сохранить имя.
- `toolkit/dependency_inventory.py`: проверяет native SHA/marker/source и completion proof, читает только
  candidate files внутри явно разрешённых roots; reparse проверяется до обхода/открытия.
  Xref/asset — точный путь относительно source, не поиск по basename и не env expansion. Escape/missing => needs_input.
  Xref DWG даже найденная требует nested probe; absolute path не объявляется staged-путём.
  Font filenames ищутся только в явных project/fonts roots: разные bytes => ambiguity, missing/registry-only => вопрос.
  FONTALT/FONTMAP лишь metadata host, не применённая замена/доказательство actual font resolution.
- Output всегда coverage=direct_tables_and_asset_dictionaries, dependency_complete=false,
  execution_authorized=false, omissions сохранены. observed_partial не approval/reuse/полная проверка.
  Нет automatic stage/печати, перепривязки, копирования шрифтов в Windows или изменения PC3/PMP.

Пример будущего контролируемого вызова **только после снятия operational blocker согласованной процедурой**:

```text
pwsh -NoProfile -File toolkit/inspect_dependencies.ps1 -SourceDwg <copy.dwg> -HostDwg <approved-safe-host.dwg> -EvidenceDir <new-ascii-dir> -TimeoutSec 120
python -I toolkit/dependency_inventory.py <evidence> --source-root <authorized-input> --source-path <relative.dwg> --environment-roots <local-roots.json> --output <new-inventory.json>
```

10 unit tests без CAD: partial/no auth, parent escape without file read, nested refs, assets/missing,
missing/ambiguous/registry fonts, unproven completion/source drift, raw-evidence hash/exclusive output,
reserved root/omissions. `check_package.py` — 26 Python sources; local Claude plugin validation passed
с прежним missing-version warning. ABI C# успешно скомпилирован против реальных AutoCAD 2024 DLL на RYZENDT,
**это не выполнение plugin/не подтверждение работоспособности native API**.

## Почему нет native acceptance

Private acceptance driver использовал общий monitor/Job wrapper. Его локальная переменная original (Path)
затёрла original Job factory в globals. После durable execution_guard running, но **до job_api.Job/_exchange/Popen**
получен TypeError. В work только task.json; нет process.json/containment/Pi session/native reports. Ни A4, ни BIG не исследованы.
Private launcher до этого также отказал на пропущенном дефисе EncodedCommand, до регистрации task; failure сохранён.

Guard корректно сохранил барьер. Установлена pause, inspect сообщает process_evidence_missing, ready_for_manual=false,
CAD свободен; 70 защищённых файлов/28 Plotters/config прежние. Своё завершённое failed scheduled task удалено,
состояние executor НЕ очищалось. Driver исправлен локально, **не повторён**. Нельзя дополнять старое full evidence
новым baseline/подделывать windows_job containment или обходить барьер отдельным control-root.

Операционный blocker и приватный locator — rd-ci `docs/00_session_handoff.md`, `docs/28_dependency_prelaunch.md`.
Дальше нужны явный разбор prelaunch barrier и затем новый UUID/native acceptance, не replay старого.
