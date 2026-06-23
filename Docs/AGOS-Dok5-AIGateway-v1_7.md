# AGOS AI Gateway Architecture (Dok 5)

**Project:** TURAN Agricultural Operating System  
**Version:** 1.7  
**Date:** 6 March 2026  
**Status:** Pre-development baseline — Schema consolidated (7 files). Gate 0 passed. Ready for implementation.  
**Depends on:** Dok 1 (v1.8), Dok 3 (RPC Catalog v1.4), Dok 4 (Event Bus v1.1)  
**Authors:** Arshidin (CEO/Domain Expert), Claude (CTO/Architect)

**Changelog v1.6 → v1.7 (Gate 0 Fixes 2026-03-06):**

| # | Дефект | Тип | Исправление |
|---|--------|-----|-------------|
| L-2 | §3.3.1 | 🔴 | Advisory lock в /chat flow — тот же root cause что L-NEW-2. Заменён на insert_user_message_dedup (ON CONFLICT). Код и объяснение исправлены |
| D-4 | §15 (новый) | 🔴 | Embedding Worker добавлен: embedding_queue + 3 SQL функции в d07. Python-реализация, интеграция в FastAPI, мониторинг |

**Changelog v1.5 → v1.6 (Schema Consolidation 2026-03-05):**

| # | Дефект | Тип | Исправление |
|---|--------|-----|-------------|
| D138 | §Deployment | 🔵 | Миграции 011/012/013 поглощены консолидированными файлами. "apply before implementation" устарело |
| L-NEW-2 | §12.1 | 🔴 | Proactive dispatch: убран advisory lock (`try_lock_conversation`). Правильный механизм: SKIP LOCKED в `claim_pending_notifications` |
| D133 | §6 | 🔵 | `get_active_prompt` tool добавлен: системный промпт из таблицы `ai_prompts` (не хардкод) |
| D134 | §0 | 🔵 | `rpc_name_registry` как canonical source. Все tool calls в §6 выверены по таблице |
| C-NEW-7 | §6/12 | 🟠 | `rpc_start_production_plan`: добавлен `p_actor_id` (уже в d05_ops_edu.sql, документируем явно) |
| NEW | §6 | 🔵 | Tool catalog: добавлены полные параметры для 22 AI Gateway RPCs из d07_ai_gateway.sql |

**Changelog v1.4 → v1.5 (Architecture Audit 2026-03-05):**

| # | Defect | Тип | Исправление |
|---|--------|-----|-------------|
| C-NEW-1 | §7.2 | 🔴 | EXTRACTION_RULES: русские коды (БМ1, БМ2, ТМ, КВ) → английские DB-коды (BULL_CALF, STEER, HEIFER_YOUNG, COW...) |
| C-NEW-2 | §6 | 🔴 | 22 missing RPCs созданы в migration 011_ai_rpc_catalog.sql (rpc_get_ai_farm_context, rpc_upsert_herd_group, rpc_create_vet_case, и др.) |
| C-NEW-5 | §9.2 | 🔴 | detect_and_cache_language: прямой UPDATE → rpc_update_conversation_language (P-AI-1 соблюдён) |
| C-NEW-6 | §9.2 | 🔴 | load_user_profile → query public.users (таблица profiles не существует) |
| C-NEW-7 | §12.2 | 🔴 | rpc_start_production_plan: добавлен p_actor_id для service_role compat (migration 012) |
| C-NEW-3 | Dok 3 | 🔴 | RPC-41 deprecated в Dok 3 v1.4 (two-run confirmation = canonical, §7) |
| C-NEW-4 | migrations | 🔴 | Audit trigger fn_audit_from_platform_event создан в migration 013 |

**Changelog v1.3 → v1.4:**

| # | Тип | Исправление |
|---|-----|-------------|
| C-1..C-8 | 🔴 | Дефекты из аудита 009_patch_ai.sql (закрыты в v1.4) |
| L-3 | 🟠 | detect_language_pure: чистая функция без DB-записи для error handler |
| D117 | 🔵 | Two-run confirmation flow: Extraction ≠ Write (заменяет RPC-41 из Dok 3) |

**Changelog v1.2 → v1.3:**

| # | Тип | Исправление |
|---|-----|-------------|
| R-6 | 🔴 | Proactive poller: `while True` → pg_cron + `SKIP LOCKED` batch 50 (v1.6: advisory lock убран из proactive_dispatch — L-NEW-2) |
| R-7 | 🔴 | Dedup: `SELECT+INSERT` → атомарный `INSERT ON CONFLICT DO NOTHING RETURNING` |
| R-8 | 🟠 | Quality metrics: negative_feedback detection + escalation_rate |
| R-9 | 🟠 | farm_context: TTL 5 мин + Event Bus invalidation при внешних изменениях |
| R-10 | 🟠 | WhatsApp templates: preferred_language из профиля / detected_language из сессии |
| R-11 | 🟠 | System prompts: таблица `ai_prompts` с версионированием, `prompt_version` в AIMessage |

**Changelog v1.1 → v1.2:**

| # | Тип | Исправление |
|---|-----|-------------|
| R-1 | 🔴 | Confirmation race condition: advisory lock на conversation перед run |
| R-2 | 🔴 | sanitize_input: regex-фильтр убран как основная защита, заменён damage radius + output validation |
| R-3 | 🔴 | parse_confirmation: regex → Claude Haiku с поддержкой "Да, но..." и "Не 80, а 85" |
| R-4 | 🟠 | Role routing: primary_role + secondary_intent, timeout на role_was_overridden |
| R-5 | 🟠 | Context summarization: rolling incremental summary вместо one-time |

**Changelog v1.0 → v1.1:** C-1..C-3, S-1..S-6, M-1..M-4, O-1, O-3..O-5 (см. v1.1)

---

## 0. Как читать этот документ

**Для Python-разработчика (AI Engineer):**
- Раздел 3 = структура LangGraph графа — это основа реализации
- Раздел 6 = каталог tools — копипаст в код
- Раздел 7 = extraction pipeline — точные правила без интерпретации
- Раздел 8 = compliance filter — нарушение = юридический риск
- Раздел 11 = error handling — реализовать до happy path

**Для vibecoding (Cursor/Claude Code):**
- Gateway вызывает те же RPC что и веб. Нет "AI-only" логики в БД.
- Все writes через validated RPC. AI никогда не пишет в таблицы напрямую.
- organization_id присутствует в КАЖДОМ вызове — это не опция.
- Confirmation flow — двухходовой (два webhook = два graph run). Смотри раздел 3.4.
- **SQL canonical names:** все `supabase.rpc("...")` вызовы должны совпадать с `sql_name` в `rpc_name_registry`. При расхождении — SQL выигрывает (D-NEW-A).
- **Proactive dispatch:** `try_lock_conversation` НЕ используется в `/proactive/dispatch`. SKIP LOCKED достаточно (L-NEW-2).

**Notation:**
- `→` = поток данных
- `[NODE]` = LangGraph узел
- `tool:name` = Claude API tool
- `rpc:name` = Supabase PostgreSQL function

---

## 1. Обзор и принципы

### 1.1. Позиция в архитектуре

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: INTELLIGENCE                                       │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  AI GATEWAY  (Python FastAPI + LangGraph)            │   │
│  │                                                       │   │
│  │  Inbound:  WhatsApp Webhook → Agent → RPC → DB       │   │
│  │  Outbound: DB Polling → Agent → WhatsApp/In-app      │   │
│  │                                                       │   │
│  │  Роли: zootechnician | vet | consultant | trading    │   │
│  └─────────────────────────────────────────────────────┘   │
│                         ↑↓                                  │
│                  Supabase RPCs (SECURITY DEFINER)           │
└─────────────────────────────────────────────────────────────┘
```

### 1.2. Ключевые принципы (нарушение = дефект)

| # | Принцип | Следствие |
|---|---------|-----------|
| P-AI-1 | AI — интерфейс, не источник данных | Все writes через RPC, AI не знает SQL |
| P-AI-2 | organization_id в каждом запросе | Фермер A никогда не видит данные фермера B |
| P-AI-3 | Extraction ≠ Write | Сначала извлечь → сохранить в DB → спросить → в следующем run записать |
| P-AI-4 | Dosages only from DB | Никогда не генерировать дозировки из головы (D61) |
| P-AI-5 | Compliance filter before send | Каждый ответ проходит через фильтр |
| P-AI-6 | Service account, not user JWT | Gateway аутентифицируется как сервис, не как пользователь |
| P-AI-7 | Stateless service, stateful DB | Весь state — в AIConversation/AIMessage, не в памяти процесса |
| P-AI-8 | User message saved first | Сохранить входящее сообщение ДО обработки — чтобы не потерять при сбое |

---

## 2. Архитектурная диаграмма (полный поток)

### 2.1. Inbound (фермер пишет → система отвечает)

```
[WhatsApp / Web]
      │
      │ webhook (POST /webhook/{provider})
      ▼
[Webhook Adapter Layer]          ← провайдер-агностик
      │
      │ normalized IncomingMessage
      ▼
[FastAPI: POST /chat]
      │
      ├─→ [dedup_check]           message_id уже обработан? → 200 OK, стоп  ← NEW S-5
      │
      ├─→ [resolve_user]          phone → user_id, org_id
      │
      ├─→ [save_user_message]     AIMessage(role=user) → DB сразу  ← NEW P-AI-8
      │
      ├─→ [load_context]          AIConversation + farm_context_snapshot
      │                           + confirmation_pending?  ← NEW C-1
      │
      ├─→ [LangGraph Agent]
      │         │
      │         ├─→ [check_confirmation]  confirmation_pending=true? → confirm_handler  ← NEW C-1
      │         │
      │         ├─→ [route_role]          auto-detect + override check
      │         │
      │         ├─→ [sync_role_to_db]     AIConversation.current_role → Supabase  ← NEW O-3
      │         │
      │         ├─→ [agent_loop]          Claude API + tools
      │         │         │
      │         │         ├─→ tool:search_knowledge   → rpc.search_knowledge_chunks
      │         │         ├─→ tool:get_farm_context   → rpc.get_ai_farm_context
      │         │         ├─→ tool:update_herd_group  → rpc.upsert_herd_group
      │         │         ├─→ tool:create_vet_case    → rpc.create_vet_case
      │         │         ├─→ tool:create_batch_draft → rpc.create_batch
      │         │         └─→ ... (полный каталог в разделе 6)
      │         │
      │         ├─→ [extract_entities]    AIMessage.extracted_entities
      │         │
      │         ├─→ [save_confirmation_payload]  pending → AIConversation  ← NEW C-1
      │         │
      │         └─→ [compliance_filter]  проверка перед отправкой
      │
      ├─→ [save_assistant_message]  AIMessage(role=assistant)
      │
      └─→ [send_response]         → WhatsApp API / WebSocket
```

### 2.2. Outbound (система инициирует → фермер получает)

```
[Scheduled Job / Event Bus]
      │
      │ ProactiveAlert | Notification (status=pending)
      ▼
[FastAPI: POST /proactive/send]
      │
      ├─→ [load_target_users]     users with pending alerts
      │
      ├─→ [compose_message]       agent в роли zootechnician/vet (по типу alert)
      │
      ├─→ [compliance_filter]     эпидемия = только approved alerts
      │
      └─→ [send_outbound]         → WhatsApp Template API + in-app Notification
```

---

## 3. LangGraph Graph Design

### 3.1. Решение по checkpointer (C-2 fix)

**Решение D116:** LangGraph используется **без встроенного checkpointer**.

Каждый webhook-вызов = новый граф с нуля. Весь state загружается из Supabase в начале каждого run и сохраняется в конце. Это соответствует P-AI-7 (Stateless service, stateful DB).

```
WHY NOT LangGraph PostgreSQL checkpointer:
  + Было бы удобно, но добавляет вторую схему хранения state (LangGraph schema ≠ AGOS schema)
  + Усложняет деплой и дебаг
  + Наши данные уже в Supabase — незачем дублировать

WHY stateless graph:
  + Соответствует P-AI-7
  + Суперпростой деплой — любое количество инстансов без coordination
  + State восстанавливается из AIConversation/AIMessage — единственный источник правды
```

### 3.2. State Schema

```python
from typing import TypedDict, Literal, Optional, List
from datetime import datetime, timezone

