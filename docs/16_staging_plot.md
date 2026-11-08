# Явный staging и экспериментальный ControlledPlot

Продолжение [15_resource_inventory.md](15_resource_inventory.md). Это не общий pipeline, dependency resolver,
разрешение исправлений/выпуска или снятие single-DWG gate сервиса. Для первого опыта — только известный reference A4.

## Snapshot + working

`toolkit/stage_inputs.py` принимает spec schema=1:

- coverage строго **explicit_not_discovered**; plan_id (SHA256) и step_id (UUID) — ссылки, не доказательство авторизации;
- files: relative path/SHA256/role drawing либо project_dependency, 1–3 drawing, без traversal/дублей/links;
- environment: root ID/relative path/SHA256; отдельный локальный JSON отображает разрешённые root IDs в реальные каталоги;
- plot_options: JSON fingerprint опций, не shell/не автоматически исполняемые параметры.

```text
python -I toolkit/stage_inputs.py prepare <spec.json> --source-root <input> --environment-roots <roots.json> --destination <new-stage>
python -I toolkit/stage_inputs.py verify <stage> --expected-stage-id <ID>
```

Проверяет входные/внешние SHA, создаёт только новый stage с manifest preparing, затем две **отдельные физические**
копии с полными относительными именами: snapshot и working. Проверяет их SHA и повторно источники/environment,
публикует prepared manifest атомарной заменой только собственной новой metadata. Ошибка сохраняет partial stage;
не clean/retry поверх него. Новая попытка — новая директория/UUID.

Verify проверяет checksum identity/ожидаемый ID, source/environment и точный file set обеих копий,
отказывает на missing/extra/modified/reparse. Snapshot всегда неизменен. Working по умолчанию также неизменен;
--allow-work-changes лишь отдельно перечисляет изменённые known files, не разрешает инженерные правки/reuse.
Environment files **не копируются**, только привязываются SHA; не писать fonts/Plotters обратно в Windows.

stage_id — контроль целостности, не подпись/HMAC. Snapshot не OS read-only/sandbox. Manifest всегда
execution_authorized=false: source scope/выбор/права/guard проверяет вызывающий. Explicit dependency list
не доказывает полноту xref/fonts/plot options, не перепривязывает absolute/parent-relative ссылки.
Добавленные вне перечня environment files/registry/search paths не покрываются этим API.
Для новых инженерных inputs нужны настоящая dependency discovery и approved selection, не фиктивное complete=true.

11 unit tests без CAD (включая partial preparing и отказ на reparse до спуска): отдельные копии/имена, source/environment drift, missing dependency/hash, old destination,
manifest/preparing/expected-ID, traversal/дубли, изменённый snapshot/working и unexpected files.

## ControlledPlot отдельно от ControlledRead

Default plot_set теперь явно отказывает при failed/unknown native execution (через AccCoreLastRun),
не сообщает success только по наличию какого-то PDF. Default QUIT AV не исправлен и не whitelist.

Для **явно допущенного теста** добавлен `plot_set.ps1 -NoPaperCheck -ControlledPlot`:

1. Caller предварительно подтверждает выбранные сохранённые параметры без Add (для smoke — ControlledRead).
2. Отказывают непустой OutDir/существующий SetPdf; исходники не заменяются, новая выдача не затирается.
3. Один progn: команды PDF для выбранных целых DWG → marker ALLDONE → DELAY, без QUIT.
   Ошибка Lisp не продолжится к отдельной строке marker. Marker означает возврат PDF-команд, не качество PDF.
4. Root должен быть жив до Stop; очищается только private Job из уже проверенного OwnedCadProcess.
   Typed PlotLastRuns: mode=owned_job_after_pdf_commands, exit_code=null, cleanup/live-root, marker, elapsed seconds.
5. После cleanup нужны точно все ожидаемые листовые файлы, каждый открывается PyMuPDF как незашифрованный
   одностраничный PDF. Missing/count mismatch/invalid PDF/merge failure — отказ, не частичный успех.
6. Отдельный PDF-audit caller проверяет merged/pages/order/dimensions/renders; для smoke сравнивает с reference.

Не применять к SaveAs/инженерным правкам и не считать controlled completion natural exit=0. Внешний Job/пауза/CAD
pre/postflight сервиса не изменяются. PDF-команды могут пересохранить **только внутренний spool**, поэтому snapshot
и отдельная working source остаются вне spool; не выдавать spool DWG как исправленный исходник.

`scripts/test_controlled_plot.ps1`: пять fake CAD случаев без Autodesk (валидный sheet/merge, missing/invalid PDF,
natural nonzero exit даже при PDF и запрет повторного output). Требует уже установленный PyMuPDF, не устанавливает ПО.

08.11.2026 genuine Pi stage → preflight → ControlledPlot в уже disconnected same-user session completed:
2 serial accoreconsole в точном outer Job, snapshot/working/source/environment verify до/после,
653 declared bindings Fonts/Plotters (SHA refs, не копии/не autodiscovery), 67 protected/28 Plotters/config hashes прежние.
Листовой и отдельный merged PDF совпали с reference по рендеру 144 dpi; outer Job пуст без termination,
CAD free/automatic idle, одноразовая task удалена. Measured plot около 2.1 секунды — только этот known A4/warm context,
не cold-family калибровка/полный job overhead/основание снизить budget остальных документов. Новые flags/reuse не включены.

Успешный reference A4 не доказывает сложные xref/font/СПДС,
нестандартные форматы/многолистовой порядок/обложку и не является приёмкой документации.
