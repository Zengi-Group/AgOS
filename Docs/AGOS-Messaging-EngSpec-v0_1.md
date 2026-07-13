# Eng-Spec — Внутриплатформенное общение (Messaging Channels)

> In-repo engineering spec (detailed intent). Тонкий синтез — в Linear ARS-221.
> Graphify индексирует этот файл — имена сущностей/RPC/таблиц держим совпадающими с SQL-токенами.
> Apply order: d01 → d02 → d03 → d04 → d05 → d07 → d08 → d09 → d10 → d11 → **d12**.

- **Linear feature:** ARS-221 (родитель-эпик ARS-112 «Уведомления & коммуникации»)
- **Linear tasks:** ARS-222 (эта спека) · ARS-223 (DB) · ARS-224 (Backend/события) · ARS-225 (UI кабинет) · ARS-226 (UI admin)
- **Canon domain owner:** ЭТА спека (новый домен `messaging`). Секции Dok1/Dok3/Dok4/Dok6 — DERIVED, указывают сюда.
- **Status:** draft
- **Проект (Linear):** Платформа & инфраструктура

---

## 0. Что это и что НЕ это

Внутриплатформенное «общение» **каналами** (модель Kaspi / супергруппы), НЕ свободный Telegram-чат. Три оси:

| Ось | Тип канала | MVP? |
|-----|-----------|------|
| фермер/МПК ↔ админ | `support` (двусторонний) | **да** |
| система → фермер/МПК | `system_broadcast` (read + история) | схема да, RPC/UI — слайс 2 |

**НЕ дублирует `notifications`** (P4): `notifications` остаётся транспортом доставки (in_app/push «у вас новое сообщение»), сам контент живёт в `comm_messages`.

### ⚠️ Дельта замысел↔код (важно для UI)
Раздел «Сообщения» в кабинете **уже построен** (ARS-231, решение CEO R-19 от 2026-07-11) на Chatscope по паттерну Kaspi «каждый модуль — собеседник»: треды `consultant` (AI) · `market` · `farm` · **`turan`**. Сейчас все треды — **проекции событий (мок)**, не реальная переписка. Ключевое: тред **`turan`** уже несёт CTA «Написать в TURAN — ответим в течение 1 рабочего дня» (`h.writeTuran`) и route `turan` (`/cabinet/turan`) = «форма обращения».
- **Фермерская сторона support-канала = тред `turan`** (`/cabinet/thread/turan`) + форма обращения (`/cabinet/turan`). Не новый экран — **привязка существующего к реальным RPC** (замена мок-`turanThreadMsgs` в части переписки на `comm_messages`; ассоциативные дайджесты — цены/членство/новости — сохраняем).
- Файлы: `src/pages/cabinet/shell/screens/{MessagesScreen,ThreadScreen}.tsx`, `data/threads.ts` (`turanThreadMsgs`), `nav.ts` (routes `messages`/`thread`/`turan`).

---

## 1. Data model (P1 — first) → канон `d12_messaging.sql`

Все таблицы: PK `uuid gen_random_uuid()`, timestamps `timestamptz` (UTC), soft-delete `is_active`/`is_deleted`, идемпотентно.

### 1.1 `comm_channels` — контейнер-канал
| Колонка | Тип | Заметки |
|---------|-----|---------|
| id | uuid PK | |
| organization_id | uuid NOT NULL → organizations(id) | клиентская орг канала |
| channel_type | text NOT NULL CHECK `('support','system_broadcast')` | FSM-безопасно text+CHECK (P6) |
| status | text NOT NULL default `'active'` CHECK `('active','archived')` | см. §1.5 — решение по `closed` |
| title | text | для support = имя орг (денорм для inbox), для broadcast = заголовок канала |
| last_message_at | timestamptz | денорм, сортировка inbox |
| created_by | uuid → users(id) | null для системных |
| is_active | boolean NOT NULL default true | soft-delete |
| created_at / updated_at | timestamptz | |

- **Инвариант:** ровно один `active` `support`-канал на орг (partial unique index на `organization_id` where `channel_type='support' and is_active`). Это опора `rpc_get_or_create_support_channel` (get-or-create).
- **P2 ownership:** создаёт — фермер/МПК (через get-or-create) или админ; авторитет статуса — админ (архивирование).
- **P12:** current-state, история диалога — в `comm_messages` (append-only).

### 1.2 `comm_participants` — участники (RLS + непрочитанное)
| Колонка | Тип | Заметки |
|---------|-----|---------|
| id | uuid PK | |
| channel_id | uuid NOT NULL → comm_channels(id) | |
| user_id | uuid NOT NULL → users(id) | |
| role | text NOT NULL CHECK `('member','admin')` | member = сторона орг; admin = техподдержка |
| last_read_at | timestamptz | курсор прочтения → счётчик непрочитанного |
| joined_at | timestamptz NOT NULL default now() | |
| is_active | boolean NOT NULL default true | |