class AgentState(TypedDict):
    # --- Identity (immutable within run) ---
    conversation_id: str               # AIConversation.id
    user_id: str                        # User.id
    organization_id: str                # Organization.id — NEVER from LLM input
    channel: Literal["whatsapp", "web", "mobile"]
    
    # --- Role ---
    current_role: Literal["zootechnician", "vet", "consultant", "trading_agent"]
    role_was_overridden: bool           # True если фермер явно выбрал командой
    role_override_message_count: int    # R-4: счётчик сообщений с момента override
    secondary_intent: Optional[str]     # R-4: вторичная роль если сообщение мультидоменное
    
    # --- Messages (loaded from AIMessage history, max last N) ---
    messages: List[dict]                # [{role, content, tool_calls?}] — Claude API format
    raw_input: str                      # Оригинальный текст текущего сообщения
    incoming_message_id: str            # Для dedup (WhatsApp message_id)
    
    # --- Farm Context ---
    farm_context: dict                  # farm_context_snapshot (структура в разделе 5)
    active_farm_id: Optional[str]       # Если org имеет несколько ферм — уточнённая  ← NEW S-3
    
    # --- Confirmation State (persisted to/from AIConversation) ---
    # ВАЖНО: эти поля загружаются из DB в начале run, не хранятся в памяти между runs
    confirmation_pending: bool
    confirmation_payload: Optional[dict]   # {entity_type, data, rpc_to_call}
    
    # --- Extraction (ephemeral, only within current run) ---
    pending_extractions: List[dict]
    
    # --- Control ---
    run_complete: bool
    error: Optional[str]
    
    # --- Metrics ---
    started_at: datetime
    tokens_used: int
```

### 3.3. AIConversation: поля (уже в d01_kernel.sql)

> ✅ Все поля ниже уже присутствуют в `d01_kernel.sql`. Применять отдельно не нужно.

```sql
-- Уже в d01_kernel.sql (таблица ai_conversations):
-- confirmation_pending    boolean     DEFAULT false
-- confirmation_payload    jsonb       DEFAULT NULL
-- message_count           int         DEFAULT 0  ← atomic counter (D137)
-- detected_language       text        DEFAULT NULL
-- active_farm_id          uuid        REFERENCES farms(id)
-- message_history_summary text        DEFAULT NULL  -- context compression
-- processing_locked_at    timestamptz DEFAULT NULL  -- R-1: race condition lock
```

**Эти поля — мост между runs. Загружаются в начале каждого run, сохраняются в конце.**

### 3.3.1. Processing Lock (L-2 fix — v1.7)

**Проблема:** Фермер отправляет два сообщения подряд. WhatsApp доставляет оба webhook одновременно. Run 2 читает `confirmation_pending=false` (Run 1 ещё не записал), обрабатывает как новый запрос — confirmation_payload теряется.

**Почему advisory lock не работал (root cause L-2 = L-NEW-2):**

```
ИЛЛЮЗИЯ (v1.1–v1.6):           РЕАЛЬНОСТЬ:
┌─────────────────────┐         ┌─────────────────────┐
│ supabase.rpc(        │         │ supabase.rpc(        │
│   "try_lock_conv"   │ ←lock   │   "try_lock_conv"   │ ←PG transaction
│ )                   │  held   │ )                   │  BEGIN→COMMIT
│ run_agent()         │         │                     │ ←lock RELEASED HERE
│ supabase.rpc(        │         │ run_agent()         │ ←NO LOCK
│   "release_lock"    │         │                     │
│ )                   │         └─────────────────────┘
└─────────────────────┘
```

`supabase.rpc()` — отдельный HTTP-запрос = отдельная PostgreSQL-транзакция.  
`pg_try_advisory_xact_lock` снимается при COMMIT этой транзакции.  
`run_agent()` стартует **после** возврата из `rpc()` — lock уже снят.  
Тот же паттерн что L-NEW-2 для proactive_dispatch. Тот же корень — другой flow.

**Правильная защита (достаточно для Phase 1):**

| Угроза | Защита | Механизм |
|--------|--------|---------|
| Один и тот же WhatsApp message_id дважды (retry) | `insert_user_message_dedup` | `ON CONFLICT whatsapp_message_id DO NOTHING` → `is_new=false` → early exit |
| Два разных сообщения одновременно (edge case) | `confirmation_pending` flag | Run 2 читает флаг в `check_confirmation` node — состояние, записанное Run 1 |

```python
async def handle_webhook(message: IncomingMessage):
    conversation_id = await get_or_create_conversation(message)

    # Атомарный dedup — единственная нужная защита (L-2 fix)
    is_new = await save_user_message_atomic(
        conversation_id=conversation_id,
        content=message.text,
        whatsapp_message_id=message.id,   # WhatsApp wamid
        supabase=supabase
    )
    if not is_new:
        return  # Дубль — WhatsApp retry. Ничего не делать.

    # Запустить агент. Без advisory lock — он не защищал.
    await run_agent(message, conversation_id)
```

`save_user_message_atomic` вызывает `insert_user_message_dedup` (§10.2) — атомарный `INSERT ON CONFLICT DO NOTHING`.

**`try_lock_conversation` / `release_conversation_lock` — DEPRECATED.**  
Функции остаются в БД для совместимости, но не должны использоваться в новом коде.  
SQL-комментарии обновлены в d01_kernel.sql (L-2 fix).

### 3.4. Confirmation Flow (C-1 fix) — двухходовой

Ключевое изменение v1.1. Подтверждение не может ждать ответа внутри одного run — WhatsApp работает через отдельные webhook вызовы.

```
╔══════════════════════════════════════════════════════════════╗
║  RUN 1: Фермер: "У меня 80 бычков, 12 месяцев, 280 кг"     ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  load_context: confirmation_pending = false                  ║
║  agent_loop: извлечь данные → сформировать вопрос           ║
║  extract_entities: pending_extractions = [{herd_group...}]  ║
║  save_confirmation_payload:                                  ║
║    AIConversation.confirmation_pending = TRUE                ║
║    AIConversation.confirmation_payload = {                   ║
║      entity_type: "herd_group",                             ║
║      rpc: "rpc_upsert_herd_group",                              ║
║      data: {category: "STEER", heads: 80, weight: 280}        ║
║    }                                                         ║
║                                                              ║
║  AI → Фермер: "Записать группу Бычки 12-24 мес:            ║
║                80 голов, ср. вес 280 кг? (Да/Нет)"         ║
╚══════════════════════════════════════════════════════════════╝
                            ↓
                   [Фермер отвечает]
                            ↓
╔══════════════════════════════════════════════════════════════╗
║  RUN 2: Фермер: "Да"                                        ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  load_context: confirmation_pending = TRUE  ← из DB         ║
║  check_confirmation: "Да" → route to write_entities         ║
║  write_entities:                                            ║
║    rpc_upsert_herd_group(                                    ║
║      p_organization_id: [из state, не от LLM],              ║
║      p_animal_category_code: "STEER",                         ║
║      p_head_count: 80,                                      ║
║      p_avg_weight_kg: 280.0,                                ║
║      p_data_source: "ai_extracted"                          ║
║    )                                                         ║
║  clear_confirmation:                                         ║
║    AIConversation.confirmation_pending = FALSE               ║
║    AIConversation.confirmation_payload = NULL                ║
║                                                              ║
║  AI → Фермер: "Записано. Группа 'Бычки 12-24 мес'          ║
║                80 голов, 280 кг добавлена."                 ║
╚══════════════════════════════════════════════════════════════╝
```

**Если фермер ответил "Нет":**
```python
# Run 2 при "Нет":
clear_confirmation()  # сбросить payload
agent_loop()          # спросить что не так, предложить исправить
```

**Распознавание ответа (R-3 fix — через Claude Haiku, не regex):**

Проблема regex: `"Да, но вес 290"` → парсер вернёт `yes`, запишет старое значение 280. Фермер теряет доверие. `"Не 80, а 85"` → парсер вернёт `no`, хотя фермер уточняет, не отказывается.

```python
async def parse_confirmation(
    user_text: str,
    original_payload: dict,
    anthropic_client
) -> dict:
    """
    Используем claude-haiku для понимания ответа фермера.
    Возвращает: {action: "confirm"|"reject"|"amend", amended_data?: {...}}
    
    Почему Haiku, не Sonnet: этот вызов не требует reasoning — только классификация.
    Haiku в 10x дешевле и в 3x быстрее. Latency: ~300ms vs ~1s.
    """
    prompt = f"""Фермер отвечает на вопрос о записи данных.

Что предлагалось записать:
{json.dumps(original_payload, ensure_ascii=False, indent=2)}

Ответ фермера: "{user_text}"

Определи намерение:
- "confirm": фермер согласен записать данные как есть
- "reject": фермер отказывается, данные не нужно записывать
- "amend": фермер согласен, но хочет изменить некоторые данные

Если "amend" — укажи какие поля нужно изменить в amended_data.

Отвечай ТОЛЬКО валидным JSON без пояснений:
{{"action": "confirm"|"reject"|"amend", "amended_data": {{...}} или null}}"""

    response = await anthropic_client.messages.create(
        model="claude-haiku-4-5-20251001",  # Haiku: быстро и дёшево для классификации
        max_tokens=200,
        messages=[{"role": "user", "content": prompt}]
    )
    
    try:
        result = json.loads(response.content[0].text)
        return result
    except json.JSONDecodeError:
        # Fallback: не поняли — спросить ещё раз
        return {"action": "unclear", "amended_data": None}


# Логика confirm_handler с новым парсером:
async def confirm_handler(state: AgentState) -> AgentState:
    parsed = await parse_confirmation(
        user_text=state["raw_input"],
        original_payload=state["confirmation_payload"],
        anthropic_client=anthropic_client
    )
    
    if parsed["action"] == "confirm":
        # Run 2: записать как есть
        return await write_entities(state)
    
    elif parsed["action"] == "amend":
        # Фермер: "Да, но вес 290" → обновить payload и спросить снова
        # L-2 fix: валидировать amended_data перед merge (Haiku может вернуть опечатку)
        entity_type = state["confirmation_payload"].get("entity_type", "")
        amended = parsed.get("amended_data") or {}
        
        # Фильтруем: оставляем только валидные ключи для этой entity_type
        valid_keys = set(TOOL_PARAM_VALIDATORS.get(entity_type, {}).keys())
        if valid_keys:
            # Убираем ключи которых нет в спецификации (опечатки Haiku)
            amended = {k: v for k, v in amended.items() if k in valid_keys}
        
        merged_payload = {**state["confirmation_payload"], **amended}
        
        # Прогнать через валидатор — если ошибка, просим уточнить
        if not validate_tool_params(entity_type, merged_payload):
            state["response"] = (
                "Не смог правильно понять изменение. "
                f"Пожалуйста, укажите точно: {', '.join(valid_keys)}"
            )
            return state
        
        state["confirmation_payload"] = merged_payload
        await save_confirmation_payload(state)
        
        # Показать обновлённые данные и спросить ещё раз
        state["response"] = format_confirmation_question(merged_payload)
        return state
    
    elif parsed["action"] == "reject":
        # Фермер отказался
        await clear_confirmation(state)
        state["response"] = "Понял, отменяю. Что нужно изменить?"
        return state
    
    else:  # unclear
        state["response"] = "Не совсем понял. Записать данные? Ответьте Да или Нет."
        return state
```

### 3.5. Граф узлов (v1.1)

```
                    ┌──────────────────┐
                    │   dedup_check    │  START — проверить message_id
                    └────────┬─────────┘
                             │ не дубль
                    ┌────────▼─────────┐
                    │  resolve_user    │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │ save_user_msg    │  → AIMessage(role=user) НЕМЕДЛЕННО
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  load_context    │  AIConversation + farm_context
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────────────────────────────┐
                    │         check_confirmation               │
                    └──────┬───────────────────────────────────┘
                           │                  │
              pending=True │                  │ pending=False
                           │                  │
              ┌────────────▼──────┐  ┌────────▼─────────┐
              │  confirm_handler  │  │    route_role     │
              └────────────┬──────┘  └────────┬─────────┘
                           │                  │
              yes/no/unclear│         ┌────────▼─────────┐
                           │         │  sync_role_to_db  │
                     yes → │         └────────┬─────────┘
              ┌────────────▼──────┐           │
              │  write_entities   │  ┌────────▼─────────┐
              └────────────┬──────┘  │   agent_loop     │◄──┐
                           │         └────────┬─────────┘   │
                           │                  │ tool_calls?  │
                           │         ┌────────▼─────────┐   │
                           │         │  execute_tools   │───┘
                           │         └────────┬─────────┘
                           │                  │
                           │         ┌────────▼─────────┐
                           │         │ extract_entities  │
                           │         └────────┬─────────┘
                           │                  │ needs_confirm?
                           │         ┌────────▼─────────┐
                           │         │ save_confirm_     │
                           │         │ payload           │
                           │         └────────┬─────────┘
                           │                  │
                           └─────────┬────────┘
                                     │
                    ┌────────────────▼─────────┐
                    │     compliance_filter     │
                    └────────────────┬─────────┘
                                     │
                    ┌────────────────▼─────────┐
                    │   save_assistant_msg     │
                    └────────────────┬─────────┘
                                     │
                                    END
