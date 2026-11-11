# Три явно выбранные xref → одна НОВАЯ подготовленная DWG-копия

**Offline candidate, НЕ native-accepted.** Новый write/SaveAs mode не наследует приёмку
ControlledRead/ControlledPlot/dependency reader. Нужны отдельные реальные SDK compile и scoped acceptance.
Никаких автоматических запусков, deployment, рекурсивного discovery, инженерных правок или выдачи здесь нет.
`docs/17_dependency_probe.md` и его reader остаются только read-only.

## Контракт

`prepare_xref_copy.ps1` + `prepare_xref_copy.py` + `dependencies/PrepareXrefCopy.cs`:

- Ровно один явно выбранный source, его approved source root/relative path/SHA; ровно три карты
  **handle + name + EXACT old PathName → explicit new relative PathName + exact supplied target SHA**.
  Handles имеют смысл лишь вместе с SHA этой DWG. Разные old name/path/handle → отказ до SaveAs.
- Источник и отдельный safe host привязаны SHA. Host допускает caller, его SHA обязателен в CLI.
  Source читается из отдельного физического snapshot с полным именем; source не становится документом.
- Caller заранее создаёт **отдельную NEW issue tree**, явно staging dependencies/signature assets, например
  через [stage_inputs.py](16_staging_plot.md). Tool ничего не ищет/не докопирует и не угадывает по basename.
  `issue_root` — выбранное private NEW дерево, не старая выдача; родитель final DWG может уже существовать
  после staging supplied targets/signature assets. Например `dwg/Внешние_ссылки/…` рядом с будущей `dwg/001 Example.dwg`.
- Source root отделён от нового output. Evidence — новый ASCII-каталог, отделённый от issue/source/host/package.
  Нельзя перезаписывать ни output, ни evidence, ни источник, ни старые снимки. Нет `-Apply`, cleanup/retry.
  Partial directories сохраняются; следующая попытка — новые пути, только после разбора отказа.
- Output filename **полностью совпадает** с source filename, включая кириллицу/пробелы. Пример ниже fake.
  Только exact output, evidence и `_pending_<uuid>` должны быть NEW/exclusive; существующий non-reparse
  output parent разрешён, supplied hashed targets могут быть его потомками. Pending DWG сохраняет полное имя.
  Source-root/package/host/evidence overlaps, links/aliases и существующий exact output по-прежнему запрещены.
  Windows `os.rename` без replace публикует DWG только после проверок и собственного Job cleanup.
- New paths — Windows relative strings (`\\` в JSON); внутренние произвольные subfolders допустимы.
  `..` допустим только пока **каждый шаг** остаётся внутри issue. Разрешение относительно FINAL referring DWG,
  а не от issue root. Rooted/UNC/drive-relative/ADS/escape/wildcard/device aliases отклоняются.
  Old absolute path лишь сравнивается как строка — его цель не открывается, не обязана существовать.
  Не утверждается old/new эквивалентность. No-op/duplicates/target collisions/missing/wrong SHA → отказ.
- Проверяются regular files, containment, symlink/reparse ancestors и hardlink `st_nlink=1` у входов,
  snapshots, targets и результата. Это защита от обычных alias-ошибок, **не filesystem sandbox/защита от
  конкурентного злонамеренного подмена каталога**. Деревья должны быть private, без иных writers.

## Generic fake spec (не проектные данные)

Все SHA ниже — placeholders, заменить точными SHA уже supplied файлов; нули не являются рабочими hashes.

```json
{
  "schema_version": 1,
  "source_root": "D:/scratch/source-snapshot",
  "source_path": "001 Example.dwg",
  "source_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "issue_root": "D:/scratch/new-issue",
  "output_path": "dwg/001 Example.dwg",
  "mappings": [
    {"handle":"A1", "name":"Frame", "old_path":"Z:\\old\\frame.dwg", "new_path":".\\Внешние_ссылки\\frame.dwg", "target_sha256":"0000000000000000000000000000000000000000000000000000000000000000"},
    {"handle":"A2", "name":"Survey", "old_path":"Z:\\old\\survey.dwg", "new_path":".\\Внешние_ссылки\\nested\\survey.dwg", "target_sha256":"0000000000000000000000000000000000000000000000000000000000000000"},
    {"handle":"A3", "name":"Plan", "old_path":"Z:\\old\\plan.dwg", "new_path":".\\Внешние_ссылки\\plan.dwg", "target_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
  ]
}
```

После отдельного live authorization/preflight и общего single-CAD guard, **не запускать из offline worker**:

```text
pwsh -NoProfile -File toolkit/prepare_xref_copy.ps1 -Spec <private-map.json> -HostDwg <approved-safe-host.dwg> -HostSha256 <exact-sha256> -EvidenceDir <NEW-ascii-evidence> -TimeoutSec 120
```

Внутренние offline Python CLI:

```text
python -I toolkit/prepare_xref_copy.py preflight <map.json> --host <safe.dwg> --host-sha <sha256> --evidence <NEW-dir>
python -I toolkit/prepare_xref_copy.py finish --evidence <same-dir>
```

`finish` требует closed native JSON/marker и **сохранённый owned helper result**, а не ручной marker.
Не фабриковать proof для реального запуска. Значения execution_authorized=false в outputs не заменяют caller authorization.

## Native API и lifetime

