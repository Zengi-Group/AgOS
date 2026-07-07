# 06 — TSP: сторона МПК (TSPM-*)

> Канон: **Microstep 4** (Pool FSM PT-01…PT-10, Offer FSM OT-01…OT-06) + **Microstep 6 §M6-B**
> (флоу МПК, контейнерная multi-category заявка D-M6-13), Dok6-Slice5b.
> Реальность: `MpkApp.tsx`, `MpkHomeScreen.tsx` (CreatePoolModal),
> `MpkIncomingOffersScreen.tsx`; `rpc_self_create_pool_request`,
> `rpc_self_activate_pool_request`, `rpc_self_accept_offer`, `rpc_self_reject_offer`,
> `rpc_self_close_due_pools`, `rpc_pool_accept_partial` (d02 + adapter-миграции).
>
> Модель заявки (D-M6-13): контейнер = общий тотал (обязателен) + строки по категориям;
> у строки MAX голов опционален, **MIN отсутствует по дизайну**; цена строки ≥ защитной
> цены категории — **hard block** (асимметрия D-TSP-4).
> Маппинг из концепта: блок I → TSPM-*.

---

## TSPM-POOL — заявка-контейнер

#### TSPM-POOL-01 · HAPPY · Создание и публикация заявки (PT-01)
`layer:ui+rpc` `canon:MS6-4d/4e;D-M6-13` `impl:CreatePoolModal+rpc_self_create_pool_request` `auto:candidate:sql` `status:active`
- **Предусловие:** МПК-организация, членство активно.
- **Шаги:** общий объём (голов), окно поставки, районы, строки по категориям (цена ₸/кг, опц. потолок голов) → «Опубликовать».
- **Ожидание:** `rpc_self_create_pool_request` + `rpc_self_activate_pool_request`; заявка активна (filling), участвует в matching; тотал обязателен; MIN по категории отсутствует (только MAX).

#### TSPM-POOL-02 · UNHAPPY · Цена строки ниже пола — hard block
`layer:ui+rpc` `canon:MS4-D-TSP-4;MS6-4e-Step1` `impl:CreatePoolModal` `auto:candidate:sql` `status:active`
- **Ожидание:** поле подсвечено ошибкой, «Минимум X ₸/кг»; публикация заблокирована. В отличие от фермера (soft-warn) для МПК подтверждение НЕ обходит запрет; RPC также отклоняет (PRICE_BELOW_FLOOR).

#### TSPM-POOL-03 · UNHAPPY · Потолки строк превышают тотал
`layer:ui` `canon:code` `impl:CreatePoolModal` `auto:candidate:unit` `status:active`
- **Ожидание:** сумма maxHeads > общего объёма → поле подсвечено, ошибка ёмкости; публикация заблокирована.

#### TSPM-POOL-04 · UNHAPPY · Ошибка RPC при публикации
`layer:ui` `canon:code` `impl:CreatePoolModal` `auto:none` `status:active`
- **Ожидание:** «Не удалось сохранить заявку: <текст>»; данные формы сохранены.

#### TSPM-POOL-05 · HAPPY · Активация подхватывает published-партии (retry-match)
`layer:sql` `canon:MS4-BT-05;MS6-4e-Step2` `impl:rpc_self_activate_pool_request` `auto:candidate:sql` `status:active`
- **Ожидание:** при активации заявки существующие published-партии подходящей категории/района/окна матчатся автоматически. Фикс TSP-FLOW-08 — перед прогоном проверить деплой миграции 20260625*.

#### TSPM-POOL-06 · EDGE · Отмена заявки МПК (PT-05)
`layer:rpc` `canon:MS4-PT-05` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Предусловие:** заявка filling, есть matched-партии.
- **Ожидание:** matched-партии возвращаются в published (как BT-14), pending-офферы отзываются, фермеры уведомлены; заявка cancelled.

#### TSPM-POOL-07 · EDGE · Окно истекло, 0 партий (PT-04)
`layer:sql` `canon:MS4-PT-04` `impl:rpc_self_close_due_pools` `auto:candidate:sql` `status:blocked:TSP-FLOW-10`
- **Ожидание:** заявка → expired_empty (терминал), без решения МПК.

#### TSPM-POOL-08 · EDGE · Лимиты строк: max_heads/current_heads
`layer:sql` `canon:DECISIONS_LOG:BATCH-SPLIT-01` `impl:d02 SECTION 9` `auto:candidate:sql` `status:active`
- **Ожидание:** кусок, переполняющий MAX строки, НЕ матчится (overshoot категорийного MAX запрещён). Уточнение по живому прогону (Слайс 8): жёсткий потолок подтверждён и на общем тотале — overshoot тотала на последнем куске (D-TSP-9) на практике НЕ допускается; формулировка "overshoot тотала допустим" устарела.

---

## TSPM-OFF — входящие предложения (Offer)

#### TSPM-OFF-01 · HAPPY · Входящие предложения (broadcast)
`layer:ui` `canon:MS6-4e-Step4;D-M6-12` `impl:MpkIncomingOffersScreen` `auto:none` `status:active`
- **Ожидание:** карточки: категория, район, головы, ~вес, тоннаж, окно готовности, цена поставщика, таймер до истечения (24 ч); кнопки «Принять»/«Отклонить»; личность фермера НЕ раскрыта — только анонимная репутация (★) до confirmed.

