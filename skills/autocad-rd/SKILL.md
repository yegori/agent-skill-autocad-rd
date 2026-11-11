---
name: autocad-rd
description: Use when the user works with AutoCAD/Civil 3D drawing sets of working documentation (РД) — checking or correcting sheets, building a «Общие данные» (ОД) sheet from a sample, renumbering sheets in title blocks, mass find-and-replace of text (including СПДС GraphiCS tables, leaders and level marks), plotting DWG to PDF, assembling a set PDF with cover, preparing an issue folder (выдача), reading SHX-text PDFs of drawings, quantities checks, or integrating AutoCAD checking executors into the rd-ci service. Triggers on DWG, DXF, accoreconsole, штамп, шифр, ИЗ, выдача, комплект, СПДС, спецификация, ведомость, ОД.
---

# AutoCAD РД: проверка и корректировка комплектов

## Корень инструментов (Claude Code и Pi)

Пакет `autocad-rd` самостоятельный; один набор навыков используется в обоих агентах.
Сервис автоматизации rd-ci — отдельный репозиторий `yegori/rd-ci`: его спецификацию и код искать там,
а инструменты и правила работы с чертежами — в этом пакете. Для ручной работы исходники сервиса не нужны.
- В Claude Code корень репозитория/плагина задаётся `${CLAUDE_PLUGIN_ROOT}`.
- В Pi вычисли корень по пути загруженного `SKILL.md`: от `skills/autocad-rd/` на два уровня вверх. Не используй текущую рабочую папку и не зашивай путь конкретного ПК.
- Далее `${CLAUDE_PLUGIN_ROOT}` в инструкциях — обозначение этого корня. В Pi перед запуском команд подставляй фактический абсолютный путь: такая переменная окружения там не гарантируется.
- Прочитай `CLAUDE.md` в корне инструментов. У конкретного объекта отдельно прочитай его `CLAUDE.md` и записки `_claude` раздела: Pi не обязан загружать их автоматически.
- Файлы инструментов не изменять в процессе работы с комплектом: установленный пакет может быть кэшем. Результаты — только в рабочую папку или согласованную папку проекта.

Инструменты и документация лежат в корне: `${CLAUDE_PLUGIN_ROOT}`.
- `${CLAUDE_PLUGIN_ROOT}/docs/11_pitfalls.md` — грабли AutoCAD / accoreconsole / СПДС / печати / PowerShell / Python. **Прочитать перед любой работой с DWG.**
- `${CLAUDE_PLUGIN_ROOT}/docs/10_playbook.md` — порядок работы и чек-лист сверки листов;
- `${CLAUDE_PLUGIN_ROOT}/docs/03_checks.md` — каталог проверок, в т.ч. объёмы (раздел Q);
- `${CLAUDE_PLUGIN_ROOT}/docs/12_arkhyz_test_cases.md` — эталонные ошибки (Архыз), на них видно, что и как находится;
- `${CLAUDE_PLUGIN_ROOT}/toolkit/README.md` — все скрипты; `toolkit/analysis/` — разбор журналов текстов (спецификации, тексты, сравнение версий);
- `${CLAUDE_PLUGIN_ROOT}/examples/` — проектные скрипты и пример сводной таблицы замечаний.

Полная проверка комплекта по шагам — навык `check-set` этого плагина.
Для автономного JSON-задания от оркестратора с `job_id`, `output_dir` и `result_file` —
`${CLAUDE_PLUGIN_ROOT}/docs/13_orchestrator.md`: выполнить выбранную операцию и обязательно сохранить manifest результата.
Это не разрешение менять исходные DWG или расширять объём проверки.
Для чернового разбиения PDF на подэтапы — `docs/14_stage_plan.md` / `toolkit/plan_stages.py`:
нужен явный inventory с counts/timings/hash; draft не запускает CAD и не разрешает исполнение/reuse.
Ограниченная read-only разведка до трёх подготовленных копий — `docs/15_resource_inventory.md`:
inspect_resources → resource_inventory. Она запускает CAD, требует явного допуска и не печатает/не меняет PMP.
Явный staging snapshots/working/environment bindings и отдельный тестовый ControlledPlot — `docs/16_staging_plot.md`.
Stage prepared/verified не означает полноту зависимостей, авторизацию или разрешение reuse.
Experimental direct side-database dependency reader — `docs/17_dependency_probe.md`: малый read принят, новый большой read принят с managed hold; VLA warnings/полная closure остаются открыты;
не запускать/не печатать в обход active service barrier, не принимать partial metadata за dependency closure.

