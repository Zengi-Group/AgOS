# AGOS — Agricultural Operating System

## Dok 4: Event Bus Specification

**v1.1 (REVISED) · 5 марта 2026 · Заменяет v1.0 полностью**

*TURAN Agricultural Association · Confidential*

---

## 0. Журнал изменений v1.0 → v1.1

v1.1 исправляет все критические и серьёзные дефекты, выявленные при кросс-аудите с Dok 1, Dok 2, Dok 3.

| ID | Тип | Изменение |
|----|-----|-----------|
| **КР-1** | Критический | Тройное несоответствие имён event_type (Dok1/Dok3/Dok4) → Введён единый реестр (Section 1) с канонической нотацией `domain.entity.action`. Все ссылки в документе заменены на canonical имена. |
| **КР-2** | Критический | 40+ событий Dok3 отсутствовали в Dok4 → Полный каталог 59 событий в Section 1. Все события Dok3 покрыты с маппингом. |
| **КР-3** | Критический | AI Proactive Worker писал напрямую в notifications → Исправлено: Worker вызывает RPC-43 `rpc_create_proactive_alert`. Section 6 переписана. |
| **КР-4** | Критический | audit_log: `is_audit` flag не существовал, SQL использовал хардкод `TEXT[]` → Добавлена patch-миграция `009_patch_event_audit.sql` (Section 8). Колонка `is_audit BOOLEAN` в `platform_events`. |
| **СР-1** | Серьёзный | 11 событий Dok1 Section 5.5 пропущены → Добавлены: `membership.suspended`, `pool.executing`, `vaccination.reminded`, `task.due_soon`, `task.overdue`, `kpi.missed`, `consultation.*` |
| **СР-2** | Серьёзный | Realtime RLS риск на `herd_groups` → Добавлено предупреждение и workaround через `platform_events` вместо прямой подписки на `herd_groups` (Section 5). |
| **СР-3** | Серьёзный | Счётчик событий несогласован (27/55/34) → Единый счёт: 59 canonical событий = Dok1(27) + Dok3(новые) + cron (системные). |
| **СР-4** | Серьёзный | `feed.inventory.low`: нет механизма генерации → Определён cron worker с threshold-логикой (Section 3, FD-02). |
| **СР-5** | Серьёзный | MPK notification channel хардкод `in_app` → Канал выбирается по `user_notification_preferences` (Section 7). |
| **ЗМ-1** | Структурный | Нет дедупликации proactive → добавлена таблица `proactive_dedup` + политика (Section 6.2). |
| **ЗМ-2** | Структурный | Один polling interval → определены 3 тира: critical/30s, standard/60s, analytics/5min (Section 1.2). |
| **ЗМ-3** | Структурный | `publish_event()` хелпер не в Dok3 → Добавлено примечание: хелпер internal, вызывается только внутри RPC-функций, не из приложения. |

---

## 1. Единый реестр canonical event_type

> **ЕДИНСТВЕННЫЙ ИСТОЧНИК ПРАВДЫ.** Все системы — Dok 3 (RPC), AI Gateway, Notification Worker, Realtime подписки — используют ТОЛЬКО эти строки. Dok 3 будет обновлён до v1.3 с заменой deprecated имён.

**Легенда:** Audit ✅ = копируется в audit_log через `is_audit=true` | RT ✅ = Supabase Realtime | AI ✅ = AI Proactive Worker реагирует | Cron ✅ = генерируется cron-джобом, не RPC.

| # | canonical_event_type (ЕДИНСТВЕННЫЙ ИСТОЧНИК ПРАВДЫ) | Домен | Dok3 original (deprecated) | Producer | Audit | RT | AI | Cron |
|---|-----------------------------------------------------|-------|---------------------------|----------|-------|----|----|------|
| I-01 | **identity.organization.registered** | Identity | organization.registered | RPC-01 [WEB,AI] | — | — | — | — |
| I-02 | **identity.organization.restricted** | Identity | organization.restricted | RPC-45 [ADMIN] | ✅ | — | ✅ | — |
| I-03 | **identity.membership.activated** | Identity | membership.approved | RPC-03 [ADMIN] | ✅ | — | ✅ | — |
| I-04 | **identity.membership.suspended** | Identity | — (отсутствовало) | RPC-03 [ADMIN] | ✅ | — | ✅ | — |
| I-05 | **identity.membership_application.submitted** | Identity | membership.application_submitted | RPC-02 [WEB,AI] | — | — | — | — |
| I-06 | **identity.membership_application.decided** | Identity | membership.approved / membership.rejected | RPC-03 [ADMIN] | ✅ | — | — | — |
| I-07 | **identity.consultation_request.created** | Identity | — (через vet_case escalate) | System/AI trigger | — | — | — | — |
| I-08 | **identity.consultation_request.resolved** | Identity | — (отсутствовало) | Expert [WEB] | — | — | — | — |
| F-01 | **farm.farm.created** | Farm | farm.created | RPC-05 [WEB,AI] | ✅ | — | — | — |
| F-02 | **farm.farm.updated** | Farm | farm.updated | RPC-05 [WEB,AI] | — | ✅ | — | — |
| F-03 | **farm.herd_group.created** | Farm | herd_group.created | RPC-06 [WEB,AI] | — | ✅ | — | — |
| F-04 | **farm.herd_group.updated** | Farm | herd_group.updated | RPC-06 [WEB,AI] | — | ✅ | — | — |
| F-05 | **farm.herd_event.logged** | Farm | herd_event.logged | RPC-07 [WEB,AI] | — | — | ✅ | — |
| M-01 | **market.batch.draft_created** | Market | batch.draft_created | RPC-09 [WEB,AI] | — | — | — | — |
| M-02 | **market.batch.published** | Market | batch.published | RPC-10 [WEB,AI] | — | ✅ | — | — |
| M-03 | **market.batch.cancelled** | Market | batch.cancelled | RPC-11 [WEB,AI,ADMIN] | ✅ | ✅ | — | — |
| M-04 | **market.batch.expired** | Market | — (отсутствовало) | System cron | — | — | ✅ | ✅ |
| M-05 | **market.batch.matched** | Market | batch.matched | RPC-14 [ADMIN] | ✅ | ✅ | ✅ | — |
| M-06 | **market.batch.match_rolled_back** | Market | batch.match_rolled_back | RPC-16 [ADMIN] | ✅ | — | — | — |
| M-07 | **market.pool_request.created** | Market | pool_request.created | RPC-12 [WEB] | — | — | — | — |
| M-08 | **market.pool_request.activated** | Market | pool_request.activated | RPC-13 [WEB,ADMIN] | — | — | — | — |
| M-09 | **market.pool.created** | Market | pool.created | RPC-13 [WEB,ADMIN] | — | ✅ | — | — |
| M-10 | **market.pool.batch_added** | Market | pool.batch_added | RPC-14 [ADMIN] | — | — | — | — |
| M-11 | **market.pool.status_changed** | Market | pool.status_changed | RPC-15 [ADMIN] | ✅ | ✅ | — | — |
| M-12 | **market.pool.contacts_revealed** | Market | pool.contacts_revealed | RPC-15 [ADMIN] | ✅ | — | — | — |
| M-13 | **market.price_grid.updated** | Market | price_grid.updated | RPC-19 [ADMIN] | ✅ | ✅ | — | — |
| M-14 | **market.price_index.published** | Market | price_index.value_published | RPC-20 [ADMIN] | — | ✅ | — | — |
| FD-01 | **feed.inventory.updated** | Feed | feed_inventory.updated | RPC-21 [WEB,AI] | — | — | — | — |
| FD-02 | **feed.inventory.low** | Feed | — (отсутствовало) | System cron | — | — | ✅ | ✅ |
| FD-03 | **feed.ration.created** | Feed | ration.created | RPC-22 [WEB,AI] | — | — | — | — |
| FD-04 | **feed.ration.archived** | Feed | ration.archived | RPC-23 [WEB,AI] | — | — | — | — |
| V-01 | **vet.case.opened** | Vet | vet_case.opened | RPC-25 [WEB,AI] | — | — | — | — |
| V-02 | **vet.case.diagnosed** | Vet | vet_case.diagnosed | RPC-26 [WEB] | — | — | — | — |
| V-03 | **vet.case.escalated** | Vet | — (отсутствовало) | System trigger | — | — | ✅ | — |
| V-04 | **vet.case.closed** | Vet | vet_case.closed | RPC-28 [WEB] | — | — | — | — |
| V-05 | **vet.recommendation.added** | Vet | vet_recommendation.added | RPC-27 [WEB] | — | — | — | — |
| V-06 | **vet.health_restriction.created** | Vet | health_restriction.created | System trigger | ✅ | — | ✅ | — |
| V-07 | **vet.vaccination_plan.created** | Vet | vaccination_plan.created | RPC-29 [WEB,AI] | — | — | — | — |
| V-08 | **vet.vaccination_plan_item.added** | Vet | vaccination_plan_item.added | RPC-30 [WEB] | — | — | — | — |
| V-09 | **vet.vaccination_plan_item.reminded** | Vet | — (отсутствовало) | System cron | — | — | ✅ | ✅ |
| V-10 | **vet.vaccination_plan_item.overdue** | Vet | — (отсутствовало) | System cron | — | — | ✅ | ✅ |
| V-11 | **vet.vaccination_record.created** | Vet | vaccination_record.created | RPC-31 [WEB,AI] | — | — | — | — |
| V-12 | **vet.epidemic_signal.detected** | Vet | epidemic_signal.registered | RPC-32 [AI,ADMIN] | ✅ | — | — | — |
| V-13 | **vet.epidemic_signal.confirmed** | Vet | — (отсутствовало) | Expert [WEB] | ✅ | — | ✅ | — |
| O-01 | **ops.production_plan.started** | Ops | production_plan.started | RPC-33 [WEB,AI] | — | — | — | — |
| O-02 | **ops.farm_phase.started** | Ops | — (отсутствовало) | System cron | — | — | — | ✅ |
| O-03 | **ops.farm_phase.completed** | Ops | — (отсутствовало) | System/Farmer | — | — | — | — |
| O-04 | **ops.farm_phase.rescheduled** | Ops | farm_phase.rescheduled | RPC-35 [WEB,AI] | — | — | ✅ | — |
| O-05 | **ops.farm_task.completed** | Ops | farm_task.completed | RPC-34 [WEB,AI] | — | — | — | — |
| O-06 | **ops.farm_task.due_soon** | Ops | — (отсутствовало) | System cron | — | — | ✅ | ✅ |
| O-07 | **ops.farm_task.overdue** | Ops | — (отсутствовало) | System cron | — | — | ✅ | ✅ |
| O-08 | **ops.farm_kpi.missed** | Ops | — (отсутствовало) | System (fn_evaluate_kpi) | — | — | ✅ | — |
| E-01 | **edu.course.enrolled** | Edu | course.enrolled | RPC-38 [WEB,AI] | — | — | — | — |
| E-02 | **edu.lesson.completed** | Edu | lesson.completed | RPC-39 [WEB,AI] | — | — | — | — |
| E-03 | **edu.course.completed** | Edu | course.completed | RPC-39 [WEB,AI] | — | — | — | — |
| E-04 | **edu.certificate.issued** | Edu | certificate.issued | System trigger | ✅ | — | — | — |
| P-01 | **platform.farm_data.extracted** | Platform | farm_data.extracted_from_ai | RPC-41 [AI] | — | — | — | — |
| P-02 | **platform.proactive_alert.created** | Platform | proactive_alert.created | RPC-43 [AI,ADMIN] | — | — | — | — |
| P-03 | **platform.knowledge_chunk.added** | Platform | knowledge_chunk.added | RPC-44 [ADMIN] | — | — | — | — |
| P-04 | **platform.ai_conversation.started** | Platform | — (отсутствовало) | RPC-40 [AI] | — | — | — | — |
| P-05 | **platform.consultation.requested** | Platform | — (платформ. уровень) | System/AI | — | — | — | — |

