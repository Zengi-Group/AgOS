# 07 — Безопасность, изоляция, антитраст (SEC-*)

> Кросс-срезы поверх всех флоу: RLS-изоляция, гейты на RPC-уровне, раскрытие контактов,
> ст.171, словарь фермера, deep-link. Канон: P-AI-2/RLS (CLAUDE.md), D-M6-5/12,
> MS4 §8 (антитраст), D-TSP-16.
> Маппинг из концепта: блок K → SEC-*.

---

## SEC-GATE — гейты на бэкенде, не только в UI

#### SEC-GATE-01 · UNHAPPY · Не-член вызывает RPC продажи напрямую
`layer:rpc` `canon:MS6-Step0;K-01` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Шаги:** deep-link/прямой вызов `rpc_create_batch`/publish от организации без активного членства.
- **Ожидание:** RPC отклоняет (membership-гейт на бэкенде); обход UI невозможен.
- **Деплой 2026-07-07:** SEC-GATE-MEMBERSHIP-01 задеплоен и верифицирован прямым запросом к БД (гейт `MEMBERSHIP_REQUIRED` подтверждён в теле self-serve `rpc_create_batch` и d07 AI-gateway пути).

#### SEC-GATE-02 · UNHAPPY · Лимит партий на RPC-уровне
`layer:rpc` `canon:MS6-4a-Step1` `impl:d02_tsp.sql` `auto:candidate:sql` `status:blocked:SEC-GATE-LIMIT-01`
- **Ожидание:** 6-я активная партия через прямой RPC-вызов отклоняется (FEATURE_LIMIT), не только в UI.

#### SEC-GATE-03 · UNHAPPY · Не-админ вызывает админские RPC
`layer:rpc` `canon:Dok6S2` `impl:fn_is_admin+d01` `auto:candidate:sql` `status:active`
- **Ожидание:** `rpc_process_membership_application`, `rpc_get_membership_queue` и админ-обзор маркетплейса отклоняют вызов не-админа с ошибкой **`FORBIDDEN: admin access required`** (код и канон Dok6-Slice2 — FORBIDDEN, не UNAUTHORIZED); EXECUTE отозван у public/anon (коммит 0229c00; на staging revoke отстаёт — NOTE-ANON-EXEC-01).

#### SEC-GATE-04 · UNHAPPY · Неавторизованный на /cabinet, /mpk, /admin
`layer:ui` `canon:code;K-05` `impl:RequireAuth/RequireAdmin` `auto:tests/router-smoke` `status:active`
- **Ожидание:** редирект на логин с сохранением from-пути; после входа — возврат по deep-link.

---

## SEC-RLS — изоляция данных ферм

#### SEC-RLS-01 · UNHAPPY · Фермер A читает/меняет партию фермера B
`layer:rpc` `canon:CLAUDE.md-RLS;K-02` `impl:d02_tsp.sql RLS` `auto:candidate:sql` `status:active`
- **Ожидание:** запрещено RLS (organization_id в каждом вызове); данные не возвращаются; мутации отклоняются. Прогонять на всех self-RPC: get_org_batches, withdraw, dispatch, price.
- **Деплой 2026-07-07:** SEC-RPC-ORGTRUST-01 задеплоен — guard в теле подтверждён прямым запросом к БД (`pg_proc.prosrc` содержит `OWNERSHIP GUARD` во всех 5 функциях). Второй слой (`revoke ... from authenticated` на 3 d07-сигнатурах) оказался no-op — PUBLIC всё еще даёт execute (revoke от authenticated не перекрывает PUBLIC-грант); реальная защита — только guard в теле, он подтверждён рабочим.

#### SEC-RLS-02 · UNHAPPY · МПК A видит заявки/офферы МПК B
`layer:rpc` `canon:CLAUDE.md-RLS` `impl:d02_tsp.sql RLS` `auto:candidate:sql` `status:active`
- **Ожидание:** заявки-пулы, офферы и filled-прогресс чужого МПК недоступны.

#### SEC-RLS-03 · UNHAPPY · Фермер видит документы членства чужой организации
`layer:rpc` `canon:CLAUDE.md-RLS` `impl:storage bucket membership-documents` `auto:candidate:sql` `status:active`
- **Ожидание:** bucket `membership-documents/{orgId}/…` защищён политикой: чтение чужого orgId запрещено.
- **Ре-верификация 2026-07-06 (SEC-STORAGE-01 закрыт, PASS):** прямое psycopg2-подключение к `mwtbozflyldcadypherr` (без anon/service-role ключей, без throwaway auth-юзера) — `SET LOCAL ROLE authenticated` + синтетический `request.jwt.claims` вместо реального JWT. До фикса: атакующий без членства видел 31/31 объектов бакета (воспроизводит FAIL этого прогона). После фикса (`fn_storage_org_id()` + `membership_documents_select_org`/`_insert_org`/`_update_org` в `d10_public_site.sql`, применено напрямую к БД): тот же атакующий — 0/31; `fn_is_admin()` — 31/31 (не задет); реальный член org `15e72599-…` — ровно свои 3 файла (регрессии нет). Подробности: `IMPL_DEBT.md` SEC-STORAGE-01, `DECISIONS_LOG.md` 2026-07-06.