#### TSPM-OFF-02 · HAPPY · Принятие оффера (OT-01/BT-08, FCFS)
`layer:ui+rpc` `canon:MS4-§2.3;D-TSP-6` `impl:rpc_self_accept_offer` `auto:tests/tsp_happy_path` `status:active`
- **Предусловие:** оффер pending, окно не истекло.
- **Ожидание:** партия → matched в мою заявку; deal = бид МПК (≥ ask фермера); filled увеличен; сиблинг-офферы той же партии → withdrawn; FCFS — первый принявший забирает.

#### TSPM-OFF-03 · EDGE · Отклонение оффера (OT-02)
`layer:ui+rpc` `canon:MS4-OT-02` `impl:rpc_self_reject_offer` `auto:candidate:sql` `status:active`
- **Ожидание:** оффер закрыт для этого МПК; партия остаётся доступной другим.

#### TSPM-OFF-04 · UNHAPPY · Принятие истёкшего/чужого оффера
`layer:rpc` `canon:MS4-OT-03` `impl:rpc_self_accept_offer` `auto:candidate:sql` `status:active`
- **Ожидание:** оффер старше 24 ч или уже resolved → ошибка (OFFER_EXPIRED / INVALID_STATUS); партия не матчится.

#### TSPM-OFF-05 · EDGE · Гонка двух МПК за одну партию (FCFS-конкуренция)
`layer:sql` `canon:MS4-§2.3` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Шаги:** два МПК одновременно принимают офферы одной партии.
- **Ожидание:** атомарность: побеждает первый; второй получает ошибку («Коллега быстрее — оффер снят»); двойного матча/двойного инкремента filled нет.

---

## TSPM-CLOSE — закрытие, underfill, приёмка, отзыв

#### TSPM-CLOSE-01 · HAPPY · Пул набран — закрытие (PT-02)
`layer:sql+ui` `canon:MS4-§2.4;D-TSP-9;D-TSP-11` `impl:d02 auto-close` `auto:tests/tsp_happy_path` `status:active`
- **Условие:** total_filled ≥ total_target. (Overshoot тотала на последнем куске — см. уточнение в TSPM-POOL-08: на практике не допускается, формулировка D-TSP-9 в этой части устарела.)
- **Ожидание:** пул закрывается (overshoot тотала допустим на последнем батче; overshoot категорийного MAX — нет); все matched-партии → confirmed; DealClosedModal с итогами; контакты сторон раскрываются симметрично (D-M6-5/12).

#### TSPM-CLOSE-02 · UNHAPPY→EDGE · Underfill: решение МПК (PT-03/06/07)
`layer:ui+rpc` `canon:MS4-§2.5;D-TSP-10;D-M6-14` `impl:rpc_pool_accept_partial/rpc_pool_return_batches` `auto:candidate:sql` `status:blocked:TSP-FLOW-10`
- **Предусловие:** окно поставки вышло, 0 < filled < target.
- **Ожидание:** окно решения 24 ч: «принять частично» → matched-партии confirmed на набранный объём (target=filled); «вернуть партии» → партии published (TSPF-LIFE-11); решение — на весь заказ, не по строкам (D-M6-14).

#### TSPM-CLOSE-03 · EDGE · Молчание 24 ч → дефолт «вернуть»
`layer:sql` `canon:MS4-D-TSP-10` `impl:rpc_self_close_due_pools` `auto:candidate:sql` `status:blocked:TSP-FLOW-10`
- **Ожидание:** нет решения МПК за mpk_decision_window → система применяет «вернуть партии» (farmer-friendly дефолт); повторный вызов решения после дефолта → «решение принято».

#### TSPM-CLOSE-04 · HAPPY · Приёмка поставок (BT-18, per-batch)
`layer:ui+rpc` `canon:MS4-BT-18;D-M6-10` `impl:MpkApp` `auto:candidate:sql` `status:active`
- **Предусловие:** партии dispatched.
- **Ожидание:** приёмка подтверждается по каждому батчу независимо → delivered; после приёмки всех батчей пул → completed; открывается окно отзыва МПК о фермере.

#### TSPM-CLOSE-05 · HAPPY · Отзыв МПК о фермере (D-M6-11)
`layer:ui+rpc` `canon:MS6-§4c` `impl:rpc_self_submit_mpk_review` `auto:candidate:sql` `status:active`
- **Ожидание (упрощено против канона — задеплоенная реализация):** одна звёздная оценка (1–5), отправляется как overall и как ключевая размерность одновременно (раздельного ввода второй размерности/комментария в UI нет); хранится в `batches.notes.mpk_review`, персистится в `rpc_get_pool_matches.myRating`. **НЕ реализовано:** double-blind reveal (visible_at) и неизменяемость после подачи canon-модели (`deal_reviews`) — та система существует в схеме, но orphan (0 вызовов из фронта). Деплой 2026-07-07, миграция `20260706120000_tsp_batch_reviews.sql`.

#### TSPM-CLOSE-06 · EDGE · Фермер отозвал партию после матча — уведомление МПК
`layer:ui` `canon:MS6-§4f` `impl:MpkApp` `auto:none` `status:active`
- **Ожидание:** «Поставщик отозвал партию»; filled уменьшен; пул остаётся filling.
