# Microstep 1 — Identity Domain v0.2
## AGOS Architecture Decision Record

| Field | Value |
|---|---|
| Date | 2026-05-14 |
| Status | ✅ Confirmed by CEO (Arshidin) |
| Supersedes | v0.1 (same-day amendment, see §0 changelog) |
| Scope | Identity domain entity catalog and the three-layer Platform / Organization / Association separation |
| Next | Microstep 2 — FSM `AssociationMembership` |

---

## 0. Changelog v0.1 → v0.2

| Что | v0.1 | v0.2 |
|---|---|---|
| OrganizationTypeApplication | отдельная FSM на каждой заявке | существует **условно** — только когда `OrganizationType.requires_approval = true`. Для `farmer`/`service_provider` — self-service, без заявки и без ревью. |
| `OrganizationType` schema | без флага approval | добавлено поле `requires_approval BOOLEAN` |
| Тип `expert` | в OrganizationType seed | удалён из MVP. Эксперт — атрибут `User.expertise_areas[]`, живёт в personal context. Тип `expert_provider`/`consultancy` отложен до v2 (когда появится монетизация консультаций). |
| `User` schema | базовые поля | добавлены `expertise_areas[]` (опционально), для эксперт-маркетплейса в LMS-домене позже |
| `PlatformSubscription` | свободная форма | **Free + Pro тиры с MVP**. Поля `tier`, `trial_until`, `trial_used`, `current_period_end`. |
| Биллинговые события | не описаны | новая сущность `SubscriptionEvent` (append-only лог: subscribed/upgraded/downgraded/cancelled/expired/renewed) |
| FeatureGate axes | обе оси «зарезервированы», MVP только `org_membership` | **обе оси активны с MVP**: `user_tier_required` и `org_membership_required` независимо. |
| TSP access | обсуждалось | финализировано: TSP-фичи имеют `user_tier_required = NULL`. TSP открывается **только** через AssociationMembership, никогда через личную подписку. Антитраст-чистота revenue streams. |

---

## 1. The Three-Layer Separation (unchanged from v0.1)

```
┌──────────────────────────────────────────────────────────┐
│ Layer 1: PLATFORM                                        │
│   Сущность: User (физ. лицо)                             │
│   Биллинг: PlatformSubscription (Free / Pro)             │
│   Доступ: всем, без ограничений                          │
└────────────────────┬─────────────────────────────────────┘
                     │ принадлежит через UserOrganizationRole
                     ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 2: ORGANIZATION                                    │
│   Сущность: Organization (ТОО / АО / ИП / КХ)            │
│   Биллинг: нет (членский взнос — это Layer 3)            │
│   Тип: OrganizationType (multi-type через assignment)    │
└────────────────────┬─────────────────────────────────────┘
                     │ через MembershipApplication
                     ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 3: ASSOCIATION                                     │
│   Сущность: AssociationMembership (на Organization)      │
│   Биллинг: членский взнос → Team Plan для всех User'ов   │
│   Eligibility: с/х вид деятельности                      │
└──────────────────────────────────────────────────────────┘
```

Каждый слой существует независимо. User может остановиться на Layer 1. Organization может остановиться на Layer 2.

---

## 2. Entity Catalog v0.2 (Identity domain)

| Сущность | Назначение | Создаёт | Изменяет | Cardinality |
|---|---|---|---|---|
| `User` | физ. лицо, учётка платформы. Поля: phone, full_name, region_id, preferences, **expertise_areas[]** (опционально). | self (через регистрацию) | self | — |
| `PlatformSubscription` | подписка User на платформу. Поля: `tier ENUM('free','pro')`, `trial_until DATE NULL`, `trial_used BOOL`, `current_period_end TIMESTAMP NULL`, `status ENUM('active','grace','cancelled','expired')`. | self (через биллинг); auto-create `tier=free` при регистрации User | self (отмена/апгрейд), billing webhook | 1:1 → User |
| `SubscriptionEvent` | append-only лог событий подписки: `subscribed`, `upgraded`, `downgraded`, `cancelled`, `expired`, `renewed`, `trial_started`, `trial_converted`, `trial_expired`. | billing logic | — (immutable) | many → PlatformSubscription |
| `Organization` | юр. лицо (ТОО/АО/ИП/КХ). Поля: name, bin, legal_form, region_id, economic_activity_type_ids[]. | User (становится owner) | роли admin+ | M:N с User через `UserOrganizationRole` |
| `OrganizationType` | справочник типов. Поля: type_code, name, **requires_approval BOOLEAN**. Seed для MVP: `farmer` (false), `mpk` (true), `service_provider` (false), `education_provider` (true), `government` (true). | seed-data | админ TURAN | — |
| `OrganizationTypeAssignment` | связка Org ↔ Type. Поля: organization_id, type_code, status (`active` / `pending_approval`), assigned_at. Для self-service типов — сразу `active`; для approval-required — `pending_approval` до решения админа. | owner (первичный); владелец Org для доп. (см. ниже) | админ TURAN (для approval-required) | M:N |
| `OrganizationTypeApplication` | **условная** сущность — существует только когда `OrganizationType.requires_approval = true`. Заявка на добавление approval-required типа. FSM: `submitted → under_review → approved \| rejected`. | owner Org | админ TURAN (ревью) | many → Org. **Не используется в MVP-фермерском флоу** (farmer = self-service). |
| `EconomicActivityType` | справочник видов деятельности (агрегированный, не полный ОКЭД). Используется для eligibility AssociationMembership. | seed-data | админ TURAN | — |
| `UserOrganizationRole` | роль User в Organization. role финализируется в Microstep 3. | owner Org (приглашение) | owner/admin | M:N |
| `AssociationMembership` | членство Organization в TURAN. FSM — в Microstep 2. | через `MembershipApplication` | админ TURAN; биллинг (paid_until) | 1:1 → Organization |
| `MembershipApplication` | заявка Organization на повышение membership level | owner Org | админ TURAN (ревью) | many → Org |
| `FeatureGate` | реестр feature-флагов. Поля: feature_code, `user_tier_required ENUM('free','pro') NULL`, `org_membership_required TEXT NULL` (уровень AssociationMembership), `org_type_required TEXT[] NULL`. NULL на оси = эта ось не открывает фичу. | админ TURAN | админ TURAN | — |

