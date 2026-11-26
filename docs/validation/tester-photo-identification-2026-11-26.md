# Photo identification: техническая приёмка 26.11.2026

Принят ограниченный пакет семи iOS-файлов на тестовых данных: предложение опубликованного вида с фото/атрибуцией и явным Confirm; Choose another species; ручной выбор при unknown; сохранение исходных job/photo/owner и нормализованного JPEG через существующий guest draft/claim, отмену/ошибку/повтор входа и холодный запуск. Прямой результат использует верхний iOS Back; старые/return-to-plant пути сохранены. EN/PL текст photo journey и prompts каталога уточнены, Home не перестроен.

Проверки: **546 Swift / 543 XCTest-метода, 149 automation, 4 новых UI, old4 + Account EN/PL, C2 light5/dark2, локальный Release** — PASS. В Release отсутствуют 7 новых DEBUG-маркеров, compiled Name/DisplayName — Narat. Независимые high Review **170.524 с**, QA **207.901 с**, замечаний нет.

Исходные восемь проверок реально выполнены на неизменном e978/FP65b. Продолжение после отсутствовавшего human receipt валидировало сохранённые исходники/артефакты/загрузку текущего runner и SHA; это **не повторный native-прогон**. Первый BLOCKED и предыдущие raw failures сохранены.

Матрица: выбор wrong/unknown в EN и PL; полный claim/cold — wrong EN и unknown PL; UIKit host-removal held-GET — та же пара. Удаление экрана подтверждает отмену GET и живой Model/SDK без нового B/draft, а не доставленный поздний HTTP success. Picker preview GET и один свежий Model validation GET — отдельные законные фазы. Confirm сам draft не создаёт.

Визуально: 124 app-owned записи (84 новых + 40 C2), 98 прямых просмотров и 26 точных SHA-дубликатов; 34 DEBUG-кадра исключены. P0 search/name prompts читаемы EN/PL в обеих темах. Известный P3: прежние пустые Account placeholders бледные на белом. Это не WCAG/полная визуальная приёмка приложения.

Ограничения: синтетические фото/изолированный HTTP; нет проверки качества распознавания исходного фото владельца, реального Storage, новой живой Google-интеграции или физического iPhone/VoiceOver/XXXL. Новые photo UI сняты в light; C2 — light/dark. Profile fixture en: canonical name/care text могут оставаться EN; это не полная локализация PL care. Loading и содержимое за пределами снимков не сертифицированы визуально.

Точная база: `8744d096466b1399c62c210b8695624b34880f87`, проверенный source commit `e978bc8a281b8633a2f1b688e582dfcb31b13c94`, fingerprint `65b22702ad1d330c9ab5c091c8590333a61267f7e94b2f99e26086fcb9678386`. Следующий шаг — точный перенос source7/curated docs в Root с сохранением пользовательских изменений, commit/push, затем новая обычная подписанная сборка7 и отдельная live-проверка. Private WIP ancestry/автоматический private handoff не переносить целиком.
