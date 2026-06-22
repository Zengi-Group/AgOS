# Dok 6 — Interface Contracts: Slice 1 "У телёнка температура"

> Version: 2.0 | Date: 2026-03-18
> Author: Architect Agent
> Status: ✅ APPROVED — all 7 CEO questions resolved. Dok 6 Gate PASSED.
>
> **Scope:** 4 farmer screens (F01, F02, F10, F11) — first farmer contact scenario.
> **User story:** Farmer registers → creates farm → reports sick animal → sees AI diagnosis.

---

## Design System

All Slice 1 screens use the **Farmer Cabinet** warm palette:

```css
:root {
  --bg-primary: #fdf6ee;
  --text-primary: #2B180A;
  --accent: hsl(24, 73%, 54%);       /* warm orange */
  --accent-hover: hsl(24, 73%, 44%);
  --surface: #ffffff;
  --border: #e8ddd0;
  --text-secondary: #6b5744;
  --success: #2d7a3a;
  --error: #c53030;
  --warning: #b7791f;
  --severity-mild: #38a169;
  --severity-moderate: #d69e2e;
  --severity-severe: #e53e3e;
  --severity-critical: #9b2c2c;
}
```

**Typography:** System font stack. Headings: 600 weight. Body: 400.
**Layout:** Max-width 640px centered (mobile-first, farmer uses phone).
**Language:** Russian UI. Field labels in Russian. Placeholders with examples.

---

## UX: Loading, Offline, and Slow Networks

**Target user:** Farmer 45+, rural Kazakhstan, 3G connection (5-10 sec page load is normal).

### Loading States

Every screen MUST implement:

| State | UX | Implementation |
|-------|-----|----------------|
| **Initial load** | Skeleton screen (gray pulsing blocks matching layout) | Show skeleton immediately, replace with data on RPC response |
| **RPC in flight** | Button disabled + spinner + "Сохранение..." text | Prevent double-submit |
| **Realtime connecting** | Subtle dot indicator (gray=connecting, green=live) | `supabase.channel().subscribe()` status |

### Error & Retry

| Scenario | UX | Implementation |
|----------|-----|----------------|
| **Network timeout** (>15 sec) | Toast: "Нет связи. Проверьте интернет." + "Повторить" button | Retry with exponential backoff (1s, 3s, 9s, max 30s) |
| **RPC error** (non-network) | Toast with error message from RPC (translated to Russian) | Show error, keep form data, allow re-submit |
| **Realtime disconnect** | Auto-reconnect (Supabase built-in). After 3 failures: banner "Обновления приостановлены. Обновите страницу." | `channel.on('close', ...)` handler |
| **Offline** | Banner at top: "Нет подключения к интернету" (persistent until online) | `navigator.onLine` + `window.addEventListener('online'/'offline')` |

### Performance Budget

| Metric | Target | Rationale |
|--------|--------|-----------|
| First Contentful Paint | < 2s on 3G | Skeleton renders before data |
| Time to Interactive | < 5s on 3G | All form inputs usable |
| RPC call budget per page | Max 2 calls on load | Minimize round-trips over slow connection |
| Bundle size (per route) | < 100KB gzipped | Code-split per route |

### Form Preservation

- On network error: form inputs MUST NOT clear. Farmer re-submits without retyping.
- On page reload: `sessionStorage` preserves F01 Step 2 form data (not OTP step).
- On navigation away with unsaved changes: `beforeunload` warning.

---

## Navigation Structure

```
/ (redirect → /register if no session, /cabinet if session)
├── /register          → F01 (Registration)
├── /cabinet           → Dashboard (Slice 2+, stub for now)
│   ├── /cabinet/farm  → F02 (Farm Profile)
│   ├── /cabinet/vet   → Vet Cases list (stub)
│   │   ├── /cabinet/vet/new    → F10 (Report Sick)
│   │   └── /cabinet/vet/:id    → F11 (Vet Case Detail)
```

---

## F01 — Регистрация (multi-role, conversational UX)

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F01 |
| Route | `/register` |
| Auth | Public → OTP (Twilio SMS) |
| User story | Пользователь выбирает роль → проходит conversational registration с benefit-экранами → автоматически создаётся организация → опционально подаёт заявку на членство |
| RPCs | `supabase.auth.signInWithOtp()` → `rpc_register_organization` (RPC-01) → `rpc_submit_membership_application` (RPC-02, optional) |
| Ref (v1) | `turan-industry-catalyst/src/pages/Registration.tsx` |