**Что переименовано / удалено относительно Dok 6 v1.0:**
- ❌ `Membership` → ✅ `AssociationMembership`
- ❌ Атомарная `rpc_register_organization` → ✅ три отдельные RPC (см. D-IDM-6)
- ❌ Тип `expert` в OrganizationType MVP seed — удалён

---

## 3. Key Decisions

### D-IDM-1 — Eligibility через вид деятельности, не правовую форму (v0.1, unchanged)

Членом TURAN может стать организация любой правовой формы (ТОО/АО/ИП/КХ) при наличии с/х вида деятельности. Eligibility — data-driven через `EconomicActivityType`.

### D-IDM-2 — User ↔ Organization: many-to-many (v0.1, unchanged)

Один User → несколько Organization с разными ролями. Двухуровневая RLS. Personal context — полноценный режим.

### D-IDM-3 — Multi-type Organization (v0.1, unchanged)

Одна `Organization` — несколько `OrganizationType` через `OrganizationTypeAssignment`. БИН уникален. Type = unlock модулей, не permission.

### D-IDM-4 — Дуальный биллинг (v0.1, unchanged formula; v0.2 detalization)

Два независимых биллинговых продукта:
- `PlatformSubscription` на User (Free / Pro).
- `AssociationMembership` с членским взносом на Organization → Team Plan derived view для всех её User'ов.

**Формула эффективного доступа:**
```
effective_access(user, feature, current_org_context) =
    user.platform_subscription.grants(feature)
  OR
    (current_org_context EXISTS
     AND current_org_context.association_membership.is_active
     AND current_org_context.association_membership.grants_team_access(feature)
     AND user.has_role_in(current_org_context))
```

`FeatureGate` — реестр с обеими осями активными. Standards-as-data.

### D-IDM-5 — Intent: soft signal, не identity (v0.1, unchanged)

На `/register` НЕ спрашиваем роль. Intent на `/welcome` → `User.preferences.onboarding_intent`. Ничего не гейтит.

### D-IDM-6 — Атомарность регистрации: три отдельные RPC (v0.1, unchanged)

`rpc_register_user`, `rpc_create_organization`, `rpc_submit_membership_application` — три отдельные операции во времени.

### D-IDM-7 — Approval как атрибут типа, не FSM на каждой заявке *(NEW v0.2)*

**Что:** `OrganizationType.requires_approval BOOLEAN`. Если `false` — добавление типа self-service (запись в `OrganizationTypeAssignment status=active` без процесса). Если `true` — создаётся `OrganizationTypeApplication` с ревью админа.
**Почему:** Большинство типов (farmer, service_provider) не требуют одобрения — самоидентификация. Approval нужен только для типов с юридическими/антитраст-импликациями (mpk, education_provider, government). FSM на каждой заявке — overengineering.
**Последствия:**
- Сущность `OrganizationTypeApplication` **не существует в MVP-фермерском флоу**, потому что `farmer.requires_approval = false`.
- Антитраст-защита (запрет на self-grant `mpk` фермером) реализована через `mpk.requires_approval = true`.

### D-IDM-8 — Эксперт = атрибут User, без Organization в MVP *(NEW v0.2)*

**Что:** Эксперт-консультант живёт как `User` в personal context. Атрибут `User.expertise_areas[]` отмечает его специализацию. Никакая Organization для эксперта в MVP не создаётся.
**Почему:** На пилоте 100% экспертов — фрилансеры. Юр. оформление через ИП — отложенный кейс. Сущность `Organization(type=expert_provider)` появится в v2 вместе с монетизацией консультаций.
**Последствия:**
- В `OrganizationType` MVP seed нет типа `expert`.
- Onboarding intent «помогать как эксперт» ведёт в personal context, не в создание Org.
- Эксперт «работает с фермой» = фермер приглашает его в свою Organization через `UserOrganizationRole`.