```

### 3.6. Context Window Strategy (R-5 fix)

AIConversation живёт 24 часа (D64). За это время может накопиться значительная история.

**Проблема v1.1:** `get_or_create_summary` создавал summary один раз при > 15 сообщений и больше не обновлял. При 30 сообщениях summary описывал сообщения 1–5, recent покрывал 21–30, сообщения 6–20 были потеряны навсегда.

**v1.2: Rolling incremental summary** — обновляется при каждом новом пороге.

```python
MAX_RECENT_MESSAGES = 10      # всегда передаём последние 10 без сжатия
SUMMARIZE_EVERY_N   = 10      # пересоздавать summary каждые 10 новых сообщений

def build_messages_for_claude(conversation_id: str, new_input: str) -> List[dict]:
    """Строим messages[] для Claude API. Rolling summary + recent tail."""
    
    history = load_message_history(conversation_id)  # все сообщения из AIMessage
    
    if len(history) <= MAX_RECENT_MESSAGES:
        # Небольшая история — передать всё как есть
        return [*history, {"role": "user", "content": new_input}]
    
    # Разделить: хвост всегда в полном виде, остальное — через summary
    recent_messages  = history[-MAX_RECENT_MESSAGES:]
    messages_to_summarize = history[:-MAX_RECENT_MESSAGES]
    
    summary = get_rolling_summary(conversation_id, messages_to_summarize)
    
    return [
        {"role": "user",      "content": f"[Краткое содержание предыдущего разговора: {summary}]"},
        {"role": "assistant", "content": "Понял, продолжаю с учётом контекста."},
        *recent_messages,
        {"role": "user",      "content": new_input}
    ]


def get_rolling_summary(conversation_id: str, messages_to_summarize: List[dict]) -> str:
    """
    Incremental rolling summary.
    
    Логика:
    - Храним в AIConversation: (summary_text, summarized_up_to_index)
    - При каждом вызове: если новых сообщений >= SUMMARIZE_EVERY_N — пересоздать
    - Новый summary = summarize(old_summary + new_messages_since_last_summary)
    - Никогда не теряем историю: каждое сообщение попадает в summary до того,
      как исчезает из recent_messages
    """
    conv = load_conversation(conversation_id)
    old_summary   = conv.get("message_history_summary", "")
    last_idx      = conv.get("summary_last_message_index", 0)
    current_total = len(messages_to_summarize)
    
    new_messages_count = current_total - last_idx
    
    if old_summary and new_messages_count < SUMMARIZE_EVERY_N:
        # Summary свежий — использовать как есть
        return old_summary
    
    # Нужно обновить: взять старый summary + новые сообщения с last_idx
    new_messages = messages_to_summarize[last_idx:]
    
    new_summary = call_claude_haiku_for_summary(
        previous_summary=old_summary,
        new_messages=new_messages
    )
    
    # Сохранить обновлённый summary и индекс
    save_summary_to_db(
        conversation_id=conversation_id,
        summary=new_summary,
        last_message_index=current_total
    )
    
    return new_summary


def call_claude_haiku_for_summary(previous_summary: str, new_messages: List[dict]) -> str:
    """Haiku: дёшево и быстро для summarization"""
    prompt = f"""Обнови краткое содержание разговора с фермером.

Предыдущее содержание:
{previous_summary or "(начало разговора)"}

Новые сообщения для добавления:
{format_messages_for_summary(new_messages)}

Напиши обновлённое краткое содержание (3-5 предложений). 
Включи: о чём говорили, какие данные упомянуты, какие действия сделаны.
Только текст, без заголовков."""
    
    # Haiku — достаточно для summarization
    response = anthropic_client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=300,
        messages=[{"role": "user", "content": prompt}]
    )
    return response.content[0].text
```

**Добавить в AIConversation (патч к Dok 1):**
```sql
ALTER TABLE ai_conversations ADD COLUMN IF NOT EXISTS
    summary_last_message_index  int  DEFAULT 0;
```

---

## 4. Роли AI-агента

### 4.1. Роль = System Prompt + Tool Set + Compliance Rules

Каждая роль — это комбинация трёх элементов. Переключение роли = замена всех трёх.

### 4.2. Таблица ролей

| Роль | Когда активна | Основная задача | Запрещено |
|------|--------------|-----------------|-----------|
| `zootechnician` | **Default** | Стадо, кормление, операционный план | Ветпрепараты с дозировкой |
| `vet` | Симптомы животных | Диагностика, лечение, вакцинация | Гарантии диагноза, конкретные дозировки не из Treatment |
| `consultant` | Документы, субсидии, членство | Консультация по НПА, ТУРАН-стандартам | Юридические заключения |
| `trading_agent` | Продажа/покупка | Создание батча, цены, пул-запросы | Согласование цен между фермерами (ст. 171) |

**Proactive messages (M-2 fix):** проактивные сообщения отправляются в роли `zootechnician` (для агрозадач) или `vet` (для вакцинаций/ветпредупреждений). "Proactive role" как отдельная роль не существует.

### 4.3. Автоматическое определение роли (auto-routing) с казахским (S-2 fix)

```python
ROLE_SIGNALS = {
    "vet": {
        "ru": [
            "кашляет", "хромает", "понос", "температура", "болезнь",
            "вакцин", "лечени", "симптом", "пал", "пало", "заболел",
            "вздутие", "аборт", "роды", "теленок не встает", "не ест",
            "слезится", "хрипит", "падёж"
        ],
        "kk": [
            "жөтеледі",    # кашляет
            "ақсайды",     # хромает
            "іші кетеді",  # понос
            "қызуы бар",   # температура есть
            "ауырады",     # болеет
            "өлді",        # умерло
            "егу",         # вакцинация
            "дәрі",        # лекарство
            "туды",        # отелилась
        ]
    },
    "trading_agent": {
        "ru": [
            "продать", "продаю", "цена", "покупатель", "сколько стоит",
            "мясокомбинат", "батч", "партия", "живой вес", "сдать",
            "реализовать", "покупают"
        ],
        "kk": [
            "сатамын",     # продаю
            "баға",        # цена
            "сатып алушы", # покупатель
            "тірі салмақ", # живой вес
        ]
    },
    "consultant": {
        "ru": [
            "субсиди", "документ", "членство", "закон", "справка",
            "ИСЖ", "регистрация", "ЛПХ", "КФХ", "господдержка", "грант"
        ],
        "kk": [
            "субсидия",    # то же
            "құжат",       # документ
            "мүшелік",     # членство
            "тіркеу",      # регистрация
        ]
    }
}

def detect_role(text: str, current_role: str) -> str:
    text_lower = text.lower()
    for role, langs in ROLE_SIGNALS.items():
        all_signals = langs.get("ru", []) + langs.get("kk", [])
        if any(s in text_lower for s in all_signals):
            return role
    return current_role


def detect_intents(text: str) -> dict:
    """
    R-4: Определяем primary_role + secondary_intent.
    Фермер: "У бычков кашель, и сколько стоит продать если вылечу?" →
      primary_role: "vet" (первый сигнал, первичная проблема)
      secondary_intent: "trading_agent" (вторичный вопрос)
    """
    text_lower = text.lower()
    found_roles = []
    
    for role, langs in ROLE_SIGNALS.items():
        all_signals = langs.get("ru", []) + langs.get("kk", [])
        if any(s in text_lower for s in all_signals):
            found_roles.append(role)
    
    if not found_roles:
        return {"primary_role": None, "secondary_intent": None}
    
    return {
        "primary_role": found_roles[0],
        "secondary_intent": found_roles[1] if len(found_roles) > 1 else None
    }
```

### 4.4. Явное переключение фермером

```
/зоотехник  → current_role = "zootechnician", role_was_overridden = True
/ветеринар  → current_role = "vet",           role_was_overridden = True
/продать    → current_role = "trading_agent", role_was_overridden = True
/помощь     → current_role = "consultant",    role_was_overridden = True
```

**R-4 fix: timeout на role_was_overridden**

Проблема v1.1: `role_was_overridden = True` блокирует auto-routing до конца разговора (24 ч). Фермер начал с `/продать`, потом бычок заболел — не может спросить про кашель без явного `/ветеринар`. Фермер 45+ этого не знает.

```python
ROLE_OVERRIDE_TIMEOUT_MESSAGES = 5  # После 5 сообщений — сбросить override

def route_role(state: AgentState) -> AgentState:
    # Проверить timeout на ручной override
    if state["role_was_overridden"]:
        messages_since_override = count_messages_since_override(state)
        if messages_since_override >= ROLE_OVERRIDE_TIMEOUT_MESSAGES:
            state["role_was_overridden"] = False  # Вернуть авто-routing
    
    if not state["role_was_overridden"]:
        intents = detect_intents(state["raw_input"])
        if intents["primary_role"]:
            state["current_role"] = intents["primary_role"]
            state["secondary_intent"] = intents.get("secondary_intent")
    
    return state
```

**Обработка secondary_intent в agent_loop:**

```python
# В system prompt добавляется если есть secondary_intent:
SECONDARY_INTENT_HINT = """
Фермер также спросил о {secondary_domain}. После ответа на основной вопрос — 
упомяни: "По поводу {secondary_topic} — напишите /продать (или /ветеринар), 
я помогу с этим отдельно."
"""
```

**Решение D106 (обновлено):** Гибридный routing с `primary_role` + `secondary_intent`. Ручной override сбрасывается через 5 сообщений — авто-routing восстанавливается. Фермер не застревает в одной роли навсегда.

### 4.5. Мультифермный disambig (S-3 fix)

Когда у организации несколько ферм — AI должен уточнить о какой идёт речь, прежде чем привязывать VetCase или HerdGroup к конкретной ферме.

```python
def check_farm_disambiguation(state: AgentState) -> str:
    """Нужно ли спросить о какой ферме речь?"""
    farms = state["farm_context"]["farms"]
    
    if len(farms) <= 1:
        # Только одна ферма — нет неопределённости
        state["active_farm_id"] = farms[0]["id"] if farms else None
        return "proceed"
    
    if state["active_farm_id"]:
        # Уже уточнили в этом сеансе
        return "proceed"
    
    # Несколько ферм — нужно уточнить
    # Спросить только если текущий запрос требует farm_id
    # (vet case, herd group update — да; поиск по базе знаний — нет)
    if action_requires_farm_id(state):
        return "ask_which_farm"
    
    return "proceed"

# В agent_loop system prompt добавляется контекст:
MULTI_FARM_CONTEXT = """
У этой организации несколько ферм: {farm_list}.
Если вопрос касается конкретных животных или задач — уточни о какой ферме речь.
Текущая активная ферма в этом разговоре: {active_farm_name_or_none}.
"""
```

### 4.6. System Prompts с версионированием (R-11 fix)

**Проблема v1.2:** Промпты хардкожены в коде. При изменении промпта невозможно: откатить, A/B тестировать, трекать какая версия дала деградацию.

**Решение: таблица `ai_prompts` + `prompt_version` в AIMessage.**

```sql
CREATE TABLE ai_prompts (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role            text NOT NULL,                    -- zootechnician|vet|consultant|trading_agent|base
    version         text NOT NULL,                    -- semver: "1.0", "1.1", "2.0"
    content         text NOT NULL,
    active_from     timestamptz NOT NULL DEFAULT now(),
    active_until    timestamptz,                      -- NULL = текущая
    created_by      uuid REFERENCES auth.users(id),
    change_reason   text,                             -- "Улучшен ответ на ветвопросы"
    
    UNIQUE (role, version)
);

-- Получить текущий активный промпт для роли
CREATE OR REPLACE FUNCTION rpc.get_active_prompt(p_role text)
RETURNS TABLE(version text, content text) LANGUAGE sql AS $$
    SELECT version, content
    FROM   ai_prompts
    WHERE  role         = p_role
      AND  active_from  <= now()
      AND  (active_until IS NULL OR active_until > now())
    ORDER  BY active_from DESC
    LIMIT  1;
$$;
```

```python
async def load_system_prompt(role: str, supabase) -> tuple[str, str]:
    """
    Загружает активный промпт из DB.
    Возвращает (content, version) — version сохраняется в AIMessage.
    """
    result = await supabase.rpc("get_active_prompt", {"p_role": role}).execute()
    if not result.data:
        raise RuntimeError(f"No active prompt for role={role}. Check ai_prompts table.")
    row = result.data[0]
    return row["content"], row["version"]


