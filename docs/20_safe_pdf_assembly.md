# Явная hash-bound сборка PDF — новый output, не инженерная выдача

`toolkit/assemble_pdf.py` собирает **все страницы** явно перечисленных PDF строго в порядке плана.
Не печатает DWG/Word, не выбирает обложку/версию/ревизию, не сортирует, не ищет файлы/glob/basename.
Это отдельный safe contract; legacy `merge_set.py` **не изменён** (sort/replace/cover==out остаются legacy).
Его replace допустим лишь в отдельно защищённом private intermediate, не как публичная no-overwrite гарантия.

## API / CLI

Python3 + уже установленный PyMuPDF (`import pymupdf`), без установки/fallback/subprocess/network.
UTF-8 JSON plan (без BOM, duplicate keys/invalid UTF-8 — отказ):

```json
{
  "inputs": [
    {"path": "front.pdf", "sha256": "<64 hex SHA256>", "pages": 2},
    {"path": "body/sheet.pdf", "sha256": "<64 hex SHA256>", "pages": 1}
  ],
  "expected_total_pages": 3
}
```

```text
python -I toolkit/assemble_pdf.py --plan <plan.json> --input-root <selected-input-directory> --output <NEW.pdf> --report <NEW.json> [--work-parent <existing-private-work-parent>]
```

Все roots/paths задаёт caller; non-ASCII filenames поддержаны. Input paths только relative под input-root,
без `..`, absolute/drive-relative/Windows reserved aliases, wildcard/ADS. Duplicate canonical path **или SHA**
запрещены. Pages/total — положительные integer, bool запрещён, сумма должна совпасть.
Output PDF, JSON sidecar и work должны быть **вне input-root**; их родители уже существуют (общий parent
со staged siblings допустим). Оба точных destinations должны отсутствовать; Force/replace/alias с input нет.
По умолчанию work-parent=output parent. Библиотечный API: `assemble(plan,input_root,output,report,work_parent=None)`;
inert publisher seam только в unit tests, не CLI/native bypass.

## Что доказывается / что нет

- Переиспользованы common guards `cover_preflight`: literal Windows rules, lstat каждого ancestor,
  symlink/reparse/hardlink отказ, regular nonempty input. Input-root тоже проверяется до спуска.
- У каждого input held/read bytes привязаны SHA и identity/size/mtime/nlink/ctime вокруг чтения;
  **именно эти bytes** передаются `pymupdf.open(stream=...,filetype='pdf')`, не повторно открытый source pathname.
  После сборки/при публикации повторные source SHA+identity checks. CLI plan также bound и postflight checked.
- Только незашифрованные PDF, точные declared pages; все pages вставляются по плану. Не извлекается text,
  не рендерятся страницы, не ищутся fonts. Никаких новых engineering/requisites/author/title metadata.
- Новый случайный private run, exclusive `assembled.pdf`; output закрыт, перечитан и проверен по SHA,
  total/order decoded content-stream hashes/rotation/rect/MediaBox/CropBox (tolerance0.0001pt).
  Stream hashes — byte-level order guard, **не semantic/annotation/resource/pixel/engineering acceptance**.
  PDF insert/save может дать RGB delta; не требовать pixel identity как единственный критерий успеха.
- Exclusive `xb` publication PDF затем JSON +flush/fsync/hash, никогда не replace. Пара **не атомарна**.
  Ошибка второй публикации оставляет первый PDF; ошибка записи может оставить partial output/report.
  CLI/API возвращает failed с published/attempt/partial flags и private result; ничего не удаляет/не retries.
- Все private work сохраняются и при успехе (`cleanup=private_work_retained_no_deletion`). Нет ложного
  cleanup proof: ошибка записи private result — failed/evidence_write_uncertain, stdout сохраняет known paths.

Успех: `status=assembled_pending_coordinator_qa`, `engineering_release_approved=false`, ordered source bindings,
output SHA/pages/formats, report SHA в stdout/private result, declared limits. Sidecar сам по себе не completion
proof: требуется exit0 **и** успешный retained private `result.json`; при failed pair не принимать отдельный
public candidate/report за completed. Выбрать NEW paths после устранения причины, старые partials сохранять.

Limits:64 inputs,1000 pages,128MiB/input,512MiB total captured input и private output; plan1MiB.
Trusted PDF parser, стабильные локальные directories без параллельных подмен; это НЕ OS/filesystem sandbox,
лимит bytes не гарантирует предел decompression/CPU parser. Нет гарантии сохранения document-level outlines,
metadata/attachments/forms/digital signatures либо полной fidelity/аннотаций/внешних ресурсов.
Никакого signing, signature authority, S4 closure/DWG freshness/native print/выпуска/full MVP не заявляется.

## Manifest / QA

Drawing merged PDF — `artifact_paths`; JSON assembly sidecar — `report_paths` (это не report PDF).
Caller создаёт orchestrator manifest по [13_orchestrator.md](13_orchestrator.md) отдельно после QA; CLI status
не меняет старые jobs/flags и не заменяет этот manifest. В `files_only` Python/PDF-tool запрещён.
Проверить порядок/число/форматы/текст/визуальную сохранность уже нового output в отдельно разрешённом scope.
Не смешивать разные версии или exploratory листы как approved revision без выбора инженера.

## Только synthetic regression tests

```text
python -I -m unittest discover -s scripts -p test_assemble_pdf.py -v
```

Только новые synthetic PyMuPDF inputs, Unicode order2+1/default metadata, malformed/hash/count/password,
path/alias/link/reparse/identity/postflight/сaptured bytes и no-replace collision/partial-pair cases.
Symlink cases могут явно skip без Windows privilege. Это не повтор старой control assembly и не приёмка
actual issued PDFs: следующий полезный coordinator scope выбирается отдельно, с NEW inputs/output/run.