### Role Branching

4 roles with different registration paths. All share Steps 1-2 (phone + contact), then diverge.

| Role | org_type | Cabinet | Slice |
|------|----------|---------|-------|
| **Фермер** | `farmer` | Farmer Cabinet (F02-F28) | Slice 1 (full path) |
| **Мясокомбинат/Откормплощадка (МПК)** | `mpk` | MPK Cabinet (future) | Registration in Slice 1, cabinet in Slice 5+ |
| **Сервисная компания** | `services` | Services Cabinet (future) | Registration in Slice 1, cabinet later |
| **Кормопроизводитель** | `feed_producer` | Feed Producer Cabinet (future) | Registration in Slice 1, cabinet later |

### User Flow — All Roles

```
Step 1: role_select
  - 4 cards with icons:
    🐄 "Фермер" — "Я выращиваю скот"
    🏭 "Мясокомбинат / Откормплощадка" — "Я закупаю скот"
    🔧 "Сервисная компания" — "Я оказываю услуги фермерам"
    🌾 "Кормопроизводитель" — "Я произвожу/продаю корма"
  - Selection → sets role, advances to Step 2

Step 2: contact
  - Input: full_name (required) — floating label "Ваше имя"
  - Input: phone (required) — +7 mask, auto-advance at 10 digits
  - Input: region (select) — 20 регионов Казахстана
  - On submit:
    - supabase.auth.signInWithOtp({ phone, options: { shouldCreateUser: true } })
    - Show OTP input (6 digits)
    - supabase.auth.verifyOtp({ phone, token, type: 'sms' })
    - Result: auth session created

Step 3: benefit_1 (informational, no input)
  - Role-specific sales pitch screen (value proposition of TURAN membership)
  - "Далее" button → advance

Step 4: role_details (ROLE-SPECIFIC — see below)

Step 5: benefit_2 (informational, no input)
  - Feature showcase for the role
  - "Далее" button → advance

Step 6: agreement
  - Checkbox: "Согласен с условиями использования платформы"
  - Link to /membership-policy
  - Checkbox: "Согласен на обработку персональных данных"
  - "Зарегистрироваться" button
  - Action: rpc_register_organization({ ... all collected data ... })
  - Result: { org_id, farm_id? }

Step 7: membership_application (optional, P11)
  - "Подайте заявку на вступление в ассоциацию ТУРАН"
  - Input: notes (textarea, optional)
  - "Подать заявку" → rpc_submit_membership_application(...)
  - "Пропустить" → skip
  - Always p_membership_type: 'associate' (upgrade via separate screen)

Step 8: success
  - Confirmation screen with next steps
  - Redirect → role-specific cabinet (farmer → /cabinet/farm)
```

### Step 4 — Role-Specific Fields

#### Farmer (org_type = 'farmer')

| Field | Type | Required | Options / Notes |
|-------|------|----------|-----------------|
| farm_name | text | ✓ | "Название хозяйства" |
| bin_iin | text | — | 12 digits, auto-advance. "БИН/ИИН (если есть)" |
| legal_form | select | — | КХ \| ИП \| ТОО \| Физлицо |
| herd_size | select | ✓ | до 50 \| 51-100 \| 100-300 \| 300-500 \| 500-1000 \| 1000+ |
| primary_breed | select | — | Казахская белоголовая \| Ангус \| Герефорд \| Симментальская \| Аулиекольская \| Калмыцкая \| Смешанная |
| ready_to_sell | select | — | Готов сейчас \| 1-3 мес \| 3-6 мес \| Пока изучаю |

#### MPK (org_type = 'mpk')

| Field | Type | Required | Options / Notes |
|-------|------|----------|-----------------|
| company_name | text | ✓ | "Название компании" |
| bin | text | ✓ | 12 digits |
| company_type | select | ✓ | Откормочная площадка \| Мясокомбинат \| Откорм+переработка \| Трейдер |
| monthly_volume | select | ✓ | до 100 голов \| 100-500 \| 500-1000 \| 1000+ |

**MPK gets extra Step 5b** (before benefit_2):