async def build_system_prompt(state: AgentState, supabase) -> tuple[str, str]:
    """Base + role prompt. Оба берутся из DB с их версиями."""
    base_content,  base_ver  = await load_system_prompt("base",            supabase)
    role_content,  role_ver  = await load_system_prompt(state["current_role"], supabase)
    
    # Подставить переменные из context
    org = state["farm_context"]["organization"]
    base_filled = base_content.format(
        org_name         = org["name"],
        region           = org["region"],
        membership_level = org["membership_level"],
        herd_groups_count = len(state["farm_context"]["herd_groups"])
    )
    
    combined_version = f"base={base_ver};role={role_ver}"
    return base_filled + "\n\n" + role_content, combined_version


# В save_assistant_message: записать версию промпта
# AIMessage.metadata["prompt_version"] = combined_version
# Это позволяет трекать: "после обновления до base=1.2 — negative_feedback_rate вырос"
```

**Seed данных (начальные промпты — те же что были в коде):**

```sql
INSERT INTO ai_prompts (role, version, content, change_reason) VALUES
('base', '1.0',
'Ты — AI-консультант ассоциации ТУРАН для казахстанского фермера.
Говори на языке фермера: по-русски если пишет по-русски, по-казахски если пишет на казахском.
Отвечай коротко — 2-4 предложения. Фермер занят — он не читает длинные тексты.
Никогда не выдумывай факты о конкретной ферме — используй только данные из инструментов.
Организация: {org_name}, регион: {region}, уровень членства: {membership_level}.
Активных групп скота: {herd_groups_count}.',
'Initial version'),

('zootechnician', '1.0',
'Ты — зоотехник. Помогаешь с управлением стадом, кормлением, производственным планом.
Если фермер говорит о болезни — переключись в ветеринарный режим.',
'Initial version'),

('vet', '1.0',
'Ты — ветеринарный консультант. Помогаешь с симптомами, диагностикой, вакцинацией.
КРИТИЧЕСКИ ВАЖНО: дозировки препаратов — ТОЛЬКО из базы данных (tool:get_treatment_protocols).
НИКОГДА не называй конкретные дозы из своих знаний.
При тяжёлых симптомах (высокая температура, отказ от корма 2+ дня, падёж) — СРАЗУ предложи эксперта.',
'Initial version'),

('consultant', '1.0',
'Ты — консультант по вопросам ассоциации ТУРАН, субсидиям и документам.
Отвечай на основе базы знаний (tool:search_knowledge).
Не давай юридических заключений — только информацию и ориентиры.',
'Initial version'),

('trading_agent', '1.0',
'Ты — торговый ассистент. Помогаешь создать предложение о продаже скота.
КРИТИЧЕСКИ ВАЖНО (ст. 171 ПК РК): НИКОГДА не обсуждай цены других ферм.
Справочные цены ТУРАН — только ориентир, не обязательство.',
'Initial version');
```

---

## 5. Context Engine

### 5.1. farm_context_snapshot (структура)

```python
FARM_CONTEXT_SCHEMA = {
    "loaded_at": "ISO datetime",
    "organization": {
        "id": "uuid",
        "name": "str",
        "region": "str",
        "membership_level": "str"
    },
    "farms": [
        {
            "id": "uuid",
            "name": "str",
            "activity_types": ["cow_calf", "finishing"]
        }
    ],
    "herd_groups": [
        {
            "id": "uuid",
            "farm_id": "uuid",
            "farm_name": "str",     # ← добавлено для multi-farm disambig (S-3)
            "label": "str",
            "animal_category_code": "str",
            "head_count": int,
            "avg_weight_kg": float,
            "data_source": "str",
            "confidence": int
        }
    ],
    "active_vet_cases": [
        {
            "id": "uuid",
            "farm_id": "uuid",      # ← добавлено (S-3)
            "herd_group_id": "uuid", # ← добавлено (M-4)
            "severity": "str",
            "symptoms_text": "str",
            "created_at": "ISO datetime"
        }
    ],
    "pending_tasks": [
        {
            "id": "uuid",
            "name": "str",
            "category": "str",
            "due_date": "date",
            "status": "str"
        }
    ],
    "active_vaccination_items": [
        {
            "id": "uuid",
            "herd_group_id": "uuid",
            "protocol_name": "str",
            "scheduled_date": "date"
        }
    ],
    "active_rations": [
        {
            "id": "uuid",
            "herd_group_id": "uuid",
            "group_label": "str"
        }
    ]
}
```

### 5.2. Context Loading RPC

```sql
-- Один вызов возвращает всё нужное
SELECT * FROM rpc.get_ai_farm_context(
    p_organization_id := :organization_id
);
-- Returns: JSONB в формате farm_context_snapshot
-- Perf target: < 200ms
```

### 5.3. Context Refresh (R-9 fix)

**Проблема v1.2:** Кеш обновлялся только после write через AI. Если зоотехник обновил стадо через веб-кабинет — AI продолжал работать со старыми данными до конца 24-часовой сессии.

**v1.3: TTL + Event Bus invalidation.**

```python
FARM_CONTEXT_TTL_SECONDS = 300  # 5 минут

def is_context_stale(farm_context: dict) -> bool:
    loaded_at = datetime.fromisoformat(farm_context["loaded_at"])
    return (datetime.now(timezone.utc) - loaded_at).seconds > FARM_CONTEXT_TTL_SECONDS  # D-4 fix: utcnow() deprecated

async def get_farm_context(state: AgentState, supabase) -> dict:
    """Загрузить контекст с учётом TTL."""
    if state.get("farm_context") and not is_context_stale(state["farm_context"]):
        return state["farm_context"]  # Свежий — использовать
    
    # Истёк TTL или не загружен — перезагрузить
    result = await supabase.rpc("get_ai_farm_context", {
        "p_organization_id": state["organization_id"]
    }).execute()
    return result.data
```

**Event Bus invalidation (для немедленной реакции):**

Когда AIConversation активна и приходит Event Bus событие об изменении данных организации — контекст инвалидируется принудительно.

```sql
-- В ai_conversations: флаг "контекст устарел, перезагрузить при следующем run"
ALTER TABLE ai_conversations ADD COLUMN IF NOT EXISTS
    context_invalidated_at  timestamptz DEFAULT NULL;
```

```python
# Event Bus consumer: при farm.herd_group.updated для активной сессии
# L-6 fix: использовать RPC вместо прямой записи в таблицу (P-AI-1: все writes через RPC)
async def on_herd_group_updated(event: dict):
    org_id = event["organization_id"]
    await supabase.rpc("invalidate_ai_context", {
        "p_organization_id": org_id
    }).execute()
    # RPC invalidate_ai_context() создан в 009_patch_ai.sql — единственный авторизованный
    # путь для инвалидации. Прямая запись в таблицу нарушает P-AI-1 и обходит audit trail.

# В load_context node: проверить invalidated_at
def should_reload_context(conv: dict, farm_context: dict) -> bool:
    if conv.get("context_invalidated_at"):
        return True  # Принудительная инвалидация от Event Bus
    return is_context_stale(farm_context)  # TTL fallback
```

**Partial refresh** (для write-событий внутри AI Gateway — остаётся как в v1.2):

| Write event | Что обновляем |
|-------------|--------------|
| HerdGroup upserted | `farm_context.herd_groups` |
| VetCase created | `farm_context.active_vet_cases` |
| FarmTask completed | `farm_context.pending_tasks` |
| VaccinationItem confirmed | `farm_context.active_vaccination_items` |

**Решение D128:** TTL 5 мин как baseline. Event Bus invalidation для немедленной реакции на внешние изменения. Полный reload дешевле чем работа с невалидными данными.

---

## 6. Tool Catalog (AI Gateway ↔ Supabase RPC)

### Правила каталога
- Каждый tool вызывает строго один RPC
- `organization_id` — **всегда implicit**: Gateway добавляет его сам из `state.organization_id`
- LLM **никогда** не видит и не передаёт `organization_id` в параметрах tool call (D110)
- Tool name = snake_case, 2-4 слова

### 6.1. Роль: zootechnician

| Tool Name | Суть | → RPC | Confirmation? |
|-----------|------|-------|:---:|
| `get_farm_context` | Текущее состояние фермы | `rpc.get_ai_farm_context` | — |
| `update_herd_group` | Обновить группу (поголовье, вес) | `rpc.upsert_herd_group` | **Да** |
| `create_herd_group` | Создать новую группу | `rpc.upsert_herd_group` | **Да** |
| `get_feeding_plan` | Текущий рацион группы | `rpc.get_feeding_plan` | — |
| `get_farm_tasks` | Задачи на ближайшие N дней | `rpc.get_farm_tasks` | — |
| `complete_farm_task` | Отметить задачу выполненной | `rpc.complete_farm_task` | **Да** |
| `search_knowledge` | Поиск в базе знаний | `rpc.search_knowledge_chunks` | — |
| `get_production_plan` | Фазы производственного плана | `rpc.get_production_plan` | — |
| `escalate_to_expert` | Запросить зоотехника | `rpc.create_consultation_request` | **Да** |

### 6.2. Роль: vet

| Tool Name | Суть | → RPC | Confirmation? |
|-----------|------|-------|:---:|
| `create_vet_case` | Открыть ветеринарный кейс | `rpc.create_vet_case` | — (auto) |
| `add_symptoms` | Добавить симптомы к кейсу | `rpc.add_vet_symptoms` | — |
| `get_diagnosis` | AI-диагноз по симптомам | `rpc.get_vet_diagnosis` | — |
| `get_treatment_protocols` | Протоколы лечения **только из Treatment таблицы** | `rpc.get_treatment_protocols` | — |
| `get_vaccination_schedule` | График вакцинации | `rpc.get_vaccination_schedule` | — |
| `confirm_vaccination` | Отметить вакцинацию выполненной | `rpc.complete_vaccination_item` | **Да** |
| `escalate_to_expert` | Создать ConsultationRequest (source=ai_referral) | `rpc.create_consultation_request` | **Да** |
| `search_knowledge` | Поиск в базе знаний (ветеринария) | `rpc.search_knowledge_chunks` | — |

**⚠️ Критично (P-AI-4):** Если `get_treatment_protocols` не нашёл лечение для заболевания — AI **обязан** ответить: *"По этому заболеванию обратитесь к ветеринару лично."* Генерировать дозировки из своих знаний — запрещено.

**Параметры `escalate_to_expert` для vet (M-3 fix):**
```python
rpc.create_consultation_request(
    p_organization_id = state["organization_id"],  # из state, не от LLM
    p_vet_case_id     = vet_case_id,
    p_source          = "ai_referral",              # ← всегда для AI-инициированных
    p_reason          = reason_text
)
```

### 6.3. VetCase: запрос herd_group_id (M-4 fix)

При создании VetCase AI должен уточнить группу если их несколько:

```python
def prepare_vet_case_params(state: AgentState, symptoms: str) -> dict:
    params = {
        "p_organization_id": state["organization_id"],
        "p_symptoms_text": symptoms,
        "p_farm_id": state["active_farm_id"],
    }
    
    # Если одна группа — привязать автоматически
    herd_groups = state["farm_context"]["herd_groups"]
    if len(herd_groups) == 1:
        params["p_herd_group_id"] = herd_groups[0]["id"]
    elif len(herd_groups) > 1:
        # Спросить: "Какая группа животных? {список}"
        # herd_group_id добавим в Run 2 после ответа фермера
        params["p_herd_group_id"] = None  # nullable FK
    
    return params
