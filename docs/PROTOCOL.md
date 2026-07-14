# Протокол моста

## Файлы

| Файл | Кто пишет | Что содержит |
|---|---|---|
| `from_sketchup.glb` | SketchUp | вся синхронизируемая геометрия (whole export) |
| `manifest_sketchup.json` | SketchUp | ревизии объектов |
| `from_blender.glb` | Blender | коллекция "SketchUp Sync" |
| `manifest_blender.json` | Blender | ревизии объектов |
| `state_sketchup.json` / `state_blender.json` | каждый своё | приватное состояние стороны |

Манифест пишется атомарно (tmp + rename) и **после** GLB — получатель, увидев новый
манифест, гарантированно читает уже дописанный GLB.

## Манифест

```json
{ "seq": 7, "saved_at": 1752500000,
  "objects": { "Chair": { "rev": 7, "deleted": false },
               "OldLamp": { "rev": 6, "deleted": true } } }
```

## Состояние стороны (state_*.json)

```json
{ "seq": 7, "objects": {
    "Chair": { "rev": 7, "origin": "blender", "local_hash": "md5..." } } }
```

`local_hash` — хэш локального представления объекта (вершины с округлением,
материалы, матрица). Сравнивается только сам с собой, никогда между программами.

## Алгоритм push (при сохранении)

1. Для каждого объекта верхнего уровня посчитать `local_hash`.
2. Совпал с хэшем в state → объект не менялся → **ревизия сохраняется** (защита от эха).
3. Не совпал / новый → `rev = seq + 1`, origin = своя сторона.
4. Объект из state отсутствует локально → tombstone `deleted: true, rev = seq + 1`.
5. Экспорт GLB → запись манифеста → запись state.

## Алгоритм pull (таймер, 2 с)

1. mtime манифеста другой стороны не изменился → выход.
2. Для каждого объекта манифеста: `rev > state.rev` → в список применения
   (или удаления, если tombstone).
3. Импорт GLB целиком во временный контейнер, из него берутся **только** нужные
   объекты (матчинг по имени, суффиксы `.001`/`#1` отбрасываются), старые версии
   удаляются, новые встают на их место с мировой трансформацией.
4. Обновление state: `rev`, `origin = другая сторона`, `local_hash` нового объекта.
5. Остаток импорта удаляется.

Ключевой инвариант: после apply `local_hash` в state равен хэшу применённого
объекта, поэтому следующий push этой стороны не поднимет ревизию — эха нет.

## Почему хэш после чистки не ломает протокол

SketchUp при импорте сливает треугольники и меняет геометрию — хэш считается
уже от очищенной версии и хранится локально. Blender об этом не знает и не должен:
его ревизия объекта осталась прежней.

## Тест-план первого запуска

1. **SU → GLB через Ruby**: `model.export(path, show_summary: false)` — на некоторых
   сборках сигнатура может отличаться (есть fallback на `model.export(path, false)`).
2. **Имена узлов в GLB из SketchUp** — матчинг объектов зависит от того, что экспортёр
   пишет имена групп в ноды. Если пишет имена definition — поправить `by_name`.
3. **`model.import` GLB** — не должен открывать диалог размещения; если открывает,
   переходить на импорт через временный отдельный процесс/деф (см. import_glb fallback).
4. **Blender export в таймере** — если `bpy.ops.export_scene.gltf` ругается на
   контекст, обернуть в `bpy.context.temp_override(...)` с первым окном.

## Исследовательская база (прецеденты)

- TCP-мост внутри SketchUp: [zinin/sketchup-mcp2](https://github.com/zinin/sketchup-mcp2),
  [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp)
- Blender-сторона: [ahujasid/blender-mcp](https://github.com/ahujasid/blender-mcp)
- Полный real-time sync (эталон архитектуры): [ubisoft/mixer](https://github.com/ubisoft/mixer)
- Observers best practices: [Observers2016.pdf](https://assets.sketchup.com/files/ewh/Observers2016.pdf)
- Обмен через сервер: [Speckle](https://speckle.systems/integrations/)
