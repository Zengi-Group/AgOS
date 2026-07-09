"""
AgOS AI Gateway — Notification Worker (Slice 2)

D-S2-2: Minimal WhatsApp + in-app notification sender.
Claims from `notifications` table via claim_pending_notifications (SKIP LOCKED).
Sends WhatsApp messages via Cloud API. Marks sent/failed via RPCs.

This is a subset of the full proactive dispatch (Slice 4).
Handles only the notification delivery path — no AI triggers.

Usage:
    # As standalone worker (cron every 30s):
    python -m ai_gateway.notification_worker

    # As FastAPI endpoint (called by pg_cron or external scheduler):
    POST /notifications/process  (internal API key required)
"""
import logging
import os
import uuid
from typing import Any

import httpx

from ai_gateway.config import get_settings, get_supabase

logger = logging.getLogger("agos.gateway.notifications")

WORKER_ID = f"notif-{uuid.uuid4().hex[:8]}"
BATCH_SIZE = 10

# Dok 4 §7: Notification templates (Russian). Texts are COPIED from the Dok 4 §7
# catalog verbatim — do not paraphrase (CLAUDE.md: reference canon, don't invent).
TEMPLATES: dict[str, str] = {
    "application_approved": "Заявка одобрена! Ваш статус: {new_level}. Откройте кабинет.",
    "application_rejected": "Заявка отклонена. Причина: {reject_reason}. Контакт: {contact_info}.",
    # ── ARS-143 (C5): TSP push-relevant templates (Dok 4 §7) ──────────────────
    # Anonymity invariant (D-M6-5/12): before `market.batch.confirmed` the
    # counterparty legal_name is NOT in the payload — matched/published/cancelled
    # texts below carry NO counterparty name by construction. pool_contacts_revealed
    # runs only AT/AFTER reveal, so {mpk_name} there is lawful.
    "batch_matched_farmer": "Батч подобран! {head_count} гол. {category}, дата отгрузки {ready_date}. Расчётная выручка: {estimated_total} ₸. Детали в кабинете.",
    "batch_matched_mpk": "Новый матч: {head_count} гол. {category}, {region}. Вес: {avg_weight} кг. Дата: {ready_date}. Подтвердите в кабинете.",
    "batch_published_mpk": "Новый лот: {head_count} гол. {category}, {region}. Грейд: {grade}. Дата готовности: {ready_date}.",
    "batch_cancelled_mpk": "Лот {head_count} гол. {category} отменён продавцом. Пул обновлён.",
    # market.batch.dispatched (rpc_confirm_dispatch): post-confirmed, payload carries
    # no name → anonymous by construction. offer.created: pre-confirmed → no name
    # (D-M6-5/12); event now EMITTED by rpc_retry_match_pool / rpc_lower_batch_price
    # (TSP-FLOW-06, 2026-07-08).
    "batch_dispatched_mpk": "Продавец отгрузил партию по вашей сделке. Дата отгрузки: {dispatched_at}. Детали в кабинете.",
    "offer_created_mpk": "Новое предложение по партии. Цена: {offered_price_per_kg} ₸/кг. Действует до {expires_at}. Ответьте в кабинете.",
    "pool_contacts_revealed": "Контакт покупателя раскрыт: {mpk_name}. Дата отгрузки: {dispatch_date}. Контакт менеджера: {contact}.",
}

# ARS-143 (C5) + ARS-144/155 (C6): deep-link path per template for the push `data`
# payload. CapacitorHost.pushNotificationActionPerformed reads data.path → onDeepLink
# → router (ARS-155). Missing entry → client falls back to '/cabinet' (no crash).
# {placeholders} are filled from notification params at dispatch time.
#
# Paths MUST match REAL routes (verified 2026-07-08):
#   Farmer surface (CabinetApp.tsx): /cabinet/batch/:id  (pool has no URL — modal only)
#   MPK surface  (MpkApp.tsx):       /mpk/tsp, /mpk/offers  (pool detail = modal, no URL)
# Audience per Dok 4 §7: *_farmer + pool_contacts_revealed → Farmer; *_mpk → MPK.
# Pool detail screens are modals (opened by id, no route), so pool-scoped events land
# on the nearest listing route that contains that pool.
PUSH_DEEP_LINKS: dict[str, str] = {
    "batch_matched_farmer": "/cabinet/batch/{batch_id}",
    # matched/dispatched/new-offer are ACTIONABLE for MPK → the offers screen
    # (MpkIncomingOffersScreen: accept/reject); published/cancelled are feed
    # updates → the TSP browse screen (MpkTspScreen: pools + batches).
    "batch_matched_mpk": "/mpk/offers",
    "batch_published_mpk": "/mpk/tsp",
    "batch_cancelled_mpk": "/mpk/tsp",
    "batch_dispatched_mpk": "/mpk/offers",
    "offer_created_mpk": "/mpk/offers",
    "pool_contacts_revealed": "/cabinet/batch/{batch_id}",
}