---

### 1.1. Маппинг Dok3 → Canonical (Таблица депрекации)

Deprecated имена из Dok3 v1.2 будут заменены в Dok3 v1.3. До выхода v1.3 — использовать canonical имена в новом коде.

| Dok3 deprecated (НЕ использовать) | Canonical (использовать) | Примечание |
|-----------------------------------|--------------------------|------------|
| organization.registered | identity.organization.registered | Добавлен domain-prefix |
| membership.approved | identity.membership.activated | Объединены approved+activated |
| membership.rejected | identity.membership_application.decided | Rejected → в payload.decision |
| membership.application_submitted | identity.membership_application.submitted | Полный namespace |
| farm.created | farm.farm.created | Entity явно указан |
| farm.updated | farm.farm.updated | Entity явно указан |
| herd_group.created | farm.herd_group.created | Domain добавлен |
| herd_group.updated | farm.herd_group.updated | Domain добавлен |
| herd_event.logged | farm.herd_event.logged | Domain добавлен |
| batch.draft_created | market.batch.draft_created | Domain добавлен |
| batch.published | market.batch.published | Domain добавлен |
| batch.cancelled | market.batch.cancelled | Domain добавлен |
| batch.matched | market.batch.matched | Domain добавлен |
| batch.match_rolled_back | market.batch.match_rolled_back | Domain добавлен |
| pool_request.created | market.pool_request.created | Domain добавлен |
| pool_request.activated | market.pool_request.activated | Domain добавлен |
| pool.created | market.pool.created | Domain добавлен |
| pool.batch_added | market.pool.batch_added | Domain добавлен |
| pool.status_changed | market.pool.status_changed | Domain добавлен |
| pool.contacts_revealed | market.pool.contacts_revealed | Domain добавлен |
| price_grid.updated | market.price_grid.updated | Domain добавлен |
| price_index.value_published | market.price_index.published | Упрощено |
| feed_inventory.updated | feed.inventory.updated | Entity упрощён |
| ration.created | feed.ration.created | Domain добавлен |
| ration.archived | feed.ration.archived | Domain добавлен |
| vet_case.opened | vet.case.opened | Убран дубль entity |
| vet_case.diagnosed | vet.case.diagnosed | Убран дубль entity |
| vet_recommendation.added | vet.recommendation.added | Убран дубль |
| health_restriction.created | vet.health_restriction.created | Domain добавлен |
| vet_case.closed | vet.case.closed | Убран дубль |
| vaccination_plan.created | vet.vaccination_plan.created | Domain добавлен |
| vaccination_plan_item.added | vet.vaccination_plan_item.added | Domain добавлен |
| vaccination_record.created | vet.vaccination_record.created | Domain добавлен |
| epidemic_signal.registered | vet.epidemic_signal.detected | Renamed: detected более точно |
| production_plan.started | ops.production_plan.started | Domain добавлен |
| farm_task.completed | ops.farm_task.completed | Domain добавлен |
| farm_phase.rescheduled | ops.farm_phase.rescheduled | Domain добавлен |
| course.enrolled | edu.course.enrolled | Domain добавлен |
| lesson.completed | edu.lesson.completed | Domain добавлен |
| course.completed | edu.course.completed | Domain добавлен |
| certificate.issued | edu.certificate.issued | Domain добавлен |
| farm_data.extracted_from_ai | platform.farm_data.extracted | Упрощено |
| proactive_alert.created | platform.proactive_alert.created | Domain добавлен |
| knowledge_chunk.added | platform.knowledge_chunk.added | Domain добавлен |
| organization.restricted | identity.organization.restricted | Domain добавлен |

---

### 1.2. Polling Strategy по типу Consumer

