# Microstep 3 — Feature Governance v1.0
## AGOS Architecture Decision Record

| Field | Value |
|---|---|
| Date | 2026-05-15 |
| Status | ✅ Confirmed by CEO (Arshidin) — каркас (Модель C: framework now, content later) |
| Builds on | M1 Identity v0.2 (`PlatformSubscription`, `AssociationMembership`, `OrganizationType`) + M2 AssociationMembership FSM v1.0 (`state ∈ {active, grace_period}` = capabilities ON) |
| Scope | Архитектурный каркас контроля доступа к функциональности: схема, формула эффективного доступа, кеш-стратегия, шаблон расширения. |
| Out of scope | Конкретный feature-by-feature monetization (отложено в per-domain product mini-sessions), pricing, UI-тексты `upgrade_hint`. |
| Next | Microstep 4 — Batch lifecycle в фермерской лексике |

---

## 0. TL;DR

- Три сущности: **`FeatureGate`** (binary access) + **`FeatureLimit`** (quotas per period) + **`FeatureUsage`** (append-only log использований).
- Из трёх типов governance в MVP реализуется **2 из 3**. Quality/intensity modifiers (Тип 3) — отложены, при необходимости расщепляются на отдельные feature_codes (не вводится отдельная сущность).
- Granularity = **action-level** (один явный пользовательский акт = один feature_code; не UI-кнопка, не экран).
- Доступ оценивается через формулу `effective_access(user, feature, current_org_context)` — две оси (личная подписка ИЛИ членство в активном орг-контексте), объединение через OR, NULL означает «эта ось эту фичу не открывает».
- Кеширование: **entitlements snapshot per session** + событие инвалидации в Event Bus.
- Seed-контент **намеренно минимальный** — 6 опорных feature_codes как примеры использования схемы. Содержательное наполнение растёт домен-за-доменом по мере UI-микрошагов.

---

## 1. Принцип: framework now, content later

Текущий микрошаг закрывает **архитектурный каркас**, а не продуктовые решения. Конкретные ответы на «что в Free / что в Pro / что только член» откладываются в продуктовые мини-сессии, привязанные к соответствующим UI-микрошагам:

| Домен | Мини-сессия привязана к |
|---|---|
| TSP | M4 (Batch lifecycle) и M6 (TSP screens) |
| Зоо / Корма / Вет | UI-микрошагу домена (отдельно) |
| AI-ассистент | UI-микрошагу AI-кабинета |
| Аналитика | UI-микрошагу дашбордов |
| LMS | UI-микрошагу LMS |
| ERP | Решено: `erp_*` целиком в Pro (D-FG-7) |

Преимущество: продуктовые решения принимаются **когда видны экраны и реальные customer-flows**, а не на абстрактных таблицах. Архитектура при этом готова сразу — `FeatureGate` seed дополняется через `INSERT`-ы без code-deploy (Principle 8).

---

## 2. Три типа governance — какие в MVP, какие нет

| # | Тип | Пример | В MVP? | Сущность |
|---|---|---|---|---|
| 1 | **Binary access** — «можно/нельзя пользоваться» | TSP только для членов | ✅ | `FeatureGate` |
| 2 | **Quantitative limits** — «сколько в период» | Free: N AI-сообщений в день | ✅ | `FeatureLimit` + `FeatureUsage` |
| 3 | **Quality/intensity modifiers** — «всем доступно, но по-разному» | AI: Pro = приоритетная очередь | ❌ (исключено по D-FG-1) | — |

**D-FG-1 — Quality modifiers исключены из MVP.** Если реально понадобится «приоритетная очередь» или «расширенный режим» — это реализуется как **отдельный feature_code**, не через дополнительную сущность. Например: `ai_chat_basic` (Free, gate'd) и `ai_chat_priority` (Pro, gate'd) — два независимых кода, под капотом один сервис с переключателем. Это расщепление, а не модификация.

