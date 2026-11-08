# Ресурсная разведка → консервативный draft PDF-плана

Продолжение [14_stage_plan.md](14_stage_plan.md). Методы принадлежат autocad-rd; rd-ci хранит lifecycle/ID,
не определяет макеты/форматы/содержание. Это **наблюдение**, не печать/инженерная проверка/разрешение выполнения.

## Сборщик

```powershell
pwsh -NoProfile -File toolkit/inspect_resources.ps1 -InputRoot <snapshot-input> -Files <1..3 absolute DWG paths> -ResultFile <new-probe.json>
```

- Только подготовленные рабочие снимки внутри InputRoot, без symlink/junction/reparse inputs и дублей.
- Один штатный check_papers -ControlledRead на каждый DWG, строго последовательно, **без -Add**; GUI/печати/изменений PMP нет.
  common.Invoke-AccCore сохраняет AccCoreLastRun(status/exit code), запускает прямой Process.Start/UseShellExecute=false
  с original held SafeHandle и async stdout pump. Не получает process association заново из PID; после timeout ждёт
  остановки своего процесса до следующего вызова/Dispose. Обычный текстовый результат старых вызовов сохранён.
- Для каждого файла отдельный GUID work/per-file root: старые raw evidence не затираются следующим check_papers.
- Бюджет сборщика <=900 секунд, native timeout <=300 на файл и остаток общего бюджета; не общий timeout
  всего комплекта. Cleanup собственного процесса отдельно ограничен 10 секундами, I/O тоже расходует budget.
- В ControlledRead: metadata закрывается → отдельный ALLDONE marker → root обязан оставаться живым →
  владелец закрывает только per-CAD nested Job с проверкой пустоты. QUIT не вызывается. Это явная граница
  read-only операции, **не natural exit=0**: exit_code=null, completion_mode=owned_job_after_metadata,
  root_alive_before_stop/controlled_cleanup_verified обязательны. Вся read/close/marker программа — один
  AutoLISP progn: ошибка не может провалиться к отдельной последующей строке записи marker.
  Использовать только новую рабочую папку; marker предыдущего запуска не evidence. Completion marker и его SHA сохраняются
  в raw_log (это не console stdout). При естественном выходе до owner cleanup даже с marker — отказ.
- Отсутствующий marker/timeout/ранний exit/изменившийся SHA/отсутствующая или неоднозначная metadata/нулевые paper layouts → failed,
  дальнейший CAD не запускается. Частичный files не трактовать полным inventory. Новая попытка — новая папка/UUID.
- ResultFile создаётся exclusive **до** CAD. Input и ResultFile/work не пересекаются. Сохраняются source SHA,
  size (только metadata), layout rows/count, measured probe duration, starts=1/exit code=0, raw metadata/log paths+SHA.
  Человеческая строка старого check_papers «Все форматы есть» не является machine-success.
  Default check_papers без ControlledRead сохраняет прежний QUIT/естественный выход и typed exit metadata;
  mode не меняет печать/SaveAs и не добавляет whitelist кодов падения.

Формат standard_unverified означает сохранённое имя ISO/ANSI/ARCH, **не успешную печать**.
UserDefined missing/configured и неизвестный device/format требуют отдельного review; источники/PC3/PMP не менять.
Текущий pipe raw format проверяется строго: не три поля/дубли layout names → отказ, а не угадывание разделителей.
Если нулевые paper layouts, не выдавать их за один лист: без отдельного диагностического подтверждения
нельзя различить model-only input и неполный native metadata проход.

## Проверка evidence и преобразование

```text
python -I toolkit/resource_inventory.py <probe.json> --input-root <snapshot-input> --evidence-root <work-root> --output <new-inventory.json> --plan-output <new-plan.json>
```

Проверяются complete observed report/requested count, explicit completion mode/typed natural exit либо
controlled live-root/cleanup/ALLDONE proof, start/duration types, containment/reparse paths,
SHA каждого текущего DWG и обоих raw files, точное совпадение raw rows/count/order со structured metadata.
Затем whole-DWG кандидат всех paper layouts (не окончательный issue selection):