# Push notification title (Android/iOS show title + body). Body = rendered template.
PUSH_TITLE = "TURAN — рынок"


def render_template(template_id: str, params: dict[str, Any]) -> str:
    """Render notification text from template + params."""
    template = TEMPLATES.get(template_id)
    if not template:
        logger.warning("Unknown template_id: %s — using raw params", template_id)
        return f"[{template_id}] {params}"
    try:
        return template.format(**params)
    except KeyError as e:
        logger.error("Template %s missing param: %s", template_id, e)
        return template.format_map({**{k: "" for k in ["new_level", "reject_reason", "contact_info", "org_name"]}, **params})


def send_whatsapp_message(phone: str, text: str, settings: Any) -> bool:
    """
    Send a WhatsApp text message via Cloud API.

    Returns True on success, False on failure.
    Requires WHATSAPP_TOKEN and WHATSAPP_PHONE_NUMBER_ID env vars.
    """
    if not settings.WHATSAPP_TOKEN or not settings.WHATSAPP_PHONE_NUMBER_ID:
        logger.warning("WhatsApp not configured — skipping send to %s", phone[:6] if phone else "?")
        return False

    url = f"https://graph.facebook.com/v21.0/{settings.WHATSAPP_PHONE_NUMBER_ID}/messages"
    headers = {
        "Authorization": f"Bearer {settings.WHATSAPP_TOKEN}",
        "Content-Type": "application/json",
    }
    payload = {
        "messaging_product": "whatsapp",
        "to": phone,
        "type": "text",
        "text": {"body": text},
    }

    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.post(url, json=payload, headers=headers)
            if resp.status_code in (200, 201):
                logger.info("WhatsApp sent to %s (status=%d)", phone[:6], resp.status_code)
                return True
            else:
                logger.error(
                    "WhatsApp API error: status=%d body=%s",
                    resp.status_code,
                    resp.text[:500],
                )
                return False
    except httpx.TimeoutException:
        logger.error("WhatsApp API timeout for %s", phone[:6] if phone else "?")
        return False
    except Exception as e:
        logger.error("WhatsApp send failed: %s", e, exc_info=True)
        return False


def _build_deep_link(template_id: str, params: dict[str, Any]) -> str:
    """Resolve the deep-link path for a push from its template + params (C6).

    Falls back to '/cabinet' when the template has no mapping or a placeholder
    param is missing — client must never crash on a bad path (ARS-155).
    """
    pattern = PUSH_DEEP_LINKS.get(template_id)
    if not pattern:
        return "/cabinet"
    try:
        return pattern.format(**params)
    except (KeyError, IndexError):
        logger.warning("push deep-link: %s missing param for %s", template_id, pattern)
        return "/cabinet"