Скрипты брать из `toolkit/`, не писать заново.

## Знания по проекту — в папке проекта, не в плагине
Плагин общий для всех объектов; всё про конкретный объект живёт на общем диске рядом с чертежами:
- `CLAUDE.md` в корне папки объекта — объект, шифры, структура выдач, решения для всего объекта, где лежат записки разделов
  (Claude Code подхватывает его сам из родительских папок). Прочитать указанные там записки раздела, в котором работаем.
- `<раздел>\_claude\README.md` или `claude.md` — состояние раздела, решения автора, найденные ошибки, открытые вопросы, рабочие скрипты.
- Новые решения и находки по разделу — дописывать в `_claude` раздела (кратко, с датой); касающиеся всего объекта — в `CLAUDE.md` объекта.
  Общие находки об инструментах (не про объект) — предложить пользователю внести в плагин.
- Если у объекта нет `CLAUDE.md` — предложить создать по шаблону `${CLAUDE_PLUGIN_ROOT}/docs/PROJECT_CLAUDE_TEMPLATE.md`.
- Личная память Claude у каждого своя и коллегам не видна: всё, что нужно другим, — только в эти файлы.

## Первый запуск на новом ПК

`pwsh -File "${CLAUDE_PLUGIN_ROOT}/toolkit/check_env.ps1" -Build` — проверит AutoCAD 2024, СПДС GraphiCS 2023, Python и пакеты, Excel/Word,
соберёт плагин СПДС (`SpdsText.dll`) в рабочую папку. Если что-то не так — показать пользователю подсказки «→» и не продолжать работу с DWG.
Рабочая папка (копии, журналы, резервные копии): `%LOCALAPPDATA%\Temp\acc`, при кириллическом профиле — `C:\rd-ci-work`; переопределяется `RDCI_WORK`.

## Правила (всегда)

1. Массовые правки DWG: сначала тест на одном (самом большом) файле → показать результат в PDF → «ок» пользователя → только потом пакет.
2. Работать на копиях в рабочей папке. Исходник заменять только после проверенной резервной копии (скрипты делают сами); файлы, открытые у пользователя, не трогать
   (проверка открытием на запись; читать открытый файл можно — `[IO.File]::Open(path,'Open','Read','ReadWrite,Delete')`).
3. AutoCAD пользователя не автоматизировать и чужие процессы acad.exe не завершать. Свой acad.exe и accoreconsole — по одному, никогда одновременно.
4. Объекты СПДС не взрывать: править через API (`toolkit/spds_text`, вкл. `-Mode props` для отметок уровня).
5. Номер листа в штампе часто — поле от имени файла: копии DWG сохраняют начало имени; поле не затирать числом.
6. Инженерные значения (длины, массы, количества, отметки, марки изделий) не менять без согласия — предлагать с обоснованием «было → стало».
   Опечатки и чисто текстовые правки — тоже только по указанию пользователя.
7. Существующие папки выдач не перезаписывать; новая выдача — новая папка. Мусор (`.bak`, `plot.log`) — только переносом в резервную папку.
8. Решения пользователя, найденные ошибки и открытые вопросы — в `_claude` проекта (рядом с выдачами, на общем диске — их читают коллеги).
   Общие находки об инструментах — сообщить пользователю: их стоит внести в плагин (`docs/11_pitfalls.md`) через git-репозиторий плагина.
9. Вопросы — с вариантами, рекомендуемый первым. Пользователь пишет по-русски — отвечать по-русски.

