# Обложка: offline preflight и guarded draft candidate

**Native availability/качество DOC/PDF ещё не приняты.** `make_cover_draft.ps1` — новый явный
кандидат для отдельного smoke/QA координатора, не готовая выдача/инженерная приёмка/full MVP.
Старый `make_cover.ps1` остаётся safe-by-default: только `-PreflightOnly`, без него ошибка до COM;
`-Force` всегда ошибка. Никакого bypass к прежнему безусловному Word COM нет.
Другие read/plot/CAD инструменты и `check_env.ps1` не изменены.

## Явный draft CLI

PowerShell 7, существующий Python 3 + установленный PyMuPDF. Никаких установок/fallback при
отсутствии модулей. Windows, интерактивная не-session0 среда; внутренний host запускается `pwsh -STA`.
Пути и SHA задаёт вызывающий; discovery шаблона/Word, выбор реквизитов и нормализация B/В отсутствуют.
Родители DOC/PDF и WorkParent уже существуют. Общий родитель со staged siblings допустим.

```powershell
# Все переменные — явные approved inputs вызывающего; новые output paths.
& ./toolkit/make_cover_draft.ps1 -Template $template -TemplateSha256 $approvedTemplateSha `
  -Out $newDoc -Pdf $newPdf -WordExe $approvedWordExe -WordSha256 $approvedWordSha `
  -WorkParent $existingPrivateWorkParent -ExpectedPages $expectedPageCount -PassthroughDraft

# После отдельной проверки применимости main-story-only replacement:
& ./toolkit/make_cover_draft.ps1 -Template $template -TemplateSha256 $approvedTemplateSha `
  -Out $newDoc -Pdf $newPdf -WordExe $approvedWordExe -WordSha256 $approvedWordSha `
  -WorkParent $existingPrivateWorkParent -ExpectedPages $expectedPageCount `
  -Replace ([ordered]@{'TOKEN'='VALUE'}) -ExpectedCounts @{'TOKEN'=1}
