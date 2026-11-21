# M2c — unaccepted checkpoint

## M2c не принят: отсутствуют UI-вложения; сохранён checkpoint — 21 ноября 2026

Run tester-care-reminder-saved-card-bridge-20261121-01 BLOCKED, исходная база c59091e.
Шесть app/test файлов содержат непринятый candidate: PreliminaryResultView.swift,
CatalogueSaveModel.swift, CatalogueSaveView.swift, GuestCatalogueView.swift,
CatalogueConnectionTests.swift, CollectionWireTests.swift. Код не интегрирован в Root.

465 Swift/build/welcome PASS106.533с,149 PASS46.104с,diff PASS0.049с,
8consentUI+strict fakeledgers PASS598.447с,4presentation assertions PASS63.448с.
Review140.200с semanticFAIL: BR3 не выполнен — q-a147afa31080b0cd0c659e7c/attachments/
manifest.json пуст. Новый controller gate ошибочно принял успешный export без изображений;
четыре старых presentation tests на PASS не прикладывают screenshots. QA ещё не запускался.
Source-дефектов reviewer не нашёл, но это не приёмка этапа.

Dev1 465.925с, Dev2 102.173с (только новые fixture watermarks/усиление early assertions),
Dev3 116.934с с EMPTYpatch; budget3 исчерпан. Два SwiftFAIL176.296/146.869с сохранены,
по88assertions одного НОВОГО tabletest. Direct stdout mapping: first→q-f1a49e191b4dcb7f85fe3c35,
second→q-412a9ac61eb5552e10343db9, pass→q-0355a18d121c18b231611c70.
Secondlog oldline14759 vs current14767 — indicator, точная infra-причина не установлена;
controller не создавал новый DD и не делал reinstall/globalreset. Последний PASS на том же corrected source.

Следующий шаг: только evidence repair — keepAlways screenshots в общем helper четырёх
existing EN/PL tests (без изменения assertions), усилить ONLY новый4gate: exact per-test mapping,
непустые настоящие PNG, уникальные paths/hash, запрет missing/other-case substitution.
Затем fresh read-only full UNION candidate_basec590 со всеми6 app/test изменениями + UIhelper,
полные465/149/8+4/MCP/diff/highReviewQA. Старый BLOCKED/FAIL не переписывать.
WholeB/старые care/Today/PL/metadata→routing→ordinary unmasked System delivery/tap→finalsigning
ещё открыты, родители T075/T077/T080/T098 не закрывались. PBX0/root user3 не тронуты;
technical only, hard50/soft48/reset запрещён. Последний actual usage17/83.