| Field | Type | Required | Options / Notes |
|-------|------|----------|-----------------|
| target_breeds | multi-select (chips) | — | Same breed list as farmer |
| target_weight | select | — | 350-400 \| 400-450 \| 450-500 \| 500+ \| Разный |
| procurement_frequency | select | — | Еженедельно \| Раз в 2 недели \| Ежемесячно \| Сезонно |

#### Services (org_type = 'services')

| Field | Type | Required | Options / Notes |
|-------|------|----------|-----------------|
| company_name | text | ✓ | "Название компании" |
| bin | text | ✓ | 12 digits |
| service_types | multi-select (chips) | ✓ | Ветеринария \| Зоотехния \| Логистика \| Страхование \| Юридические услуги \| Сертификация \| Другое |
| service_regions | multi-select | — | Регионы обслуживания (из тех же 20 регионов) |

#### Feed Producer (org_type = 'feed_producer')

| Field | Type | Required | Options / Notes |
|-------|------|----------|-----------------|
| company_name | text | ✓ | "Название компании" |
| bin | text | ✓ | 12 digits |
| feed_types | multi-select (chips) | ✓ | Сено \| Сенаж \| Силос \| Комбикорм \| Зерновые \| Жмых/шрот \| Минеральные добавки \| Другое |
| production_volume | select | — | Малый (до 100 т/мес) \| Средний (100-500) \| Крупный (500-1000) \| Промышленный (1000+) |
| delivery_regions | multi-select | — | Регионы доставки |

### Shared Field: how_heard (all roles, Step 6 or 7)

| Field | Type | Required | Options |
|-------|------|----------|---------|
| how_heard | select | — | Рекомендация \| WhatsApp/Telegram \| Соцсети \| Мероприятие \| Поставщик кормов \| Другое |

### Data Requirements

| RPC | When called | Input | Output | Error handling |
|-----|------------|-------|--------|----------------|
| `supabase.auth.signInWithOtp` | Step 2 | `{ phone }` | — | "Ошибка отправки SMS" |
| `supabase.auth.verifyOtp` | Step 2 OTP | `{ phone, token, type: 'sms' }` | Session | "Неверный код" |
| `rpc_register_organization` (RPC-01) | Step 6 submit | `{ p_org_type, p_name, p_bin, p_region_id, p_phone, p_role_data (jsonb) }` | `{ org_id, farm_id? }` | `BIN_DUPLICATE` → "Организация с таким БИН уже зарегистрирована" |
| `rpc_submit_membership_application` (RPC-02) | Step 7 submit | `{ p_org_id, p_membership_type: 'associate', p_notes }` | `uuid` | `PENDING_EXISTS` → "Заявка уже подана" |

**Note on RPC-01:** `p_role_data` is a JSONB parameter containing role-specific fields:
- Farmer: `{ farm_name, herd_size, primary_breed, ready_to_sell, legal_form }`
- MPK: `{ company_type, monthly_volume, target_breeds, target_weight, procurement_frequency }`
- Services: `{ service_types, service_regions }`
- Feed Producer: `{ feed_types, production_volume, delivery_regions }`

This avoids 4 different RPC signatures (P7 additive) — one RPC, role-specific payload.

### Reference Data (preloaded)

| Source | Data | Used for |
|--------|------|----------|
| `regions` table | 20 регионов Казахстана | Region selects |
| `breeds` table | 7 пород (P8: data, not code) | Breed selects |
| Hardcoded (v1 compat) | legal_form, herd_size, company_type options | Select dropdowns |
| Hardcoded (new) | service_types, feed_types options | Chip selects |

**TODO (P8):** Move herd_size, company_type, service_types, feed_types to DB lookup tables in future.
For Slice 1: hardcoded constants are acceptable (matches v1 pattern).

### Validation Rules

| Field | Rule | Error message |
|-------|------|---------------|
| phone | Required, 10 digits after +7 | "Введите номер телефона" |
| full_name | Required, 2-100 chars | "Введите ваше имя" |
| farm_name / company_name | Required, 2-200 chars | "Введите название" |
| bin / bin_iin | 12 digits if provided | "БИН/ИИН должен содержать 12 цифр" |
| region | Optional but recommended | Warning: "Укажите регион" |
| herd_size (farmer) | Required | "Укажите размер поголовья" |
| consent | Required (both checkboxes) | "Необходимо согласие" |

### UI Components

