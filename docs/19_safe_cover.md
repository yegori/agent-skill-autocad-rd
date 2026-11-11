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
JSON stdin обоих Python CLI — **строго UTF-8 bytes** независимо от locale TextIO/CP1251;
invalid UTF-8 и duplicate JSON keys дают failed до staging/native. Обе PS-обёртки явно используют
script-local UTF-8 без BOM для pipe и восстанавливают прежний `$OutputEncoding` даже при ошибке.
`-I` сохранён; OS locale/chcp/console/profile и `PYTHONIOENCODING` не изменяются/не требуются.
Unicode-пути и literal B/В не переименовываются/не нормализуются; stdout JSON остаётся ASCII-escaped.
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
Далее ровно прямой approved WINWORD `/w /a /q`, **без source на CLI**, через прежний suspended
`OwnedCadProcess.Start`: private noninheritable kill-on-close Job до ResumeThread, original held handle.

Единственный shared-source delta — read-only `OriginalProcessId`, однократно из CreateProcessInfo
до assign/resume; CAD Start/Stop/Dispose/lifetime не менялись. Shared process/OriginalPID host regressions
ранее проверены координатором; новый startup delta их не меняет, не повторять kernel/CAD reads.
PID используется только для проверки HWND, никогда для kill/late ownership adoption.

Bounded EnumWindows/child search выбирает `_WwG` только original PID. OBJID_NATIVEOM/IDispatch bind
только этому pane; возвращённый Application.Hwnd тоже должен принадлежать original STILL-LIVE root.
Root.Guard перед OM/settings/Open/операциями; root handoff/early exit (даже 0), foreign HWND,
непоявление pane или недоступный OM — failed, никакого fallback на другой процесс.

Identity chain: Bind callback явно возвращает `,object`, чтобы PowerShell не раскрыл IEnumerable
pane в pipeline до Keep-CoverRcw. Pure Keep helper сохраняет scalar reference; array/null/замена объекта
от Track отвергаются, без unwrap/подбора/повторного bind. Этот managed дефект воспроизведён на inert
IEnumerable pane, **не доказано**, что настоящий Word RCW имел такой shape или это причина старого сбоя.
Application/Hwnd берутся через фиксированные PS property descriptors с явным `get_Value()`:
исключение getter не должно тихо превратиться в null. Реальный COM adapter ещё требует проверки.
До `[long]` проверяются null/array/CLR integer type/overflow; Hwnd=0 у application — отказ до PID lookup,
selector=0 остаётся только ожиданием pane в прежнем deadline. Нет speculative signed32/64 reinterpretation.
`native-result.identity_chain` содержит фиксированный substep (selector/pane_pid_lookup/bind/pane_track/
application_access/application_track/application_hwnd_get/validate/application_pid_lookup/document),
только scalar integer HWND/CLR numeric type либо null/array shape/length, Track shape/reference flags, observed PID/match flags,
outer/inner HRESULT и вложенный Win32 error code. Нет COM serialization/ToString/Name/text/captions.
Missing getter/null/zero не схлопываются в одну причину; provenance failure не заменяет primary error.
Новая provenance не восстанавливает неизвестные HWND/substep прошлых failed UUID задним числом.
`/w` вместо `/x` явно запрашивает отдельный instance **с новым blank**, `/a` и `/q` сохранены;
`/Automation`, shell/DDE/factory/ROT, source или synthetic seed на argv не используются.
Это кандидат startup policy, не доказательство, что switches исполнены/прежняя pane-причина исправлена.
Один настоящий `/x /a /q` trial завершился pane timeout при живом root и verified own cleanup;
дерево тогда не записано, причина **UNKNOWN**, не доказаны StartScreen/licensing/modal/desktop/enum причины.
Deadlines остаются 30/120 секунд, без blind repeat старого startup.

EnumWindows false без найденного pane/контролируемой остановки — явная API ошибка (даже lastError=0),
callback-found — не ошибка. GetPID/GetClassName failures не превращаются в pane timeout. Возврат
EnumChildWindows документирован как unused: его не трактуем как success/last-error proof; отсутствие
callbacks не доказывает полноту child tree или причину отсутствия pane. Один поиск ограничен 2048 callbacks/
100 ms; превышение — failed/owned_window_scan_limited, не скрытая timeout-причина.
На readiness failure до own stop — одна root-PID-only class/visibility запись, guard до/после capture:
не более 16 records, class до 64 chars, 512 callbacks/250 ms. Только HWND/top-or-child/class/visibility;
без captions/text/UIA/screenshots/foreign-window metadata. Limited/error/missing diagnostic не разрешает
success и не заменяет primary failure; старые деревья/состояния не восстанавливаются задним числом.

Ноль startup docs не требует Close; при одном закрыть можно только проверенный own свежий blank.
Path='' **недостаточно**: Saved=true, Type=document, не ReadOnly/protected; main range 0..1/StoryType=main,
по одному character/paragraph/section/story; ноль fields/shapes/inline images/tables/frames/content controls/
hyperlinks/comments/revisions/notes/variables, нет next story. Это metadata-only guard без чтения Text/Name;
неизвестная metadata/unsaved recovered/nonempty/другие stories — отказ **до Close и source Open**.
Действительность этих Word properties на настоящем `/w` blank ещё требует native проверки; ограничения
не ослаблять ради smoke. Macro/link guards по-прежнему ставятся до любого approved snapshot Open.

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

Для изменённой identity chain — отдельно `pwsh -NoProfile -File scripts/test_cover_identity_chain.ps1`:
actual Invoke-CoverSession + actual Keep helper + production Bind callback AST, только inert objects,
healthy scalar/IEnumerable path и invalid/foreign/stale/null/array/Track/getter cases до Document tripwire.
Это не реальная Word/NativeOM/Open/export acceptance и не основание ещё одного физического повтора без review.

Для изменённого startup/window/blank guard — отдельно
`pwsh -NoProfile -File scripts/test_cover_pane_startup.ps1`: только inert Win32/Word/process stubs,
без настоящего EnumWindows/NativeOM/Word. Не повторять неизменённые kernel/UTF-8/CAD suites.

Для узкой transport-регрессии без любых native/ownership suites:
`python -I -m unittest discover -s scripts -p test_cover_utf8_cli.py -v` — настоящие UTF-8 byte pipes,
Cyrillic filenames, legacy CP1251 stdin только в isolated test child, PS roundtrip, invalid UTF-8/duplicates;
draft CLI намеренно ExpectedPages=0 (pre-native gate), никаких Word/export acceptance claims.

Только synthetic files/PDF, inert backend/CLR Word/process stubs. Проверяются path/hash/maps,
collisions/partial publication, actual PS document lifecycle/order/count/overlap failures, managed
watchdog/session ownership gates и timeout uncertainty. Три реальные symlink cases могут skip без
Windows privilege; mocked reparse отдельно. Никакой Word/COM/native process activation в этих тестах.
Fake Open boundary НЕ моделирует IDispatch optional Missing marshaling; C# compile-only не native read.
Настоящие HWND/_WwG/OM/Open(optional args)/SaveAs/Export/Close/release/Job-family acceptance ещё нужны.
Координатор: review changed identity chain → выбрать fresh UUID narrow identity probe либо approved passthrough в NEW location →
provenance/cleanup audit → визуальная/text/requisites/headers/images/fields/layout QA. Никаких
инженерных значений/шифров/дат/ревизий автоматически не исправлять, B/В конфликт не нормализовать.
