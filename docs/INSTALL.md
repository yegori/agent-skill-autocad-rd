# autocad-rd: установка и работа

Самостоятельный пакет Pi и плагин Claude Code с навыками `autocad-rd` и `check-set`, инструментами проверки,
правки и сборки комплектов AutoCAD РД. Сервис [rd-ci](https://github.com/yegori/rd-ci) устанавливать не нужно.
Внутренние имена Claude-плагина `rd-ci` и marketplace `rd-ci-arkhyz` сохранены для совместимости.

## Что нужно на компьютере

- Windows 10/11, **AutoCAD 2024** с Civil 3D Object Enabler, **СПДС GraphiCS 2023 x64**, Excel и Word.
- **PowerShell 7**: `winget install Microsoft.PowerShell`.
- **Python 3.11+**, затем `python -m pip install pymupdf ezdxf numpy scipy shapely pillow openpyxl`.
- Git и GitHub CLI: `winget install Git.Git GitHub.cli`.
- Pi и/или Claude Code, учётная запись GitHub с доступом к приватному `yegori/agent-skill-autocad-rd`
  (приглашение даёт Егор Иванов). Наличие доступа к сервису rd-ci не заменяет доступ к пакету.

Вход: `gh auth login`, затем `gh auth setup-git`. Лицензии AutoCAD/СПДС и авторизация внешних сервисов
настраиваются отдельно на каждом ПК; GitHub-вход их не переносит.

## Pi

Для установки из GitHub:

```text
pi install git:github.com/yegori/agent-skill-autocad-rd
```

Для разработки и установки из рабочей копии:

```text
gh repo clone yegori/agent-skill-autocad-rd D:/dev/agent-skills/autocad-rd
pi install D:/dev/agent-skills/autocad-rd
```

На ПК автора: `pi install D:/yad/YandexDisk/dev/agent-skills/autocad-rd`.
Вместо последней команды можно из клона выполнить `pwsh -File scripts/install.ps1`.
Выбрать **один** источник: локальный пакет читается без копирования, Git-пакет загружается отдельно.
После установки в активной сессии — `/reload`.

```text
/skill:autocad-rd проверь окружение
/skill:check-set проверь комплект в папке …
```

Обновление Git-пакета: `pi update --extensions`, затем `/reload`.
Локальный пакет обновлять через `git pull --ff-only` в его рабочей копии, затем `/reload`.
В Pi явно просить прочитать `CLAUDE.md` объекта и `_claude` раздела.

### Переход со старой установки Pi

Посмотреть `pi list` и удалить **только реально подключённый старый источник**, например:

```text
pi remove D:/yad/YandexDisk/dev/agent-skills/rd-ci
pi remove git:github.com/yegori/agent-skill-rd-ci
```

Если подключён ещё более старый `git:github.com/yegori/rd-ci`, удалить и его: теперь этот URL ведёт
на **сервис, не пакет навыков**. Затем установить один новый источник выше и выполнить `/reload`.
Команды навыков не менялись. Старые пользовательские копии/обёртки навыков сохранять вне каталогов
обнаружения (`~/.pi/agent/skill-backups/`), не держать вторую редактируемую копию в `~/.pi/agent/skills/`.

## Claude Code

```text
claude plugin marketplace add yegori/agent-skill-autocad-rd
claude plugin install rd-ci@rd-ci-arkhyz
```

Если без SSH-ключа скачивание не работает, задать `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`.
В VS Code: Manage plugins → добавить marketplace `yegori/agent-skill-autocad-rd` → установить `rd-ci`.
В `/plugin` → Marketplaces → `rd-ci-arkhyz` включить auto-update, либо обновлять вручную:

```text
claude plugin marketplace update rd-ci-arkhyz
claude plugin update rd-ci@rd-ci-arkhyz
```

При локальной разработке вместо GitHub-источника:
`claude plugin marketplace add D:/yad/YandexDisk/dev/agent-skills/autocad-rd`.
Не менять имена плагина и marketplace: существующие установки используют их как идентификаторы.

### Переход со старого marketplace

Если marketplace указывает на прежнюю локальную папку или `yegori/rd-ci`, источник нужно заменить.
Для старого `agent-skill-rd-ci` GitHub может сохранить redirect, но рекомендуется явно указать новое имя:

```text
claude plugin uninstall rd-ci@rd-ci-arkhyz
claude plugin marketplace remove rd-ci-arkhyz
claude plugin marketplace add yegori/agent-skill-autocad-rd
claude plugin install rd-ci@rd-ci-arkhyz
```

Для локальной разработки в команде `marketplace add` подставить новую локальную папку.
Проверить `claude plugin list`, `claude plugin marketplace list`, при необходимости снова включить auto-update.
Перезапустить активную сессию Claude Code после изменения установки.

## Проверки

Статически, без AutoCAD:

```text
python -I scripts/check_package.py
claude plugin validate .
```

Перед работой с DWG попросить агента проверить окружение или выполнить:

```text
pwsh -File "<корень пакета>/toolkit/check_env.ps1" -Build
```

Скрипт проверит AutoCAD, СПДС, Python, Excel/Word и соберёт SpdsText в рабочую папку.
Он не устанавливает AutoCAD/СПДС. При ошибках сначала устранить причины, не переходить к DWG.

## Работа и безопасность

Открывать агента в папке объекта. Прочитать `CLAUDE.md` объекта и записки `_claude` раздела;
для нового объекта есть `docs/PROJECT_CLAUDE_TEMPLATE.md`.

- Массовые правки: один файл → показать PDF → получить «ок» → пакет.
- Работать на копиях; перед заменой исходника — проверенная резервная копия, открытые файлы не перезаписывать.
- AutoCAD пользователя не автоматизировать, чужие процессы не завершать.
- Свои acad.exe/accoreconsole запускать по одному, не одновременно. СПДС не взрывать, использовать API.
- Инженерные значения менять только по решению пользователя.
- Решения и ошибки объекта — в `_claude` рядом с чертежами, не в репозитории пакета.
- Общие находки инструментов — в `docs/11_pitfalls.md` пакета через Git; секреты и пользовательские документы в Git не добавлять.

## Рабочая папка

Копии, журналы, резервные копии и сборки: `%LOCALAPPDATA%/Temp/acc`, при кириллическом профиле — `C:/rd-ci-work`.
Переопределяется `RDCI_WORK`; AutoCAD/СПДС — `RDCI_ACAD_DIR`, `RDCI_SPDS_DIR`.
Имена переменных сохранены, несмотря на переименование пакета. В установленный пакет ничего не писать.

## Диагностика

- Не скачивается — `gh auth status`, доступ collaborator к **пакету**, настройка HTTPS.
- Нет навыков — `pi list`, `/reload`, отсутствие старых копий; в Claude — `claude plugin list`.
- Нет подходящего носителя — нестандартный формат: скрипты печати добавляют его в DWG To PDF с резервной копией PMP.
- Ошибки сервиса/бота — проект rd-ci; ошибки исполнителей и ручных навыков — autocad-rd.
