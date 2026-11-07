# Профиль монстеры: пробное дополнение — 2026-11-03

## Полученный результат

Сохранён [исследовательский профиль](../../catalogue/pilot/profiles/monstera_deliciosa.research.json) Monstera deliciosa: 24 записи фактов/кандидатов с evidence и состоянием проверки, 5 коротких текстов на EN и PL. Его точная копия и SHA256 записаны в локальную SQLite, таблица `plant_profile_research`. Это **research draft**, не опубликованный PlantProfile и не действующий источник рекомендаций приложения.

## Источники и фактический сбор

- Прямым HTTP с согласованным Wikimedia User-Agent получены новые entities **Q159216 (Monstera)** и **Q48227 (Araceae)**. Их JSON, revision, дата и SHA256 сохранены в `knowledge-base/raw/wikidata-http/`. Проверена цепочка вида Q161077 → род → семейство, включая scientific names и taxon ranks. Это не WCVP-проверка принятого имени/синонимов.
- Прочитаны официальные [NC State](https://plants.ces.ncsu.edu/plants/monstera-deliciosa/), [RHS-карточка](https://www.rhs.org.uk/plants/11192/monstera-deliciosa-f/details), [RHS-гайд рода](https://www.rhs.org.uk/plants/swiss-cheese-plants), [Wisconsin Extension](https://hort.extension.wisc.edu/articles/monstera-deliciosa/). В JSON сохранены краткие собственные фактографические заметки и section locators; исходный текст/фото сайтов не зеркалировались. Их page hashes неизвестны и остаются null. Production-права этих доноров не утверждены, автоматические HTML-адаптеры не включены.
- Две RHS-страницы считаются одним независимым донором; все Wikidata entities — одним. Три care-донорские группы: NC State, RHS, UW–Madison. Это количество прочитанных доноров, не три независимых подтверждения каждого поля и не готовность к публикации.
- ASPCA/Perenual не импортировались и не использовались для LLM-преобразования. Существующая личная ASPCA-копия не менялась. Новые фото не загружались.

## Какие блоки появились

| Блок | Результат |
|---|---|
| Таксономия | Род Monstera, семейство Araceae из проверенной цепочки snapshots; EN common name, исходный PL label; один кандидат в синонимы для дальнейшей сверки |
| Основной уход | Качественные сведения о свете, подсушивании субстрата, дренаже, влажности, подкормке, опоре и удалении пыли |
| Возможные проблемы | Кандидаты root_rot, sunburn, low_humidity, scale_insects, spider_mites; mealybugs/aphids пока по одному донору. Это не готовые ConditionProfile/инструкции лечения |
| Safety | Зафиксированы сведения о возможном вреде при поедании и кристаллах оксалата кальция. Видовая animal-specific запись и severity не утверждены; release cat/dog остаётся unknown |
| Языки | По 5 коротких draft-текстов EN/PL; каждый связан с соответствующим фактом. Языковая/предметная проверка остаётся |

## Расхождения и пробелы

В рекомендациях различается степень подсушивания: NC State — верхняя четверть/треть, Wisconsin — слегка просохший субстрат, RHS-гайд рода — почти сухой. Требуется решение с учётом scope/условий, а не усреднение. О прямом солнце также различается контекст: комнатное выращивание, зима, летнее солнце и акклиматизация. Общий подтверждённый выбор для draft — яркий непрямой свет; универсальный direct-sun enum пока unknown.

Не назначены глубина в cm, дни полива summer/winter, fc-диапазоны света, множители условий, PL-сезонные месяцы, min/max повторной проверки, fallback protocol ID, точный soil preset/пропорции, NPK/частота подкормки. Месячная подкормка записана как кандидат одного RHS-источника и не превращена в фиксированные 30 дней. Human low-severity из NC State не переносилась на кошек/собак.

Открыты права/полные snapshots для production provenance, WCVP-сверка и PL-названия, два конфликта, алгоритм/fallback, animal-specific safety, проверенные ConditionProfile и EN/PL, каноническая/семантическая валидация и KB release. Профиль прямо содержит `publishable=false`, `canonical_profile_ready=false` и список release blockers.

## Проверки

На реальных локальных данных выполнены: ссылки всех 24 evidence-записей на существующие источники/разделы, 10 связей локализованных текстов с фактами, SHA256 трёх Wikidata snapshots, соответствие кандидатов проблем закрытому enum, наличие явных unknown/conflicts/release blockers; точное совпадение JSON и SQLite по payload/SHA256; SQLite integrity = ok, foreign_key_check без нарушений. В базе 1 research profile, прежние 3 catalogue drafts и 3 media сохранены.

Хеш основного `plants.json` по manifest совпадает; все три основные care-записи по-прежнему null/available=false и safety unknown. Исследовательский профиль отделён от основного экспорта. Runtime, iOS/Supabase и код pipeline не менялись; unit-тесты кода не запускались. Полная JSON Schema validation не выполнялась: исследовательский формат сознательно не объявлен canonical PlantProfile.

Начальная sandbox-загрузка упёрлась в DNS; разрешённая загрузка с сетевым доступом прошла. Никаких блокировок источника не обходили.

## Следующий шаг

Закрыть основание production-использования care-источников либо выбрать лицензированную замену; получить воспроизводимые source snapshots. Затем решить конфликты, дополнить применимые algorithm/fallback и safety/ConditionProfile, проверить профиль по канонической схеме и семантике. После этого включать Basic Care; публикация в Supabase этим этапом не выполнялась. Реализационные задачи не закрывались.