def send_push(user_id: str, text: str, path: str, settings: Any) -> bool:
    """ARS-142 (C4): dispatch a native push by invoking the push-send edge fn (C3/ARS-141).

    The edge function resolves the user's active push_token rows itself (service_role),
    sends via FCM/APNs, retries, and deactivates dead tokens — the worker only hands it
    user_id + rendered text + deep-link data. Returns True on a 2xx from the function.
    """
    if not settings.SUPABASE_URL or not settings.SUPABASE_SERVICE_ROLE_KEY:
        logger.warning("push: Supabase not configured — skipping send to %s", user_id[:8])
        return False

    url = f"{settings.SUPABASE_URL}/functions/v1/push-send"
    headers = {
        "Authorization": f"Bearer {settings.SUPABASE_SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    }
    body = {
        "user_id": user_id,
        "title": PUSH_TITLE,
        "body": text,
        "data": {"path": path},
    }
    try:
        with httpx.Client(timeout=20.0) as client:
            resp = client.post(url, json=body, headers=headers)
            if resp.status_code in (200, 201):
                logger.info("push sent for user %s (%s)", user_id[:8], resp.text[:120])
                return True
            logger.error("push-send edge error: status=%d body=%s", resp.status_code, resp.text[:300])
            return False
    except httpx.TimeoutException:
        logger.error("push-send edge timeout for user %s", user_id[:8])
        return False
    except Exception as e:
        logger.error("push send failed: %s", e, exc_info=True)
        return False


def process_notification_batch() -> dict[str, int]:
    """
    Claim and process a batch of pending notifications.

    Flow:
        claim_pending_notifications(BATCH_SIZE, WORKER_ID)
        → for each notification:
            if channel=whatsapp → send via Cloud API
            if channel=in_app  → mark as sent (UI reads from DB)
        → mark_notification_sent / mark_notification_failed

    Returns: { "claimed": N, "sent": N, "failed": N }
    """
    supabase = get_supabase()
    settings = get_settings()

    # 1. Claim batch (SKIP LOCKED — L-NEW-2)
    try:
        result = supabase.rpc("claim_pending_notifications", {
            "p_batch_size": BATCH_SIZE,
            "p_worker_id": WORKER_ID,
        }).execute()
    except Exception as e:
        logger.error("claim_pending_notifications failed: %s", e)
        return {"claimed": 0, "sent": 0, "failed": 0}

    notifications = result.data or []
    if not notifications:
        return {"claimed": 0, "sent": 0, "failed": 0}

    logger.info("Claimed %d notifications (worker=%s)", len(notifications), WORKER_ID)

    sent = 0
    failed = 0

    for notif in notifications:
        notif_id = notif["id"]
        channel = notif["channel"]
        template_id = notif["template_id"]
        params = notif.get("params") or {}
        user_id = notif["user_id"]
        organization_id = notif["organization_id"]

        try:
            # Render message text
            text = render_template(template_id, params)

            if channel == "whatsapp":
                # Look up user phone (DEF-013/P-AI-1: via RPC)
                phone = _get_user_phone(supabase, user_id, organization_id)
                if not phone:
                    _mark_failed(supabase, notif_id, "NO_PHONE: user has no phone number")
                    failed += 1
                    continue

                success = send_whatsapp_message(phone, text, settings)
                if success:
                    _mark_sent(supabase, notif_id)
                    sent += 1
                else:
                    _mark_failed(supabase, notif_id, "WHATSAPP_API_ERROR")
                    failed += 1

            elif channel == "push":
                # ARS-142 (C4): native push via the push-send edge fn (ARS-141).
                # Deep-link path derived from template+params (C6) so a tap lands on
                # the right screen (ARS-155). whatsapp/in_app paths untouched.
                path = _build_deep_link(template_id, params)
                success = send_push(str(user_id), text, path, settings)
                if success:
                    _mark_sent(supabase, notif_id)
                    sent += 1
                else:
                    _mark_failed(supabase, notif_id, "PUSH_SEND_ERROR")
                    failed += 1

            elif channel == "in_app":
                # In-app notifications are "sent" immediately — UI reads from DB
                _mark_sent(supabase, notif_id)
                sent += 1

            else:
                _mark_failed(supabase, notif_id, f"UNKNOWN_CHANNEL: {channel}")
                failed += 1

        except Exception as e:
            logger.error("Failed to process notification %s: %s", notif_id, e, exc_info=True)
            _mark_failed(supabase, notif_id, str(e)[:500])
            failed += 1

    logger.info("Batch done: claimed=%d sent=%d failed=%d", len(notifications), sent, failed)
    return {"claimed": len(notifications), "sent": sent, "failed": failed}


def _get_user_phone(supabase, user_id: str, organization_id: str) -> str | None:
    """Look up user phone via RPC (DEF-013/P-AI-1: PII access org-scoped)."""
    try:
        result = (
            supabase
            .rpc("rpc_get_user_phone", {
                "p_organization_id": str(organization_id),
                "p_user_id": str(user_id),
            })
            .execute()
        )
        return result.data  # returns phone string or None
    except Exception as e:
        logger.error("Failed to get phone for user %s: %s", user_id[:8], e)
        return None


def _mark_sent(supabase, notif_id: str) -> None:
    """Mark notification as sent via RPC."""
    try:
        supabase.rpc("mark_notification_sent", {"p_notification_id": notif_id}).execute()
    except Exception as e:
        logger.error("mark_notification_sent failed for %s: %s", notif_id[:8], e)


def _mark_failed(supabase, notif_id: str, error: str) -> None:
    """Mark notification as failed via RPC (with retry logic in DB)."""
    try:
        supabase.rpc("mark_notification_failed", {
            "p_notification_id": notif_id,
            "p_error": error,
        }).execute()
    except Exception as e:
        logger.error("mark_notification_failed failed for %s: %s", notif_id[:8], e)


# ─── TAXONOMY-M3b → Slice 4: platform_event polling ─────────────────────────
# Dok 4 §3.9: standards.animal_category.updated → invalidate taxonomy caches
# in both ai_gateway (this process) and consulting_engine (separate process).
#
# Design note: platform_events is APPEND-ONLY (no processed_at column — by design,
# it is an immutable event log per Dok 4 §2). Polling uses a module-level watermark
# (_pe_watermark) that persists for the process lifetime. Reset on restart = catch
# events from last 60s to avoid missing events during restart window.
#
# SKIP LOCKED: N/A for a read-only SELECT; watermark ensures each event is
# processed exactly once per process (service_role read access).

from datetime import datetime, timezone, timedelta

# Watermark: process events newer than this timestamp.
# Initialized to now()-60s to catch events during deploy window.
_pe_watermark: datetime = datetime.now(timezone.utc) - timedelta(seconds=60)


def poll_platform_events() -> dict:
    """
    Poll platform_events for new events since last check (watermark pattern).

    Called periodically (e.g. from /proactive/dispatch or standalone cron).
    Returns: {"polled": N, "handled": N, "errors": N}

    platform_events is append-only — no processed_at update needed.
    Watermark advances after each successful poll.
    """
    global _pe_watermark

    supabase = get_supabase()
    since = _pe_watermark.isoformat()
    now = datetime.now(timezone.utc)

    try:
        # service_role: SELECT allowed without RLS restriction
        result = (
            supabase.table("platform_events")
            .select("id, event_type, payload, created_at")
            .gt("created_at", since)
            .order("created_at")
            .limit(100)
            .execute()
        )
    except Exception as e:
        logger.error("poll_platform_events: SELECT failed: %s", e)
        return {"polled": 0, "handled": 0, "errors": 1}

    events = result.data or []
    if not events:
        _pe_watermark = now
        return {"polled": 0, "handled": 0, "errors": 0}

    logger.info(
        "poll_platform_events: %d new events since %s",
        len(events),
        since[:19],
    )

    handled = 0
    errors = 0

    for event in events:
        event_type = event.get("event_type", "")
        payload = event.get("payload") or {}
        try:
            handle_platform_event(event_type, payload)
            handled += 1
        except Exception as e:
            logger.error(
                "poll_platform_events: handler failed for %s (id=%s): %s",
                event_type,
                str(event.get("id", "?"))[:8],
                e,
            )
            errors += 1

    # Advance watermark past the last processed event
    last_created = events[-1].get("created_at", now.isoformat())
    try:
        _pe_watermark = datetime.fromisoformat(last_created.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        _pe_watermark = now

    return {"polled": len(events), "handled": handled, "errors": errors}


def handle_platform_event(event_type: str, payload: dict) -> None:
    """Dispatch a platform_events row to the appropriate handler.

    Called from future polling loop (Slice 4 proactive dispatch).
    Currently only wires taxonomy cache invalidation.
    """
    if event_type == "standards.animal_category.updated":
        _handle_taxonomy_updated(payload)
    # Other event types handled in Slice 4


def _handle_taxonomy_updated(payload: dict) -> None:
    """Invalidate in-process L1 taxonomy cache on standards.animal_category.updated.

    ai_gateway.taxonomy._cache holds the L1 code list for tool schemas.
    After invalidation, next call to get_l1_codes() re-fetches from DB.
    """
    try:
        from ai_gateway.taxonomy import invalidate_l1
        invalidate_l1()
        logger.info(
            "taxonomy_updated: L1 cache invalidated (action=%s, code=%s)",
            payload.get("action", "?"),
            payload.get("code", "?"),
        )
    except Exception as exc:
        logger.error("taxonomy_updated: invalidate_l1 failed: %s", exc)

    # Consulting_engine runs in a separate process — its TaxonomyCache must be
    # invalidated via an HTTP call to /internal/taxonomy/invalidate or a shared
    # Redis key. Deferred to Slice 4 when service mesh is defined.
    logger.debug("taxonomy_updated: consulting_engine invalidation deferred to Slice 4")


# --- Standalone runner ---
if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    result = process_notification_batch()
    print(f"Result: {result}")