```

### 6.4. Роль: consultant

| Tool Name | Суть | → RPC | Confirmation? |
|-----------|------|-------|:---:|
| `search_knowledge` | Поиск НПА, инструкций, стандартов | `rpc.search_knowledge_chunks` | — |
| `get_membership_status` | Статус членства организации | `rpc.get_membership_status` | — |
| `get_subsidy_programs` | Программы субсидий | `rpc.search_knowledge_chunks` (filtered) | — |
| `create_consultation_request` | Запросить эксперта | `rpc.create_consultation_request` | **Да** |

### 6.5. Роль: trading_agent

| Tool Name | Суть | → RPC | Confirmation? |
|-----------|------|-------|:---:|
| `get_farm_context` | Состояние стада для выбора групп | `rpc.get_ai_farm_context` | — |
| `create_batch_draft` | Создать черновик предложения | `rpc.create_batch` | **Да** |
| `publish_batch` | Опубликовать батч | `rpc.publish_batch` | **Да** |
| `get_price_grid` | Справочная сетка цен | `rpc.get_price_grid` | — |
| `get_market_overview` | Анонимный спрос/предложение | `rpc.get_aggregated_supply` + `rpc.get_aggregated_demand` | — |
| `get_active_batches` | Мои активные предложения | `rpc.get_org_batches` | — |
| `search_knowledge` | Правила TSP, стандарты | `rpc.search_knowledge_chunks` | — |

**⚠️ Запрет (ст. 171 ПК РК):** `get_market_overview` возвращает только агрегированные анонимные данные. Детали конкретных ферм — никогда.

### 6.5a. Deployed tools (AI-GATEWAY-07) — дополнительный каталог

> Эти инструменты задеплоены в `ai_gateway/tools/*.py` но отсутствовали в §6.1–6.5.
> Добавлены в рамках doc-reconciliation Phase 1. Полная верификация параметров — в коде.

| Tool Name | Роль | Суть | → RPC | Confirmation? |
|-----------|------|------|-------|:---:|
| `cancel_batch` | `trading_agent` | Отменить черновик или активный батч | `rpc_cancel_batch` | **Да** |
| `get_price_for_sku` | `trading_agent` | Справочная цена для конкретного SKU | `rpc_get_price_for_sku` | — |
| `get_market_summary` | `trading_agent` | Агрегированный рыночный срез (спрос + предложение) по региону/месяцу | `rpc_get_market_summary` | — |
| `close_vet_case` | `vet` | Закрыть ветеринарный кейс с исходом (outcome) | `rpc_close_vet_case` | **Да** |
| `get_farm_summary` | `zootechnician` | Сводка по ферме: поголовье, кормление, задачи | `rpc_get_farm_summary` | — |
| `get_current_ration` | `zootechnician` | Текущий рацион всех групп фермы | `rpc_get_current_ration` | — |
| `update_feed_inventory` | `zootechnician` | Обновить остатки корма (один вид корма) | `rpc_upsert_feed_inventory` | **Да** |
| `log_herd_event` | `zootechnician` | Записать событие стада (падёж, перевод, взвешивание) | `rpc_log_herd_event` | **Да** |
| `get_active_plan` | `zootechnician` | Полный обзор активного производственного плана | `rpc_get_active_plan` | — |

**Примечание по `get_market_summary` (ст. 171 ПК РК):** только агрегированные данные, без раскрытия конкретных ферм — аналогично `get_market_overview`.

### 6.6. Матрица tools × роли

| Tool | zoоtech | vet | consultant | trading |
|------|:---:|:---:|:---:|:---:|
| get_farm_context | ✅ | ✅ | — | ✅ |
| update_herd_group | ✅ | — | — | — |
| create_herd_group | ✅ | — | — | — |
| get_feeding_plan | ✅ | — | — | — |
| get_farm_tasks | ✅ | — | — | — |
| complete_farm_task | ✅ | — | — | — |
| get_production_plan | ✅ | — | — | — |
| create_vet_case | — | ✅ | — | — |
| add_symptoms | — | ✅ | — | — |
| get_diagnosis | — | ✅ | — | — |
| get_treatment_protocols | — | ✅ | — | — |
| get_vaccination_schedule | — | ✅ | — | — |
| confirm_vaccination | — | ✅ | — | — |
| escalate_to_expert | ✅ | ✅ | ✅ | — |
| create_consultation_request | — | — | ✅ | — |
| get_membership_status | — | — | ✅ | — |
| get_subsidy_programs | — | — | ✅ | — |
| create_batch_draft | — | — | — | ✅ |
| publish_batch | — | — | — | ✅ |
| get_price_grid | — | — | — | ✅ |
| get_market_overview | — | — | — | ✅ |
| get_active_batches | — | — | — | ✅ |
| search_knowledge | ✅ | ✅ | ✅ | ✅ |
| cancel_batch | — | — | — | ✅ |
| get_price_for_sku | — | — | — | ✅ |
| get_market_summary | — | — | — | ✅ |
| close_vet_case | — | ✅ | — | — |
| get_farm_summary | ✅ | — | — | — |
| get_current_ration | ✅ | — | — | — |
| update_feed_inventory | ✅ | — | — | — |
| log_herd_event | ✅ | — | — | — |
| get_active_plan | ✅ | — | — | — |

### 6.7. Tool-name ↔ RPC-name mapping (A3)

**Решение A3:** LLM-видимые имена tool (левый столбец) принадлежат Dok 5 — это абстракция Gateway-уровня. SQL RPC-имена (правый столбец) — реальность: они живут в `rpc_name_registry` и в `ai_gateway/tools/*.py`. Gateway сам выполняет маппинг при каждом вызове. **RPCs не переименовываются** (P7 — Additive Architecture): RPC-имя = вызываемый SQL identifier, изменение требует миграции.

| Tool name (LLM-видимый, Dok 5) | SQL RPC name (canonical, rpc_name_registry) | Расхождение? | Файл |
|-------------------------------|---------------------------------------------|:---:|------|
| `get_farm_context` | `rpc_get_ai_farm_context` | ✅ расходится | `tools/` (nodes.py) |
| `create_batch_draft` | `rpc_create_batch` | ✅ расходится | `tools/market.py` |
| `get_market_overview` | `rpc_get_aggregated_supply` + `rpc_get_aggregated_demand` | ✅ расходится (1→2 RPC) | `tools/market.py` |
| `get_active_batches` | `rpc_get_org_batches` | ✅ расходится | `tools/market.py` |
| `update_herd_group` / `create_herd_group` | `rpc_upsert_herd_group` | ✅ расходится (2→1 RPC) | `tools/` |
| `update_feed_inventory` | `rpc_upsert_feed_inventory` | ✅ расходится | `tools/feed.py` |
| `cancel_batch` | `rpc_cancel_batch` | совпадает (prefix) | `tools/market.py` |
| `get_price_for_sku` | `rpc_get_price_for_sku` | совпадает (prefix) | `tools/market.py` |
| `get_market_summary` | `rpc_get_market_summary` | совпадает (prefix) | `tools/market.py` |
| `close_vet_case` | `rpc_close_vet_case` | совпадает (prefix) | `tools/expert.py` |
| `get_farm_summary` | `rpc_get_farm_summary` | совпадает (prefix) | `tools/feed.py` |
| `get_current_ration` | `rpc_get_current_ration` | совпадает (prefix) | `tools/feed.py` |
| `log_herd_event` | `rpc_log_herd_event` | совпадает (prefix) | `tools/feed.py` |
| `get_active_plan` | `rpc_get_active_plan` | совпадает (prefix) | `tools/ops.py` |

> **⚠️ Debt AI-GATEWAY-02/06:** полный список tool↔RPC маппингов должен быть верифицирован против `ai_gateway/tools/*.py`. Таблица выше содержит известные расхождения; остальные инструменты (где `rpc_` prefix match) подлежат финальной проверке в Phase 2. Унификация именования — отдельный backlog item (не в Phase 1).

---

## 7. Entity Extraction Pipeline (D65)

### Принцип: Extraction ≠ Write (теперь через два run)

```
Run 1:
  Фермер: "У меня 80 бычков, 12 месяцев, вес 280 кг"
  → extract_entities: найти кандидата HerdGroup
  → save_confirmation_payload: сохранить в AIConversation
  → AI → Фермер: "Записать: Бычки 12-24 мес, 80 голов, 280 кг? (Да/Нет)"
  
Run 2:
  Фермер: "Да"
  → check_confirmation: pending=true, ответ=yes
  → write_entities: rpc_upsert_herd_group(org_id из state, ...)
  → clear_confirmation
  → AI → Фермер: "Записано."
```

### 7.1. Что извлекается и confirmation policy

| Entity | Поля для извлечения | Confirmation |
|--------|---------------------|:---:|
| HerdGroup | animal_category, head_count, avg_weight_kg | **Да** |
| FarmFeedInventory | feed_item, quantity_kg | **Да** |
| VetCase | symptoms_text, herd_group_id, severity | Нет (auto) |
| FarmTask completion | task_id, result_description | **Да** |
| VaccinationPlanItem | item_id, completed_date | **Да** |

### 7.2. Extraction правила

```python
EXTRACTION_RULES = {
    "herd_group": {
        "patterns_ru": [
            r"(\d+)\s*(бычк|телк|коров|нетел|телёнок)",
            r"группа.*?(\d+)\s*голов",
            r"(\d+)\s*голов.*?(бычк|коров)"
        ],
        "patterns_kk": [
            r"(\d+)\s*(бұзау|өгіз|сиыр|қашар)",  # телёнок, бычок, корова, нетель
        ],
        # C-NEW-1 FIX: коды соответствуют animal_categories.code в БД (001_kernel.sql)
        # Неправильные русские коды (БМ1, БМ2, ТМ, КВ) заменены на английские DB-коды.
        "mapping": {
            r"бычок.{0,10}(6-12|6\s*мес)|бұзау.{0,10}6":  "BULL_CALF",     # 6-12 мес, самцы
            r"бычок.{0,10}(12-24|год)|молодняк":            "STEER",         # 12-24 мес, откорм
            r"телк|тёлк|қашар":                             "HEIFER_YOUNG",  # тёлки 8-18 мес
            r"нетел":                                       "HEIFER_PREG",   # нетели 18-30 мес
            r"корова|коров|сиыр":                           "COW",           # коровы 30+ мес
            r"телён|бұзау(?!.{0,10}6)":                    "YOUNG_CALF",    # телята отъёмные
        },
        # Справка: полный каталог кодов (001_kernel.sql, animal_categories):
        # YOUNG_CALF    — Телята отъёмные, 3-8 мес
        # BULL_CALF     — Бычки, 8-18 мес
        # STEER         — Бычки на откорме, 12-30 мес
        # HEIFER_YOUNG  — Тёлки, 8-18 мес
        # HEIFER_PREG   — Нетели, 18-30 мес
        # COW           — Коровы, 30+ мес
        # COW_CULL      — Коровы выбракованные
        # BULL_BREEDING — Быки-производители
        # BULL_CULL     — Быки выбракованные
        "required_for_write": ["animal_category_code", "head_count"],
        "optional": ["avg_weight_kg"]
    }
}
```

### 7.3. Логирование extraction (D65)

```json
{
    "extractions": [
        {
            "entity_type": "herd_group",
            "confidence": 0.87,
            "raw_text": "80 бычков, им 12 месяцев",
            "extracted": {
                "animal_category_code": "STEER",
                "head_count": 80,
                "avg_weight_kg": null
            },
            "status": "confirmed",
            "wrote_to": "herd_groups",
            "rpc_called": "rpc_upsert_herd_group",
            "wrote_in_run": 2
        }
    ]
}
```

---

## 8. Compliance Filter

Последний узел перед отправкой ответа. Применяется ко всем ролям и каналам.

```python
COMPLIANCE_RULES = [
    {
        "id": "CF-01",
        "name": "Antitrust: price coordination",
        "triggers_ru": ["цена другого фермера", "договоримся о цене", "не продавайте ниже"],
        "triggers_kk": ["басқа фермер бағасы", "бағаға келісейік"],
        "action": "REPLACE",
        "replacement": "Я не могу обсуждать цены других участников рынка. "
                       "Ориентируйтесь на справочную сетку цен ТУРАН."
    },
    {
        "id": "CF-02",
        "name": "Vet: dosage hallucination",
        "check": "response contains specific drug dosage AND source != treatment_db",
        "action": "REPLACE_PARTIAL",
        "replacement": "Дозировку должен назначить ветеринар лично."
    },
    {
        "id": "CF-03",
        # ⚠️ DEBT AI-GATEWAY-05: CF-03 определена в каноне (Dok 5), но НЕ реализована в коде.
        # compliance.py не содержит логики approved_proactive_alerts check.
        # Оставить в спецификации — убрать из реестра долга при реализации.
        "name": "Epidemic: unauthorized alert",
        "check": "mentions regional outbreak AND NOT in approved_proactive_alerts",
        "action": "REPLACE",
        "replacement": "По эпидемиологической ситуации в регионе обращайтесь "
                       "в ветеринарную службу или администрацию ТУРАН."
    },
    {
        "id": "CF-04",
        # ⚠️ DEBT AI-GATEWAY-05: CF-04 определена в каноне (Dok 5), но НЕ реализована в коде.
        # Проверка "response contains specific farm data NOT from current org" требует
        # сравнения entity ID-ов в ответе с разрешёнными для organization_id.
        # CRITICAL severity остаётся в канон-спецификации; enforcement — Phase 2 backlog.
        "name": "Data isolation: cross-org reference",
        "check": "response contains specific farm data NOT from current organization",
        "action": "BLOCK",
        "log_severity": "CRITICAL"
    },
    {
        "id": "CF-05",
        "name": "Legal advice prohibition",
        "triggers": ["юридически обязан", "суд решит", "закон однозначно"],
        "action": "APPEND",
        "append_text": "\n\n*Это информационная справка, не юридическое заключение.*"
    }
]

# При любом упоминании цен (get_price_grid был вызван) — добавить:
PRICE_DISCLAIMER = (
    "\n\n*Справочные цены являются индикативными ориентирами. "
    "ТУРАН не устанавливает и не гарантирует цены сделок.*"
)
```

---

## 9. Proactive Engine

### 9.1. Источники и каналы

| Источник | Событие | Роль при отправке | Канал | Timing |
|---------|---------|:-----------------:|-------|--------|
| VaccinationPlanItem | due -14d, -3d, overdue | `vet` | WA + in-app | Cron 09:00 |
| FarmTask | due -3d, overdue | `zootechnician` | WA + in-app | Cron 08:00 |
| ProactiveAlert (approved) | epidemic/seasonal | `vet` | WA + in-app | Immediate |
| HerdGroup | weight near KPI target | `zootechnician` | in-app | Cron weekly |
| FarmPhase | starting next week | `zootechnician` | in-app | Cron weekly |

### 9.2. WhatsApp Templates (D113)

Все outbound-сообщения через approved Template — независимо от 24-часового окна.

**R-10 fix: определение языка фермера.**

```python
SUPPORTED_LANGUAGES = ["ru", "kk"]

# Структура templates: один ключ, два языка
WHATSAPP_TEMPLATES = {
    "vaccination_reminder": {
        "ru": {"name": "turan_vaccination_reminder",    "params": ["{{group_name}}", "{{vaccine_name}}", "{{scheduled_date}}"]},
        "kk": {"name": "turan_vaccination_reminder_kk", "params": ["{{group_name}}", "{{vaccine_name}}", "{{scheduled_date}}"]},
    },
    "task_reminder": {
        "ru": {"name": "turan_task_reminder",    "params": ["{{task_name}}", "{{due_date}}"]},
        "kk": {"name": "turan_task_reminder_kk", "params": ["{{task_name}}", "{{due_date}}"]},
    },
    "epidemic_alert": {
        "ru": {"name": "turan_epidemic_alert",    "params": ["{{disease_name}}", "{{region}}", "{{recommendation}}"]},
        "kk": {"name": "turan_epidemic_alert_kk", "params": ["{{disease_name}}", "{{region}}", "{{recommendation}}"]},
    }
}


def get_user_language(user_id: str, supabase) -> str:
    """
    Приоритет определения языка:
    1. users.preferred_language (если явно выбран пользователем)
    2. AIConversation.detected_language (кеш последнего определения)
    3. Fallback: "ru"

    C-NEW-6 FIX: таблица profiles не существует. Используем public.users.
    """
    # C-NEW-6: читаем из public.users (не из несуществующей profiles)
    result = supabase.table("users")\
        .select("preferred_language")\
        .eq("id", user_id)\
        .maybe_single()\
        .execute()

    if result.data and result.data.get("preferred_language") in SUPPORTED_LANGUAGES:
        return result.data["preferred_language"]

    conv = load_latest_conversation(user_id, supabase)
    if conv and conv.get("detected_language") in SUPPORTED_LANGUAGES:
        return conv["detected_language"]

    return "ru"  # Default


# L-3 fix: чистая функция без DB-записи — безопасна в error handler
# (в т.ч. при supabase_unavailable когда DB недоступна)
def detect_language_pure(text: str) -> str:
    """
    Определить язык без записи в БД. Использовать в error handler.
    """
    KK_MARKERS = ["мен", "сен", "бар", "жоқ", "иä", "қажет", "болады", "үшін"]
    return "kk" if any(m in text.lower() for m in KK_MARKERS) else "ru"


async def detect_and_cache_language(
    text: str,
    conversation_id: str,
    organization_id: str,
    supabase
) -> str:
    """
    Определяем язык по входящему сообщению и кешируем в AIConversation.
    Использовать только в нормальном flow (load_context node).
    В error handler использовать detect_language_pure() без DB-записи (L-3).

    C-NEW-5 FIX: вместо прямой записи в ai_conversations через .table().update()
    вызываем rpc_update_conversation_language (SECURITY DEFINER, с ownership check).
    Прямая запись через service_role нарушала P-AI-1 (нет ownership check, нет audit trail).
    """
    detected = detect_language_pure(text)  # L-3: вызываем чистую функцию

    # C-NEW-5 FIX: через RPC (не прямой UPDATE) — ownership check + audit trail
    await supabase.rpc("rpc_update_conversation_language", {
        "p_conversation_id": conversation_id,
        "p_language": detected,
        "p_organization_id": organization_id,   # ownership validation в RPC
    }).execute()

    return detected


def send_template(phone: str, template_key: str, params: list, lang: str):
    """Выбрать правильную языковую версию template."""
    tmpl = WHATSAPP_TEMPLATES[template_key][lang]
    return whatsapp_provider.send_template(phone, tmpl["name"], params)
```

**Patch к таблице `ai_conversations` (если не применён в 009_patch_ai.sql):**
```sql
-- ai_conversations.detected_language уже добавлен в 009_patch_ai.sql
-- users.preferred_language уже существует в 001_kernel.sql (C-NEW-6: profiles не существует)
-- Проверка:
SELECT column_name FROM information_schema.columns
WHERE table_name = 'users' AND column_name = 'preferred_language';
-- Ожидаемый результат: 1 строка (поле существует с migration 001)
```

### 9.3. Proactive Dispatch (R-6 fix)

**Почему `while True` в FastAPI-процессе — неприемлемо для продакшена:**
- Не переживёт рестарт контейнера (потеряет состояние)
- При горизонтальном масштабировании → два инстанса дублируют уведомления
- Нет backpressure: 1000 накопленных уведомлений = 1000 одновременных запросов в WhatsApp

**Решение D127: pg_cron → POST /proactive/dispatch (один инстанс-триггер) + advisory lock.**

```sql
-- Supabase pg_cron: запускать каждые 5 минут
SELECT cron.schedule(
    'proactive-dispatch',
    '*/5 * * * *',
    $$
    SELECT net.http_post(
        url    := current_setting('app.gateway_url') || '/proactive/dispatch',
        headers := '{"Authorization": "Bearer " || current_setting(''app.internal_key'')}'::jsonb,
        body   := '{}'::jsonb
    );
    $$
);
```

```python
# FastAPI: POST /proactive/dispatch
# Вызывается pg_cron, не живёт в памяти процесса
# L-NEW-2: Advisory lock УБРАН — он освобождался после RPC-вызова,
# до запуска process_notification_batch(). SKIP LOCKED в claim_pending_notifications
# — реальная защита от дублей при нескольких инстансах.
@app.post("/proactive/dispatch")
async def proactive_dispatch(req: Request):
    verify_internal_key(req)  # INTERNAL_API_KEY
    
    # NO advisory lock here — SKIP LOCKED in claim_pending_notifications
    # is the real concurrency protection. Two instances calling dispatch
    # simultaneously both call claim_pending_notifications, which uses
    # FOR UPDATE SKIP LOCKED — they claim different non-overlapping batches.
    await process_notification_batch()
    
    return {"status": "ok"}