Отдельная команда `RDPREPAREXREFCOPY`, request через `RDCI_PREPARE_REQUEST` (JSON, не Lisp-интерполяция
xref names/paths). Wrapper временно ставит SECURELOAD=0 на NETLOAD и восстанавливает/проверяет **до** команды.
Safe host copy — единственный `/i` argument. `Database(false,true).ReadDwgFile` + `CloseInput(true)` читают
source snapshot; нет DocumentManager.Open, ResolveXrefs, FindFile или WorkingDatabase assignment.
Сначала проверяются все три BTR, затем только `BlockTableRecord.PathName` в transaction → Commit.
Direct dependent BTR менять нельзя. Проверяется точная полная direct-xref table (handles/names/paths),
включая нетронутые записи; `Database.SaveAs(pending, DwgVersion.Current)`, закрытие DB, повторное side-DB
чтение pending **без resolution**, повторная exact-table проверка. Source/targets/request SHA сверяются вновь.

Только затем closed `native.json` → closed `native.complete` с ALLDONE → distinct
`inside_managed_prepare_command` sleep. Нет Lisp DELAY/QUIT и нет возврата к command-ended reactors.
Существующий `Invoke-OwnedTxtfixProcess`/`OwnedCadProcess` неизменён: suspended creation → private Job assignment
до resume, held handle, root **жив** до owner Stop, проверка пустого Job. Ранний exit даже 0, marker missing,
timeout/неопределённая cleanup → отказ. Nullable live exit остаётся null; собственного termination code не выдаём
за natural exit. Общий/outer service verifier, CAD guard, single-process gate и production state не меняются.

После cleanup Python повторно проверяет source/original snapshot/host/targets, request/raw bindings,
actual paths/count=3/output SHA, exclusive output, затем no-replace rename и closed `prepared.json`.
Failures/partial evidence не удаляются; если ошибка после DWG publish — artifact всё равно не принят без report.
`binding.json`, `request.json`, `build.txt`, SCR, `owned.json`, native JSON/marker, prepared/failure reports разделены.
Managed exceptions отдельно сохраняются через CreateNew в `native.failure.json` рядом с request: phase,
exception_type/message/status=failed; исключение повторно выбрасывается, success marker не создаётся после ошибки.
Если запись failure evidence не удалась, AggregateException сохраняет исходную и reporting ошибки, без overwrite/retry.
Marker сначала полностью закрывается в `native.complete.pending`, затем no-overwrite File.Move публикует ALLDONE;
ошибка записи/закрытия оставляет только partial evidence. `finish` отвергает native.failure даже при чужом/fake marker.
Owner timeout/cleanup state остаётся отдельно в owned/failure JSON; shared process helper/console capture не менялись.

**SaveAs может пересериализовать proxy/СПДС, поля и другое содержимое.** Source/output hashes — provenance,
не семантическая идентичность, сохранность proxy-графики или качество. Prepared candidate — не original-as-is,
не полная dependency closure, не инженерная приёмка/разрешение публикации. Signature assets не перепривязываются.
Никаких persistent SECURELOAD/fonts/PC3/CTB/PMP changes; environment resources не project xrefs.

## S4 и следующий допуск координатора

Для **каждой** project xref проверять relative portability/containment отдельно от existence/hash:
наружная цель — finding даже если существует. Любые корректные internal subfolders допустимы, не только
буквальное `Внешние_ссылки`. Nested relative path считать от **каждой referring DWG**. Reader даёт bounded direct
metadata, не полное замыкание графа. Установленные Fonts/PC3/CTB — отдельные environment resources.
Legacy `xrefs.ps1` строит paths по basename, чистит generic workdir, default QUIT и `-Apply` заменяет source;
он **не подходит** этому controlled acceptance и не является общим доказательством S4.

Оффлайн tests:

```text
python -I -m unittest discover -s scripts -p test_prepare_xref_copy.py -v
pwsh -NoProfile -File scripts/test_prepare_xref_copy.ps1
pwsh -NoProfile -File scripts/test_prepare_xref_failure.ps1
```

Python: 19 tests, включая conventional `.\Внешние_ссылки\…` same-parent happy (точные пути/targets неизменны),
contained `..` happy, source/target SHA, duplicate/no-op/path aliases, missing/escape, hardlinks/junctions,
output collision и source/host/evidence aliases, snapshot drift, invalid native counts/hash, managed failure/marker/lifetime.
Symlink test skipped явно, если ОС не даёт privilege. PS: 17 fake-wrapper cases, включая same-parent happy,
output collision/hardlink fail-before и separate native error/owner timeout; fake compiler проверяет source,
reference **и out** native Join-Path arguments. Дополнительно 4 exception tests компилируют actual C# source
только с inert API stubs: read/SaveAs/marker error и no-overwrite предыдущей failure evidence, rethrow без marker.
Это STUB compile/managed-handler execution, НЕ SDK ABI/native acceptance; Autodesk API не загружается.

Перед native — настоящая SDK compile без запуска CAD, затем три **отдельно допущенных последовательных** шага:
1. Prepare одну NEW copy с private exact3 map: protected/source/snapshot/environment hashes, native reopened table,
   root alive/cleanup/outer Job, complete raw proof; любое failure останавливает цепочку.
2. Inspect именно derived copy с новым SHA (read-only docs17), отдельно проверить targets/nested/assets и S4;
   bounded metadata не выдавать за closure.
3. Только после проверки первых двух — scoped plot derived copy и PDF/proxy/field/resource quality acceptance.
   Не менять инженерные значения и не выдавать копию пользователю автоматически.