```

`ExpectedPages` обязателен, не выводится из шаблона. Default TimeoutSec=120 (1..3600),
PaneTimeoutSec=30 (1..120, не больше общего timeout). Нет Force/overwrite/автовосстановления.
PassthroughDraft явно несовместим с непустыми Replace/ExpectedCounts; не выдумывает замен/значений.
Подписи не создаются; Word digital signatures в source запрещают генерацию, картинки-подписи
не интерпретируются/не проверяются. Их допустимость/сохранность остаётся QA.

Python API `generate(request)` / CLI `python -I toolkit/cover_draft.py` с JSON stdin:
`template`, `template_sha256`, `out`, `pdf`, `word_exe`, `word_sha256`, `work_parent`, `expected_pages`,
`timeout_sec`, `pane_timeout_sec`, `replace`, `expected_counts`, `passthrough_draft`.
Fake backend/validator инъекции существуют только в библиотечном unit-test API, не в CLI.
Успех возвращает `draft_generated_pending_coordinator_qa`, `draft=true`, `native_accepted=false`,
`engineering_approved=false`, private `run_dir`, hashes, native/count/cleanup evidence и published paths.
Это НЕ orchestrator manifest `13_orchestrator.md`; координатор формирует его отдельно после своей QA.
Ошибка — nonzero и failed; если private run уже создан, внутри него новый `result.json` и все partials.

## Path/hash/staging/publication

- Обе output collision/source alias проверки до Word, повторно после snapshot и перед публикацией.
  Локальные literal paths; UNC/device-prefix, ADS, wildcard, control/invalid Windows characters запрещены.
  Drive-relative `C:foo`, trailing-dot/space components, NUL/CON/PRN/AUX/CONIN$/CONOUT$/CLOCK$ и
  COMn/LPTn (консервативно также 0/multidigit/superscript variants, с расширениями) отвергаются **до записи**.
- Source/approved WINWORD.EXE — непустые regular files, `st_nlink=1`; source и все существующие
  source/output/work parent components без symlink/reparse. Никаких замен существующих файлов.
- Явные SHA проверяются до запуска, после snapshot; source/snapshot/binary SHA повторно после native.
  Identity/size/mtime/nlink проверяются вокруг hash, ctime — в пределах одного stat/fstat метода:
  Windows pathname/handle ctime могут иметь разные semantics, их не сравниваем между собой.
- Новый непредсказуемый private work subdir, snapshot с исходным полным именем, generated DOC с полным
  requested output filename, отдельный PDF. Открывается только snapshot readonly/no MRU/no repair.
  Никакого source Save/SaveAs, поиска соседних templates, удаления artifacts или cleanup чужих файлов.
- После own Document.Close/release, **до** held Stop: source/snapshot SHA, непустые closed DOC/PDF,
  PyMuPDF open/no password/точные expected pages/nonempty finite page rectangles и closed hashes;
  root ещё жив. После verified-empty-Job Python повторяет проверки и сверяет closed hashes перед publication.
- Publication — эксклюзивное `xb` создание, flush/fsync/hash; никогда не replace. Пара **не атомарна**:
  collision/ошибка второй публикации оставляет первую, error содержит published/attempt paths;
  ошибка копирования может оставить явно failed partial output. Ничего не удаляется/не перезаписывается,
  после причины отказа выбирать NEW paths, не делать silent retry.

Стабильная локальная папка без параллельной подмены каталогов обязательна. Нет filesystem sandbox,
ACL isolation от других пользователей, reservation будущих paths или защиты от злонамеренной гонки.
Непредсказуемый run dir не является доказательством OS security boundary.

## Ownership / bounded controlled completion

`cover_native_host.ps1` не вызывает CoCreate/Word.Application factory/GetActiveObject и не принимает
broker-created PID. До запуска: интерактивная Windows STA/session проверка, консервативный отказ при
любом WINWORD/ошибке enumeration, повторная проверка binary/snapshot SHA и private output absence.
Далее ровно прямой approved WINWORD `/x /a /q`, **без source на CLI**, через прежний suspended
`OwnedCadProcess.Start`: private noninheritable kill-on-close Job до ResumeThread, original held handle.

Единственный shared-source delta — read-only `OriginalProcessId`, однократно из CreateProcessInfo
до assign/resume; CAD Start/Stop/Dispose/lifetime не менялись. Shared process regressions — координатору,
не новые CAD reads. PID используется только для проверки HWND, никогда для kill/late ownership adoption.

Bounded EnumWindows/child search выбирает `_WwG` только original PID. OBJID_NATIVEOM/IDispatch bind
только этому pane; возвращённый Application.Hwnd тоже должен принадлежать original STILL-LIVE root.
Root.Guard перед OM/settings/Open/операциями; root handoff/early exit (даже 0), foreign HWND,
непоявление pane или недоступный OM — failed, никакого fallback на другой процесс.
`/x /a /q` намеренно оставляет startup blank/pane: `/Automation` не используется. Единственный startup
blank с Path='' закрывается только внутри проверенного own instance; другие startup docs — отказ.

В own instance до Open: AutomationSecurity=3, DisplayAlerts=0, Options UpdateLinksAtOpen,
UpdateFieldsAtPrint, UpdateLinksAtPrint, SaveNormalPrompt, ConfirmConversions=false; значения
сохраняются/восстанавливаются, ошибки не превращаются в успех. NoEncodingDialog, readonly,
no MRU/repair/conversion, non-user password sentinels в Open; никаких Fields.Update/links fetching/signing.
После close — release только полученных own RCW. **Word.Quit не вызывается**: новый controlled режим
требует root живым после closed document/release, затем Stop только своего held Job и verified empty.
Это не natural-exit success и не наследование CAD native acceptance.

`CoverOwner` watchdog не вызывает COM, по общему deadline останавливает только свой Job, пишет audit;
COM hang никогда не success. Если сам COM host не вернулся через timeout+90s, Python возвращает
`native_host_timeout_cleanup_uncertain_no_publication`: не убивает PID/name, не публикует, не retries.
Host может остаться зависшим; журнал watchdog сам по себе не заменяет returned cleanup evidence.
До разбирательства координатора дальнейшие native операции запрещены. Не выдавать outer Job за
контейнер Office COM/service brokers: контролируется лишь прямо созданный root/обычная Job family.
Office startup/addins/OS/attached templates/linked content могут иметь внешние эффекты; `/a` и настройки
не sandbox/сетевой firewall и не гарантия отсутствия всех возможных Office brokers/инициализаций.

## Literal replacements / coverage

Passthrough — ноль запрошенных/наблюдённых замен, без whole-story/text/field semantic acceptance.
Replacements поддерживаются только в **main story**, без любых main fields/shapes/inline images и
без содержательных/field-containing nonmain stories (headers/footers/textboxes/notes и т.п.).
Неподдерживаемый случай — отказ, не молчаливый пропуск. Пустые не-field nonmain stories допустимы.
Целые фразы, exact ordinal case-sensitive .NET text/range matching; caret, paragraph/table/field/control
tokens отвергаются. No Word Find wildcard/caret interpretation; Find.Execute boolean не используется.
Ожидаемые counts строго положительны/совпадают с actual pre-edit counts: missing/0/duplicate → failed.
Substring/cascading maps запрещены до Word, реальные overlapping ranges — до edits. Исходные offsets,
descending range edits, каждый Range.Text ordinal проверяется перед присваиванием; main Text целиком
не перезаписывается. Exact expected main-text transform проверяется после edits и Save/Export.
Это counts в own Word memory, не reopened DOC/render/PDF acceptance. Сохранность форматирования
внутри заменённых ranges и layout/таблиц проверяет координатор; SaveAs сам может пересериализовать DOC.

## Offline tests / remaining real gates

```text
python -I -m unittest discover -s scripts -p test_cover_*.py -v
pwsh -NoProfile -File scripts/test_cover_document.ps1
pwsh -NoProfile -File scripts/test_cover_owner.ps1
```

Только synthetic files/PDF, inert backend/CLR Word/process stubs. Проверяются path/hash/maps,
collisions/partial publication, actual PS document lifecycle/order/count/overlap failures, managed
watchdog/session ownership gates и timeout uncertainty. Три реальные symlink cases могут skip без
Windows privilege; mocked reparse отдельно. Никакой Word/COM/native process activation в этих тестах.
Fake Open boundary НЕ моделирует IDispatch optional Missing marshaling; C# compile-only не native read.
Настоящие HWND/_WwG/OM/Open(optional args)/SaveAs/Export/Close/release/Job-family acceptance ещё нужны.
Координатор: shared owner regression → отдельный approved passthrough draft в NEW location →
provenance/cleanup audit → визуальная/text/requisites/headers/images/fields/layout QA. Никаких
инженерных значений/шифров/дат/ревизий автоматически не исправлять, B/В конфликт не нормализовать.