async def process_notification_batch(batch_size: int = 50):
    """
    Atomic claim: берём только незанятые уведомления, помечаем locked_by.
    Batch 50 штук с паузой между ними — backpressure.
    """
    notifications = await supabase.rpc("claim_pending_notifications", {
        "p_batch_size": batch_size,
        "p_worker_id":  os.getenv("FLY_MACHINE_ID", "local")  # уникальный ID инстанса
    }).execute()
    
    for notif in notifications.data:
        try:
            await send_proactive_message(notif)
            await supabase.rpc("mark_notification_sent", {
                "p_notification_id": notif["id"]
            }).execute()
        except Exception as e:
            await supabase.rpc("mark_notification_failed", {
                "p_notification_id": notif["id"],
                "p_error": str(e)
            }).execute()
        
        await asyncio.sleep(0.1)  # 100ms пауза = max 500 notif/мин, не флудим WA API
```

```sql
-- RPC: атомарно занять batch (UPDATE ... RETURNING, не SELECT+UPDATE)
CREATE OR REPLACE FUNCTION rpc.claim_pending_notifications(
    p_batch_size int,
    p_worker_id  text
) RETURNS SETOF notifications LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    UPDATE notifications
    SET    locked_by = p_worker_id,
           locked_at = now()
    WHERE  id IN (
        SELECT id FROM notifications
        WHERE  status = 'pending'
          AND  (locked_by IS NULL OR locked_at < now() - interval '10 minutes')
          AND  scheduled_for <= now()   -- L-9 fix: correct column name (001_kernel.sql)
        ORDER BY scheduled_for
        LIMIT  p_batch_size
        FOR UPDATE SKIP LOCKED   -- ← ключевое: пропускаем занятые строки
    )
    RETURNING *;
END;
$$;
```

**Поля `notifications` (уже в d01_kernel.sql):**
```sql
-- Уже в d01_kernel.sql (таблица notifications):
-- locked_by   text        -- worker ID for SKIP LOCKED claim
-- locked_at   timestamptz
-- retry_count int DEFAULT 0  -- max_retry_count cap (L-NEW-4)
-- locked_by   text,
-- locked_at   timestamptz,
    failed_at   timestamptz,
    error_text  text;
```

---

## 10. Webhook Layer (провайдер-агностик)

### 10.1. Interface

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass

@dataclass
class IncomingMessage:
    phone_number: str        # E.164: +77771234567
    message_text: str
    message_id: str          # Для dedup — уникальный ID от провайдера
    timestamp: datetime
    media_url: Optional[str] # Голосовое/фото (обработка в Q-AI-02)

class WhatsAppProvider(ABC):
    @abstractmethod
    async def parse_webhook(self, request: Request) -> Optional[IncomingMessage]: ...
    
    @abstractmethod
    async def send_message(self, phone: str, text: str) -> bool: ...
    
    @abstractmethod
    async def send_template(self, phone: str, template: str, params: list) -> bool: ...
    
    @abstractmethod
    async def verify_webhook(self, request: Request) -> bool: ...
```

### 10.2. Idempotency (R-7 fix)

**Проблема SELECT-then-INSERT (v1.2):** Два webhook с одним `message_id` приходят с интервалом в миллисекунды. Оба проходят `SELECT` — оба видят 0 записей. Оба проходят дальше. Дубль создан.

**Решение: атомарный `INSERT ... ON CONFLICT DO NOTHING`.**

