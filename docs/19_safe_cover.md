# Обложка: промежуточный offline preflight, НЕ генерация

`make_cover.ps1` больше не запускает старый небезопасный путь Word COM.
Это намеренное несовместимое безопасное изменение default: обычный вызов после preflight
завершается ошибкой `native_word_ownership_timeout_cleanup_not_implemented` **до COM**.
Нет bypass-флага. Это отсутствие реализованного/принятого ownership/timeout пути,
а НЕ доказательство отсутствия Word или невозможности автоматизации на этом ПК.
Другие package/read/plot инструменты и `check_env.ps1` не изменены.

## CLI / API

PowerShell 7, установленный Python 3, стандартная библиотека; без установки модулей.
`Template`, `Out`, `Pdf`, `Replace` сохранены; `Force` теперь всегда ошибка, не разрешение перезаписи.
Новые обязательные данные: `TemplateSha256` и точная карта `ExpectedCounts` для каждого ключа `Replace`.
Родители выходов должны уже существовать; один общий существующий родитель допустим.
Расширение Out совпадает с Template (`.doc` или `.docx`); необязательный Pdf имеет `.pdf`.

Generic пример **только preflight**, пути и SHA выбирает вызывающий:

```powershell
# $template, $newDoc, $newPdf, $approvedTemplateSha — явные параметры вызывающего.
& ./toolkit/make_cover.ps1 -Template $template -TemplateSha256 $approvedTemplateSha `
  -Out $newDoc -Pdf $newPdf -Replace ([ordered]@{'TOKEN'='VALUE'}) `
  -ExpectedCounts @{'TOKEN'=1} -PreflightOnly

# Явный черновой passthrough-контракт без выдуманных замен (экспорта пока нет):
& ./toolkit/make_cover.ps1 -Template $template -TemplateSha256 $approvedTemplateSha `
  -Out $newDoc -Pdf $newPdf -PassthroughDraft -PreflightOnly
```

`-PreflightOnly` возвращает JSON в stdout, код 0 только для контрактной/файловой проверки.
Без него даже валидный контракт завершится ошибкой, файлов не создаст.
`cover_preflight.py` — та же offline-функция `preflight(dict)`; CLI `python -I toolkit/cover_preflight.py`
читает один JSON из stdin, возвращает JSON, код 0/1. Ключи: `template`, `template_sha256`, `out`,
`pdf`, `replace`, `expected_counts`, `passthrough_draft`, `force`.
Дубли JSON-ключей запрещены. Строки сравниваются буквально, без преобразования B/В или других реквизитов.
PowerShell hashtable может сам объединить ключи, различающиеся только регистром: для таких контрактов
использовать case-sensitive IDictionary либо прямой JSON API, не предполагать восстановление потерянных ключей.

## Что реально проверяется

- Оба выходных пути: отсутствие DOC и PDF (включая dangling link); нормализованный alias с source запрещён.
  Уже существующие файлы никогда не открываются на запись. Никаких Copy/Export/публикаций/очисток.
- Source — непустой regular file, без hardlink (`st_nlink=1`); source и все существующие
  компоненты source/output-parent без symlink/reparse. Родитель — directory, без автоматического создания.
- Локальные literal paths; UNC/device-prefix, wildcard и Windows ADS запрещены.
- Явный SHA256 source совпадает; identity/size/mtime и ctime в пределах одного метода stat/fstat
  проверяются вокруг чтения. Windows path stat и handle fstat могут иметь разные ctime semantics:
  их ctime не сравниваются между собой. Source читается как байты, не как документ.
- Карты замен/ожидаемых количеств имеют одинаковые ключи; количества — положительные целые,
  не bool; пустой контракт возможен только с явным `PassthroughDraft`, несовместимым с заменами.

Это не защита от конкурентной подмены каталогов и не filesystem sandbox: нужен стабильный локальный
каталог без параллельных писателей. План не резервирует output и не годится для последующего исполнения
без повторной проверки/защищённого snapshot. Непустой `.docx` может быть вообще не Word-документом.

## Чего НЕ реализовано / НЕ доказано

JSON всегда `status=preflight_only`, `execution_authorized=false`, `native_generation_available=false`,
`draft=true`, `engineering_approved=false`. `observed` и `postflight` равны null.
Это НЕ manifest выполненной генерации из `13_orchestrator.md`, не replacement evidence и не acceptance.

Нет чтения/изменения **ни одной Word story**: main body, headers/footers, textbox/shape stories,
fields и embedded content не проверены. Не обнаружены отсутствующие/лишние фактические совпадения;
`ExpectedCounts` — только заявленное ожидание. Нет гарантии сохранения форматирования/полей/картинок.
Нет Word startup/macros/link suppression, ownership, Document.Close/Word.Quit, release/timeout evidence.
Поскольку COM вообще не активируется, эти риски не реализуются в этом пути, но и не объявляются решёнными.
Нет DOC/PDF output, partial publication, PDF opening/pages/hash validation или visual/text/requisites QA.
Не выдумываются шифр/дата/ревизия/подписи; существующие supplied values не нормализуются.

## Минимальный следующий native adapter (ещё не реализован)

1. До COM консервативно отказать при любом существующем WINWORD; неопределённая process enumeration — отказ.
   Создать одну новую COM application, проверить HWND → новый WINWORD и held process identity до Open.
   Гонка чужого запуска/непроверяемая identity — uncertainty, не повод Quit чужого приложения.
   Не использовать GetActiveObject, PID/name kill или глобальные Stop-Process/taskkill.
2. Только в проверенном own instance до Documents.Open установить `AutomationSecurity=3`, отключить
   external link updates/prompts, сохранить/безопасно восстановить свои изменённые options; release всех RCW.
   Office startup/addins и OS ограничения честно отдельно: это не sandbox, macro setting не блокирует весь startup.
3. Сохранить hash-bound snapshot и новые частные временные artifacts; сначала exact literal counts в явно
   поддерживаемых stories, отказ при 0/duplicate/mismatch, затем replacements и postflight counts.
   Не считать boolean Find.Execute доказательством. Явно отказаться от unsupported stories/fields,
   не затирать Content.Text целиком и не обещать whole-document coverage.
4. Только свой document Close и только проверенный own Word Quit; ошибки Open/Find/Export/Close,
   зависание COM, uncertain ownership/cleanup — failed/uncertain. Нужна доказанная bounded strategy,
   а не внешний Job, якобы содержащий broker-created COM server; ни чужие процессы, ни чужие файлы не чистить.
5. Проверить непустой openable PDF/число ожидаемых страниц, source/output SHA, counts и cleanup evidence;
   только после этого no-replace publication из частных temp. Повторно проверить оба output,
   сохранить partials при ошибке (включая публикацию одного из пары), не делать silent retry/rollback overwrite.
   Реальные макет/текст/реквизиты/headers/images смотрит координатор; результат всё ещё draft, не инженерная приёмка.

## Offline tests

```text
python -I -m unittest discover -s scripts -p test_cover_preflight.py -v
```

Только synthetic bytes/files, mock reparse и PowerShell tripwires вместо COM/process commands.
Покрыты DOC/PDF collisions, общий parent без записей, source alias/hardlink, SHA mismatch и mutation
во время hash, link checks (реальные symlink cases могут skip без прав Windows), карты и literal Unicode,
явный passthrough, отсутствие Force, default fail-before и offline-only stdout через wrapper.
Это НЕ fake/native acceptance Open/Find/Export/Close: адаптера пока нет; эти failure tests,
verified ownership/foreign Word enumeration, uncertain cleanup и no-replace partial publication остаются следующему шагу.