---

## SEC-RVL — раскрытие контактов (D-M6-5/12)

#### SEC-RVL-01 · UNHAPPY · Фермер не видит покупателя до confirmed
`layer:rpc+ui` `canon:D-M6-5;K-03` `impl:fn_tsp_batch_json` `auto:candidate:sql(E2E-TSP-02)` `status:active`
- **Ожидание:** ни в одном состоянии до confirmed UI/RPC не отдают идентичность МПК (`fn_tsp_batch_json` отдаёт buyer только при `mpk_contact_revealed_at != null`); после confirmed — раскрытие; для дроблёной партии — per-кусок.

#### SEC-RVL-02 · UNHAPPY · МПК не видит фермера до confirmed
`layer:rpc+ui` `canon:D-M6-12` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Ожидание:** до confirmed МПК видит характеристики партии + анонимную репутацию (★), но не название/контакты хозяйства; раскрытие симметрично при confirmed.

#### SEC-RVL-03 · EDGE · Оба пути раскрытия ставят reveal
`layer:sql` `canon:TSP-FLOW-07(IMPL_DEBT)` `impl:d02_tsp.sql:2849` `auto:candidate:sql` `status:active`
- **Ожидание:** и adapter-путь (rpc_self_accept/auto-match), и canon-путь (rpc_accept_offer auto-close) ставят `mpk_contact_revealed_at` (регресс-защита фикса TSP-FLOW-07 от 2026-06-24).

#### SEC-RVL-04 · EDGE · Админ видит контакты сторон (оператор)
`layer:ui` `canon:DECISIONS_LOG:ADMIN-MGMT-01` `impl:admin marketplace overview` `auto:none` `status:active`
- **Ожидание:** админ-обзор маркетплейса read-only показывает контакты обеих сторон оператору (это не утечка — роль оператора).

---

## SEC-ART — антитраст (ст.171 ПК РК)

#### SEC-ART-01 · EDGE · Дисклеймер везде, где есть справочная цена
`layer:ui` `canon:MS4-§8;K-04` `impl:WizStep4Price+PriceSheet+CreatePoolModal` `auto:none` `status:active`
- **Ожидание:** каждый экран со справочной ценой содержит дисклеймер («не является обязательной — цену вы назначаете сами»); формулировка со ссылкой на ст.171 — за легал-гейтом ARS-10 (пока суть без ссылки — известный хвост).

#### SEC-ART-02 · EDGE · Справочная цена не участвует в матчинге
`layer:sql` `canon:MS4-§8.1` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Ожидание:** deal_price всегда из farmer_price/mpk_price, никогда из reference_price.

#### SEC-ART-03 · EDGE · Словарь фермера (D-TSP-16)
`layer:ui` `canon:MS4-§7;D-TSP-16` `impl:фермерские экраны TSP` `auto:candidate:unit` `status:active`
- **Ожидание:** слова Pool/Offer/match/target/filled в фермерском UI не появляются; фермер не видит число адресатов broadcast и прогресс заполнения пула.

#### SEC-ART-04 · EDGE · МПК не видит цены других МПК
`layer:ui+rpc` `canon:MS4-§8.4-8.6` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Ожидание:** офферы независимы; горизонтальная ценовая информация конкурентов не доступна ни в UI, ни через RPC.

---

## SEC-MISC

#### SEC-MISC-01 · EDGE · Пользователь с двумя типами организаций
`layer:ui` `canon:MS1-D-IDM-2;K-06` `impl:pickShellPath` `auto:candidate:unit` `status:active`
- **Ожидание:** приоритет farmer → /cabinet; профиль по preferType без падений (= ONB-ROUTE-03, здесь — сквозная проверка обоих кабинетов одного пользователя).

#### SEC-MISC-02 · UNHAPPY · Организация не может быть продавцом и покупателем в одном пуле
`layer:sql` `canon:MS4-§7-антигейт` `impl:d02_tsp.sql` `auto:candidate:sql` `status:blocked:SEC-SELFDEAL-01`
- **Ожидание:** партия организации не матчится в пул той же организации (farmer+mpk мульти-тип); RPC/матчинг отклоняют самосделку.