| Consumer | Интервал | Тир | Фильтруемые event_type |
|----------|----------|-----|------------------------|
| AI Proactive Worker | 30 сек | Critical | `vet.vaccination_plan_item.overdue`, `vet.health_restriction.created`, `vet.epidemic_signal.confirmed`, `market.batch.expired`, `market.batch.matched`, `feed.inventory.low`, `ops.farm_phase.rescheduled`, `identity.organization.restricted` |
| Notification Worker | 60 сек | Standard | `market.batch.published` (MPK), `ops.farm_task.due_soon`, `ops.farm_task.overdue`, `ops.farm_kpi.missed`, `vet.vaccination_plan_item.reminded`, `edu.certificate.issued` |
| Audit Logger | 60 сек | Standard | Все `is_audit=true` события (see Section 8) |
| Analytics Worker | 5 мин | Analytics | `market.*`, `feed.inventory.updated`, `farm.herd_group.updated`, `ops.farm_kpi.missed` |

---

## 2. Схема таблиц Event Bus

### 2.1. platform_events — PATCH: добавить is_audit

> *Миграция `009_patch_event_audit.sql` ОБЯЗАТЕЛЬНА до деплоя Notification Worker. Без `is_audit` поле Audit Logger использует хардкод массива, что нарушает P7 (Additive Architecture).*

```sql
-- 009_patch_event_audit.sql
-- Patch: добавить is_audit в platform_events
-- Зависит от: 001_kernel.sql (platform_events существует)

ALTER TABLE public.platform_events
  ADD COLUMN IF NOT EXISTS is_audit boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.platform_events.is_audit IS
  'P7/P8: true = копировать в audit_log через триггер fn_audit_from_platform_event.
   Заменяет hardcoded AUDITED_EVENTS массив. Новые audited события:
   INSERT в event_audit_registry, не ALTER FUNCTION.';

-- Вспомогательная таблица: реестр аудируемых типов событий (P8)
CREATE TABLE IF NOT EXISTS public.event_audit_registry (
  event_type  text PRIMARY KEY,
  description text,
  added_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.event_audit_registry IS
  'P8 (Standards as Data): Список event_type, которые копируются в audit_log.
   Admin добавляет строку → новый тип начинает аудироваться без деплоя.';

-- Seed: начальные audited events (59 canonical names)
INSERT INTO public.event_audit_registry (event_type) VALUES
  ('identity.organization.restricted'),
  ('identity.membership.activated'),
  ('identity.membership.suspended'),
  ('identity.membership_application.decided'),
  ('market.batch.matched'),
  ('market.batch.cancelled'),
  ('market.batch.match_rolled_back'),
  ('market.pool.status_changed'),
  ('market.pool.contacts_revealed'),
  ('market.price_grid.updated'),
  ('vet.health_restriction.created'),
  ('vet.epidemic_signal.detected'),
  ('vet.epidemic_signal.confirmed'),
  ('farm.farm.created'),
  ('edu.certificate.issued'),
  ('platform.proactive_alert.created')
ON CONFLICT DO NOTHING;

-- Обновить триггер: использовать event_audit_registry вместо хардкода
CREATE OR REPLACE FUNCTION public.fn_audit_from_platform_event()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.event_audit_registry WHERE event_type = NEW.event_type) THEN
    INSERT INTO public.audit_log (
      user_id, actor_type, action, entity_type, entity_id,
      organization_id, changes, created_at
    ) VALUES (
      NEW.actor_id, NEW.actor_type, NEW.event_type, NEW.entity_type, NEW.entity_id,
      NEW.organization_id, NEW.payload, NEW.created_at
    );
    -- Синхронно обновить is_audit для трассировки
    NEW.is_audit := true;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_from_platform_event ON public.platform_events;

CREATE TRIGGER trg_audit_from_platform_event
  BEFORE INSERT ON public.platform_events
  FOR EACH ROW EXECUTE FUNCTION public.fn_audit_from_platform_event();
```

---

### 2.2. Таблица user_notification_preferences (НОВАЯ)

Исправляет дефект СР-5: канал уведомления не может быть хардкодом в шаблоне. Каждый пользователь выбирает предпочтительный канал.

```sql
-- В составе 009_patch_event_audit.sql или отдельной миграции
CREATE TABLE IF NOT EXISTS public.user_notification_preferences (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  channel    text NOT NULL CHECK (channel IN ('whatsapp','in_app')),
  is_enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, channel)
);

COMMENT ON TABLE public.user_notification_preferences IS
  'D68-fix: Пользователь сам выбирает каналы. Default: оба включены.
   Notification Worker читает эту таблицу перед отправкой.
   MPK может отключить WhatsApp, оставить only in_app — или наоборот.';

-- Default: включить оба канала для всех существующих пользователей
INSERT INTO public.user_notification_preferences (user_id, channel)
  SELECT id, unnest(ARRAY['whatsapp','in_app']) FROM public.users
  ON CONFLICT DO NOTHING;
```

---

## 3. Полный каталог событий по доменам

*Все 59 canonical событий. Payload структура для каждого: `{ before: {}, after: {}, meta: {} }`. Полные схемы ключевых событий — Section 4.*

### 3.1. Identity Domain (8 событий)

| canonical_event_type | Producer | Consumers | Описание / after-payload key fields |
|----------------------|----------|-----------|-------------------------------------|
| **identity.organization.registered** | RPC-01 | Notification Worker | org_id, org_type, name, region_id, invited_by |
| **identity.organization.restricted** | RPC-45 [ADMIN] | AI GW ✅, Notification, Audit | restriction_id, org_id, restriction_type, reason_code, expires_at |
| **identity.membership.activated** | RPC-03 [ADMIN] | AI GW ✅, Notification, Audit | org_id, old_level, new_level, valid_from, valid_to |
| **identity.membership.suspended** | RPC-03 [ADMIN] | AI GW ✅, Notification, Audit | org_id, suspended_reason, suspended_at |
| **identity.membership_application.submitted** | RPC-02 | Admin Console, Notification | org_id, membership_type, application_id, notes |
| **identity.membership_application.decided** | RPC-03 [ADMIN] | Farmer Notification, Audit | application_id, decision (approved\|rejected), decision_notes, new_membership_id? |
| **identity.consultation_request.created** | System/AI trigger | Expert Console, Notification | request_id, farm_id, specialization, region_id, urgency, created_via |
| **identity.consultation_request.resolved** | Expert [WEB] | Farmer Notification | request_id, expert_id, resolution_summary |

### 3.2. Farm Domain (5 событий)

| canonical_event_type | Producer | Consumers | Описание / after-payload key fields |
|----------------------|----------|-----------|-------------------------------------|
| **farm.farm.created** | RPC-05 | Audit, AI GW (init context) | farm_id, org_id, region_id, shelter_type, calving_system |
| **farm.farm.updated** | RPC-05 | Realtime (farmer cabinet), AI GW | farm_id, changed_fields[] |
| **farm.herd_group.created** | RPC-06 | AI GW, Feed Module, Realtime | group_id, farm_id, category_code, head_count, confidence, data_source |
| **farm.herd_group.updated** | RPC-06 | AI GW, Feed Module, Vet Module, Realtime | group_id, before.head_count, after.head_count, before.avg_weight_kg, after.avg_weight_kg, confidence, data_source |
| **farm.herd_event.logged** | RPC-07 | AI GW context, Analytics | event_id, farm_id, group_id, event_type (birth\|death\|sale...), value_before, value_after |

### 3.3. Market / TSP Domain (14 событий)

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **market.batch.draft_created** | RPC-09 | — | batch_id, org_id, category_code, heads, target_month |
| **market.batch.published** | RPC-10 | MPK Feed (Realtime ✅), Match Engine | batch_id, org_id, category_code, head_count, weight_kg, grade_code, region_id, ready_date |
| **market.batch.cancelled** | RPC-11 | MPK Feed (Realtime ✅), Audit | batch_id, org_id, reason, cancelled_by_role |
| **market.batch.expired** | System cron ✅ | AI GW ✅, Farmer Notification | batch_id, org_id, head_count, target_month (истёк без матча) |
| **market.batch.matched** | RPC-14 [ADMIN] | Farmer + MPK Notification ✅, Audit | batch_id, pool_id, agreed_price, matched_heads, match_type |
| **market.batch.match_rolled_back** | RPC-16 [ADMIN] | Audit, Farmer Notification | batch_id, pool_id, reason |
| **market.pool_request.created** | RPC-12 | — | request_id, org_id, total_heads, target_month, region_id |
| **market.pool_request.activated** | RPC-13 | Farmer Feed (Realtime ✅) | request_id, pool_id, org_id |
| **market.pool.created** | RPC-13 | Realtime (Market screen) | pool_id, request_id, target_heads, region_id |
| **market.pool.batch_added** | RPC-14 | — | pool_id, batch_id, matched_heads, pool.total_matched_now |
| **market.pool.status_changed** | RPC-15 [ADMIN] | Realtime ✅, Audit | pool_id, old_status, new_status, notes |
| **market.pool.contacts_revealed** | RPC-15 [ADMIN] | Matched Farmers, Audit | pool_id, revealed_at (MPK identity становится доступна) |
| **market.price_grid.updated** | RPC-19 [ADMIN] | Realtime (все) ✅, Audit | version, effective_date, changes[{category_code, grade_code, old_price, new_price}] |
| **market.price_index.published** | RPC-20 [ADMIN] | Realtime (Market screen) ✅ | index_id, period_date, value_per_kg, data_source |

