<!--
AgOS · надстройка к контракт-эталону слайс-спека. НЕ копия контракта.
Канонический ФОРМА-эталон (frozen-блок · FR-/M- · frontmatter · Open Questions · append-only хвосты):
скилл /feature → references/eng-spec-slice.md (доставляется со скиллом; в сессии /feature читается оттуда).
Контракт-ЗАКОН: тот же скилл, SKILL.md §«Slice-spec contract». Здесь — ТОЛЬКО AgOS-дельты.
-->

# AgOS — надстройка слайс-спека (product deltas)

**База:** контракт-эталон `/feature → references/eng-spec-slice.md` (frozen-блок, `FR-`/`M-`,
frontmatter `status`/`g2_approved`/`baseline_commit`, Open Questions, append-only хвосты). Заполняй
эталон, а сюда смотри за AgOS-специфику. Заполненный инстанс обязан проходить `preflight --anchor 6`.

- **Дом.** Слайс-спек — `Docs/...` этого репо (детальная высота, graphify-индексируемый; держи
  имена сущностей/RPC/таблиц в тон SQL-токенам); тонкий синтез — мозг
  `[[projects/agos/specs/<feature>]]` (ссылка через `brain_spec:`). Дом задач — Linear team `ARS`.
- **Порядок применения (Design contract → `/build`):** d01 → d02 → d03 → d04 → d05 → d07 → d08.
- **Маппинг секций на Doks.** Data model = P1 (Dok 1): additive-only, FSM (text+CHECK), кто пишет /
  авторитет при конфликте (P2), история vs current (P12), неполное состояние (P11). API/RPC = Dok 3:
  `rpc_`-имена (registry-canonical), сигнатуры additive (существующие не менять, P7), SECURITY DEFINER,
  `organization_id` в каждом вызове, одна fn для web+AI. Events = Dok 4 (`domain.entity.action`).
  UI contract = Dok 6: `useSetTopbar()`, состояния пусто/частично/ошибка.
- **Инварианты (Boundaries `Never`/`Always` со ссылкой).** P1–P12 · RLS/`organization_id` ·
  Art. 171 (cross-org) · HS-1…6 · additive-first (P7). Полная таблица Source-of-Truth — `CLAUDE.md`
  (auto-loads, всегда выигрывает).
- **Персона приёмки (I/O-матрица · Slices→Tasks) — её словами, не разработчика.** Фермер / эксперт
  (P9 farmer-centric). Тёплая палитра = кабинет фермера, нейтральная = экспертная консоль.
- **Verify (G3).** `cross_check.sh` (вкл. CHECK 11 контракт-снапшот RPC) + preview + reality↔intent
  reconcile (converge); набор — из биндинга `[[projects/agos/_project]]` §Биндинг.