> **Reality (A8):** expert_profiles table exists and is RETAINED (HS-2). Treat expert_profiles as the v2 expert_provider concept; User.expertise_areas[] may be added additively. Canon ratified to deployed reality; do not delete expert_profiles.

### D-IDM-9 — PlatformSubscription = Free + Pro с MVP *(NEW v0.2)*

**Что:** Два тира с первого дня. Trial-механика в схеме. SubscriptionEvent — append-only лог.
**Почему:** Real revenue stream с пилота. Trial без полей в схеме = миграция позже. Event log без append-only = невозможны корректные billing-операции (proration, повторный trial, история апгрейдов).
**Условия:**
- Schema-1: ровно 2 тира на User-уровне (`free` / `pro`). Третий тир — additive (новое значение enum + строки в FeatureGate), не сейчас.
- Schema-2: поля `trial_until`, `trial_used` в `PlatformSubscription` с MVP. Конкретная продолжительность — биллинговая сессия.
- Schema-3: `SubscriptionEvent` append-only — обязательно с MVP.
**Последствия:**
- При регистрации User автоматически создаётся `PlatformSubscription` с `tier='free'`.
- Конкретный feature-сплит Free/Pro — в Microstep 3 (FeatureGate seed).

### D-IDM-10 — TSP доступен только через AssociationMembership, не через PlatformSubscription *(NEW v0.2)*

**Что:** Все TSP-фичи (создание Batch, публикация, просмотр reference price) имеют `FeatureGate.user_tier_required = NULL` и `org_membership_required = 'declared_supplier'` (или выше).
**Почему:** TSP — инфраструктура ассоциации, не платформенная фича. Личная Pro-подписка не должна давать доступ к координации поставок — это разъезжалось бы с самой идеей членского взноса и создавало бы антитраст-двусмысленность.
**Последствия:** Чистое разведение revenue streams. Pro-подписка монетизирует **личный** AI/аналитику/расчёты. Членский взнос монетизирует **участие в координации**. Не конкурируют, не пересекаются.

---

## 4. Impact на текущий Dok 6 v1.0 (обновлённый)

| Что в Dok 6 v1.0 | Что становится |
|---|---|
| `RPC-01 rpc_register_organization` (атомарно создаёт всё) | Три RPC: `rpc_register_user`, `rpc_create_organization`, `rpc_submit_membership_application` |
| Step1 F01: role_select | Удалить из F01. Intent — на F24/welcome, не блокирующий. |
| Сущность `Membership` | `AssociationMembership` |
| `Membership.level` FSM | Пересмотр в Microstep 2 |
| Farm auto-create при регистрации (P11) | Farm создаётся при добавлении `OrganizationTypeAssignment(type='farmer')` (первичного или дополнительного) |
| Подписка не описана | `PlatformSubscription` (Free/Pro) на User + `SubscriptionEvent` лог |
| Hardcoded feature checks | `FeatureGate` registry с двумя осями |
| `Pool` экспонируется в F27 | Pool — backend-only. Фермерский UI работает только с `Batch` (проекция Pool-статусов в фермерский словарь). Решение зафиксировано как принцип, реализация — в TSP-UI микрошагах. |

---

## 5. Open Questions

| ID | Вопрос | Микрошаг |
|---|---|---|
| Q-FSM-MEMBERSHIP | FSM `AssociationMembership` — действительно ли 4 уровня? Зачем `observer`? Что триггерит переходы? | M2 |
| Q-FSM-MEMBERSHIP-GRACE | Что при просрочке членского взноса (grace period, auto-downgrade?) | M2 |
| Q-ROLES | Финальный перечень `UserOrganizationRole.role` (owner/admin/member/viewer?) и их permissions | M3 (отложен, MVP = только owner) |
| Q-CAPABILITY-MATRIX | FeatureGate seed: Free / Pro / Membership level × фичи | M3 |
| Q-PRO-FEATURES | Конкретный feature set Pro-тира | M3 |
| Q-TRIAL-DURATION | Продолжительность trial, частота повторных trial'ов | Биллинговая сессия |
| Q-PRICING | Цена Pro / цена членского взноса по уровням | Биллинговая сессия |
| Q-TEAM-PLAN-EXIT | Что с User'ом, покинувшим Organization с активным Team Plan? | Биллинговая сессия |
| Q-INTENT-OPTIONS | Финальный перечень intent-опций на /welcome | UX-стадия |
| Q-ACTIVITY-TYPES | Конкретный перечень `EconomicActivityType` (агрегированных) | Seed-data сессия |
| Q-PRIMARY-TYPE | Может ли первичный `OrganizationType` быть сменён? | M3 |
| Q-MULTI-TYPE-PILOT | Когда в пилоте появятся реальные multi-type кейсы? | После M5 |

---

## 6. Не делать в Microstep 2

- SQL DDL
- Дизайн экранов
- Имена API endpoints
- FeatureGate seed (Free vs Pro split)
- Roles permissions
- UserOrganizationRole.role финализация
- Биллинговые тарифы

**Только:** FSM `AssociationMembership` — состояния, переходы, триггеры (что инициирует), gating (что блокирует), временна́я модель (grace, expiration), ownership of transitions (кто авторизует каждый переход).