#### 3.3a. Market / TSP — M4 + M6 Extension (2026-06-15, +15 событий)

> События, генерируемые 14 новыми RPC из [Dok 3 §4a](AGOS-Dok3-RPC-Catalog-v1_5.md#4a-market--tsp--m4--m6-extension-canonical-2026-06-15). Все эмитятся **дважды**: в `batch_events` (append-only audit log per batch, M4 §6.4) И в `platform_events` (для consumers / Realtime / notification).
> **Legacy совместимость:** старые события `market.batch.matched/cancelled/expired`, `market.pool.batch_added/status_changed/contacts_revealed` сохраняются для backward compat (P7). Новые M4/M6 flow используют события ниже.

| canonical_event_type | Producer (RPC) | Consumers | Описание |
|----------------------|----------------|-----------|----------|
| **market.batch.scheduled** | `rpc_publish_batch` (D-M6-7 path) | Farmer Realtime ✅ | batch_id, org_id, scheduled_publish_at, ready_from, ready_to |
| **market.batch.auto_published** | System cron (scheduled→published) | MPK Feed ✅, Match Engine | batch_id, org_id, farmer_price_per_kg, ready_window |
| **market.batch.offering** | `rpc_publish_pool` / `rpc_retry_match_pool` / `rpc_lower_batch_price` | MPK с активным Offer (Realtime ✅), AI GW | batch_id, mpk_org_ids[], offer_window_hours, expires_at |
| **market.batch.awaiting_price_decision** | System cron (offers expired) | Farmer Notification ✅, AI GW | batch_id, org_id, expired_offers_count |
| **market.batch.price_lowered** | `rpc_lower_batch_price` | MPK с новым Offer (Realtime ✅), Audit | batch_id, old_price, new_price, was_clamped, broadcast_mpk_count |
| **market.batch.matched** *(M4 канон)* | `rpc_accept_offer` | Farmer+MPK Notification ✅, Audit | batch_id, pool_id, pool_line_id, mpk_org_id, deal_price_per_kg, volume_kg |
| **market.batch.confirmed** | `rpc_accept_offer` (auto-close path) | Farmer+MPK Notification ✅ (D-M6-5: identity revealed), Audit | batch_id, pool_id, mpk_org_id, mpk_legal_name, farmer_org_id, farmer_legal_name |
| **market.batch.dispatched** | `rpc_confirm_dispatch` | MPK Notification ✅, AI GW | batch_id, dispatched_at, by_user_id |
| **market.batch.delivered** | `rpc_confirm_delivery` | Farmer Notification ✅, Review-prompt scheduler | batch_id, delivered_at, by_user_id |
| **market.offer.created** | `rpc_publish_pool` / `rpc_retry_match_pool` / `rpc_lower_batch_price` | MPK Notification ✅ | offer_id, batch_id, mpk_org_id, offered_price_per_kg, expires_at |
| **market.offer.withdrawn** | `rpc_accept_offer` (sibling withdraw) / cancel paths | MPK Realtime ✅ | offer_id, batch_id, mpk_org_id, reason: 'sibling_accepted'\|'batch_cancelled'\|'pool_cancelled'\|'pool_returned' |
| **market.pool.cancelled** | `rpc_cancel_pool` | MPK + всех matched Farmer Notification ✅, Audit | pool_id, mpk_org_id, reason, affected_batches_count |
| **market.pool.closed_partial** | `rpc_pool_accept_partial` | Farmer Notification ✅ (matched batches confirmed), Audit | pool_id, mpk_org_id, confirmed_batches_count, fill_ratio |
| **market.pool.closed_unfilled** | `rpc_pool_return_batches` / cron (window expired, no decision) | Farmer Notification ✅ (batches → published), Audit | pool_id, mpk_org_id, returned_batches_count |
| **market.deal_review.submitted** | `rpc_submit_deal_review` | Other party Notification (only "получен отзыв" — без content до reveal), Audit | deal_review_id, batch_id, reviewer_org_id, reviewer_role, overall_score (visible to reviewer only) |
| **market.deal_review.revealed** | `rpc_submit_deal_review` (when both submitted) / cron (window expired) | Both parties Realtime ✅ | batch_id, reviews[{reviewer_role, overall_score, dimension_scores[], comment}] |

**Notes on payload conventions:**
- Все события M4/M6 содержат `org_id` источника (для P-AI-2 фильтрации).
- `batch.confirmed` — единственное событие, раскрывающее `legal_name` контрагента (D-M6-5). До этого — только `org_id` без identity.
- `deal_review.submitted` payload в notification-канале маскируется до `visible_at`: получатель видит "получен отзыв", не содержание.
- `deal_review.revealed` эмитится один раз при reveal — оба отзыва приходят вместе.

**Aggregate market events (для AI/analytics, через `is_audit=true`):** none пока. Pending Dok 5 §6 antitrust review для aggregated-market-data tooling.

#### 3.3b. A-CAT Admin Events (D-TSP-CATEGORY-BRIDGE, 2026-06-15)

> **Архитектурное решение (Architect, DOC-SYNC-A-CAT-01, 2026-06-15):** 11 admin RPC из [Dok 3 §4b](AGOS-Dok3-RPC-Catalog-v1_5.md#4b-a-cat-admin-rpc-d-tsp-category-bridge-2026-06-15) **в MVP не эмитят `platform_events`**.

**Обоснование:**
- A-CAT экраны (A-CAT-01..04) — admin-only, низкочастотные: разовый setup (~1 час CEO+зоолог) + редкие quarterly корректировки.
- Real-time consumer'ов нет: UI перечитывает данные при открытии экрана; floor-clamp и pool-floor работают на `is_active=true` snapshot (eventually consistent — read-on-demand).
- **Audit trail обеспечивается denormalised columns:**
  - `minimum_prices.approved_by` + `approved_at` — кто и когда утвердил защитный floor (Art.171 ПК РК — стандарт ассоциации).
  - `reference_prices.approved_by` + `approved_at` + `legal_disclaimer_shown` — индикативная цена.
  - `tsp_sku_category_map.created_by` + `created_at` + `version` — кто и когда замапил SKU; полная история через `is_active=false` строки.
- P7-additive путь к подключению events: при появлении consumer'а (AI Gateway tool «show floor history», proactive alert «protective floor changed», notification «новая категория добавлена») — добавить эмиссию в соответствующий RPC без слома существующих callers.

**Phase 2 candidate events (NOT in MVP, для справки):**

| candidate event_type | Producer (RPC) | Trigger для добавления |
|----------------------|----------------|------------------------|
| `platform.livestock_category.upserted` | AC-1 | Notification «новая SKU-категория доступна» для UI / consulting projects |
| `platform.livestock_category.deactivated` | AC-2 | Если AI tool «category lookup» появится — invalidate cache |
| `platform.livestock_category_rule.activated` | AC-4 | AI extraction tool для batch creation начнёт использовать derive — нужен ruleset change broadcast |
| `platform.sku_category_map.updated` | AC-5 | Coverage metric (% SKU mapped) — Realtime для admin dashboard |
| `platform.minimum_price.updated` | AC-6 | Notification farmers (Art.171 announcement) ИЛИ AI proactive alert «floor changed» |
| `platform.reference_price.updated` | AC-7 | То же что minimum, но низший приоритет (indicative-only) |

**Status:** все 6 строк выше — **deferred** до появления конкретного consumer'а. Не блокирует pilot.

**Aggregate / audit считаем через прямой DB query на `tsp_sku_category_map` / `minimum_prices` / `reference_prices` истории (`is_active=false` строки сохраняются как archive).**

### 3.4. Feed Domain (4 события)

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **feed.inventory.updated** | RPC-21 | AI GW context update, Analytics | farm_id, items[{feed_item_id, qty_kg_before, qty_kg_after}], data_source |
| **feed.inventory.low** | System cron ✅ | AI GW ✅, Farmer Notification | farm_id, feed_item_id, feed_name, current_kg, days_remaining (< threshold) |
| **feed.ration.created** | RPC-22 | AI GW context, Farmer Notification | ration_id, farm_id, herd_group_id, animal_category_code, period_type |
| **feed.ration.archived** | RPC-23 | — | ration_id, farm_id, reason |

> *`feed.inventory.low` генерируется cron-воркером, который каждые 6 часов считает `SELECT (quantity_kg / daily_consumption_kg)` для каждой фермы из `rpc_get_farm_summary.feed_inventory_days`. При < 14 дней — публикует событие. Повторная публикация не чаще 1 раза в 24 ч на пару `(farm_id, feed_item_id)` — через таблицу `cron_state`.*

### 3.5. Veterinary Domain (13 событий)

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **vet.case.opened** | RPC-25 [WEB,AI] | Expert Console, Notification | case_id, farm_id, group_id, symptoms_text, severity, created_via |
| **vet.case.diagnosed** | RPC-26 [WEB] | Vet Module | case_id, disease_id, diagnosis_type, confidence_pct |
| **vet.case.escalated** | System trigger | Expert Console ✅, AI GW ✅, ConsultationRequest | case_id, farm_id, severity=critical, escalated_at |
| **vet.case.closed** | RPC-28 [WEB] | Farm Graph update | case_id, outcome, resolved_heads |
| **vet.recommendation.added** | RPC-27 [WEB] | Farmer Notification (if withdrawal) | case_id, rec_type, withdrawal_days |
| **vet.health_restriction.created** | System trigger | Market TSP ✅ (blocks batch), AI GW ✅, Audit | restriction_id, org_id, group_id, expires_at, source (withdrawal\|quarantine) |
| **vet.vaccination_plan.created** | RPC-29 [WEB,AI] | Expert Console (review queue) | plan_id, farm_id, plan_year, generated_trigger |
| **vet.vaccination_plan_item.added** | RPC-30 [WEB] | — | plan_item_id, plan_id, group_id, disease_code, scheduled_date |
| **vet.vaccination_plan_item.reminded** | System cron ✅ | AI GW ✅, Farmer Notification | plan_item_id, farm_id, group_id, disease_code, scheduled_date, days_until |
| **vet.vaccination_plan_item.overdue** | System cron ✅ | AI GW ✅, Farmer Notification, Expert | plan_item_id, farm_id, disease_code, days_overdue |
| **vet.vaccination_record.created** | RPC-31 [WEB,AI] | Vet Plan status update | record_id, group_id, disease_code, actual_heads, vaccine_batch_number |
| **vet.epidemic_signal.detected** | RPC-32 [AI,ADMIN] | Expert Console (review required) ✅, Audit | signal_id, disease_id, region_id, case_count, severity, source |
| **vet.epidemic_signal.confirmed** | Expert [WEB] | AI GW ✅ (region alert), Audit, ProactiveAlert | signal_id, confirmed_by, confirmed_at, alert_radius_km |

> *ВАЖНО: `vet.epidemic_signal.confirmed` (не `detected`) является триггером для AI-проактивного оповещения фермеров региона. Эпидемия должна быть подтверждена экспертом до рассылки. Это требование зафиксировано в Dok3 RPC-43 (`requires_expert_approval=true` для `epidemic_warning`).*

### 3.6. Operations Domain (8 событий)

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **ops.production_plan.started** | RPC-33 [WEB,AI] | AI GW context, Farmer Notification | plan_id, farm_id, template_id, start_date, phases_count |
| **ops.farm_phase.started** | System cron ✅ | AI GW (weekly briefing), Farmer Notification | phase_id, plan_id, farm_id, phase_name, start_date, end_date |
| **ops.farm_phase.completed** | System/Farmer | Plan Module (next phase trigger) | phase_id, plan_id, completed_at, completion_type (auto\|manual) |
| **ops.farm_phase.rescheduled** | RPC-35 [WEB,AI] | AI GW ✅, Farmer Notification | phase_id, old_start, new_start, shift_days, cascaded_phases[] |
| **ops.farm_task.completed** | RPC-34 [WEB,AI] | KPI update, AI GW context | task_id, phase_id, result_value, completed_at, kpi_updates[] |
| **ops.farm_task.due_soon** | System cron ✅ | AI GW ✅, Farmer Notification | task_id, farm_id, phase_id, task_name, due_date, days_until |
| **ops.farm_task.overdue** | System cron ✅ | AI GW ✅, Expert Notification | task_id, farm_id, task_name, due_date, days_overdue |
| **ops.farm_kpi.missed** | System (fn_evaluate_kpi) | AI GW ✅, Expert Console | plan_id, kpi_code, target, actual, gap_pct |

### 3.7. Education Domain (4 события)

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **edu.course.enrolled** | RPC-38 [WEB,AI] | Farmer Notification | enrollment_id, user_id, course_id, course_name, access_type |
| **edu.lesson.completed** | RPC-39 [WEB,AI] | Progress tracker | enrollment_id, lesson_id, score, progress_pct_now |
| **edu.course.completed** | RPC-39 [WEB,AI] | Certificate trigger, Farmer Notification | enrollment_id, course_id, completed_at, final_score |
| **edu.certificate.issued** | System trigger | Farmer Notification, Audit | certificate_id, user_id, course_id, course_name, issued_at |

### 3.8. Platform Domain (5 событий)

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **platform.farm_data.extracted** | RPC-41 [AI] | Farm Graph update, Analytics | conv_id, entities_created, entities_updated, warnings[] |
| **platform.proactive_alert.created** | RPC-43 [AI,ADMIN] | Notification Worker (if approved) | alert_id, alert_type, severity, target_region_id, requires_expert_approval |
| **platform.knowledge_chunk.added** | RPC-44 [ADMIN] | AI GW (re-index trigger) | chunk_id, source_domain, title, embedding_status (pending\|done) |
| **platform.ai_conversation.started** | RPC-40 [AI] | Analytics | conv_id, org_id, channel, initial_role |
| **platform.consultation.requested** | System/AI (cross-domain) | Expert Console, Notification | request_id, requester_type, specialization, urgency |

---

### 3.9. Standards Domain (ADR-ANIMAL-01, 2026-04-15)

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **standards.animal_category.updated** | RPC-T4 / RPC-T5 / RPC-T6 [ADMIN] | Python engine (read-through cache invalidate), React Query (invalidate `animal_categories`), AI Gateway (rebuild tool schema at session-start) | code, action (added\|deprecated\|migrated), replaced_by[], valid_to?, actor_user_id |

**Продюсер:** любой из трёх admin-RPC (add/deprecate/migrate) — вызывает `publish_platform_event('standards.animal_category.updated', NULL, payload)` с `actor_org = NULL` (association-level).

**Потребители (propagation chain, target ≤60s):**
1. **Python engine** (`feeding_model.py`, `compliance.py`) — на session start читает таксономию через RPC-T3; подписчик realtime слушает event и сбрасывает кэш.
2. **React Query** (`useAnimalCategories`, `useCategoryMapping`) — `staleTime=60s` + `invalidateQueries` на event.
3. **AI Gateway graph init** — перестраивает tool JSON schema (enum значений L1) при рестарте или явном signal.

**Полная цепочка распространения** — см. DECISIONS_LOG § 2026-04-15 ADR-ANIMAL-01 § "Propagation mechanism".

---

### 3.10. Consulting Domain (ADR-CAPEX-01, 2026-04-17)

Дополняет существующие Consulting events (`consulting.project.created`,
`consulting.version.created` — уже эмитятся из RPC-C01/C05).

| canonical_event_type | Producer | Consumers | Описание |
|----------------------|----------|-----------|----------|
| **consulting.capex_override.saved** | RPC-CAPEX-5 (`rpc_save_project_infra_override`) [WEB / ADMIN] | UI React Query (invalidate project cache), QA audit log | project_id, enclosed?, support?, override_count (jsonb_array_length) |

**Продюсер:** UI ProjectWizard (после изменения материалов в Мастере) или UI
CapexTab (после toggle/qty_override/material_override изменений). RPC пишет
в `consulting_projects` (materials + infra_items_override), ставит
`needs_recalc=true`, публикует event.

**Потребители:**
1. **UI React Query** — invalidate `['consulting_project', project_id]` →
   повторное чтение проекта → CapexTab badge «Требуется пересчёт» → expert
   triggers `/calculate`.
2. **QA audit log** — платформенный event collector для отслеживания, кто
   и когда поменял CAPEX настройки.
3. **(Future)** — Dashboard проекта может показывать историю изменений CAPEX.

**Почему отдельный event, а не `consulting.version.created`:** save override
≠ recalc. Expert может сохранить много мелких правок, затем один раз
пересчитать. Event `version.created` emits только при /calculate success.

---

## 4. Схемы payload (ключевые события)

### 4.1. market.batch.matched

| Поле payload | Тип | Описание |
|--------------|-----|----------|
| after.batch_id | *uuid* | ID батча |
| after.pool_id | *uuid* | ID пула (null для прямого матча) |
| after.matched_heads | *int* | Голов в матче |
| after.agreed_price | *numeric* | Справочная цена тенге/кг на момент матча (reference_price_at_match) |
| after.match_type | *text* | "pool" \| "direct" |
| meta.matched_at | *timestamptz* | Время матча |
| meta.matched_by | *uuid* | admin user_id |

### 4.2. farm.herd_group.updated

| Поле payload | Тип | Описание |
|--------------|-----|----------|
| before.head_count | *int* | Поголовье до |
| after.head_count | *int* | Поголовье после |
| before.avg_weight_kg | *numeric* | Средний вес до |
| after.avg_weight_kg | *numeric* | Средний вес после |
| after.confidence | *int* | Уровень достоверности 0-100 (Layered Truth) |
| meta.data_source | *text* | "registration" \| "ai_extracted" \| "platform" \| "erp" |
| meta.update_source | *text* | "farmer" \| "ai_conversation" \| "erp_sync" |

### 4.3. vet.epidemic_signal.detected

| Поле payload | Тип | Описание |
|--------------|-----|----------|
| after.signal_id | *uuid* | ID сигнала |
| after.disease_id | *uuid* | Заболевание (FK → diseases) |
| after.region_id | *uuid* | Регион вспышки |
| after.case_count | *int* | Количество случаев в окне |
| after.severity | *text* | "watch" \| "warning" \| "alert" \| "emergency" |
| after.source | *text* | "ai_pattern" \| "manual_report" \| "external" |
| after.threshold_id | *uuid* | Применённый порог (P8 snapshot) |
| meta.requires_expert_approval | *boolean* | ВСЕГДА true для epidemic_warning (D62) |

### 4.4. ops.farm_phase.rescheduled

| Поле payload | Тип | Описание |
|--------------|-----|----------|
| after.phase_id | *uuid* | Сдвинутая фаза |
| before.start_date | *date* | Старая дата начала |
| after.start_date | *date* | Новая дата начала |
| after.shift_days | *int* | Сдвиг в днях (+ вперёд, - назад) |
| after.cascaded | *jsonb[]* | Зависимые фазы: [{phase_id, phase_name, new_start}] |
| meta.actor_id | *uuid* | user_id инициатора |
| meta.preview_approved | *boolean* | true = зоотехник видел превью перед применением |

---

## 5. Supabase Realtime — подписки UI

> *ИСПРАВЛЕНИЕ СР-2: Прямая подписка на `herd_groups` и `vaccination_plan_items` НЕБЕЗОПАСНА. Сложные RLS-политики с вложенными SELECT не применяются к Realtime корректно в некоторых версиях Supabase. Используйте `platform_events` как единую точку Realtime-подписки.*

| event_type / filter | Подписчик | Реакция UI | Примечание (RLS) |
|---------------------|-----------|------------|------------------|
| platform_events WHERE event_type = 'market.batch.published' | MPK (buyer cabinet) | Добавить карточку батча без reload | RLS: platform_events_read_own + публичные события без org_id фильтра ✅ |
| platform_events WHERE event_type = 'market.batch.matched' | Farmer + MPK | Обновить статус батча/пула, показать alert | org_id фильтр — каждый видит только свои события ✅ |
| platform_events WHERE event_type = 'market.pool.status_changed' | MPK + Matched Farmers | Обновить статус пула в UI | org_id фильтр ✅ |
| platform_events WHERE event_type = 'market.price_grid.updated' | Все авторизованные | Toast: "Справочные цены обновлены" | Публичное событие (org_id = null) ✅ |
| platform_events WHERE event_type = 'market.price_index.published' | Все авторизованные | Обновить график цен | Публичное событие ✅ |
| platform_events WHERE event_type = 'farm.herd_group.updated' | Farmer | Обновить счётчик на дашборде | ВМЕСТО прямой подписки на herd_groups (СР-2 fix) |
| platform_events WHERE event_type LIKE 'vet.%' | Farmer (own org) | Красный баннер в разделе Ветеринария | org_id фильтр ✅ |
| notifications WHERE user_id = :own_user_id | Farmer / MPK | Красная точка, in-app toast | Точный user_id фильтр — RLS безопасен ✅ |

### 5.1. React-пример подписки (для Lovable / Cursor)

```javascript
// ИСПРАВЛЕНО: подписываемся на platform_events (не herd_groups напрямую)
function useFarmEvents(orgId, onEvent) {
  useEffect(() => {
    const ch = supabase
      .channel(`farm-events-${orgId}`)
      .on("postgres_changes", {
        event: "INSERT",
        schema: "public",
        table: "platform_events",
        filter: `organization_id=eq.${orgId}`
      }, payload => onEvent(payload.new))
      .subscribe()
    return () => supabase.removeChannel(ch)
  }, [orgId])
}

// MPK: подписка на рынок (публичные события)
function useMarketFeed(onBatch) {
  useEffect(() => {
    const ch = supabase
      .channel("market-feed")
      .on("postgres_changes", {
        event: "INSERT",
        schema: "public",
        table: "platform_events",
        filter: "event_type=eq.market.batch.published" // canonical name!
      }, payload => onBatch(payload.new))
      .subscribe()
    return () => supabase.removeChannel(ch)
  }, [])
}
```

---

## 6. AI Gateway — проактивные реакции

> *ИСПРАВЛЕНИЕ КР-3: AI Proactive Worker НЕ пишет напрямую в таблицу `notifications`. Все проактивные сообщения создаются через RPC-43 `rpc_create_proactive_alert`. RPC проверяет права, создаёт запись в `proactive_alerts`, Notification Worker забирает одобренные.*

| event_type (canonical) | Задержка | Условие | Действие (через RPC-43 / notification) |
|------------------------|----------|---------|----------------------------------------|
| vet.vaccination_plan_item.overdue | **немедленно** | days_overdue >= 1 | RPC-43: alert_type=vaccination_reminder. Auto-approved. WhatsApp: "Вакцинация {disease} просрочена на {N} дней" |
| vet.health_restriction.created | **немедленно** | org_id = farmer | RPC-43: alert_type=disease_watch. Auto-approved. WhatsApp: "Введено ограничение на продажу скота" |
| vet.epidemic_signal.confirmed | **немедленно** | farm в зоне region_id | RPC-43: alert_type=epidemic_warning. requires_expert_approval=true (D62). Ждёт одобрения. ⚠️ NOT auto-sent |
| market.batch.expired | **немедленно** | org_id = farmer | Напрямую в notifications (template: batch_expired) — не через RPC-43 (это не alert, а транзакционное уведомление) |
| market.batch.matched | **немедленно** | org_id = farmer | Напрямую в notifications (template: batch_matched_farmer) — транзакционное, не проактивное |
| feed.inventory.low | **немедленно** | days_remaining < 14 | RPC-43: alert_type=seasonal_prevention. Auto-approved. WhatsApp: "Запасов {feed} на {N} дней" |
| ops.farm_phase.rescheduled | **60 мин** | shift_days > 7 | Напрямую в notifications (template: phase_shifted_notice) — информационное уведомление |
| ops.farm_task.overdue | **немедленно** | days_overdue >= 1 | RPC-43: alert_type=vaccination_reminder (reuse) или новый type=task_reminder. Auto-approved |
| ops.farm_kpi.missed | **2 ч** | gap_pct > 15% | RPC-43: alert_type=disease_watch (reuse) или новый type=kpi_alert. Expert уведомляется отдельно |
| identity.organization.restricted | **немедленно** | org_id = farmer/mpk | Напрямую в notifications (template: restriction_notice) — критичное транзакционное уведомление |

### 6.1. Разграничение: RPC-43 vs прямая запись в notifications

| Тип сообщения | Метод | Примеры |
|---------------|-------|---------|
| Проактивный alert (инициирован системой по событию) | RPC-43 `rpc_create_proactive_alert` → proactive_alerts table → Notification Worker | epidemic_warning, feed_low, vaccination_reminder, kpi_alert |
| Транзакционное уведомление (следствие действия пользователя) | Прямой INSERT в notifications (внутри RPC) | batch_matched, batch_expired, phase_shifted, restriction_notice, certificate_issued |

### 6.2. Дедупликация проактивных сообщений (НОВОЕ)

> *Без дедупликации: 10 overdue вакцинаций = 10 WhatsApp за 60 сек = блокировка номера Meta WhatsApp Business API. Это не open question — это обязательный механизм.*

```sql
-- В 009_patch_event_audit.sql
CREATE TABLE IF NOT EXISTS public.proactive_dedup (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id       uuid NOT NULL REFERENCES public.organizations(id),
  alert_type   text NOT NULL,
  entity_id    uuid,  -- farm_id, plan_item_id и т.д.
  last_sent_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_dedup_org_type_entity
  ON public.proactive_dedup (org_id, alert_type, COALESCE(entity_id, gen_random_uuid()));
```

```python
# Политика: не более 1 сообщения типа X для организации Y за период Z
# Реализация в AI Gateway Python:

DEDUP_COOLDOWN = {
    'vaccination_reminder': timedelta(hours=24),  # 1 раз в день
    'feed_low':             timedelta(hours=24),
    'task_overdue':         timedelta(hours=12),
    'kpi_alert':            timedelta(hours=48),
    'epidemic_warning':     timedelta(hours=1),    # критично — чаще
    'batch_expired':        timedelta(hours=0),    # всегда (однократно)
}

async def should_send(org_id, alert_type, entity_id):
    result = await supabase.rpc("fn_check_dedup", {
        "p_org_id": org_id,
        "p_alert_type": alert_type,
        "p_entity_id": entity_id,
        "p_cooldown_hours": DEDUP_COOLDOWN[alert_type].seconds // 3600
    }).execute()
    return result.data["can_send"]  # bool
```

---

## 7. Каталог шаблонов уведомлений

ИСПРАВЛЕНИЕ СР-5: Канал (channel) теперь определяется из `user_notification_preferences`, не хардкодится в шаблоне. Колонка "Дефолтный канал" — только для случаев когда preference не настроена.

| template_id | Канал | Аудитория | Текст (шаблон с переменными) |
|-------------|-------|-----------|------------------------------|
| batch_matched_farmer | WA + in_app | Farmer | *Батч подобран! {head_count} гол. {category}, дата отгрузки {ready_date}. Расчётная выручка: {estimated_total} ₸. Детали в кабинете.* |
| batch_matched_mpk | WA + in_app | MPK | *Новый матч: {head_count} гол. {category}, {region}. Вес: {avg_weight} кг. Дата: {ready_date}. Подтвердите в кабинете.* |
| batch_expired | WA | Farmer | *{head_count} гол. {category} — батч истёк без покупателя. Хотите переопубликовать? Ответьте ДА.* |
| batch_published_mpk | in_app | MPK | *Новый лот: {head_count} гол. {category}, {region}. Грейд: {grade}. Дата готовности: {ready_date}.* |
| batch_cancelled_mpk | in_app | MPK | *Лот {head_count} гол. {category} отменён продавцом. Пул обновлён.* |
| pool_contacts_revealed | WA + in_app | Farmer | *Контакт покупателя раскрыт: {mpk_name}. Дата отгрузки: {dispatch_date}. Контакт менеджера: {contact}.* |
| vaccination_overdue | WA | Farmer | *{farmer_name}, вакцинация {disease_name} для группы «{group_name}» просрочена на {days_overdue} дней. Ответьте ПЛАН.* |
| vaccination_reminder | WA | Farmer | *{farmer_name}, напоминание: вакцинация {disease_name} через {days_until} дней ({scheduled_date}).* |
| health_restriction_notice | WA + in_app | Farmer | *Введено ограничение на продажу: {restriction_type}. Причина: {reason}. Снятие: {expires_at}.* |
| restriction_notice | WA + in_app | Farmer/MPK | *Ограничение организации: {restriction_type}. Детали в кабинете.* |
| restriction_lifted | WA + in_app | Farmer | *Ограничение снято. Вы снова можете публиковать партии в TSP.* |
| epidemic_alert_region | WA | Farmer | *⚠️ Вспышка {disease_name} в вашем районе. Уровень: {severity}. Рекомендации эксперта: {recommendations}. Нужна помощь?* |
| consultation_assigned | WA + in_app | Farmer | *Запрос принят. {expert_name} свяжется в течение {eta_hours} ч.* |
| consultation_resolved | in_app | Farmer | *Консультация завершена. Рекомендации от {expert_name} в личном кабинете.* |
| membership_activated | WA + in_app | Farmer | *Статус изменён: {old_level} → {new_level}. {consequence_text}* |
| membership_suspended | WA + in_app | Farmer | *Членство приостановлено. Причина: {reason}. Для вопросов: {contact_info}.* |
| application_approved | WA + in_app | Farmer | *Заявка одобрена! Ваш статус: {new_level}. Откройте кабинет.* |
| application_rejected | WA + in_app | Farmer | *Заявка отклонена. Причина: {reject_reason}. Контакт: {contact_info}.* |
| ration_ready | in_app | Farmer | *Рацион рассчитан для «{group_name}». Сводка: {summary}. Раздел → Кормление.* |
| feed_low_warning | WA | Farmer | *{farmer_name}, запасов {feed_name} на {days_left} дн. Расход: {daily_kg} кг/день. Нужна помощь с заказом?* |
| phase_started | WA | Farmer | *Началась фаза «{phase_name}». Первые задачи: {first_tasks}. Удачи!* |
| phase_shifted_notice | WA | Farmer | *Фаза «{phase_name}» перенесена → {new_start_date}. Затронуто задач: {affected_count}.* |
| task_due_soon | WA | Farmer | *{farmer_name}, задача «{task_name}» через {days_until} дней ({due_date}). Готов помочь подготовиться?* |
| task_overdue | WA | Farmer | *{farmer_name}, задача «{task_name}» просрочена на {days_overdue} дней. Зоотехник уведомлён.* |
| kpi_missed | in_app | Farmer | *KPI «{kpi_label}»: план {target} {unit}, факт {actual}. Отклонение {gap_pct}%.* |
| certificate_issued | WA + in_app | Farmer | *🎓 Сертификат получен! «{course_name}» пройден. Доступен в кабинете.* |
| enrollment_confirmed | in_app | Farmer | *Записаны на курс «{course_name}». Начало: {start_date}.* |
| epidemic_signal_detected | in_app | Admin/Expert | *Зафиксирован сигнал: {disease_name}, {region}. Требует подтверждения.* |

---

## 8. Журнал аудита

ИСПРАВЛЕНИЕ КР-4: `is_audit boolean` в `platform_events` заменяет хардкодированный `AUDITED_EVENTS TEXT[]`. Список аудируемых типов хранится в `event_audit_registry` (P8: Standards as Data). Admin добавляет строку → новый тип аудируется без деплоя.

### 8.1. Аудируемые события (seed event_audit_registry)

| canonical_event_type | Причина аудита |
|----------------------|----------------|
| **identity.organization.restricted** | Ограничение организации — юридически значимое действие |
| **identity.organization.registered** | Регистрация — точка входа в систему, baseline для аудита |
| **identity.membership.activated** | Изменение членства — влияет на доступ к TSP и функциям |
| **identity.membership.suspended** | Приостановка членства — юридически значимое |
| **identity.membership_application.decided** | Решение по заявке — трассировка процесса вступления |
| **market.batch.matched** | Матч = факт координации — требует трассировки по антимонопольному законодательству |
| **market.batch.cancelled** | Отмена после публикации — возможен спор |
| **market.batch.match_rolled_back** | Откат матча — исключительная ситуация, требует объяснения |
| **market.pool.status_changed** | Смена статуса пула — критический бизнес-процесс |
| **market.pool.contacts_revealed** | Раскрытие контактов МПК — юридически значимый момент |
| **market.price_grid.updated** | Изменение справочных цен — Tier 3, требует трассировки |
| **vet.health_restriction.created** | Ограничение на продажу скота — влияет на TSP |
| **vet.epidemic_signal.detected** | Регистрация эпидсигнала — требует трассировки для МСХ |
| **vet.epidemic_signal.confirmed** | Подтверждение экспертом — точка принятия решения |
| **farm.farm.created** | Создание фермы — baseline запись |
| **edu.certificate.issued** | Выдача сертификата — юридически значимый документ |
| **platform.proactive_alert.created** | Проактивный alert — трассировка исходящих коммуникаций |
| **identity.consultation_request.resolved** | Закрытие консультации экспертом — медицинский/зоотехнический документ |

---

## 9. Паттерн публикации событий

> *`publish_event()` — внутренний хелпер, вызывается ТОЛЬКО внутри RPC-функций PostgreSQL. Приложение (Lovable, AI Gateway) НЕ вызывает `publish_event()` напрямую. Единственная точка входа — соответствующий RPC из Dok 3 каталога.*

```sql
-- Хелпер (001_kernel.sql или 009_patch)
CREATE OR REPLACE FUNCTION public.publish_event(
  p_event_type      text,
  p_entity_type     text,
  p_entity_id       uuid,
  p_organization_id uuid,
  p_actor_type      text,
  p_actor_id        uuid,
  p_payload         jsonb DEFAULT '{}'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.platform_events (
    event_type, entity_type, entity_id, organization_id,
    actor_type, actor_id, payload
    -- is_audit: заполняется триггером fn_audit_from_platform_event (BEFORE INSERT)
  ) VALUES (
    p_event_type, p_entity_type, p_entity_id, p_organization_id,
    p_actor_type, p_actor_id, p_payload
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
```

**Пример использования в RPC-10 `rpc_publish_batch()`:**

```sql
-- После UPDATE batches SET status = 'published':
PERFORM public.publish_event(
  'market.batch.published',  -- CANONICAL name из реестра Section 1
  'batches',
  p_batch_id,
  v_batch.organization_id,
  'farmer',
  p_actor_id,
  jsonb_build_object(
    'after', jsonb_build_object(
      'batch_id', p_batch_id,
      'organization_id', v_batch.organization_id,
      'category_code', v_batch.category_code,
      'head_count', v_batch.head_count,
      'grade_code', v_batch.grade_code,
      'region_id', v_batch.region_id,
      'ready_date', v_batch.ready_date
    ),
    'meta', jsonb_build_object('source', p_source)
  )
);
```

---

## 10. Архитектурные решения (обновлено)

**D66. Canonical event_type: domain.entity.action (ПОДТВЕРЖДЕНО)**

Единый реестр в Section 1 — единственный источник правды. Все три документа (Dok1, Dok3, Dok4) синхронизированы на canonical именах. Dok3 v1.3 обновит все deprecated имена.

**D67. Phase 1: Polling + Supabase Realtime для UI (ПОДТВЕРЖДЕНО)**

Polling: 30/60/300 сек в зависимости от тира (Section 1.2). Realtime: только `platform_events` через фильтр `event_type`. Прямые подписки на `herd_groups`, `vaccination_plan_items` — ЗАПРЕЩЕНЫ до подтверждения Supabase RLS совместимости в staging-среде.

**D68. Каналы: WhatsApp + in_app (ОБНОВЛЕНО)**

Канал определяется из `user_notification_preferences`, не хардкодится в шаблоне. Default: оба канала включены. Farmer или MPK могут отключить любой канал в настройках.

**D68-new. Разграничение RPC-43 vs прямая запись в notifications**

Правило: всё что инициировано системой по событию (без действия пользователя) — через RPC-43. Всё что является прямым следствием RPC-вызова пользователя — напрямую в notifications внутри того же RPC. Граница: "Кто инициатор коммуникации — система или пользователь?"

**D69. audit_log через event_audit_registry (ОБНОВЛЕНО)**

`is_audit boolean` в `platform_events` + `event_audit_registry` таблица. Триггер `fn_audit_from_platform_event` проверяет EXISTS в registry вместо IN (hardcoded array). Добавление нового audited типа = INSERT в registry без деплоя (P7, P8).

**D.Dedup. Дедупликация проактивных сообщений (НОВОЕ)**

`proactive_dedup` таблица с cooldown-интервалами по alert_type. Cooldown настраивается в константах AI Gateway Python, не в БД (частота изменений низкая, тестируемость важна). При >5 событий одного типа за 5 мин → один суммарный alert вместо N отдельных.

---

## 11. Статус открытых вопросов

| ID | Статус | Решение |
|----|--------|---------|
| **OQ-1** | ✅ ЗАКРЫТ | Шаблоны уведомлений хранятся в коде (i18n) на Phase 1. При необходимости редактирования без деплоя — добавить таблицу `notification_templates` в Dok2 v2.0. Решение отложено осознанно. |
| **OQ-2** | ✅ ЗАКРЫТ | Дедупликация реализована через `proactive_dedup` + cooldown-константы (Section 6.2). Cooldown по типу: vaccination_reminder=24ч, feed_low=24ч, task_overdue=12ч. |
| **OQ-3** | ✅ ЗАКРЫТ | Retry: max 3 попытки с интервалом 5/15/60 мин. После окончательного отказа: `delivery_status=failed`, `admin_alert=true` в payload. Notification Worker логирует в `audit_log`. |
| **OQ-4** | Открыт → Dok2 v2.0 | Архивирование `platform_events` при >1M строк: партиционирование по `created_at`. Задача для Dok2 v2.0 при масштабировании >5000 фермеров. |

---

## Итог v1.1

| Параметр | Значение |
|----------|----------|
| **Версия** | v1.1 — 5 марта 2026 (полная замена v1.0) |
| **Canonical событий** | 59 (были 34 в v1.0) — полное покрытие Dok1 + Dok3 |
| **Устранено дефектов** | 12 из 12 (4 критических, 5 серьёзных, 3 структурных) |
| **Новые миграции** | `009_patch_event_audit.sql` (is_audit, event_audit_registry, proactive_dedup, user_notification_preferences) |
| **Notification шаблонов** | 28 (были 18 в v1.0) |
| **Realtime подписок** | 8 — все через platform_events (не прямые таблицы) |
| **AI Proactive триггеров** | 10 (были 8) — разграничены RPC-43 vs транзакционные |
| **Требует обновления** | Dok3 v1.3: заменить deprecated event_type имена на canonical |
| **Следующий документ** | **Dok 5: AI Gateway Architecture** |