- UNIQUE `(channel_id, user_id)`.
- **Все активные члены орг** — участники `role='member'` support-канала (заводятся лениво при первом входе/сообщении). Каждый может писать (решение G2).

### 1.3 `comm_messages` — сообщения (свободный текст)
| Колонка | Тип | Заметки |
|---------|-----|---------|
| id | uuid PK | |
| channel_id | uuid NOT NULL → comm_channels(id) | |
| organization_id | uuid NOT NULL → organizations(id) | денорм для RLS |
| author_user_id | uuid → users(id) | **null = система** |
| author_actor_type | text NOT NULL CHECK `('farmer','admin','expert','system')` | в тон `platform_events.actor_type` |
| body | text | свободный текст |
| attachments | jsonb default `'[]'` | список вложений (см. §1.4) |
| is_deleted | boolean NOT NULL default false | soft-delete сообщения |
| created_at | timestamptz NOT NULL default now() | append-only, без updated_at |

### 1.4 Вложения (MVP)
`attachments jsonb` = массив `[{storage_path, mime, size, width?, height?}]`. Файлы — в Supabase Storage (private bucket `comm-attachments`), путь namespaced `{organization_id}/{channel_id}/{uuid}`. RLS бакета — по org. Загрузка через существующий upload-механизм фронта; RPC хранит только метаданные.

### 1.5 Статус канала — РЕШЕНО (вопрос A)
`status='closed'` **не вводим** (реш. CEO 2026-07-13). Support-канал — постоянный диалог (Kaspi-стиль), не тикет. Только `active`/`archived`; новое сообщение в архивный канал автоматически возвращает его в `active` (логика в `rpc_send_message`).

---

## 2. RPC (Dok 3 contract) — `rpc_` префикс, SECURITY DEFINER, аддитивно (P7)

`organization_id` выводится из канала/членства и проверяется в каждом вызове. Регистрация имён в `rpc_name_registry`.

| RPC | Сигнатура (набросок) | Делает |
|-----|----------------------|--------|
| `rpc_get_or_create_support_channel` | `(p_organization_id uuid) → comm_channels` | вернуть/создать единственный active support-канал орг; добавить вызывающего в participants (member) |
| `rpc_send_message` | `(p_channel_id uuid, p_body text, p_attachments jsonb default '[]') → comm_messages` | вставить сообщение; проставить `author_actor_type` по роли; обновить `last_message_at`; **publish** `platform_events` `comm.message.created` |
| `rpc_list_channels` | `() → setof` | админ → все `support`-каналы (inbox, сорт по last_message_at, непрочитанные сверху); фермер/МПК → каналы своих орг |
| `rpc_list_messages` | `(p_channel_id uuid, p_before timestamptz default null, p_limit int default 50) → setof comm_messages` | тред с пагинацией |
| `rpc_mark_channel_read` | `(p_channel_id uuid) → void` | `last_read_at = now()` для участника |
| `rpc_archive_channel` | `(p_channel_id uuid) → comm_channels` | админ: `status='archived'` |

**Слайс 2 (broadcast/рассылка, admin):**
| RPC | Сигнатура (набросок) | Делает |
|-----|----------------------|--------|
| `rpc_create_broadcast` | `(p_title text, p_recipients uuid[] \| null, p_scope text) → comm_channels` | админ создаёт `system_broadcast`-канал; `p_scope in ('all','selected')`; при `selected` добавляет `p_recipients` в participants, при `all` — материализует по фильтру аудитории |
| `rpc_post_broadcast` | `(p_channel_id uuid, p_body text, p_attachments jsonb) → comm_messages` | пост в broadcast; событие `comm.message.created` → notif всем участникам |

- Web и AI (если понадобится) вызывают ОДНИ и те же RPC — без дублирования.
- Роль вызывающего (member/admin) определяет ветку в `rpc_list_channels` и `author_actor_type`.

---

## 3. Events (Dok 4)

- **Новое событие:** `comm.message.created` (namespace domain.entity.action). Payload: `{channel_id, message_id, organization_id, author_user_id, author_actor_type, preview}` (preview — короткий срез, НЕ полный текст).
- **Консьюмер:** channel-agnostic диспетчер уведомлений (ARS-142). Новый notif-шаблон `new_message` (in_app + push), канал по `user_notification_preferences`.
- **Адресаты:** все активные участники канала, **КРОМЕ автора**.
- **Инвариант notif (d01_kernel.sql:1102):** template-only сохраняется — `notifications.params` несёт только `{channel_id, preview}` и deep-link, полный контент НЕ дублируется.

---

## 4. UI contract (Dok 6)

