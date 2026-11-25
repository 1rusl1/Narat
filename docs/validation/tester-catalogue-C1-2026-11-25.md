# C1 — каталог и видимость сохранения, 25 ноября 2026

Scoped local/fixture PASS: обычный Browse открывает список; продолжение сохранения выполняется явно. Новое намерение не перенимает старый flow. Публикация checkpoint проверяет captured pointer до/после await и сохраняет более новый callback pointer. Вместо технического «нового save» показано изменение данных растения.

Изменены пять файлов: GuestCatalogueView, CatalogueSaveView, CatalogueUIFixtures, CatalogueConnectionTests, CatalogueSaveUITests. Принятый media footer и старый rememberModel API сохранены. Двенадцать unit-вариантов проверяют scope/pointer replacement, checkpoint/journal и отсутствие POST.

Фактически PASS: семь проверок, 535 Swift / 532 XCTest без пропусков, 149 automation, Release; UI10 EN/PL / 22 PNG / 18 строгих proofs. High Review208.532с и QA203.760с: замечаний0, полный union5. Восемь short/long cancel/error PNG просмотрел Root, остальные14 — независимый reviewer. Полный notice и Google action видимы без прокрутки после результата. Финальные Fresh/Resume PNG сами по себе не показывают пустое поле/список — это подтверждают XCTest и ledger.

Дополнительно реально выполнены два прежних ACK restart теста: EN101.370с / PL100.639с, оба PASS, 10 PNG. Три byte-identical POST одного operation дали один новый Luna/один commit, сохранив две seed-карточки. Raw helper завершился FAIL из-за неверного ожидания одной карточки всего; отдельная исправленная офлайн-проверка PASS. UI не повторялся, raw не менялся. Root отдельно просмотрел два финальных EN/PL PNG; все10 ACK изображений человеком не заявляются.

UI10 имеет собственные test-time nine pins before/after. Последующий разрешённый full Swift build перелинковал debug dylib и обновил xctestrun; другие семь pins и пять исходников совпали. Точная причина различия байтов не установлена. ACK2 привязан к новому post-build комплекту, actual loaded runner UUID/SHA, App4 и неизменным namespace ledgers. Первая ошибочная preflight-попытка не запускала App/UI.

История сохраняется: первоначальный широкий Developer900 timeout/source0, новая unit compile ошибка и фактический XCTUnwrap repair, preflight и ACK metadata FAIL. Publish отключён намеренно; private WIP история не отправляется.

Ограничения: только plain catalogue/local fixtures. Identification/diagnosis resume требует C2; реальные фото/physical и итоговый объединённый ordinary build здесь не проверялись. T046/T096/T150/T175 остаются открытыми. Root перенёс точные пять файлов и отчёты: SHA5 совпали, ID-B1 в Model/Prelim/Wire и исходные пользовательские правки сохранены. Следующий шаг — C2 на свежем Root: Guest production отдельно, затем tests3, миниатюры/общий loader и точное taxon resume.
