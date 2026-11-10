# Пилот нового engine — 10 ноября 2026

По команде владельца в Plants A и Plants B перенесён `25a5830`, выполнено ровно
по одному новому продуктовому пакету. Оба COMPLETED/exit0, очереди снова остановлены.
CI/workflow/helpers/manifests и main не менялись. Полные числа, вызовы, состояния,
baseline и источники — [JSON](throughput-pilot-2026-11-10.json).

## Результат и время

| Метрика | Plants A — T036 DTO/transport | Plants B — GET access acceptance |
| --- | ---: | ---: |
| Подготовка по журналу controller, секунд | 441,566 | 322,843 |
| Runtime до принятия и push, секунд | **935,649** | **249,722** |
| Runtime, мин:сек округлённо | **15:36** | **4:10** |
| Developer | 1 × Sol medium, 630,584 с | **0 вызовов** |
| Reviewer | 1 × Astra high, 81,336 с | 1 × Astra high, 93,515 с |
| QA | 1 × Astra high, 101,714 с | 1 × Astra high, 74,125 с |
| Все модели, секунд | 813,634 | 167,640 |
| Все проверки, секунд | 114,201 | 74,120 |
| Остальной runtime overhead, секунд | 7,814 | 7,962 |
| Повторные модельные вызовы / repairs / re-review | **0 / 0 / 0** | **0 / 0 / 0** |
| Тайм-ауты моделей / checks | **0 / 0** | **0 / 0** |
| Принятый commit | `e04103f` | `88a8ea8` |

Подготовка включает merge/config/manifest/preflight и сохранение перед run;
это не время Developer. A потребовались два merge: engine `20f49b6` и точный
принятый B SQL/wire prerequisite `4ab2b60` ← `6d689b7`; B — engine `2d1b374`.
Конфликты были в handoff/T006. До принятия пакета от первой измеренной отметки
controller прошло A **1377,158 с (22:57)**, B **572,582 с (9:33)**.

Эти цифры не включают последующее оформление отчёта и итогового handoff. У B
публикация итоговых документов заняла ещё **350,923 с (5:51)** после runtime,
а полный turn чата — **1030,9 с (17:11)**. У A до первого отчёта прошло ещё
**422,257 с (7:02)**, до финальной metadata-публикации — **488,842 с (8:09)**.
Полный turn A — **1902,765 с (31:43)**. Итоговые документы опубликованы в A
`f343f83`, в B `123c123`; оба чата idle, деревья чистые.
Отметки first-observed controller и app turn start различаются: это явно
разделённые источники времени. Суммы A+B не равны общему времени ожидания:
сессии работали параллельно. Затраты родительского чата на этот сводный отчёт
не включены в runtime дочерних контроллеров.

## Что принято

**A:** один `parallel-ios-t036-access-wire-pilot-20261110-01`, task
`parallel-ios-t036-access-wire-pilot`, risk high/complexity medium. Реализован
canonical monthly-access DTO и transport настоящего PlantsAPIClient: owner,
shared monthly, nullable unknown, camelCase mode keys и точные timestamp strings.
Изменены три существующих Swift-файла; Developer вернул patch с 687 добавленными
строками реализации/тестов. Diff, build/welcome/все **191 тест (184 прежних + 7 новых)**,
Simulator smoke и отдельные Review/QA PASS, без skips/expected failures.
Repository/UI/billing/live и полный T036 не приняты.

**B:** один `parallel-backend-access-http-pilot-20261110-01`, task
`parallel-backend-t163-access-http-pilot`, risk high/complexity medium. Явный read-only
full snapshot audit существующего GET: Developer не вызывался, минимальность
сравнительного diff не заявлялась. Исходный GET от `a151427` не переписывался.
Все 7 gates PASS: **39 HTTP**, **336 Deno**, **147 automation**, typecheck/diff,
PostgreSQL clean/upgrade по **511 pgTAP**, 12 UTC cases/99 actual admit+finalize
перед каждым из 6 раундов по 20 real connections; cap 55+131 pgTAP/4 races.
Это synthetic/private PG и mock transport; installation/bind HTTP, worker,
deploy/live и полный T163 остаются открытыми.

У обеих сессий сравнение файлов engine/default config с `25a5830` — точное.
Собственные configs сохранили providers/checks/budgets/publish branch, заменены
только context/preflight. SHA A `6bd5008b1fa38b96938a9f82a6eb14d92e309006743fe2db7d27b1bcee88a523`,
B `0a7d0752cfa4a36d65c8cf0c7df630cb641adfdeabfb272bdf33e1bde608d632`.
В каждой сессии появился ровно один новый runtime directory относительно снимка
предыдущего аудита; [X] всех 151 задач совпадают с исходными (15/136).

## Сравнение с прежними пакетами

**A:** прежний canonical sync transport прошёл через три runs. Первый потратил
503,746 + 475,298 с Developer на невалидные patches и ещё 95,448 с на прерванный
вызов (по process.json; исходный state сохраняет elapsed=null). Второй остановился
на compile check. Третий — принятие compile-repair на уже готовом кандидате:
Developer 48,141 с / Review 62,761 с / QA 66,201 с. Сумма наблюдаемого времени
моделей всей цепочки 1251,595 с; это не wall time и не идентичная задача нынешнему
DTO. Сравнение нового Developer только с 48-секундным repair было бы неверным.

**B:** old08 проверял тот же GET, но был прерван владельцем во время QA:
Developer 68,111 с (patch пуст), Reviewer 77,672 с, partial QA 28,559 с по process.json.
Первый вызов теперь исключён; новый Reviewer стал **медленнее** (93,515 против
77,672 с). Новый QA закончился за 74,125 с, но старый не закончен. Automation
расширилась 123→147; quality_contract и scope acceptance различаются. Полный
старый runtime/принятая QA отсутствуют, поэтому процент ускорения не вычисляется.

## Вывод

Оба новых пакета приняты с первой попытки, без повторов и тайм-аутов; у B убран
лишний Developer. A успешно использовала medium effort при high risk, сохранив
независимую строгую приёмку. Но реализация A всё ещё заняла 10:31, а подготовка
и отчётность стоят заметного времени. **Ускорение всего процесса и снижение
частоты тайм-аутов этим малым пилотом не доказаны.** Изменённый timeout guard,
delta resume и context rotation не задействованы в пилоте: повторов/тайм-аутов в пилоте не было.
CLI tokens не суммировались и не переводились в процент подписочного лимита.

Следующий шаг — оценить эти результаты с владельцем. Очереди не продолжаются
автоматически, main promotion и новый пакет требуют новой команды. Полная
интеграция двух принятых веток и live evidence в этот пилот не входили.