```python
async def save_user_message_atomic(
    conversation_id: str,
    content: str,
    whatsapp_message_id: str,
    supabase
) -> bool:
    """
    Сохраняет user message И делает dedup одной атомарной операцией.
    Возвращает True если сообщение новое, False если дубль.
    
    Заменяет отдельный dedup_check + save_user_message.
    UNIQUE constraint на whatsapp_message_id гарантирует атомарность.
    """
    result = await supabase.rpc("insert_user_message_dedup", {
        "p_conversation_id":     conversation_id,
        "p_content":             content,
        "p_whatsapp_message_id": whatsapp_message_id,
    }).execute()
    
    return result.data["is_new"]  # False = дубль, прекратить обработку


```sql
CREATE OR REPLACE FUNCTION rpc.insert_user_message_dedup(
    p_conversation_id     uuid,
    p_content             text,
    p_whatsapp_message_id text
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO ai_messages (
        conversation_id, role, content_text, whatsapp_message_id
    )
    VALUES (
        p_conversation_id, 'user', p_content, p_whatsapp_message_id
    )
    ON CONFLICT (whatsapp_message_id) DO NOTHING
    RETURNING id INTO v_id;
    
    -- v_id IS NULL означает конфликт (дубль)
    RETURN jsonb_build_object('is_new', v_id IS NOT NULL, 'message_id', v_id);
END;
$$;
```

-- Schema: UNIQUE constraint обязателен
-- ALTER TABLE ai_messages ADD COLUMN IF NOT EXISTS whatsapp_message_id text;
-- CREATE UNIQUE INDEX IF NOT EXISTS ai_messages_wa_msgid_key
--     ON ai_messages (whatsapp_message_id) WHERE whatsapp_message_id IS NOT NULL;
```

**Изменение в flow:** `dedup_check` и `save_user_message` объединяются в один вызов `save_user_message_atomic`. Граф упрощается: `dedup_check` узел убирается, его логика внутри `save_user_message`.

### 10.3. User Resolution

```python
async def resolve_user(phone: str, supabase) -> Optional[dict]:
    """E.164 phone → {user_id, organization_id, membership_level}"""
    result = await supabase.rpc("resolve_user_by_phone", {
        "p_phone": phone
    }).execute()
    
    if not result.data:
        return None  # → "Добро пожаловать в ТУРАН! turanstandard.kz/join"
    
    return result.data[0]
```

---

## 11. Error Handling Pipeline (O-4 fix)

Ошибки — не исключения, а ожидаемые состояния. Каждый узел знает что делать при сбое.

```python
ERROR_RESPONSES = {
    # Claude API недоступен
    "claude_timeout": {
        "ru": "Сейчас не могу ответить — попробуйте через минуту.",
        "kk": "Қазір жауап бере алмаймын — бір минуттан кейін қайталаңыз.",
        "log": "WARNING",
        "retry": True,
        "retry_after_sec": 60
    },
    # RPC вернул constraint violation (например, batch без membership)
    "rpc_constraint": {
        "ru": "Это действие недоступно при вашем уровне членства. "
              "Свяжитесь с менеджером ТУРАН.",
        "kk": "Бұл әрекет сіздің мүшелік деңгейіңізде қол жетімді емес.",
        "log": "INFO",
        "retry": False
    },
    # Supabase недоступен
    "supabase_unavailable": {
        "ru": "Система временно недоступна. Ваше сообщение сохранено и будет обработано.",
        "kk": "Жүйе уақытша қол жетімді емес.",
        "log": "CRITICAL",
        "retry": True,
        "retry_after_sec": 300,
        "alert_admin": True
    },
    # Пользователь не найден по номеру
    "user_not_found": {
        "ru": "Ваш номер не зарегистрирован в ТУРАН. Регистрация: turanstandard.kz",
        "kk": "Сіздің нөміріңіз ТУРАН жүйесінде тіркелмеген.",
        "log": "INFO",
        "retry": False
    },
    # Compliance CF-04: cross-org data (критично)
    "data_isolation_violation": {
        "ru": None,  # Не отправлять ничего фермеру
        "log": "CRITICAL",
        "alert_admin": True,
        "block_response": True
    }
}

async def handle_node_error(error_type: str, state: AgentState) -> AgentState:
    cfg = ERROR_RESPONSES.get(error_type, ERROR_RESPONSES["claude_timeout"])
    
    if cfg.get("alert_admin"):
        await notify_admin(error_type, state["organization_id"])
    
    lang = detect_language_pure(state["raw_input"])  # L-3 fix: была undefined detect_language()
    state["error_response"] = cfg.get(lang, cfg.get("ru"))
    state["run_complete"] = True
    return state
```

---

## 12. FastAPI Service

### 12.1. Эндпоинты

```
POST /webhook/{provider}     # WhatsApp входящие
GET  /webhook/{provider}     # WhatsApp verify (Meta)
POST /chat                   # Web Cabinet (Supabase JWT)
POST /proactive/send         # Internal cron trigger
GET  /health
```

### 12.2. Аутентификация

| Источник | Auth | Примечание |
|---------|------|------------|
| WhatsApp webhook | Signature (провайдер-специфично) | Secret в ENV |
| Web Cabinet | Supabase JWT | user_id из токена |
| Internal cron | `INTERNAL_API_KEY` header | Не публичный |
| → Supabase RPC | Service Role Key | P-AI-6, всегда с p_organization_id |

### 12.3. Защита от Prompt Injection (R-2 fix)

**Прежний подход (v1.1) — неверный.** Regex-фильтр ловил только буквальные паттерны. Атакующий напишет через транслит, Unicode или indirect injection через фото — и фильтр пропустит. Хуже: команда считает проблему закрытой.

**Правильный подход: ограничить damage radius.**

Если injection пройдёт — что максимум произойдёт? Ответ должен быть: "почти ничего".

```
5 слоёв damage radius:

Слой 1 (D110): org_id НИКОГДА не от LLM → чужие данные недоступны
Слой 2 (P-AI-1): все writes через SECURITY DEFINER RPC → неавторизованный write отклонён
Слой 3 (раздел 6.6): tool matrix per-role → vet не создаст batch, trading не создаст VetCase
Слой 4: output validation — проверяем tool call параметры ДО вызова RPC
Слой 5: anomaly monitoring — аномальные паттерны → WARNING/CRITICAL
```

```python
# Слой 4: Output validation
TOOL_PARAM_VALIDATORS = {
    "update_herd_group": {
        "head_count":    lambda v: isinstance(v, int) and 0 < v < 10_000,
        "avg_weight_kg": lambda v: isinstance(v, (int, float)) and 0 < v < 2_000,
    },
    "create_batch_draft": {
        "head_count": lambda v: isinstance(v, int) and 0 < v < 5_000,
    }
}

def validate_tool_params(tool_name: str, params: dict) -> bool:
    """False = аномальные параметры, не вызывать RPC, логировать"""
    for field, validator in TOOL_PARAM_VALIDATORS.get(tool_name, {}).items():
        if field in params and not validator(params[field]):
            logger.warning(f"Anomalous param: tool={tool_name} {field}={params[field]}")
            return False
    return True

# Слой 5: Anomaly signals
ANOMALY_THRESHOLDS = {
    "tool_calls_per_run": 8,       # > 8 tool calls в одном run → WARNING
    "writes_per_run": 3,           # > 3 write-tool calls → WARNING
}

# ФУНДАМЕНТАЛЬНОЕ ПРАВИЛО (не убирать):
# user input ВСЕГДА в role=user, НИКОГДА не интерполируется в system prompt
```

### 12.4. Rate Limiting

```python
RATE_LIMITS = {
    "messages_per_minute": 5,
    "messages_per_hour": 50,
    "tool_calls_per_conversation": 20,
    "max_conversation_tokens": 50_000
}
```

### 12.5. ENV переменные

```bash
SUPABASE_URL=https://xxx.supabase.co
SUPABASE_SERVICE_KEY=eyJ...        # Service role — не anon
ANTHROPIC_API_KEY=sk-ant-...
CLAUDE_MODEL=claude-sonnet-4-20250514
WHATSAPP_PROVIDER=meta|360dialog|twilio
WHATSAPP_API_URL=...
WHATSAPP_API_KEY=...
WHATSAPP_VERIFY_TOKEN=...
INTERNAL_API_KEY=...
LOG_LEVEL=INFO
```

---

## 13. Интеграция с Event Bus (Dok 4)

### 13.1. AI Gateway → Event Bus

| Событие | Когда | Из какого узла |
|---------|-------|----------------|
| `farm.herd_group.updated` | update_herd_group подтверждён (Run 2) | write_entities |
| `vet.case.created` | create_vet_case вызван | write_entities |
| `vet.case.escalated` | escalate_to_expert вызван | write_entities |
| `platform.consultation.requested` | ConsultationRequest создан | write_entities |
| `ops.task.completed` | complete_farm_task подтверждён (Run 2) | write_entities |
| `market.batch.published` | publish_batch подтверждён (Run 2) | write_entities |
| `vet.vaccination.reminded` | proactive_poller отправил напоминание | proactive_poller |

### 13.2. Event Bus → AI Gateway

| Событие | Реакция AI Gateway |
|---------|-------------------|
| `vet.signal.confirmed` | Проверить ProactiveAlert → отправить если approved |
| `ops.task.due_soon` | Сформировать WhatsApp-напоминание |
| `vet.vaccination.overdue` | Alert фермеру + эксперту |
| `ops.phase.started` | Обновить farm_context + уведомить фермера |

---

## 14. Мониторинг (D72)

### 14.1. Операционные метрики (per-message)

```python
# Записываются в PlatformEvent.payload для каждого AIMessage
{
    "tokens_input": int,
    "tokens_output": int,
    "model": "claude-sonnet-4-20250514",
    "prompt_version": str,             # R-11: версия промпта (раздел 4.6)
    "latency_ms": int,
    "role": str,
    "tools_called": list,
    "extractions_count": int,
    "confirmation_run": int,
    "compliance_triggered": bool,
    "compliance_rule": str
}
```

### 14.2. Метрики качества ответов (R-8 fix)

Операционные метрики не отвечают на вопрос: "AI помогает или нет?"

```python
# Negative feedback detection: следующее сообщение после ответа AI
NEGATIVE_SIGNALS_RU = [
    "не понял", "не то", "не помог", "что за", "зачем",
    "бесполезно", "не правильно", "ошибся", "не так"
]
NEGATIVE_SIGNALS_KK = [
    "түсінбедім",    # не понял
    "дұрыс емес",   # неправильно
    "көмектеспеді",  # не помог
]

def detect_negative_feedback(user_text: str) -> bool:
    t = user_text.lower()
    all_signals = NEGATIVE_SIGNALS_RU + NEGATIVE_SIGNALS_KK
    return any(s in t for s in all_signals)


# Логировать при обнаружении:
async def log_quality_event(
    conversation_id: str,
    prev_message_id: str,  # сообщение AI на которое отреагировали
    feedback_type: str,    # "negative_feedback" | "escalation" | "no_resolution"
    role: str
):
    await supabase.rpc("publish_platform_event", {
        "p_event_type": "platform.ai.quality_signal",
        "p_entity_id":  conversation_id,
        "p_payload": {
            "prev_message_id": prev_message_id,
            "feedback_type":   feedback_type,
            "role":            role
        }
    }).execute()
```

**Ключевые quality метрики (агрегированные, dashboard):**

| Метрика | Формула | Тревожный порог |
|---------|---------|:---:|
| `negative_feedback_rate` | negative_signals / total_conversations | > 15% |
| `escalation_rate` | escalate_to_expert calls / vet conversations | > 50% |
| `confirmation_abandon_rate` | confirmation_pending=true без ответа 24ч | > 20% |
| `avg_turns_to_resolution` | сообщений до завершения темы | > 8 |

> `escalation_rate > 50%` означает: AI не решает ветеринарные вопросы самостоятельно. Либо база знаний неполная, либо prompts неверные.

### 14.3. Алерты

| Метрика | Порог | Действие |
|---------|-------|---------|
| Latency | > 10 сек | WARNING |
| CF-04 (data isolation) | Любое | CRITICAL + admin notify |
| Error rate | > 5% / час | ERROR |
| Supabase unavailable | Любое | CRITICAL + admin notify |
| negative_feedback_rate | > 15% за сутки | WARNING → prompt review |
| escalation_rate (vet) | > 50% за сутки | WARNING → knowledge base review |

---

## 15. Embedding Worker (D-4 fix — v1.7)

### 15.1. Зачем нужен отдельный воркер

`rpc_search_knowledge_chunks` работает в двух режимах:

| Режим | Когда | Точность |
|-------|-------|---------|
| **Vector** | `embedding IS NOT NULL` → cosine similarity (HNSW) | Высокая |
| **Text FTS** | `embedding IS NULL` → `plainto_tsquery('russian')` | Средняя |

Без воркера все чанки остаются с `embedding = NULL` → поиск всегда в text mode → RAG работает существенно хуже. Вызов Embeddings API из PostgreSQL триггера блокирует `INSERT INTO knowledge_chunks` на 200–500 мс — поэтому async-очередь.

### 15.2. Архитектура

```
knowledge_chunks INSERT/UPDATE (is_published=true)
        │
        ▼ AFTER trigger (fn_enqueue_knowledge_chunk_embedding)
embedding_queue  status: pending
        │
        ▼ каждые 60 сек
Embedding Worker (APScheduler внутри FastAPI)
        │
        ├─ claim_embedding_batch(10)   → N строк {job_id, chunk_id, title, content}
        ├─ Embeddings API              → vector(1536)
        ├─ complete_embedding_job()    → done + knowledge_chunks.embedding = vector
        └─ fail_embedding_job()        → retry (< 3) или failed_permanent
```

**SQL (d07_ai_gateway.sql):**

| Объект | Описание |
|--------|---------|
| `embedding_queue` | FSM очередь: `pending → processing → done \| failed → failed_permanent` |
| `fn_enqueue_knowledge_chunk_embedding` | AFTER INSERT/UPDATE trigger, dedup по `content_hash` (SHA-256) |
| `claim_embedding_batch(n, worker_id)` | FOR UPDATE SKIP LOCKED — параллельные воркеры без конфликтов |
| `complete_embedding_job(job_id, vector)` | Атомарно: queue→done + chunk.embedding = vector |
| `fail_embedding_job(job_id, error)` | Retry FSM: retry_count < 3 → pending, иначе → failed_permanent |

### 15.3. Python-реализация

```python
# embedding_worker.py — запускается через APScheduler внутри FastAPI

import asyncio, logging, os
logger = logging.getLogger("agos.embedding_worker")

BATCH_SIZE = 10
WORKER_ID  = f"worker-{os.getenv('HOSTNAME', 'local')}"


async def get_embedding(text: str) -> list[float]:
    """vector(1536) — совместимо с text-embedding-3-small / Voyage AI voyage-3."""
    import voyageai
    client = voyageai.AsyncClient()
    result = await client.embed([text], model="voyage-3")
    return result.embeddings[0]


async def run_embedding_cycle(supabase) -> int:
    result = await supabase.rpc(
        "claim_embedding_batch",
        {"p_batch_size": BATCH_SIZE, "p_worker_id": WORKER_ID}
    ).execute()

    jobs = result.data or []
    if not jobs:
        return 0

    processed = 0
    for job in jobs:
        text = job["title"] + "\n\n" + job["content"]
        try:
            vector = await get_embedding(text)
            await supabase.rpc(
                "complete_embedding_job",
                {"p_job_id": job["job_id"], "p_embedding": vector}
            ).execute()
            processed += 1
        except Exception as e:
            result = await supabase.rpc(
                "fail_embedding_job",
                {"p_job_id": job["job_id"], "p_error_message": str(e)[:500]}
            ).execute()
            outcome = result.data or {}
            if outcome.get("status") == "failed_permanent":
                logger.error(f"chunk {job['knowledge_chunk_id']} FAILED PERMANENT")
    return processed


async def embedding_worker_loop(supabase):
    while True:
        try:
            n = await run_embedding_cycle(supabase)
            if n > 0:
                logger.info(f"Embedded {n} chunks")
        except Exception as e:
            logger.error(f"Embedding Worker error: {e}")
        await asyncio.sleep(60)
```

**Интеграция в FastAPI (lifespan):**

```python
from contextlib import asynccontextmanager
from embedding_worker import embedding_worker_loop

@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(embedding_worker_loop(supabase), name="embedding_worker")
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

app = FastAPI(lifespan=lifespan)
```

### 15.4. Мониторинг

```sql
-- Статус очереди
SELECT status, count(*), max(retry_count) as max_retries
FROM public.embedding_queue GROUP BY status ORDER BY status;

-- Чанки без embedding (text FTS fallback)
SELECT count(*) FROM public.knowledge_chunks
WHERE is_published = true AND embedding IS NULL;

-- failed_permanent — ручной разбор
SELECT eq.id, kc.title, kc.source_domain, eq.error_message
FROM public.embedding_queue eq
JOIN public.knowledge_chunks kc ON kc.id = eq.knowledge_chunk_id
WHERE eq.status = 'failed_permanent' ORDER BY eq.updated_at DESC;
```

| Метрика | Порог WARNING | Порог CRITICAL |
|---------|:---:|:---:|
| `embedding_queue` pending | > 50 | > 200 |
| `chunks_without_embedding` | > 20% published | — |
| `failed_permanent` | > 0 | — |

### 15.5. Приоритеты очереди

| `source_domain` | priority | Обоснование |
|-----------------|:--------:|-------------|
| `veterinary`, `legal` | 2 | Критично для ответов AI по болезням и НПА |
| `zootechnical`, `tsp` | 3 | Основные рабочие домены |
| `education` | 7 | Курсы — фоновая задача |
| `faq` | 8 | Самый низкий приоритет |

### 15.6. ⚠️ Важно для vibecoding

- **Не вызывать** `claim_embedding_batch` из LangGraph агента или endpoint'ов — только из Embedding Worker
- `failed_permanent` чанки: исправить контент в `knowledge_chunks` → `UPDATE` → триггер создаст новый job автоматически
- `embedding_queue` — писать только через триггер, не вставлять вручную

---

## 16. Decisions Log (Dok 5)

| # | Решение | Почему |
|---|---------|--------|
| D105 | WhatsApp провайдер за абстракцией | Провайдер не выбран. Смена = один класс |
| D106 | Гибридный role-routing с timeout | Авто + явная команда. Override сбрасывается через 5 сообщений (D125) |
| D107 | Confirmation для HerdGroup/FeedInventory | Каскадное влияние на рационы, планы, TSP |
| D108 | Proactive: оба канала | Фермер может не смотреть кабинет |
| D109 | Service Role Key + explicit org_id | JWT не для server-to-server |
| D110 | LLM не передаёт org_id в tool call | Защита от prompt injection |
| D111 | farm_context: TTL 5 мин + Event Bus invalidation (обновлено в v1.3) | Внешние изменения (веб-кабинет) иначе не видны AI в течение сессии |
| D112 | Compliance filter — последний узел | Нельзя обойти |
| D113 | Outbound только через WhatsApp Template | Policy compliance + гарантированная доставка |
| D114 | Tool matrix жёстко per-role | Предотвращает cross-domain writes |
| D115 | VetCase auto, HerdGroup confirm | VetCase не влияет на производство |
| D116 | LangGraph без checkpointer, stateless | P-AI-7. State в Supabase — единственный источник |
| D117 | Confirmation flow — двухходовой (два run) | WhatsApp: один webhook = один run, нельзя ждать |
| D118 | User message сохраняется ДО обработки | Не потерять при сбое Claude API |
| D119 | message_id dedup перед обработкой | WhatsApp at-least-once → предотвратить дубли |
| D120 | Rolling incremental summary (обновлено в v1.2) | Управляемый context window без потери истории |
| D121 | Advisory lock по conversation_id перед каждым run | Race condition: два параллельных run перезаписывают confirmation_payload |
| D122 | Damage radius вместо input sanitization | Regex не ловит injection. Настоящая защита = D110 + RPC + tool matrix + output validation |
| D123 | parse_confirmation через Claude Haiku | Regex ломается на "Да, но вес 290". Haiku: 300ms, понимает nuance |
| D124 | primary_role + secondary_intent в routing | Одно сообщение может содержать два домена |
| D125 | role_was_overridden сбрасывается через 5 сообщений | Фермер не застревает в роли навсегда |
| D126 | Rolling incremental summary: каждые 10 новых сообщений | One-time summary устаревает и теряет историю |
| D127 | Proactive dispatch: pg_cron + SKIP LOCKED + batch 50 (advisory lock убран — L-NEW-2) | while True = дубли при масштабировании. Advisory lock в proactive_dispatch был no-op (освобождался до batch). SKIP LOCKED в claim_pending_notifications = реальная защита |
| D128 | farm_context: TTL 5 мин + Event Bus invalidation | Кеш без TTL устаревает при внешних изменениях |
| D129 | Dedup: атомарный INSERT ON CONFLICT вместо SELECT+INSERT | SELECT+INSERT = race condition, два webhook = два дубля |
| D130 | Quality metrics: negative_feedback + escalation_rate | Без quality метрик нельзя улучшать промпты |
| D131 | preferred_language в profiles + detected_language в conversations | Proactive template на неверном языке = плохой UX |
| D132 | System prompts в таблице ai_prompts с версионированием | Хардкод = невозможно откатить, A/B тест, трекать деградацию |
| D133 | get_active_prompt(p_role) вместо хардкода | ai_prompts.version записывается в AIMessage.prompt_version → трекинг деградации |
| D134 | rpc_name_registry = canonical RPC source в БД | SQL имя = вызываемое имя. Dok 3/5 = производные документы |
| D135 | Proactive dispatch: убран advisory lock (L-NEW-2) | try_lock_conversation освобождается после RPC-вызова, до process_notification_batch. SKIP LOCKED в claim_pending_notifications — реальная атомарная защита |
| D136 | Confirmation flow двухходовой | WhatsApp: webhook = sync run. Нельзя ждать пользователя внутри одного run |
| D137 | AIMessage.sequence_number atomic через UPDATE message_count | SELECT MAX → race condition при двух одновременных сообщениях |
| D138 | Schema consolidation: 17 files → 7 | Pre-dev baseline. Разработка от чистого состояния |

---

## 17. Open Questions (актуальные)

| # | Вопрос | Блокирует |
|---|--------|-----------|
| Q-AI-01 | WhatsApp провайдер — Meta / 360dialog / Twilio? | Webhook Adapter + Template registration |
| Q-AI-02 | Голосовые сообщения: нужен STT? Старт с текстом? | AudioMessage в IncomingMessage |
| Q-AI-04 | LangSmith/LangFuse или кастом через PlatformEvent? | Observability setup |
| Q-AI-05 | Eval pipeline: набор тест-кейсов для regression? | Качество при обновлении prompts |
| Q-AI-06 | MPK (мясокомбинат) пользуется Gateway? Какие роли? | Полнота системы |

*Q-AI-03 (казахский) — закрыт: ROLE_SIGNALS расширены (S-2 fix)*  
*Q-AI-07 (context window) — закрыт: summarization strategy добавлена (O-1 fix)*

> ✅ **Schema status:** Все SQL-патчи, упомянутые в changelog v1.1–v1.5 (migrations 009, 011, 012, 013, 014, 015, 016), поглощены консолидированными файлами d01–d07. Применять отдельно не нужно.

---

## Appendix A: Deployment

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

```
# requirements.txt
fastapi>=0.110.0
uvicorn>=0.27.0
langgraph>=0.2.0          # ← исправлено M-1
anthropic>=0.40.0         # ← исправлено M-1
supabase>=2.4.0
pydantic>=2.6.0
python-jose>=3.3.0
httpx>=0.27.0
apscheduler>=3.10.4
```

**Деплой:** Railway / Fly.io / Render. Один stateless контейнер. Любое количество инстансов без координации (D116 — state в Supabase).

> ✅ **Schema pre-applied:** Применить d01_kernel.sql → d02 → d03 → d04 → d05 → d07 в Supabase перед запуском Gateway. Отдельные migration patches (011, 012, 013) устарели — поглощены консолидированными файлами.

---

## Appendix B: Пример полного диалога (trace) — исправленный

```
━━━━━━ RUN 1 ━━━━━━
Фермер (WhatsApp): "Здравствуйте. У меня бычок кашляет уже два дня"

dedup_check: message_id=wamid.abc123 → не дубль, продолжаем
resolve_user: +77771234567 → user_id=u1, org_id=o1, "КХ Аргынбеков"
save_user_message: AIMessage(role=user, whatsapp_message_id="wamid.abc123") → saved

load_context:
  confirmation_pending = false (новый разговор)
  farms = [{id: f1, name: "Основная ферма"}]  ← одна ферма
  herd_groups = [
    {id: g1, label: "Бычки 12-24 мес", heads: 45},
    {id: g2, label: "Коровы", heads: 30}
  ]

check_confirmation: pending=false → route_role
route_role: сигнал "кашляет" → role=vet
sync_role_to_db: AIConversation.current_role = "vet"

agent_loop (vet role):
  [Claude думает: одна ферма f1, две группы — нужно уточнить группу]
  
  tool:create_vet_case({
    # org_id НЕ передаётся от LLM — Gateway добавляет сам ← C-3 fix
    "symptoms_text": "кашель, 2 дня",
    "farm_id": "f1",
    "herd_group_id": null  ← спросим потом (M-4 fix)
  })
  → Gateway добавляет: p_organization_id = state["organization_id"] = "o1"
  → rpc.create_vet_case → VetCase(id=v1, severity=moderate)

  tool:get_treatment_protocols({"disease_hint": "бронхорезпираторный"})
  → rpc.get_treatment_protocols → {drug: "Флорфеникол", dosage_note: "назначает ветврач"}

compliance_filter: OK (дозировка из DB, не из knowledge)
save_assistant_message: AIMessage(role=assistant) saved

AI → Фермер:
"Здравствуйте! Похоже на бронхореспираторный комплекс (БРД).
У вас два стада — какая группа: Бычки 12-24 мес или Коровы?
По протоколу может применяться Флорфеникол — дозировку назначит ветврач."

━━━━━━ RUN 2 ━━━━━━
Фермер: "Бычки"

dedup_check: message_id=wamid.xyz → не дубль
[...resolve, save_user_message...]
load_context: confirmation_pending=false, active_vet_case=v1

agent_loop:
  tool:add_symptoms({
    "vet_case_id": "v1",
    "herd_group_id": "g1",  ← теперь знаем
    "symptoms": ["кашель"]
  })
  
  AI: "Хотите, чтобы я связал вас с ветеринаром ТУРАН? (Да/Нет)"

  save_confirmation_payload:
    AIConversation.confirmation_pending = TRUE
    AIConversation.confirmation_payload = {
      "action": "create_consultation_request",
      "vet_case_id": "v1",
      "source": "ai_referral"
    }

━━━━━━ RUN 3 ━━━━━━
Фермер: "Да"

check_confirmation: pending=TRUE, parse="yes" → confirm_handler

write_entities:
  rpc.create_consultation_request(
    p_organization_id = "o1",   ← из state
    p_vet_case_id     = "v1",
    p_source          = "ai_referral",  ← M-3 fix
    p_reason          = "БРД подозрение"
  ) → ConsultationRequest created, assigned to vet expert

clear_confirmation: pending=FALSE, payload=NULL

AI → Фермер: "Запрос отправлен. Ветеринар свяжется с вами в течение часа."
```

---

*Dok 5 v1.3 — зависит от Dok 1 v1.6 + патч разделов 3.3, 4.6, 9.3; Dok 3 v1.3, Dok 4 v1.1*  
*Следующий документ: Dok 6 — Interface Contracts*
