# Каталог: точка остановки ordinary live — 20 ноября 2026

**B01 не принят.** Обычная EN Release source56d7455, binary SHA-256
`f3b2184acd5b58575c3c60ae60886f57d9c8741d9e5a4cc1f6c0201d2490a271`,
реальный SDK/Supabase, собственный Simulator. Public search/detail/search подтвердили
текущую Ficus elastica и стабильные identity/release; это только preflight.

Первый запуск FAIL до fill/Save: скрипт требовал viewport y>90 для поля поиска,
реальный центр поля y79. Новых намерений0, canonical digest неизменен. Порог исправлен
только в private helper. Исходные FAIL/checkpoint/AX/PNG сохранены.

Вторая отдельная попытка FAIL: один Save tap, typed Plant saved не появился.
На фактическом снимке клавиатура всё ещё открыта, хотя проверка AX type Keyboard
её не обнаружила. Фактическое выполнение Save callback не доказано; продуктовый
дефект сохранения этим не установлен. Повторный create автоматически не выполнялся.

До и после остановки только тестового процесса read-only серверный readback подтвердил
полный исходный canonical digest и0новых активных растений. Read-only SQLite после
остановки app: create confirmations0, input checkpoints0, outbox0. Pending/inflight
этой попытки разрешён этими свидетельствами; статус остаётся FAIL. Старые история,
условия, memberships и коллекция сохранены; delete/care/AI/покупки не выполнялись.
Исходный failed checkpoint до разрешения также сохранён отдельно.

Следующий шаг: explicit supported keyboard Enter (source onSubmit только снимает
focus), проверка видимой формы и стабильной кнопки, затем новая отдельная guarded
attempt с одним Save. Нельзя менять эти два FAIL в PASS или повторять неизвестную
созданную операцию. UI delete разрешён только после точного подтверждения новой UUID.
Wire guard private photos исправить с plant_photos на фактический photo_assets.

[Машинный отчёт](tester-catalogue-live-stop-2026-11-20.json). Raw API/SQLite/AX,
снимки и имена тестовых записей остаются private в указанных там каталогах.
Это не physical UI proof и не полный B01 care chain.