Точное «где живёт» (иконка/пункт меню) НЕ фиксируется здесь — собирается на старте UI-задач из graphify. Контракт:

### 4.1 Кабинет фермера/МПК — существующий раздел «Сообщения» (РЕШЕНО, вопрос B)
Клиентская сторона живёт **в существующем разделе «Сообщения»** (не новый пункт) — тред **`turan`** становится реальным двусторонним support-каналом (реш. CEO 2026-07-13).
- Лента `/cabinet/thread/turan`: реальные `comm_messages` (свои/админ) + сохранённые ассоциативные дайджесты (цены/членство/новости) как системный контент; вложения-превью; авто mark-read при открытии (`rpc_mark_channel_read`).
- Отправка через форму обращения `/cabinet/turan` (`writeTuran`): свободный текст + загрузка фото → `rpc_send_message`.
- Список тредов `MessagesScreen`: превью/unread треда `turan` из реального канала.
- Тёплая палитра, PhIcon, Chatscope kit (как в ARS-231). Merge-стратегия «дайджест + переписка» в одном треде — деталь UI-задачи.
- RPC: `rpc_get_or_create_support_channel` → `rpc_list_messages` → `rpc_send_message` → `rpc_mark_channel_read`.

### 4.2 Admin-консоль — новый раздел «Обращения» (`[data-shell]`, нейтральная палитра, lucide)
Раздел с двумя режимами (реш. CEO 2026-07-13):
- **(MVP) Обращения / inbox:** все support-каналы, сорт по `last_message_at`, непрочитанные сверху; открытие треда, ответ конкретной орг/человеку свободным текстом + вложения, архивирование.
- **(Слайс 2) Рассылка:** создать broadcast, выбрать аудиторию — **конкретные люди или все**; отправить объявление. RPC `rpc_create_broadcast` / `rpc_post_broadcast`.
- `useSetTopbar` — иконка = как в Sidebar admin.
- RPC (MVP): `rpc_list_channels` (admin) → `rpc_list_messages` → `rpc_send_message` → `rpc_archive_channel`.

---

## 5. Slices → Tasks

| Task | Tier | Acceptance |
|------|------|-----------|
| ARS-222 · эта eng-spec | semantic | slice закоммичен; вопросы A/B решены; ARS-221 → Ready for Dev |
| ARS-223 · DB `d12_messaging.sql` | semantic | cross_check.sh зелёный; RLS-тест орг A ≠ орг B; RPC создают/читают канал+сообщения |
| ARS-224 · события + notif-транспорт | mechanical | send → участники (кроме автора) получают in_app/push; выкл. канал в prefs не шлётся |
| ARS-225 · UI кабинет: тред `turan` → реальный канал | semantic | фермер пишет с фото из формы обращения, видит ответ админа в треде TURAN, unread корректен (preview) |
| ARS-226 · UI admin: раздел «Обращения» (inbox) | semantic | админ отвечает конкретной орг, архивирует; фермер получает уведомление (preview) |
| ARS-227 · admin рассылка (broadcast) — **слайс 2** | semantic | админ создаёт рассылку, выбирает всех/выбранных, отправляет; адресаты получают в «Сообщениях» + notif |

Порядок: 222 → 223 → 224 → (225 ∥ 226) → 227 (слайс 2).
Слайс 2 также добавляет broadcast-RPC (§2) и UI treда `system_broadcast` в кабинете (отдельный собеседник или в TURAN — решается в слайсе 2).

---

## 6. Conflict / invariant check (G1 inputs)

- **P7 (аддитивно):** новый домен, новые таблицы/RPC — существующие сигнатуры не трогаем. ✅
- **FINAL schema:** не модифицируем — только добавляем `d12`. ✅
- **RLS / кросс-орг:** обязательна на всех трёх таблицах; фермер/МПК видит только каналы своей орг, админ — все `support`. `organization_id` в каждом RPC. ⚠️ главный риск утечки — покрыть тестом.
- **notif template-only (d01:1102):** не нарушаем — контент в `comm_messages`, notif несёт preview+link. ✅
- **Art. 171:** не применимо (не ценообразование/торговля). ✅
- **DECISIONS_LOG:** конфликтующих записей не найдено (green-field домен).

---

## 7. Verification (G3 inputs)

- `cross_check.sh` зелёный после d12.
- RLS-тесты: пользователь орг A НЕ читает канал/сообщения орг B (SELECT возвращает 0).
- FSM-тест: archived канал + новое сообщение → active.
- Событийный тест: `rpc_send_message` публикует `comm.message.created`; диспетчер шлёт всем кроме автора.
- Preview-пруф обеих UI-задач.
- `graphify update .` после кода; сверка reality↔intent, расхождения → IMPL_DEBT.md.