```
F01-Registration (conversational, mobile-first, max-width 480px)
├── ProgressBar (0-100%, smooth animation)
├── Step-RoleSelect
│   ├── RoleCard[farmer] 🐄
│   ├── RoleCard[mpk] 🏭
│   ├── RoleCard[services] 🔧
│   └── RoleCard[feed_producer] 🌾
├── Step-Contact
│   ├── FloatingInput[full_name]
│   ├── PhoneInput (+7 mask, auto-advance at 10 digits)
│   ├── OtpInput (6 digits, auto-submit)
│   ├── RegionSelect (bottom sheet on mobile)
│   └── NextButton
├── Step-Benefit1 (illustration + text, role-specific)
│   └── NextButton "Далее"
├── Step-RoleDetails (ROLE-SPECIFIC form — see fields above)
│   ├── FloatingInput / Select / ChipSelect per field
│   └── NextButton
├── Step-Benefit2 (illustration + text, role-specific)
│   └── NextButton "Далее"
├── Step-Agreement
│   ├── Checkbox[consent_terms]
│   ├── Checkbox[consent_data]
│   ├── PolicyLink
│   ├── Select[how_heard] (optional)
│   └── SubmitButton "Зарегистрироваться"
├── Step-Membership (optional, P11)
│   ├── InfoCard "О членстве в ТУРАН"
│   ├── TextArea[notes]
│   ├── SubmitButton "Подать заявку"
│   └── SkipLink "Пропустить"
└── Step-Success
    ├── SuccessIllustration
    ├── NextStepsText (role-specific)
    └── CabinetLink → role-specific cabinet
```

---

## F02 — Профиль фермы

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F02 |
| Route | `/cabinet/farm` |
| Auth | Authenticated farmer |
| User story | Фермер заполняет данные о ферме: название, тип содержания, система отёлов, поголовье по группам |
| RPCs | `rpc_get_my_context` (RPC-04) → display; `rpc_upsert_farm` (RPC-05) → save; `rpc_set_farm_activity_types` (RPC-05b) → activities; `rpc_upsert_herd_group` (RPC-06, already implemented) → herd |

### User Flow

```
1. Page load → rpc_get_my_context()
   - Returns: user info, organizations, farms, memberships
   - If no farm exists: show "create farm" form
   - If farm exists: show farm profile with edit capability

2. Farm Info section (always visible):
   - Display/Edit: farm name, region, shelter_type, calving_system
   - Display: membership level badge (registered | observer | ...)
   - Display: membership application status if pending

3. Activity Types section:
   - Checkboxes: Мясное скотоводство, Молочное, Овцеводство, Козоводство, Коневодство
   - On change: rpc_set_farm_activity_types({ p_farm_id, p_activity_type_ids[] })

4. Herd Groups section:
   - Table/cards showing current herd groups:
     | Группа | Порода | Голов | Ср. вес (кг) | Источник | Обновлено |
   - "Добавить группу" button → inline form:
     - Select: animal_category (from animal_categories table)
     - Input: head_count (required, int > 0)
     - Input: avg_weight_kg (optional, numeric)
     - Select: breed_id (from breeds table, optional)
     - Action: rpc_upsert_herd_group({
         p_organization_id, p_farm_id,
         p_animal_category_code, p_head_count,
         p_avg_weight_kg, p_breed_id
       })
   - Existing groups: click to edit (same form, p_herd_group_id set)

5. Save farm → rpc_upsert_farm({
     p_organization_id, p_farm_id,
     p_name, p_region_id, p_shelter_type, p_calving_system
   })
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_my_context` (RPC-04) | Page load | — (JWT) | `{ user_id, organizations[], farms[], memberships[] }` |
| `rpc_upsert_farm` (RPC-05) | Save farm info | `{ p_organization_id, p_farm_id?, p_name, p_region_id?, p_shelter_type?, p_calving_system? }` | `uuid (farm_id)` |
| `rpc_set_farm_activity_types` (RPC-05b) | Activity change | `{ p_farm_id, p_activity_type_ids[] }` | `{ inserted[], removed[] }` |
| `rpc_upsert_herd_group` (RPC-06) | Add/edit herd group | `{ p_organization_id, p_farm_id, p_animal_category_code, p_head_count, ... }` | `{ herd_group_id, ... }` |

### Reference Data (preloaded)