## Быстрые рецепты (`${CLAUDE_PLUGIN_ROOT}/toolkit/`)

| Задача | Скрипт |
|---|---|
| Разведка листа (номер, шифр, объекты СПДС) | `dump_layout_texts.ps1 -Dwg … [-Model]` |
| Форматы листов / номера листов до печати | `check_papers.ps1 -DwgDir … -Add`, `check_sheet_numbers.ps1 -DwgDir …` |
| Внешние ссылки (отчёт / перепривязка / докопирование) | `xrefs.ps1 -DwgDir … [-XrefFolder "внешние ссылки"] [-Relativize] [-CopyMissingFrom …] [-Apply]` |
| Все тексты комплекта вкл. таблицы и выноски СПДС | `spds_text/run_txtfix.ps1 -Files … -Find '[\s\S]+' -Repl '$0' -Dry` → журнал `<рабочая папка>\txtfix\txtfix.log` + `map.txt` |
| Разбор журнала: таблицы, тексты, разница версий, арифметика спецификаций | `analysis/tblshow.py`, `textlist.py`, `textdiff.py`, `xdiff.py`, `kw.py`, `titles.py`, `specarith.py` |
| Найти/заменить текст вкл. СПДС | `spds_text/run_txtfix.ps1 -Files … -Find … -Repl … [-Seen …] [-Dry] [-Apply]` |
| Свойство объекта СПДС (отметка уровня) | `spds_text/run_txtfix.ps1 -Files … -Mode props -Class mcsDbObjectLevelMark -Prop Text -From … -To …` |
| Чужие коды сооружений, устаревшие ГОСТ | `run_txtfix -Dry` по кодам, затем `python -I find_codes.py --codes … --own …` |
| Перенумерация листов | `renum_stamp.ps1 -Files … -Prefix "Т7." -Map @{…}` (сначала без `-Apply`) |
| Имена / удаление пустых макетов | `fix_layouts.ps1 -File … -Rename @{…} -Delete …` |
| Печать комплекта и сводный PDF | `plot_set.ps1 -DwgDir … -OutDir … [-Exclude …] [-CoverPdf … -SetPdf …]` |
| Сводный PDF ↔ PDF по листам, шифр на страницах | `analysis/setcheck.py <сводный.pdf> <папка листов>` |
| PDF актуальны / что изменилось против прошлой выдачи | `python -I compare_pdfs.py <старое> <новое> [--diff-out …]` |
| Текст штампов, поиск текста, форматы, рендер PDF | `python -I pdf_tools.py stamps|grep|sizes|render …` |
| Самодостаточный отчёт из готового MD + локальных PNG/JPEG (не drawing set; запрещён в files_only) | `python -I report_pdf.py <summary.md> --output <NEW report.pdf>`; ограничения и manifest — `docs/13_orchestrator.md` |
| Обложка из шаблона Word; мусор в выдаче | `make_cover.ps1 -PreflightOnly` — offline контракт; новый `make_cover_draft.ps1` — guarded candidate только для отдельно допущенного coordinator smoke/QA, native acceptance pending (`docs/19_safe_cover.md`); `clean_issue.ps1 [-Apply]` |
| Лист ОД по образцу | `od/build_od.ps1` + генератор по шаблону `od/example_gen_od.py` |
| Объёмы: площадь по откосу, объекты по слоям, объёмы 3D-тел | `quantities/export_dxf.ps1` → `slope_area.py` / `layer_stats.py`; `quantities/massprop.ps1` |
| Зависший пакетный acad.exe — что на экране | `snap_window.ps1` |

Запускать `.ps1` из PowerShell 7 (`pwsh`), не из Git Bash. Python — `python -I`; в pwsh перед этим `[Console]::OutputEncoding = [Text.Encoding]::UTF8`.
Текст SHX в PDF не извлекается — проверять рендером (pymupdf) с кропом. Тексты с `\` (пути Windows) писать в файлы через Write/Edit
или raw-строки Python: `\a`, `\b`, `\20…` в обычной строке портят текст.
