# Удаление комнат из активного контракта

Узкий срез T158 от 9 ноября: без комнат в новых записях и sync; исторические данные не удаляются. Free-места, count<3, месячные квоты и expiry меняются отдельно.

| Путь | Изменение |
|---|---|
| execute_room_command | Новые create/rename/delete отвергаются ROOM_COMMAND_RETIRED (22023). Точный повтор ранее завершённой операции возвращает исходный receipt без новой записи/изменения watermark; payload mismatch остаётся конфликтом. |
| execute_plant_create_command | Нет room insert/link/ответа. Новые top-level/overrides room_id, new_room_name, create_room_name отвергаются ROOM_FIELDS_RETIRED (22023), включая null. Ранее завершённый точный повтор возвращает прежний receipt. |
| prepare_guest_claim / commit_guest_claim | Нет создания/назначения комнаты. Room-поля отвергаются; commit сохраняет прежний точный receipt. Сохранённые overrides также проверяются, без преобразования исторических строк. |
| owner_sync_entries | Удалены rooms и plant.data.room_id. Остальные проекции, pagination/cursor/watermark, фото/история не меняются. Старый generic cache может хранить room data; активный интерфейс его не использует. |
| TypeScript/Swift claim overrides | Новые writers не содержат room fields; HTTP prepare явно отклоняет их до RPC. Swift читает старые unknown room fields, сохраняя остальные условия, но не пишет их снова. |

Применённые SQL и таблицы/столбцы rooms/plants.room_id/receipts не удалять. Owner-only чтение исторических данных сохраняется. Сигнатуры/SECURITY DEFINER/search_path/service-only grants не расширяются. Нет нового wrapper API или универсального migration engine.

Найденное ограничение baseline: старые prepare/commit_guest_claim ссылаются на отсутствующие guest_drafts.state/claim_secret_hash и draft_claims.owner_id/proof_expires_at; API helper также использует другую RPC сигнатуру. Это T159/T042/T019. В этом срезе исправляются только room guards/ветви; положительный claim не объявляется рабочим. Отрицательные room guards проверяются до несовместимой части; полный перенос требует отдельного исправления и тестов proof/TTL/cleanup/media.

Приёмка SQL: реальный PostgreSQL17/pgTAP на clean и seeded upgrade, неизменность всех public rows, legacy rooms/plant links/photos/receipts/расход, owner A/B и grants, no-room create/retry, actual concurrent owner-lock wait и pagination. TS/Swift отдельно: Deno, существующие PlantsTests/build/welcome/Simulator и regression старого overrides JSON. Это локальные fixtures, не live deployment и не закрытие T158/T155.
