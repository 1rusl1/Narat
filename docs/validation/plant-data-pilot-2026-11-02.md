# Пилот загрузки данных растений — 2026-11-02

## Результат

Реально получены и сохранены полные Wikidata entity JSON для трёх видов, API metadata и три оригинальные фотографии Wikimedia Commons. Все записи — draft, не опубликованный KB release. Подготовлены локальная SQLite-база и JSON/CSV-экспорт; запросы к внешним каталогам при чтении этих файлов не нужны.

| Растение | Wikidata / revision | Польское имя из источника | Фото | Лицензия фото |
|---|---|---|---:|---|
| Monstera deliciosa | Q161077 / 2547601493 | Monstera dziurawa | 1512 × 1719 | Raul654, CC BY-SA 3.0 |
| Ficus elastica | Q160576 / 2546495189 | Figowiec sprężysty | 1632 × 921 | VuThiAnh, CC0 1.0 |
| Epipremnum aureum | Q161809 / 2563948953 | Epipremnum złociste | 4288 × 2848 | Joydeep, CC BY-SA 3.0 |

JSON source snapshots: 81 200 / 89 605 / 72 734 bytes в первоначальной браузерной копии; прямой HTTP-импорт выполнен отдельно и сохраняет собственные sha256. Исходники содержат все поля выданного entity JSON, не только нормализованную проекцию.

Нормализованы EN/PL labels/aliases, statements общеупотребительных имён при наличии, научное имя, сокращение автора таксона, parent taxon IDs, кандидаты изображений и внешние идентификаторы. Внешних типов ID: 66 / 63 / 42 соответственно. Их наличие не означает, что все внешние каталоги были загружены/проверены. Строка EN label может оставаться латинским именем — её не объявляем готовым пользовательским переводом.

## Файлы

- [SQLite](../../knowledge-base/staging/catalogue.sqlite): 3 строки `catalogue_drafts`, 3 строки `catalogue_media`; журнал `import_runs`.
- [JSON](../../catalogue/pilot/plants.json), [CSV](../../catalogue/pilot/plants.csv), [manifest](../../catalogue/pilot/manifest.json).
- [Медиа и атрибуция](../../catalogue/manifests/pilot-media.json): исходные URL, автор, лицензия, metadata hash, image sha1/sha256, local path и даты. Изображения скачаны без изменений.
- `knowledge-base/raw/wikidata-http/`: прямые HTTP JSON snapshots и metadata.
- `knowledge-base/raw/wikidata/`: ранее сохранённый JSON из открытых в браузере документов; acquisition явно обозначен как текст документа, а не raw HTTP bytes.
- `knowledge-base/raw/commons/`: оригинальные ответы imageinfo API.
- `knowledge-base/raw/media/`: три оригинальных JPG, суммарно 17 305 414 bytes.
- `knowledge-base/references/personal/aspca/swiss-cheese-plant.html`: одна личная некоммерческая reference-копия HTML, с метаданными. Исключена из Git и public KB.
- `knowledge-base/raw/rights/kew-wcvp-index.html`: сохранён индекс выгрузок Kew. Сам WCVP archive ещё не скачан.

## Как выполнено

Первичный DNS-запрос из sandbox не прошёл. После разрешённого сетевого запуска проверка Kew index и одна выбранная ASPCA-страница загрузились. Три записи Wikidata сначала получены через обычный браузер, затем **отдельно успешно выполнен прямой HTTP-импорт** с предоставленным владельцем контактом в User-Agent. Контакт не встроен в исходники загрузчика или manifest.

Для Commons прочитаны страницы каждого выбранного файла и его лицензия, затем сохранены API metadata и originals. Доступ разрешён operation-level записью `wikimedia_commons_pilot_assets` только для этих трёх конкретных файлов; это не общее одобрение любых фотографий Commons.

Исходные изображения просмотрены. Они пригодны как иллюстративные референсы, но не утверждены как финальные hero-фото интерфейса и не подтверждают особенности всех сортов/возрастов. Крупное фото эпипремнума — 15,9 MB: перед app release понадобятся оптимизированные варианты с соблюдением условий лицензии. В пилоте сохранён original.

## Повторная сборка без сети

```sh
python3 knowledge-base/pipeline/import_wikidata.py --offline --raw-dir knowledge-base/raw/wikidata-http
python3 knowledge-base/pipeline/download_pilot_media.py --offline --user-agent offline-rebuild
python3 knowledge-base/pipeline/export_pilot.py
```

Для нового сетевого запуска обоим downloader передаётся `--user-agent` с реальным контактом. Изображения и metadata переиспользуют локальный кеш; сеть не нужна для приведённых выше команд. Хеши проверяются до экспорта. `retrieved_at` медиа соответствует mtime первого скачанного original; `verified_at` — повторной проверке локальной копии.

## Проверки

- `python3 -m unittest discover -s knowledge-base/tests -p 'test_*.py' -v`: **11 passed**.
- На реальных данных: ровно 3 уникальных вида, ровно 3 media rows после повторного экспорта.
- `PRAGMA integrity_check`: **ok**.
- SHA256 каждого entity snapshot совпадает с записанным provenance.
- SHA1 каждого original совпадает с imageinfo; SHA256 совпадает с manifest/экспортом.
- Offline-сборка повторена успешно, дубли растений/медиа не появились.
- Raw и персональные reference-копии исключены из Git; JSON/CSV — переносимые draft-артефакты.

## Ограничения и продолжение

Это 3/300 видов, не полный импорт. Уход и токсичность в draft не заполнены: `care=null`, cat/dog `unknown`, `care_profile_available=false`. Сохранённая личная страница ASPCA не опубликована в данных приложения. Perenual не выгружался; нужен API key/подходящие условия получения. Семейства и принятые синонимы ещё не сверены с выбранным WCVP release. Подготовка собственного KB и публикация в Supabase не выполнены.

Следующий этап — согласованный seed 300 видов и точная WCVP-выгрузка, затем масштабирование импортёров/сверка таксономии, оптимизация лицензированных изображений, заполнение профилей ухода по разрешённым независимым основаниям. T108/T109/T110/T115 пока не закрыты.

## Источники

- [Monstera — Wikidata](https://www.wikidata.org/wiki/Q161077), [Ficus — Wikidata](https://www.wikidata.org/wiki/Q160576), [Epipremnum — Wikidata](https://www.wikidata.org/wiki/Q161809).
- [Monstera photo](https://commons.wikimedia.org/wiki/File:Monstera_deliciosa2.jpg), [Ficus photo](https://commons.wikimedia.org/wiki/File:Da_bup_do.jpg), [Epipremnum photo](https://commons.wikimedia.org/wiki/File:Epipremnum_aureum_31082012.jpg).
- [ASPCA reference page](https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants/swiss-cheese-plant).
