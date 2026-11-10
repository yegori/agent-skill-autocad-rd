# autocad-rd — инструменты и навыки для комплектов AutoCAD РД

Проверка, корректировка и сборка комплектов рабочей документации AutoCAD 2024 + СПДС GraphiCS.
Два навыка — `autocad-rd` и `check-set` — используют общие скрипты и документацию в Pi и Claude Code.
Пакет самостоятельный: для работы с чертежами проект сервиса rd-ci не нужен.

Приватный GitHub: https://github.com/yegori/agent-skill-autocad-rd .
Рабочая копия автора: `D:/yad/YandexDisk/dev/agent-skills/autocad-rd`.

## Установка

На новом ПК нужны доступ к приватному репозиторию и отдельная настройка AutoCAD/СПДС/Python.
GitHub-вход не переносит лицензии и авторизацию внешних сервисов.

```text
gh auth login
gh auth setup-git
gh repo clone yegori/agent-skill-autocad-rd D:/dev/agent-skills/autocad-rd
pi install D:/dev/agent-skills/autocad-rd
```

В активной сессии Pi — `/reload`. Для разработки автора:
`pi install D:/yad/YandexDisk/dev/agent-skills/autocad-rd`.
Альтернатива без рабочей копии: `pi install git:github.com/yegori/agent-skill-autocad-rd`.
Использовать только один источник, чтобы не дублировать навыки.

Установка Claude Code (старые внутренние имена сохранены для совместимости):

```text
claude plugin marketplace add yegori/agent-skill-autocad-rd
claude plugin install rd-ci@rd-ci-arkhyz
```

Полная инструкция, обновление и переход со старых установок — [docs/INSTALL.md](docs/INSTALL.md).
Скрипт локальной установки Pi: `pwsh -File scripts/install.ps1`.

## Карта пакета

| Путь | Назначение |
|---|---|
| `skills/autocad-rd/` | Работа с DWG/PDF, рецепты и правила безопасности |
| `skills/check-set/` | Полная проверка комплекта без изменения выдачи |
| `toolkit/` | PowerShell/Python и плагин СПДС; [список инструментов](toolkit/README.md) |
| `docs/03_checks.md` | Общий каталог проверок S/F/P/C/V/R/Q |
| `docs/10_playbook.md` | Порядок ручной работы и чек-листы |
| `docs/11_pitfalls.md` | Грабли AutoCAD/СПДС/печати; читать перед работой с DWG |
| `docs/12_arkhyz_test_cases.md` | Эталонные ошибки для проверки инструментов |
| `docs/14_stage_plan.md`, `toolkit/plan_stages.py` | Черновой PDF-план из явного inventory, не executor/автоматическое разрешение |
| `docs/15_resource_inventory.md`, `toolkit/inspect_resources.ps1`, `toolkit/resource_inventory.py` | До трёх read-only probe, raw evidence/SHA/timings → проверенный консервативный draft, не печать |
| `docs/17_dependency_probe.md`, `toolkit/inspect_dependencies.ps1` | Strict `--issue-only`, 16 unit + fake-wrapper checks; один native read принят, большой source failed/root exited, весь job failed; не closure/печать |
| `docs/16_staging_plot.md`, `toolkit/stage_inputs.py` | Explicit-only stage/snapshot/working/environment hashes и тестовый ControlledPlot; не discovery/авторизация/reuse |
| `docs/PROJECT_CLAUDE_TEMPLATE.md` | Шаблон инструкции для папки объекта |
| `docs/06_decisions.md` | Решения по пакету и границе с сервисом |
| `examples/reports/` | Пример генерации таблицы замечаний |
| `examples/arkhyz/` | Унаследованные эталонные скрипты и записки (только чтение) |
| `scripts/` | Установка и статическая проверка пакета |
| `package.json`, `.claude-plugin/` | Манифесты Pi и Claude Code |

## Проверки

Без запуска AutoCAD и изменения чертежей:

```text
python -I scripts/check_package.py
claude plugin validate .
python -I -m unittest discover -s scripts -p test_stage_plan.py -q
pwsh -NoProfile -File scripts/test_txtfix_process.ps1
python -I -m unittest discover -s scripts -p test_resource_inventory.py -q
pwsh -NoProfile -File scripts/test_resource_probe.ps1
python -I -m unittest discover -s scripts -p test_stage_inputs.py -q
python -I -m unittest discover -s scripts -p test_dependency_inventory.py -q
pwsh -NoProfile -File scripts/test_dependency_probe.ps1
pwsh -NoProfile -File scripts/test_controlled_plot.ps1
```

PowerShell test-скрипты используют только фиктивные native процессы, не Autodesk/DWG/MultiCAD.
`run_txtfix` назначает приостановленный GUI-процесс в собственный Job до первого выполнения; источники этим не разрешается менять.

На рабочем месте перед DWG: `pwsh -File toolkit/check_env.ps1 -Build`.
Сборки и временные результаты — только в рабочую папку, не в установленный пакет.
Переменные `RDCI_WORK`, `RDCI_ACAD_DIR`, `RDCI_SPDS_DIR` сохранены.

## Связь с rd-ci

[rd-ci](https://github.com/yegori/rd-ci) — отдельный проект автоматического сервиса: наблюдатель, очередь, Telegram-бот,
пайплайн проверки и сборки. Он ссылается на этот пакет как на источник исполнителей, а не хранит вторую копию.
Спецификация, архитектура и паспорта сервиса находятся там.

30.10.2026 общий репозиторий разделён без переписывания истории: существующий `agent-skill-rd-ci`
переименован в `agent-skill-autocad-rd`, а сервис выделен в новый `rd-ci` с той же общей историей до разделения.
Старые коммиты содержат обе части. Имена навыков, Claude-плагина `rd-ci` и marketplace `rd-ci-arkhyz` не менялись.