**Цена решения:** при обилии модификаторов будет «инфляция» feature_codes. На MVP — приемлемо. При появлении системного паттерна (десятки модификаторов) — возвращаемся к идее `FeatureModifier` (additive, не ломает текущую схему).

---

## 3. Schema

### 3.1. `FeatureGate` (binary access)

```sql
CREATE TABLE feature_gate (
  feature_code              TEXT PRIMARY KEY,                -- стабильный машинный идентификатор
  category                  TEXT NOT NULL,                   -- 'tsp' | 'ai' | 'herd' | 'vet' | 'feed' | 'analytics' | 'lms' | 'erp' | 'identity'

  -- Ось 1: личная подписка User
  user_tier_required        TEXT NULL,                       -- ENUM-like: 'free' | 'pro' | NULL
                                                             -- NULL = эта ось эту фичу не открывает

  -- Ось 2: членство Organization (current_org_context)
  org_membership_tier_required TEXT NULL,                    -- ENUM-like: 'any' | 'standard' | 'premium' | NULL
                                                             -- 'any' = любой active/grace tier
                                                             -- 'standard' = standard или выше
                                                             -- 'premium' = только premium
                                                             -- NULL = эта ось эту фичу не открывает
                                                             -- ВАЖНО: 'any' и 'standard' в MVP эквивалентны (premium ещё нет)

  -- Дополнительный фильтр: тип организации
  org_type_required         TEXT[] NULL,                     -- inclusive: организация должна иметь
                                                             -- хотя бы один из перечисленных OrganizationType
                                                             -- в OrganizationTypeAssignment status='active'.
                                                             -- NULL = нет ограничения по типу

  -- UI-метаданные
  upgrade_hint              TEXT NULL,                       -- copy для UI «доступно для членов / для Pro»
                                                             -- NULL = UI скрывает фичу полностью
  is_teaser                 BOOLEAN NOT NULL DEFAULT false,  -- true = «витрина» / preview для нечленов
                                                             -- (например, tsp_view_market_preview)

  -- Аудит
  created_at                TIMESTAMP NOT NULL DEFAULT now(),
  updated_at                TIMESTAMP NOT NULL DEFAULT now(),
  updated_by                UUID NULL                        -- админ TURAN, последний редактор
);
```

