# Direct dependencies через side Database — эксперимент, native acceptance НЕ пройдена

08–10.11.2026. Продолжение explicit staging (`16_staging_plot.md`). Не включать печать/общий consumer по этой заготовке.

## Последняя native приёмка — большой source прочитан (10.11)

Runtime **fa34d5c** установлен на RYZENDT. Один новый genuine Pi/один CAD-start на том же большом source:
**8.13 s**, native hold внутри managed команды, root alive before stop/cleanup verified, exit_code=null,
outer Job empty. Источник/снимок и 30 issue files, 28 Plotters/configs неизменны; pause/idle/ready возвращены.
Один paper layout А1, 12 xref/44 STYLE records; strict issue-only inventory независимо воспроизведён:
needs_input/56 ресурсных вопросов, external bindings=0. Это metadata, не actual usage/closure/печать.
14 прежних полей raw совпали, новое поле только completion_hold; старый failed не переоценён.

**Оговорка:** две строки `VLA-OBJECT nil` остаются и в новом stdout. Исчез последующий сбой command из
`*error*`/ранний выход в этом read-only сценарии, не все проблемы стороннего Lisp/ActiveX окружения.
Точный источник предупреждений не установлен. Нельзя переносить managed hold на plot/SaveAs или
утверждать, что DWG/всё окружение исправлены. Приватный locator — `dependency_root_exit`.

## Предыдущая native приёмка — частичная (10.11, 48bad1a)

Runtime `48bad1a`: настоящий Pi в same-user disconnected session выполнил **два** последовательных CAD-start.
Первый source принят: один paper layout А2, direct xref найден внутри selected snapshot, 18 STYLE records,
5.11 s, native SHA/marker/source hashes совпали, root alive до owner stop/cleanup verified, exit_code=null.
Штатный `--issue-only` converter после failed задания независимо дал needs_input/19 вопросов, без external bindings.
STYLE записи не доказывают фактическое использование шрифтов; extensionless filename не угадывается.

Второй, большой source: marker/native JSON получены, но root exited before stop (~9.15 s),
AllDone=true/TimedOut=false/Terminated=false. **Операция failed, raw metadata не приняты**; третий файл не запускался.
Весь job остаётся failed. Это не доказательство прежнего QUIT AV: здесь QUIT не вызывался, причина выхода ещё неизвестна.
Следующее — диагностика lifetime большого source и отдельный ограниченный запуск после разбора, не whitelist marker-only success.

Outer Job empty, pause/idle/ready восстановлены; 30 selected source files/snapshot, 28 Plotters и production configs прежние.
45 Python tests (16 dependency), 3 fake-wrapper сценария и реальная ABI compile прошли на RYZENDT; они не заменяют native test.
Проектные пути/UUID/шрифты/изображения — private locator `issue_dependency_acceptance`, не Git.
Полная native приёмка reader, nested/actual resources closure, остальные DWG и печать остаются впереди.

## Разбор раннего выхода (10.11)

В исходном console output большого source после загрузки Civil OE есть `VLA-OBJECT nil` и запрет
`(command)` из `*error*` без `*push-error-using-command*`. Это конкретная ошибка AutoLISP после записи metadata,
а не доказанный access violation/повреждённый DWG. Исходный root exit code не был сохранён; отсутствие
Application Error/WER/.NET events в ограниченном временном окне его не восстанавливает.

Узкое изменение: после закрытия side DB, проверки source SHA и закрытых JSON/marker команда **не возвращается
в AutoLISP**, а остаётся в managed sleep до остановки собственного Job. В SCR больше нет DELAY loop.
Использовать только bounded wrapper, не вручную/интерактивно и не для print/SaveAs. Marker + ранний exit,
даже exit=0, по-прежнему failed. Новые native reports указывают `completion_hold=inside_managed_command`.
Owned helper теперь получает nullable unsigned `RootExitCodeBeforeStop` по исходному held handle до Stop;
живой root → null, собственный termination code не выдается за natural exit. Старое evidence не дополнено задним числом.
45 Python tests, fake-wrapper 4 сценария и native fake-process tests (exit=17/NTSTATUS bits/sentinel) проходят;
они проверены отдельно от нового реального теста большого DWG, описанного выше.

## Подготовка и сохранённые отказы

