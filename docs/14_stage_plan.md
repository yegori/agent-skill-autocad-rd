# Черновой план PDF-подэтапов

`toolkit/plan_stages.py` — чистый producer плана **в пакете autocad-rd**, не CAD-исполнитель,
не rd-ci scheduler, не автоматическая приёмка инженерных данных. Ничего не открывает в AutoCAD,
не копирует/не изменяет DWG и не включает очередь. Сервису остаются ID/связи/timeout/lifetime.

## Вход от метода разведки пакета

```json
{
  "schema_version": 1,
  "operation": "pdf",
  "files": [
    {
      "path": "DWG/001 example.dwg",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "sheet_count": 2,
      "cad_starts": 2,
      "estimated_seconds": 300,
      "estimate_basis": "conservative"
    }
  ]
}
```

Это синтетический пример, не измерение/хеш реального чертежа.
Порядок массива задан методом выбора листов пакета и сохраняется; producer не сортирует и не угадывает его.
Единица пока **целый DWG**: исключать/делить отдельные layouts без поддержки исполнителя нельзя.
Path — canonical relative POSIX DWG path, SHA256 — текущего immutable snapshot, lowercase hex.
Windows-drive/UNC/backslash/traversal/пустые компоненты/дубли case-insensitive отказывают.
Реальные пути/инвентари/измерения/планы сохранять в work/output проекта, не в Git пакета.

sheet_count/cad_starts/estimated_seconds обязаны происходить из package-owned разведки и измерений либо
явной консервативной оценки. `measured` — пометка источника оценки, не самопроверяемое доказательство:
разведка должна сохранить sample/log и cold/warm context отдельно. Байты файла не являются заменой этих полей.
Unknown/NaN/boolean/нулевые оценки → needs_input с file_index/reason и **пустым steps**; не частичный auto-run.
Крупный отдельный DWG → needs_input для package split/review, не автоматически увеличенный timeout.

## Выход и пределы

- Бюджет до 1200 секунд на подэтап, по умолчанию reserve 180 секунд на Pi/setup/report overhead,
  максимум три CAD-start на шаг в начальном пилоте. Reserve — явная политика запаса, не измеренное время.
- Greedy contiguous groups без изменения порядка, сумма estimates + reserve <= budget и starts <= limit.
  Число листов сохраняется в метриках, не подменяется весом файла.
- Stable plan_id и UUID step_id зависят от order/source hashes/оценок/числа листов/starts/политики.
  Size_bytes/посторонние поля не участвуют. Изменение оценки/источника создаёт новый plan_id.
- Успешный результат **status=draft, execution_authorized=false**. Needs_input также не разрешает исполнение.
  Ни это поле, ни status не заменяют согласование/проверку runner и current source integrity.
- Общего budget всего комплекта нет: несколько шагов могут суммарно занять больше 20 минут.
  Длинный/неожиданный шаг всё равно ограничивается runner timeout, а не обещанием точной оценки.

```text
python -I toolkit/plan_stages.py <inventory.json> --output <new-plan.json>
python -I -m unittest discover -s scripts -p test_stage_plan.py -q
```

CLI пишет только новый файл (exclusive create), существующий план не заменяет. Exit: 0 draft, 3 needs_input, 2 error.
Восемь тестов: order/reserve/starts, unknown/oversize/boolean/nonfinite/huge estimates, paths/hash/dedup,
стабильность идентификаторов, независимость от bytes и неизменность существующего output.

## Что ещё НЕ реализовано

Полное покрытие layout inventory комплекта, калибровка cost families/cold starts/СПДС/xref, физический staging
копий/зависимостей, отдельная сборка и независимая PDF-проверка, adaptive replanning, исполнение plan из rd-ci
и безопасный reuse intermediates. SHA одного DWG **недостаточен для reuse**: нужны также xref/шрифты/plot options,
версии методов, artifact hashes и validation evidence. По одному plan_id не возобновлять и не переиспользовать.

Ограниченный resource collector/проверка raw evidence и начальная консервативная cost policy добавлены в
[15_resource_inventory.md](15_resource_inventory.md): до трёх подготовленных входов, не автоматический полный комплект.
Single-DWG gate cad_pdf в rd-ci не снят. Следующий шаг — соединить этот черновик с настоящей package-owned
разведкой/стейджингом и фазами inspect → plot → assemble → validate, а не просто передать список файлов старому worker.