**Семантика NULL — критично:**
- `user_tier_required = NULL` → личная подписка эту фичу не открывает (ни Free, ни Pro). Открыть может только membership.
- `org_membership_tier_required = NULL` → membership эту фичу не открывает. Открыть может только подписка.
- **Обе NULL одновременно** → фича публична (доступна всем зарегистрированным User'ам). Например, `lms_free_courses`.
- **Обе заполнены** → фича доступна по любому из двух путей (логика OR — см. §4).

### 3.2. `FeatureLimit` (quotas per period)

```sql
CREATE TABLE feature_limit (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  feature_code        TEXT NOT NULL REFERENCES feature_gate(feature_code),

  applies_to          TEXT NOT NULL,            -- 'user_tier' | 'org_membership_tier'
  applies_value       TEXT NOT NULL,            -- например 'free', 'pro', 'standard'

  limit_value         INTEGER NOT NULL,         -- допустимое количество
  limit_unit          TEXT NOT NULL,            -- 'messages' | 'batches' | 'export_jobs' | ...
  limit_period        TEXT NOT NULL,            -- 'day' | 'week' | 'month' | 'billing_cycle'

  created_at          TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (feature_code, applies_to, applies_value, limit_period)
);
```

**Принцип:** `FeatureLimit` НЕ имеет смысла без `FeatureGate` для того же `feature_code`. Если gate возвращает false — limit неприменим (нет доступа = не считаем квоту).

**Пример заполнения:**
```
feature_code='ai_chat_basic', applies_to='user_tier', applies_value='free',
limit_value=10, limit_unit='messages', limit_period='day'
```

Если у пользователя `tier='pro'` — для него нет строки в `FeatureLimit` с `applies_value='pro'` → нет лимита.

### 3.3. `FeatureUsage` (append-only лог использований)

```sql
CREATE TABLE feature_usage (
  id              BIGSERIAL PRIMARY KEY,
  user_id         UUID NOT NULL REFERENCES users(id),
  org_id          UUID NULL REFERENCES organizations(id),       -- контекст организации (если применимо)
  feature_code    TEXT NOT NULL REFERENCES feature_gate(feature_code),
  used_at         TIMESTAMP NOT NULL DEFAULT now(),
  count           INTEGER NOT NULL DEFAULT 1,                    -- обычно 1, но можно 5 за раз
  metadata        JSONB NULL                                     -- например, request_id для отладки
);

CREATE INDEX idx_feature_usage_lookup
  ON feature_usage(user_id, feature_code, used_at);
```

**Принципы:**
- **Append-only.** Нет UPDATE, нет DELETE (кроме регулярного TTL-cleanup по политикам ассоциации, если нужно).
- Проверка лимита = SUM(count) по окну: `WHERE user_id=? AND feature_code=? AND used_at >= now() - period`.
- Запись в `FeatureUsage` происходит **внутри той же транзакции**, что и выполнение действия (RPC). Если действие откатилось — usage тоже не записан.

---

## 4. Формула `effective_access`

Псевдо-код, по которому работает RPC `rpc_check_feature_access(user_id, feature_code, current_org_context)`:

```
function effective_access(user, feature, current_org_context):
  gate = feature_gate[feature]

  if gate is NULL:
    return DENY  -- неизвестная фича, fail-closed

  -- Ось 1: личная подписка
  user_tier_grants = false
  if gate.user_tier_required is NOT NULL:
    if user.platform_subscription.is_active                            -- состояние active/grace
       AND user.platform_subscription.tier >= gate.user_tier_required:  -- 'pro' >= 'free' etc
      user_tier_grants = true

  -- Ось 2: membership активной организации
  org_membership_grants = false
  if gate.org_membership_tier_required is NOT NULL
     AND current_org_context is NOT NULL:

    org = current_org_context
    am = org.association_membership

    -- (a) membership должен быть active или grace_period (capabilities ON)
    if am is NOT NULL AND am.state IN ('active', 'grace_period'):

      -- (b) tier должен соответствовать
      tier_match = (
        gate.org_membership_tier_required = 'any'
        OR am.tier >= gate.org_membership_tier_required
      )

      -- (c) user должен иметь роль в этой организации
      role_ok = user.has_role_in(org)

      -- (d) тип организации должен соответствовать (если задан)
      type_ok = (
        gate.org_type_required is NULL
        OR org.has_any_type_in(gate.org_type_required) with status='active'
      )

      if tier_match AND role_ok AND type_ok:
        org_membership_grants = true

  -- Объединение через OR (D-FG-3)
  if user_tier_grants OR org_membership_grants:
    return ALLOW
  else:
    return DENY
```

**Закрытые этой формулой случаи:**
- Публичная фича (обе оси NULL) — вернётся DENY по формуле, но в коде это спецслучай: для `NULL/NULL` всегда `ALLOW`. Это альтернативное решение через separate code path.
- `org_type_required` с `org_membership_tier_required=NULL` — не имеет смысла (тип проверяется только в контексте membership-оси). Запрещаем такие записи на уровне CHECK constraint.

**D-FG-2 — Fail-closed.** Если `feature_code` неизвестен / запись отсутствует / RPC падает → доступ отказан. Безопаснее, чем разрешать по умолчанию.

---

## 5. Cache-стратегия

### 5.1. Entitlements snapshot per session

При логине пользователя (или при смене активного `current_org_context`) сервер вычисляет **полный список доступных feature_codes** для текущего контекста — **entitlements snapshot** — и возвращает в session/JWT.

```json
{
  "user_id": "...",
  "current_org_context": "...",
  "computed_at": "2026-05-15T12:00:00Z",
  "entitlements": {
    "tsp_create_batch": { "allowed": true, "source": "org_membership" },
    "tsp_view_market_preview": { "allowed": true, "source": "public" },
    "ai_chat_basic": { "allowed": true, "source": "public", "limit": { "value": 10, "period": "day", "unit": "messages" } },
    "nasem_ration_calculator": { "allowed": false, "upgrade_hint": "Доступно для Pro" }
  }
}
```

Фронтенд читает локально — без round-trip на каждый клик. Это паттерн Linear / Slack / Stripe Entitlements.

### 5.2. Invalidation Events

Snapshot инвалидируется при пяти событиях:

| Событие | Триггер | Что делать |
|---|---|---|
| `platform_subscription.changed` | upgrade / downgrade / cancel / expire | refresh snapshot текущего user'а |
| `association_membership.state_changed` | T2..T10 в FSM из M2 | refresh snapshot всех users этой Org |
| `organization_type_assignment.changed` | добавлен/удалён OrganizationType | refresh snapshot всех users этой Org |
| `user_organization_role.changed` | пользователь добавлен/удалён из Org, изменена роль | refresh snapshot этого user'а |
| `feature_gate.updated` | админ TURAN изменил FeatureGate | refresh snapshot всех затронутых users (батчем) |

Реализация — через Event Bus (Dok 4). Каждое из 5 событий публикуется доменным сервисом → подписчик в frontend-фасаде / Realtime-канале вычисляет новый snapshot и пушит клиенту.

**D-FG-4 — Soft invalidation.** Клиент **не блокируется** на момент инвалидации. Он работает со старым snapshot до получения нового. Худший случай: пользователь видит «доступно» по фиче, на которую только что потерял доступ — RPC откажет на server-side (server всегда проверяет real-time через формулу § 4). UI отрисует разово ошибку «обновите страницу», после чего snapshot обновится.

---

## 6. Granularity: action-level

**D-FG-5 — Один пользовательский акт = один `feature_code`.** Не UI-кнопка, не экран, не RPC сам по себе, а **смысловое действие, на которое имеет смысл повесить gating**.

| ❌ Слишком мелко | ❌ Слишком крупно | ✅ Правильно |
|---|---|---|
| `tsp_create_batch_button_visible` | `tsp_module` (весь TSP одним кодом) | `tsp_create_batch`, `tsp_publish_batch`, `tsp_view_market`, `tsp_view_reference_price` (4 отдельных acta) |
| `feed_input_field_animal_count` | `nutrition` | `feed_basic_inventory`, `feed_ration_calculator_nasem` |

**Правило большого пальца:** если две функции имеют **разные правила доступа** в разных tier'ах — это два разных `feature_code`. Если правила одинаковые — один.

**Связь с RPC:** обычно 1 RPC соответствует 1 feature_code, но не обязательно. Список фич, перекрываемых конкретной RPC, проверяется в начале её выполнения (`SECURITY DEFINER` функция вызывает `rpc_check_feature_access` для каждой нужной фичи).

---

## 7. Шаблонный seed (6 примеров)

Этот seed **не закрывает MVP** — он демонстрирует все паттерны схемы, чтобы команда разработки могла добавлять новые фичи по аналогии без архитектурных вопросов.

```sql
-- 1. TSP create batch — только член, только организация типа farmer
INSERT INTO feature_gate (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser) VALUES
('tsp_create_batch', 'tsp', NULL, 'any', ARRAY['farmer'], 'Доступно для членов ассоциации с типом «фермер»', false);

-- 2. TSP market preview — публичная витрина (teaser для нечленов)
INSERT INTO feature_gate (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser) VALUES
('tsp_view_market_preview', 'tsp', NULL, NULL, NULL, NULL, true);

-- 3. AI базовый чат — публичный с лимитом для Free
INSERT INTO feature_gate (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser) VALUES
('ai_chat_basic', 'ai', NULL, NULL, NULL, NULL, false);

INSERT INTO feature_limit (feature_code, applies_to, applies_value, limit_value, limit_unit, limit_period) VALUES
('ai_chat_basic', 'user_tier', 'free', 10, 'messages', 'day');

-- 4. NASEM-калькулятор (placeholder content — конкретные правила в product-сессии)
INSERT INTO feature_gate (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser) VALUES
('feed_ration_calculator_nasem', 'feed', 'pro', NULL, NULL, 'Расчёт рационов NASEM — для Pro-подписчиков', false);

-- 5. ERP-доступ — целиком в Pro (D-FG-7)
INSERT INTO feature_gate (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser) VALUES
('erp_access', 'erp', 'pro', NULL, NULL, 'ERP-модуль доступен в Pro-подписке', false);

-- 6. LMS открытый каталог — публичный
INSERT INTO feature_gate (feature_code, category, user_tier_required, org_membership_tier_required, org_type_required, upgrade_hint, is_teaser) VALUES
('lms_free_courses', 'lms', NULL, NULL, NULL, NULL, false);
```

**Заметка:** строки 4 и 5 содержат конкретные правила, но это **placeholder**. В соответствующей продуктовой мини-сессии могут быть изменены (например, NASEM может оказаться частично-Free / частично-Pro по типу подкомпонентов).

---

## 8. Key Decisions

### D-FG-1 — Quality modifiers исключены из MVP

Тип-3 governance (модификаторы поведения по tier'у) не реализуется через отдельную сущность. При необходимости — расщепление на отдельные feature_codes. Если паттерн станет системным — введём `FeatureModifier` additive.

### D-FG-2 — Fail-closed

Неизвестная фича / отсутствие записи в `FeatureGate` / ошибка вычисления → доступ отказан. Безопаснее, чем разрешать по умолчанию.

### D-FG-3 — OR между осями, NULL = «эта ось не открывает»

Личная подписка ИЛИ членство (в активной организации). Каждая ось независимо может разблокировать. NULL на оси = эта ось эту фичу не открывает. Обе NULL = публичная (спецслучай).

### D-FG-4 — Soft invalidation

Snapshot инвалидируется асинхронно. Server-side всегда проверяет real-time. UI работает с slightly-stale snapshot. Это приемлемо для отзывчивости и простоты.

### D-FG-5 — Action-level granularity

Один смысловой пользовательский акт = один `feature_code`. Не кнопка, не экран.

### D-FG-6 — Standards as data

Любое изменение правил доступа (Free / Pro / membership) — это **INSERT/UPDATE в таблице `feature_gate`**, не code deploy. Полностью соответствует Principle 8.

### D-FG-7 — ERP целиком в Pro

`erp_*` фичи требуют `user_tier_required = 'pro'`. Решение принято CEO 2026-05-15 (Вариант C из развилки M3 product-сессии). Конкретные erp_* коды добавятся когда ERP интегрируется в AGOS.

---

## 9. Связь с Event Bus (Dok 4)

Новые события, которые должны быть добавлены в Dok 4:

| Event code | Producer | Consumers | Payload |
|---|---|---|---|
| `entitlements.invalidated` | Любой из 5 триггеров (§5.2) | Realtime fan-out на клиент(ов) | `{ user_id, org_id?, reason }` |
| `feature_gate.updated` | Admin TURAN UI | invalidator (вычисляет затронутых users), Realtime | `{ feature_code, changed_at, changed_by }` |
| `feature_usage.recorded` | Любой RPC, потребляющий квоту | (опционально) аналитика, billing | `{ user_id, feature_code, used_at, count }` |

Полное описание формата — в обновлённом Dok 4.

---

## 10. Open Questions (для следующих мини-сессий)

Эти вопросы **не блокируют каркас**, но должны быть отвечены в соответствующей продуктовой мини-сессии перед наполнением seed.

| ID | Вопрос | Когда отвечать |
|---|---|---|
| Q-PROD-MONETIZATION-PRINCIPLE | Какова единая формула «что в Free / что в Pro / что только член»? Эмоциональное обещание каждого уровня. | Перед первой product-сессией |
| Q-PROD-TSP-PREVIEW-CONTENT | Что именно показываем нечленам в `tsp_view_market_preview` — какие колонки, какая агрегация, какая privacy? | M4 / M6 (TSP-микрошаги) |
| Q-PROD-AI-LIMITS | Дневной лимит сообщений в `ai_chat_basic` для Free — 10 правильное число? | AI UI-микрошаг |
| Q-PROD-NASEM-PLACEMENT | NASEM в Pro целиком, или базовый расчёт Free + advanced в Pro? | Feed UI-микрошаг |
| Q-PROD-AI-MARKET-ADVISOR | Существует ли «AI-советник по рынку» как отдельная фича для членов? Если да — что внутри? | AI UI-микрошаг |
| Q-PROD-LMS-CERTIFICATES | Сертификаты TURAN — только для членов, или для Pro тоже? | LMS UI-микрошаг |
| Q-PROD-ANALYTICS-BENCHMARK | Бенчмарк фермы против рынка — только для членов? Какая агрегация? | Analytics UI-микрошаг |
| Q-PROD-WILLINGNESS-TO-PAY | Сколько фермер реально готов платить за Pro (исследование, не догадки)? | Перед запуском Pro-тарифа |
| Q-PROD-ALTERNATIVE-COST | За что сейчас платят фермеры внеплатформенно (зоотехник, ветврач, консультант)? Это пол Pro-цены. | Перед запуском Pro-тарифа |

---

## 11. Не делать в Microstep 4

- Расширять feature_gate seed («давай сразу пропишем все 50 фич TSP»)
- Финализировать NASEM/AI/Analytics монетизацию
- Дизайн экранов
- SQL DDL финализация для `feature_*` таблиц (это будет в коде, не в decision record)
- Pricing

**Только M4:** Batch lifecycle в фермерской лексике — состояния `Batch` как видит фермер, проекция Pool-статусов через Batch (Pool не упоминается в фермерском UI), словарь, FSM Batch.

---

## 12. Summary diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                       Identity (M1) + FSM (M2)                       │
│                                                                       │
│  ┌──────┐  ┌─────────────────┐  ┌────────────┐  ┌─────────────────┐ │
│  │ User │  │PlatformSubscript│  │Organization│  │AssociationMember│ │
│  │      │──│  tier=free/pro  │  │ types[]    │  │  state, tier    │ │
│  └──────┘  └─────────────────┘  └────────────┘  └─────────────────┘ │
└────────────────────────────────┬─────────────────────────────────────┘
                                 │
                                 │ feeds into
                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    Feature Governance (M3, this doc)                  │
│                                                                       │
│  ┌──────────────────────┐   ┌──────────────────────┐                 │
│  │    FeatureGate       │   │    FeatureLimit      │                 │
│  │  (binary access)     │◄──│   (quotas, optional) │                 │
│  └──────────┬───────────┘   └──────────────────────┘                 │
│             │                                                         │
│             │                  ┌──────────────────────┐               │
│             └─────reads────────┤   FeatureUsage       │               │
│                                │   (append-only log)  │               │
│                                └──────────────────────┘               │
│                                                                       │
│         ┌─────────────────────────────────────────┐                  │
│         │   effective_access(user, feature, ctx)  │                  │
│         │   = user_tier_grants OR org_member_grants│                 │
│         └─────────────────────────────────────────┘                  │
│                                                                       │
│         ┌─────────────────────────────────────────┐                  │
│         │  Entitlements Snapshot (per session)    │                  │
│         │  + Event Bus invalidation (5 triggers)  │                  │
│         └─────────────────────────────────────────┘                  │
└──────────────────────────────────────────────────────────────────────┘
                                 │
                                 │ used by
                                 ▼
                ┌────────────────────────────────────┐
                │  All UI screens, all RPCs (M4+)    │
                │  Each gate'd action checks access. │
                └────────────────────────────────────┘
```