| Source | Data | Used for |
|--------|------|----------|
| `animal_categories` | Platform standard categories (10+) | Herd group category select |
| `breeds` | Breed catalog | Breed select (optional) |
| `regions` | Oblast → Район | Region select |
| `activity_types` | Activity type catalog | Activity checkboxes |

### Validation Rules

| Field | Rule | Error message |
|-------|------|---------------|
| farm name | Required, 2-200 chars | "Введите название фермы" |
| head_count | Required, integer > 0, max 50000 | "Укажите количество голов" |
| avg_weight_kg | Optional, 1-2000 if provided | "Вес должен быть от 1 до 2000 кг" |
| shelter_type | Optional (P11: gradual accumulation) | — |
| calving_system | Optional (P11: gradual accumulation) | — |

### UI Components

```
F02-FarmProfile
├── Header
│   ├── FarmName (editable)
│   └── MembershipBadge (registered | observer | заявка подана)
├── FarmInfoSection
│   ├── Select[region_id]
│   ├── Select[shelter_type] — "Тип содержания"
│   ├── Select[calving_system] — "Система отёлов"
│   └── SaveButton
├── ActivityTypesSection
│   ├── CheckboxGroup[activity_types]
│   └── AutoSave on change
├── HerdGroupsSection
│   ├── HerdGroupCard[] (per group)
│   │   ├── CategoryName + BreedName
│   │   ├── HeadCount + AvgWeight
│   │   ├── DataSourceBadge (manual | ai_extracted | erp)
│   │   └── EditButton
│   ├── AddGroupButton → InlineForm
│   │   ├── Select[animal_category]
│   │   ├── NumberInput[head_count]
│   │   ├── NumberInput[avg_weight_kg]
│   │   ├── Select[breed_id]
│   │   └── SaveButton
│   └── EmptyState "Добавьте группы животных"
└── Footer
    └── NavigateLink → /cabinet/vet/new "Сообщить о болезни"
```

---

## F10 — Сообщить о болезни

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F10 |
| Route | `/cabinet/vet/new` |
| Auth | Authenticated farmer |
| User story | Фермер сообщает о больном животном → создаётся vet case → перенаправляется на F11 |
| RPCs | `rpc_get_my_context` (RPC-04) → load farm/groups; `rpc_create_vet_case` (RPC-25, deployed) → create case |

### User Flow

```
1. Page load → rpc_get_my_context()
   - Populate farm selector (if multiple farms)
   - Populate herd group selector

2. Form:
   - Select: farm_id (auto-selected if single farm)
   - Select: herd_group_id (optional) — "Какая группа животных?"
     Options from herd_groups: "Бычки 6-12 мес (45 гол.)", "Коровы (80 гол.)", ...
   - TextArea: symptoms_text (required) — "Опишите что случилось"
     Placeholder: "Например: телёнок не ест второй день, температура 40°C, вялый"
   - **Severity: НЕ показывать фермеру** (CEO decision).
     Причины: (1) фермер не квалифицирован — всегда скажет "критическая",
     (2) AI определит точнее по симптомам, (3) D57 auto-escalation будет
     ложно срабатывать. Severity определяется AI при диагностике.
   - Input: affected_heads (optional) — "Сколько голов болеет?"

3. Submit → rpc_create_vet_case({
     p_organization_id,
     p_farm_id,
     p_herd_group_id,     -- nullable
     p_symptoms_text,
     p_severity: null,    -- ALWAYS null from cabinet. AI determines during diagnosis.
     p_affected_heads,    -- nullable
     p_created_via: 'cabinet_farmer'
   })

4. Success → redirect to /cabinet/vet/{case_id} (F11)
   - Toast: "Обращение создано. AI анализирует симптомы..."
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_my_context` (RPC-04) | Page load | — (JWT) | Farm/herd group data |
| `rpc_create_vet_case` (RPC-25) | Submit | `{ p_organization_id, p_farm_id, p_symptoms_text, p_severity?, p_herd_group_id?, p_affected_heads?, p_created_via }` | `{ vet_case_id, status, severity }` |

### Validation Rules

| Field | Rule | Error message |
|-------|------|---------------|
| farm_id | Required | "Выберите ферму" |
| symptoms_text | Required, 10-5000 chars | "Опишите симптомы подробнее (минимум 10 символов)" |
| affected_heads | Optional, int > 0 if provided | "Укажите число больше 0" |

