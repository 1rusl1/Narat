# Базовый каталог из 606 записей

Выпуск подготовлен для английского MVP. Все 606 исходных пар `plant_id` и Wikidata ID сохранены. Полный выпуск ещё предстоит загрузить в Supabase и проверить в приложении.

- `plants.json` — карточки с научным именем, названиями EN/PL, поисковыми aliases,
  описаниями, основным изображением, интервалами полива по сезонам (`watering`) и происхождением каждого блока.
- `media/` — скачанные изображения и metadata; приложение не должно зависеть от
  внешних URL при показе фотографий.
- `coverage.json` — 606 английских и 603 исторических польских описания, 407 карточек с английскими обиходными названиями и 424 с польскими. Из 606 справочных записей полива 278 совпадают по виду, 15 по синониму, 223 по роду и 90 по группе.
- `manifest.json` — контрольные суммы данных и изображений.
- `validation.json` — независимая проверка целостности и совпадения JSON/SQLite/Plantfolio.
- `editorial-review.json` — объём редакционной проверки и хеш проверенного выпуска. `image-validation.json` и `offline-validation.json` фиксируют декодирование и повторную сборку тех же данных.
- `discovery.json` — воспроизводимый набор кандидатов и источник категории.

Научное имя и названия сохраняют происхождение в Wikidata и закреплённых ревизиях Wikipedia. Поисковые aliases включают научные синонимы. При отсутствии обиходного названия используется научное. `Philodendron × domesticum` сохраняет прежний ID и помечен как гибрид. В остальных записях сохраняется историческая таксономическая номенклатура. [Kew Plants of the World Online](https://powo.science.kew.org/taxon/193021-2)

Описания сохраняют ссылку на статью и ревизию, авторство и условия CC BY-SA 4.0. У Begonia maculata, Begonia corallina и Hoya lanceolata некорректные польские источники заменены на `descriptions.pl: null`. При польском запросе возвращается оригинальное английское описание с `language: en`.

Все 606 медиа проверены по закреплённым источникам, лицензиям и байтам. При визуальном просмотре проверялась пригодность изображения для карточки, в том числе ботанических рисунков и гербарных образцов. Историческое поле `species_visual_review` фиксирует статус исходной записи импорта. Шесть замен и основания выбора закреплены в [манифесте изображений](../../manifests/skeleton-300-editorial-media.json). Для Hoya lanceolata используется гербарный экземпляр, для Philodendron × domesticum — снимок листа с пофайловой лицензией. [Royal Botanic Garden Edinburgh](https://iiif.rbge.org.uk/herb/iiif/E01479576/manifest), [Pl@ntNet](https://identify.plantnet.org/oc/k-world-flora/species/Philodendron%20%C3%97%20domesticum%20G.S.Bunting/data)

Сезонные данные Plantfolio остаются справочными. Применимость конкретного совета проверяется отдельно перед публикацией профиля ухода.

## Воспроизведение из корня проекта

```sh
python3 knowledge-base/pipeline/import_catalogue_300.py --offline
python3 knowledge-base/pipeline/validate_catalogue_skeleton.py --check
python3 tools/automation/t148_catalogue_gate.py --mode release --run-id t148-local
python3 -m unittest discover -s knowledge-base/tests -q
```

Офлайн-пересборка требует сохранённых `knowledge-base/raw/catalogue-300/`, `media/` и снимка Plantfolio из `knowledge-base/references/personal/watering/plantfolio-common-plants/`.
Сырые API snapshots и SQLite staging игнорируются Git. Для нового сетевого запуска
передать `--user-agent` с настоящим публичным контактом оператора. Существующий кеш
не обновляется автоматически; новый релиз требует отдельного каталога снимков.

## Атрибуция

Wikidata structured data: CC0. Тексты Wikipedia: CC BY-SA 4.0, с URL статьи,
revision/history и указанием авторов Wikipedia в каждой записи. Сохранить эти сведения
при показе/распространении; переводы и редакции соответствующего текста должны
соблюдать условия share-alike. Фото имеют индивидуальные лицензии, авторов и ссылки.
Лицензия данных не задаёт лицензию исходного кода приложения.

[Исследование источников](../../../research/plant-data/basic-catalogue-sources-2026-11-04.md).
