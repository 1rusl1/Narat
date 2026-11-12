# V19 — запись первой помощи без подтверждённого срока

12 ноября 2026, `narat-staging`, миграция 028, `plants-api` v18, `analysis-worker` v8. Выделенный постоянный владелец `97244b1a-fa55-4db5-8f35-a47ce149b680` и карточка Monstera `e1cd2ad6-fbd1-43ce-8c00-f997f2cc2421` созданы для этого прогона. Действующий KB `staging-monstera-care-v2` публикует `overwatering / check_soil` с null интервалом.

## Реальный провайдер

Через обычный приватный upload и `POST /analysis/jobs` с `target_plant_id` отправлен JPEG с пожелтевшим листом Monstera. Исходник Phil Hearing, нормализовано до 960×1440 без EXIF, 366 527 байт, SHA-256 `b3b84ff8dd3e927ffe86916e079fef35073eb765669c1a4f84504435ae9d0824`. Фото показывает внешний признак, причина пожелтения неизвестна. [Фото](https://unsplash.com/photos/yellowing-monstera-deliciosa-leaf-on-a-table-6yqLhMtQinA) · [Лицензия](https://unsplash.com/license).

Job `639b0ee7-2f27-4ff9-9279-4a2cfe782caf`, фото `3aa25847-c2d9-4fa4-a680-4dcff45e0e44`. Провайдер завершил его за 5,41 с с `genus_only / insufficient_data` и null condition. Штатная диагностика списала один starter нового владельца, месячный остаток остался 3. `care.first_aid.record` для этого job вернул 404, `/sync` и доступ не изменились. Живого положительного `overwatering` от провайдера в этом прогоне нет.

## Живой API с маркированным входом

В том же изолированном владельце создан отдельный SQL fixture-job `dd282796-178e-5b3b-a26f-1f580cb0c495` с `prompt_version=staging-v19-first-aid-fixture`, `limitations=["staging_fixture"]` и без подписанной квитанции анализа. Fixture связан с той же карточкой, текущим snapshot и активным опубликованным действием `overwatering/check_soil`. В первом GET отсутствовали поля привязки. Для fixture скопирован `repeat_context` штатного job того же владельца и карточки. Следующий GET подтвердил UUID карточки и фото. Живой job, KB и квотный учёт сохранились. SQL подтвердил отсутствие запуска провайдера и monthly ledger у fixture.

Первый `care.first_aid.record` вернул 200, `control_id: null` и одну активную запись `check_soil`. Точный повтор из новой Auth-сессии вернул тот же receipt, новый operation ID для того же job получил 409. `care.undo` и его точный повтор дали одну отмену. Повтор исходной команды после undo сохранил исходную квитанцию, а канонический `/sync` сохранил состояние `voided`. SQL подтвердил один факт, одну отмену, два receipts, ноль controls и ноль care tasks. Аналитический доступ до и после fixture и журнала совпал.

| Объект | UUID |
| --- | --- |
| Record operation | `8759e095-b9f6-5c02-a049-fbcb5ae21a68` |
| Entry | `a237bcb6-e3df-43dc-b5aa-8528b85caa51` |
| Undo operation | `7b7c0262-293c-5f34-a9ec-318239b10636` |
| Reversal | `feeba288-b9f1-4c76-b049-c1dc8df6459c` |

## Повторение для A

1. В новой постоянной тестовой сессии на `narat-staging` сохраните Monstera из каталога. Загрузите новое фото обычным upload и запустите `diagnosis` с `target_plant_id`. Подходит завершённый `problem_detected` с `identified / monstera_deliciosa`, `selected_condition_id=overwatering` и `plan_availability=available`. При недостаточном результате используйте отдельный SQL fixture только у этого нового владельца. Шаблон записи job и runtime есть в [SQL-тесте](../../supabase/tests/first_aid_control.test.sql). На стенде используйте текущие KB и каталог, опубликованный `action_en` и null интервал. Привяжите job к карточке и её snapshot и скопируйте `repeat_context` из штатного job этой же карточки. Отметьте `prompt_version=staging-v19-first-aid-fixture` и `limitations=["staging_fixture"]`. Сохраните `provider_started_at` пустым и проверьте одинаковый `GET /analysis/access` до и после. Существующие jobs и KB не редактируются.
2. Проверьте owner `GET /analysis/jobs/{job_id}`. Отправьте `POST /commands` с `command_name=care.first_aid.record`, UUID карточки в `plant_id` и JSON-строкой `payload_json` с `job_id`, `occurred_at` и `timezone`. В этом прогоне `occurred_at` был `2026-11-12T13:51:01+00:00`, зона `UTC`. Сохраните весь envelope для retry. Ожидается `active`, `control_id: null`.
3. После новой сессии повторите тот же envelope и проверьте ту же квитанцию. Для отмены отправьте `care.undo` с отдельным operation UUID и полученным `entry_id`. В `/sync` ожидаются одна отменённая запись, одна отмена и отсутствие pending control. Перечисленные UUID относятся к завершённому прогону, поэтому для проверки первого сохранения нужен свежий job. [HTTP-контракт](../../specs/001-plants-ios-mvp/contracts/manual-care-journal-http.md).

Следующий отдельный срез — подтверждённое наблюдение для активного контроля. Для optional фото можно переиспользовать private upload с owner/ready проверкой и сохранить ссылку в `care_observations`. Маршрут не требует запроса к провайдеру. Датированный живой контроль остаётся открыт до опубликованного срока с источником.