### UI Components

```
F10-ReportSick
├── Header "Сообщить о болезни"
├── FarmSelector (auto-select if single)
├── HerdGroupSelector (optional, with "Не знаю / Вся ферма")
├── SymptomsTextArea
│   ├── Label "Опишите что случилось"
│   ├── Placeholder "Например: телёнок не ест второй день, температура 40°C, вялый"
│   └── CharCounter (10-5000)
├── AffectedHeadsInput (optional) — "Сколько голов болеет?"
├── SubmitButton "Отправить"
└── [NO SeveritySelector — AI determines severity from symptoms]
```

---

## F11 — Ветеринарный случай (детали)

### Meta

| Field | Value |
|-------|-------|
| Screen ID | F11 |
| Route | `/cabinet/vet/:caseId` |
| Auth | Authenticated farmer (owner) |
| User story | Фермер видит свой vet case: симптомы, AI-диагноз, рекомендации по лечению. Обновляется в реальном времени. |
| RPCs | `rpc_get_vet_case_detail` (NEW) → full case with diagnoses + recommendations; Realtime subscription on `platform_events` |

### User Flow

```
1. Page load:
   - Fetch vet case by ID (verify organization_id matches user's org)
   - Display case status, symptoms, severity
   - Display timeline of events (diagnoses, recommendations)

2. Case Header:
   - Status badge: Открыт | В работе | Решён | Эскалирован
   - Severity badge with color coding
   - Created date + "Создано через: кабинет" / "WhatsApp"
   - Herd group info (if set): "Бычки 6-12 мес, ферма Жаңа"

3. Symptoms section:
   - symptoms_text (farmer's original description)
   - symptoms_structured (if AI extracted): structured symptom chips
     Example: [Температура 40°C] [Отказ от корма] [Вялость]

4. Diagnosis section (read-only for farmer):
   - If AI diagnosis exists:
     Cards showing disease candidates with confidence:
     | Диагноз | Уверенность | Источник |
     | Пневмония | 78% | AI-анализ |
     | Диарея новорождённых | 45% | AI-анализ |
   - If no diagnosis yet: "AI анализирует симптомы..."

5. Recommendations section (read-only for farmer):
   - Cards per recommendation:
     ┌──────────────────────────────────────────────┐
     │ 💊 Лечение: Антибиотик (Энрофлоксацин)       │
     │ Способ: инъекция                              │
     │ Длительность: 5 дней                          │
     │ ⚠️ Дозировку определяет ветеринарный врач     │
     │ ⚠️ Период выведения: 14 дней                  │
     └──────────────────────────────────────────────┘
   - **P-AI-4 CRITICAL:** NEVER display numeric dosage values.
     Always show: "Дозировку определяет ветеринарный врач"
   - If withdrawal_period > 0: warning banner
     "⚠️ Введено ограничение на продажу на 14 дней (до DD.MM.YYYY)"

6. Escalation notice (if severity=critical):
   - Banner: "Случай передан эксперту-ветеринару ТУРАН"
   - ConsultationRequest status (если создан)

7. Realtime updates:
   - Subscribe to platform_events WHERE entity_id = caseId AND organization_id = user's org
   - On new event: refetch case data via rpc_get_vet_case_detail, animate new entry in timeline
   - **RLS REQUIREMENT:** platform_events MUST have RLS policy for SELECT:
     `organization_id = ANY(fn_my_org_ids())`. DB Agent must verify/create this policy.
     Without it, farmer could see events from other organizations via Realtime subscription.
```

### Data Requirements

| RPC | When called | Input | Output |
|-----|------------|-------|--------|
| `rpc_get_vet_case_detail` (NEW) | Page load | `{ p_organization_id, p_vet_case_id }` | Full case: header + diagnoses[] + recommendations[] + health_restrictions[] |
| `platform_events` subscription | Realtime | Filter: `entity_id = caseId` | Live updates: new diagnosis, recommendation, escalation |

**IMPORTANT (CEO decision):** `rpc_get_ai_farm_context` is SECURITY DEFINER for service_role (AI Gateway).
Web cabinet uses JWT auth → CANNOT call AI Gateway RPCs. A dedicated `rpc_get_vet_case_detail`
must be created in d04_vet.sql with JWT-compatible auth (checks `fn_my_org_ids()` for ownership).