- `sheet_count` = наблюдаемое число paper layouts, с явной пометкой candidate;
- `cad_starts=2`: консервативная будущая проверка форматов + печать, не reuse текущего probe;
- `estimated_seconds=2 * measured_probe_seconds + 60 * layout_count`, basis=conservative;
  2 и 60 — явная начальная policy, **не измеренная скорость печати** и не калиброванный cost family;
- budget/reserve/IDs — через существующий plan_stages.build_plan; результат draft/execution_authorized=false.

Для всего кандидата неизвестный/custom format или device не DWG To PDF → needs_input, files/steps пусты;
отброшенных молча файлов нет. Явный subset — повторяемый `--select <relative/path.dwg>` в нужном порядке;
все records всё равно проходят integrity validation, выбранный scope сохраняется. Не считать subset всем комплектом.
CLI outputs только новые, вне input; существующие не заменяются. Два JSON не одна транзакция:
ошибка второго оставляет первый диагностическим результатом, не авторизованным планом.

Exit 0 draft, 3 needs_input, 2 invalid/tampered/I/O. Никаких shell/CAD/копирования/настроек из Python converter.

## Проверки и оставшийся объём

- `scripts/test_resource_probe.ps1`: 5 fake-native сценариев без Autodesk/DWG: три serial calls, exclusive output,
  nonzero exit при существующей metadata, timeout/остановка без запуска следующего файла и legacy delayed exit code.
- `python -I -m unittest discover -s scripts -p test_resource_inventory.py -q`: 10 tests — costs/order/SHA/evidence,
  missing metadata, devices/format blockers, explicit scope, paths, nonfinite/types, old-output protection.
- Существующие 8 draft-plan tests и native GUI/resolver/env checks не отменяются.

При первых natural-QUIT опытах real input дал -1073741819/0xC0000005 после записи metadata.
Три failed jobs сохранены: исходная большая группа остановилась на первом файле, диагностический проход
подтвердил AV большого, explicit SMALL/SMOKE subset остановился на SMALL. Следующие файлы не запускались.
Наличие p1.txt не превращает их в success. ControlledRead — другая, явно ограниченная операция чтения
с owner-controlled cleanup, не исправление AutoCAD QUIT/SaveAs/печати и не whitelist ненулевого exit.

Финальная genuine Pi приёмка ControlledRead (08.11.2026, already-disconnected) прошла с тремя последовательными
accoreconsole в точном outer Job: paper-layout counts 1/2/1, probe около 25.1/2.1/2.1 секунды, диапазон размеров
примерно 0.3–85 MB. Никакой печати; natural exit=0 не заявляется. 68 protected files/28 Plotters/config hashes
прежние, outer Job пуст без termination, CAD свободен/executor idle. Перед marker добавлен единый progn guard,
и финальная версия повторно проверена. Пять одноразовых tasks удалены, все три failed сохранены.

Whole candidate вернул needs_input: у малого DWG два layouts с неизвестным format/device. Явный subset
BIG/SMOKE дал два draft шага примерно 290/244 секунды **с reserve 180**, по 2 предполагаемых future CAD-start;
это оценки, не измеренная печать/подтверждённая issue selection. SMALL не выкинут молча, разрешение исполнения false.
Реальные пути/имена/UUID/raw evidence остаются вне Git.

Реальная приёмка делается только через общий execution guard/Windows Job с внешним CAD pre/postflight,
known session и независимой проверкой источников/Plotters/raw evidence. Wrapper сам не CAD mutex/sandbox.

Пока **не реализованы**: автоматическое покрытие всех файлов комплекта, xref/font/plot dependencies snapshot,
подтверждённая issue selection, measured plot-cost calibration, staging execution/phase journal, adaptive replanning
и validated intermediate reuse. Single-DWG gate rd-ci не снят, production execution/auth/background не включаются.