09.11 старый service-инцидент закрыт отдельным протоколом rd-ci docs/32, новый files-only Pi completed.
Это не native acceptance reader. До нового ограниченного прогона исправлен конфликт `$host` с read-only `$Host`
и добавлен режим **`--issue-only`**: только точные относительные пути внутри выбранной выдачи, без external roots,
поиска по basename/системным Fonts и подстановок. Absolute/UNC/drive-relative/ADS/escape → вопрос с исходным
name/path; такой файл не хешируется/не добавляется. Root reparse проверяется до resolve. Остальные omissions
и dependency_complete=false сохраняются. Host по-прежнему отдельный проверенный технический тестовый файл,
не проектная зависимость и не разрешение брать шрифты/подложки из других выдач.

Новая genuine Pi попытка 09.11 штатно failed до CAD: Framework csc укоротил mixed-slash source path (CS1504).
Нет native metadata/closure; outer Job empty, pause/idle возвращены, protected inputs/configs/Plotters прежние.
Исправление — native `Join-Path` source и references, fake compiler теперь проверяет их существование и разделители;
новая регрессия отвергает старый wrapper и проходит на исправленном. Старый failed не переименовывается в success.

10.11 реальная ABI compile прошла; новый Pi дошёл до одного CAD start, но NETLOAD не загрузил DLL,
RDDEPENDENCIES осталась неизвестной. Failed сохранён, остальные два DWG не запускались.
В wrapper добавлен уже применяемый run_txtfix порядок загрузки: сохранить SECURELOAD, временно 0 только
на NETLOAD, catch ошибки загрузки, восстановить/проверить исходное значение **до** RDDEPENDENCIES.
Причина первого NETLOAD refusal по одной строке консоли не установлена; новый прогон — отдельная приёмка,
не переименование failed. Failure JSON новых запусков сохраняет исходный результат owned helper.
Следующий native прогон установил конкретный дефект catch: COMMAND — special form, прямой
`vl-catch-all-apply 'command` дал «неверная порядковая функция: COMMAND»; root exited до marker (~1.44 s),
SECURELOAD восстановлен до 1, native metadata отсутствуют. Исправлено через lambda; весь load/restore/условный
reader/DELAY объединён в progn, чтобы отказ проверки не продолжал следующие отдельные SCR forms.
Это ещё один сохранённый failed, не успех reader.

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
  После marker native команда удерживает root managed sleep; нет возврата в command-ended Lisp/DELAY.
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

Пример контролируемого вызова после live preflight и отдельного resume в разрешённом scope (актуальный статус — handoff rd-ci):

```text
pwsh -NoProfile -File toolkit/inspect_dependencies.ps1 -SourceDwg <copy.dwg> -HostDwg <approved-safe-host.dwg> -EvidenceDir <new-ascii-dir> -TimeoutSec 120
python -I toolkit/dependency_inventory.py <evidence> --source-root <authorized-input> --source-path <relative.dwg> --environment-roots <local-roots.json> --output <new-inventory.json>
```

Для согласованного relative-only scope:

```text
python -I toolkit/dependency_inventory.py <evidence> --source-root <selected-snapshot> --source-path <relative.dwg> --issue-only --output <new-inventory.json>
```

`--issue-only` и `--environment-roots` взаимоисключающие; прежний explicit-roots API сохранён для иных явно
разрешённых задач. No external roots в issue-only проверяется до чтения источника; отсутствие шрифта — needs_input,
не автоматическая замена. PowerShell wrapper отказывает для reparse source/host/output и не-ASCII EvidenceDir
до native старта; полное имя source copy сохраняется. Fake-wrapper test не загружает Autodesk.

16 unit tests без CAD (включая 6 issue-only cases) + `scripts/test_dependency_probe.ps1` (fake compiler/process, 4 сценария): partial/no auth, parent escape without file read, nested refs, assets/missing,
missing/ambiguous/registry fonts, unproven completion/source drift, raw-evidence hash/exclusive output,
reserved root/omissions. `check_package.py` — 26 Python sources; local Claude plugin validation passed
с прежним missing-version warning. ABI C# успешно скомпилирован против реальных AutoCAD 2024 DLL на RYZENDT,
**это не выполнение plugin/не подтверждение работоспособности native API**.

## История первой попытки native acceptance (08.11; service-инцидент уже закрыт)

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