**`rpc_get_vet_case_detail` return structure:**
```json
{
  "case_id": "uuid",
  "farm_id": "uuid",
  "farm_name": "text",
  "herd_group": { "id": "uuid", "category_name": "text", "head_count": "int" },
  "status": "open | in_progress | resolved | escalated",
  "severity": "mild | moderate | severe | critical",
  "symptoms_text": "text",
  "symptoms_structured": [{ "symptom_code": "text", "confidence": "int" }],
  "affected_heads": "int?",
  "created_at": "timestamptz",
  "created_via": "cabinet_farmer | ai_whatsapp | expert_manual",
  "diagnoses": [{
    "id": "uuid",
    "disease_name": "text",
    "confidence_pct": "int",
    "source": "expert_created | protocol_auto | ai_rag | expert_confirmed | expert_override",
    "created_at": "timestamptz"
  }],
  "recommendations": [{
    "id": "uuid",
    "type": "medication | isolation | nutrition | monitoring | specialist",
    "treatment_name": "text?",
    "application_method": "text?",
    "duration_days": "int?",
    "dosage_note": "Дозировку определяет ветеринарный врач",
    "withdrawal_days": "int?",
    "notes": "text?",
    "source": "expert_created | protocol_auto | ai_rag | expert_confirmed | expert_override",
    "created_at": "timestamptz"
  }],
  "health_restrictions": [{
    "restriction_type": "withdrawal | quarantine",
    "reason": "text",
    "expires_at": "timestamptz"
  }],
  "consultation_request": {
    "id": "uuid?",
    "status": "text?",
    "expert_name": "text?"
  }
}
```

### Compliance Rules (P-AI-4, D61)

| Rule | Implementation |
|------|----------------|
| No numeric dosage display | UI MUST NOT render any `dosage_per_kg`, `dosage_ml` or similar numeric fields. Show only `dosage_note` which always says "Дозировку определяет ветеринарный врач" |
| Withdrawal period warning | If `withdrawal_days > 0`: show warning banner with calculated end date |
| Health restriction notice | If active `health_restriction` exists for this org: show persistent banner on F02 and F11 |

### UI Components

```
F11-VetCaseDetail
├── Header
│   ├── BackLink → /cabinet/vet
│   ├── CaseTitle "Ветеринарный случай #NNN"
│   ├── StatusBadge (open | in_progress | resolved | escalated)
│   └── SeverityBadge (mild=green | moderate=yellow | severe=red | critical=dark red)
├── CaseInfoSection
│   ├── CreatedDate + CreatedVia badge
│   ├── FarmName + HerdGroupName (if set)
│   └── AffectedHeads (if set)
├── SymptomsSection
│   ├── SymptomsText (farmer's description, blockquote style)
│   └── StructuredSymptoms (chips, if AI extracted)
├── DiagnosisSection
│   ├── DiagnosisCard[] (per diagnosis)
│   │   ├── DiseaseName
│   │   ├── ConfidenceBar (0-100%)
│   │   └── SourceBadge (AI-анализ | Эксперт)
│   └── EmptyState "AI анализирует симптомы..." (with spinner)
├── RecommendationsSection
│   ├── RecommendationCard[] (per recommendation)
│   │   ├── TypeIcon (💊 medication | 🔬 monitoring | 🏥 specialist)
│   │   ├── TreatmentName
│   │   ├── ApplicationMethod
│   │   ├── DurationDays
│   │   ├── DosageWarning "Дозировку определяет ветеринарный врач"
│   │   └── WithdrawalWarning (if withdrawal_days > 0)
│   └── EmptyState "Рекомендации будут добавлены после анализа"
├── EscalationBanner (if status=escalated)
│   └── "Случай передан эксперту-ветеринару ТУРАН"
├── WithdrawalBanner (if health_restriction active)
│   └── "⚠️ Ограничение на продажу до DD.MM.YYYY"
└── Timeline (chronological events)
    ├── TimelineEntry[] (created, diagnosed, recommendation added, ...)
    └── RealtimeIndicator (live dot when subscribed)
```

---

## Cross-Screen Data Flow

