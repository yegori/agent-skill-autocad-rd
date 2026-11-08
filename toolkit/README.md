# toolkit — исполнители для работы с DWG

Проверены вручную на «Архыз ВО, РД 1 этап» (октябрь 2026). Порядок работы — `..\docs\10_playbook.md`,
ловушки — `..\docs\11_pitfalls.md`. Запускать из PowerShell 7 (`pwsh`), не из Git Bash.

| Файл | Что |
|---|---|
| `common.ps1` | Общие функции: запуск accoreconsole, `.scr` в cp1251 (с переводом строки в конце), проверка скобок LISP, занятость файла, копии в рабочую папку с сохранением начала имени (поля от dwgname), LISP-заготовки (макеты по вкладкам, печать). |
| `dump_layout_texts.ps1` | Разведка: тексты/атрибуты по макетам (и в модели) + типы объектов. |
| `check_papers.ps1`, `add_pmp_size.py` | Форматы листов до печати; недостающие — в PMP «DWG To PDF» (с копией). |
| `check_sheet_numbers.ps1` | Номера листов (поле / атрибут / текст) против номера из имени файла и порядка вкладок. |
| `renum_stamp.ps1` | Перенумерация в штампах по таблице «старый → новый» (MTEXT вида «Т7.N»). |
| `set_sheet_attr.ps1` | Номер листа в атрибут — только для действительно пустых (не трогать поля!). |
| `fix_layouts.ps1` | Переименование макетов, удаление пустых. |
| `xrefs.ps1` | Внешние ссылки: отчёт OK / НЕ ОТНОСИТЕЛЬНЫЙ / НЕТ ФАЙЛА (S4); `-Relativize` → `.\Внешние_ссылки\<файл>`; `-CopyMissingFrom`. |
| `plot_set.ps1`, `merge_set.py` | Печать всех макетов в `NNN <наименование>.pdf` (перед печатью — проверка форматов) и сводный PDF (обложка + листы). |
| `stage_inputs.py` | Новые snapshot/working, declared file/environment hashes, exact verify/plan-step refs; coverage explicit_not_discovered, всегда execution_authorized=false. `../docs/16_staging_plot.md`. |
| `inspect_resources.ps1`, `resource_inventory.py` | До трёх serial check_papers без Add, source/raw hashes/layouts/durations/exit codes; validation → conservative inventory/draft. `../docs/15_resource_inventory.md`; не print/reuse. |
| `plan_stages.py` | Draft PDF-план из package-owned inventory/оценок: порядок, sheet/start counts, budget/reserve, stable IDs; не разведка/исполнитель/reuse. См. `../docs/14_stage_plan.md`. |
| `spds_text/owned_acad.ps1`, `spds_text/OwnedCadProcess.cs` | Частный Job для GUI-исполнителя TXTFIX: suspended CreateProcess → assign → resume, очистка только своего семейства (включая оставшихся потомков), без PID/name kill. |
| `make_cover.ps1` | Обложка/титул из шаблона .doc(x): замены через Word COM → PDF. |
| `clean_issue.ps1` | Мусор в папке выдачи (`*.bak`, `_recover`, `plot.log`, `*.dwl*`…): отчёт, `-Apply` — перенос в резервную папку. |
| `spds_text\` | Найти/заменить текст, вкл. таблицы и выноски СПДС, без взрыва; режим `-Mode props` — свойства объектов СПДС (напр. отметки уровня). Отдельный acad.exe + плагин `SpdsText.cs` (`build_txtfix.ps1`). |
| `find_codes.py` | C1: чужие коды сооружений, устаревшие формулировки/ГОСТ — на листах и в именах макетов; разбор журнала `run_txtfix.ps1 -Dry`. |
| `compare_pdfs.py` | R1 / «PDF актуальны»: старая выдача против новой постранично; отличия по скоплениям пикселей с областями в мм, штамп отдельно; `--diff-out` — картинки «было / стало». |
| `pdf_tools.py` | `render` (страница → PNG), `stamps` (текст штампа), `grep [--missing]` (поиск текста по PDF), `sizes` (форматы страниц). |
| `snap_window.ps1` | Снимок окон процесса (PrintWindow) — диагностика зависшего acad.exe / диалогов в пакетном режиме. |
| `od\` | Лист «Общие данные» по образцу: `od_lib.py`, `build_od.ps1`, шаблон генератора `example_gen_od.py`. |
| `quantities\` | Объёмы (Q, `..\docs\03_checks.md`): `export_dxf.ps1` (DWG → DXF), `slope_area.py` (площадь в плане и по 3D-откосу), `layer_stats.py` (сводка по слоям, «узкие прямоугольники»), `massprop.ps1` (объёмы 3D-тел). |
| `check_env.ps1` | Проверка рабочего места (AutoCAD, СПДС, Python и пакеты, Excel/Word, рабочая папка); `-Build` — собрать плагин СПДС. |
| `analysis\` | Разбор журнала всех текстов (`run_txtfix -Find '[\s\S]+' -Dry`): `textlist.py` (тексты файла), `tblshow.py` (таблицы СПДС, поиск), `titles.py` (заголовки листов), `kw.py` (ключевые слова по макетам), `textdiff.py` / `xdiff.py` (что изменилось между версиями), `specarith.py` (арифметика спецификаций: кол × масса, масса = Ø × L; в спецификациях изделий с объединённой графой «масса изделия» — ложные срабатывания), `setcheck.py` (сводный PDF ↔ PDF по листам, шифр на страницах). Порядок проверки — навык `check-set`. |

Рабочая папка (копии, журналы, резервные копии, собранный `bin\SpdsText.dll`) — `%LOCALAPPDATA%\Temp\acc`; если профиль Windows
кириллический — `C:\rd-ci-work`; переопределяется `RDCI_WORK`. Пути AutoCAD/СПДС — `RDCI_ACAD_DIR`, `RDCI_SPDS_DIR`.
`backup\<скрипт>_<дата>` — оригиналы перед заменой.

Правила:
* acad.exe и accoreconsole не запускать одновременно; переменные PowerShell не называть одинаково с точностью до регистра.
* Python — `python -I …`; вывод в UTF-8, в pwsh перед запуском `[Console]::OutputEncoding = [Text.Encoding]::UTF8`.
* Скрипт, заменяющий исходник, сначала делает резервную копию и сверяет её размер; не получилось — исходник не трогается.

Проверка на Архызе (17.10.2026):
* `slope_area.py` (В-5А-1 л.7) — 183,70 → 259,44; 27,64 → 39,08; 80,95 → 108,56 м², как при ручной проверке;
* `massprop.ps1` (В-5А-1 л.6, inf_gsi_ditch_wall) — 27 тел, 47,910 м³;
* `find_codes.py` на выдаче В-4А-1 от 12.10 — все известные ошибки: «В-5А-2» в заголовке л.5, ГОСТ 34027 и макет «06_КВ-1_В-5А-1» на л.6, «цементно-грунтовой» на л.3;
* `compare_pdfs.py` — правки В-4А-2 л.3 и л.8 найдены; `xrefs.ps1` — перепривязка В-5А-2 л.8 (на копии).