```
F01 (Register)
  │ Creates: User, Organization, Farm (auto), MembershipApplication
  │ Returns: org_id, farm_id
  ▼
F02 (Farm Profile)
  │ Reads: rpc_get_my_context → organizations, farms, memberships, herd_groups
  │ Creates/Updates: Farm details, HerdGroups, ActivityTypes
  │ Farmer fills gradually (P11)
  ▼
F10 (Report Sick)
  │ Reads: farms + herd_groups from context
  │ Creates: VetCase via rpc_create_vet_case
  │ Returns: vet_case_id
  ▼
F11 (Vet Case Detail)
  │ Reads: rpc_get_vet_case_detail (JWT-compatible, NOT rpc_get_ai_farm_context)
  │ Subscribes: platform_events for live updates
  │ Displays: AI diagnosis, treatment recommendations (NO dosage numbers)
```

---

## RPC Implementation Status for Slice 1

| RPC | Screen | Status | File | Notes |
|-----|--------|--------|------|-------|
| RPC-01 `rpc_register_organization` | F01 | ❌ NOT IMPLEMENTED | d01_kernel.sql | DB Agent must create |
| RPC-02 `rpc_submit_membership_application` | F01 | ❌ NOT IMPLEMENTED | d01_kernel.sql | DB Agent must create |
| RPC-04 `rpc_get_my_context` | F01, F02, F10 | ❌ NOT IMPLEMENTED | d01_kernel.sql | DB Agent must create |
| RPC-05 `rpc_upsert_farm` | F02 | ❌ NOT IMPLEMENTED | d01_kernel.sql | DB Agent must create |
| RPC-05b `rpc_set_farm_activity_types` | F02 | ❌ NOT IMPLEMENTED | d01_kernel.sql | DB Agent must create |
| RPC-06 `rpc_upsert_herd_group` | F02 | ✅ Deployed | d07_ai_gateway.sql | Already works |
| RPC-25 `rpc_create_vet_case` | F10 | ✅ Deployed | d07_ai_gateway.sql | Already works |
| RPC-26 `rpc_add_vet_diagnosis` | (AI/Expert) | ✅ Deployed | d04_vet.sql | Deployed |
| RPC-27 `rpc_add_vet_recommendation` | (AI/Expert) | ✅ Deployed | d04_vet.sql | Deployed |
| RPC-40 `rpc_start_ai_conversation` | (AI init) | ❌ NOT IMPLEMENTED | d01_kernel.sql | DB Agent — needed for Backend |
| NEW `rpc_get_vet_case_detail` | F11 | ✅ Deployed | d04_vet.sql | JWT-compatible, NOT AI Gateway RPC |
| RLS policy on `platform_events` | F11 Realtime | ⚠️ VERIFY | d01_kernel.sql | Must filter by `organization_id = ANY(fn_my_org_ids())` for SELECT |

---

## Open Questions for CEO

1. ~~**F01 Step 3 (Membership):**~~ **RESOLVED.** Опциональна (P11 Gradual Accumulation). Фермер регистрируется, пользуется бесплатным функционалом (vet, ration quick mode), подаёт заявку когда увидит ценность. Конверсия выше.

2. ~~**F02 Activity Types:**~~ **RESOLVED.** CEO: "давай пока так". Slice 1 список: Мясное скотоводство, Молочное, Овцеводство, Козоводство, Коневодство. Расширяется по P7 (additive) в будущих слайсах.

3. ~~**F10 Severity:**~~ **RESOLVED.** CEO decision: severity полностью убран из формы. Причины: (1) фермер не квалифицирован, (2) AI точнее по симптомам, (3) D57 auto-escalation ложно срабатывает при farmer-set "critical". Severity = null → AI определяет.

4. ~~**F11 Read RPC:**~~ **RESOLVED.** CEO confirmed: `rpc_get_vet_case_detail` (new, JWT-compatible). `rpc_get_ai_farm_context` is service_role only — web cabinet cannot use it.

5. ~~**Realtime на F11:**~~ **RESOLVED.** CEO confirmed: подписка на `platform_events` — правильный подход. Добавлено требование RLS policy для SELECT по `organization_id`.

6. ~~**Loading/offline:**~~ **RESOLVED.** CEO feedback: добавлена секция UX (skeleton screens, retry, offline banner, form preservation, performance budget).

7. ~~**F01 membership_type:**~~ **RESOLVED.** Hardcode `'associate'` корректен. Добавлен комментарий: новые члены всегда начинают как associate.
