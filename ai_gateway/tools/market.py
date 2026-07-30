"""
AgOS AI Gateway — Market Tools (Slice 5a)

Dok 5 §6.5: Trading agent role tools for market operations.
AI-16..21 already in d07. New RPCs: RPC-11, 17, 18 in d02.

Tools:
    AI-16: get_price_grid         -> rpc_get_price_grid (d07, read)
    AI-17: get_aggregated_supply  -> rpc_get_aggregated_supply (d07, read)
    AI-18: get_aggregated_demand  -> rpc_get_aggregated_demand (d07, read)
    AI-19: get_org_batches        -> rpc_get_org_batches (d07, read)
    AI-20: create_batch           -> rpc_create_batch (d07, write, confirmation!)
    AI-21: publish_batch          -> rpc_publish_batch (d07, write, confirmation!)
    NEW:   cancel_batch           -> rpc_cancel_batch (d02, write, confirmation!)
    NEW:   get_price_for_sku      -> rpc_get_price_for_sku (d02, read)
    NEW:   get_market_summary     -> rpc_get_market_summary (d02, read)
"""
import logging
from typing import Any, Optional

from supabase import Client

logger = logging.getLogger("agos.gateway.tools.market")


MARKET_TOOL_DEFINITIONS = [
    {
        "name": "get_price_grid",
        "description": (
            "Получить справочные цены по категориям скота. "
            "ВАЖНО: всегда показывай дисклеймер из ответа."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "region_id": {"type": "string", "description": "UUID региона (необязательно)"},
            },
            "required": [],
        },
    },
    {
        "name": "get_aggregated_supply",
        "description": "Агрегированное предложение на рынке по категориям (анонимные данные).",
        "input_schema": {
            "type": "object",
            "properties": {
                "target_month": {"type": "string", "description": "YYYY-MM-01 (необязательно)"},
                "region_id": {"type": "string", "description": "UUID региона (необязательно)"},
            },
            "required": [],
        },
    },
    {
        "name": "get_aggregated_demand",
        "description": "Агрегированный спрос МПК по категориям (анонимные данные).",
        "input_schema": {
            "type": "object",
            "properties": {
                "target_month": {"type": "string", "description": "YYYY-MM-01 (необязательно)"},
                "region_id": {"type": "string", "description": "UUID региона (необязательно)"},
            },
            "required": [],
        },
    },
    {
        "name": "get_org_batches",
        "description": "Мои батчи — список батчей фермера с фильтрацией по статусу.",
        "input_schema": {
            "type": "object",
            "properties": {
                "status_filter": {"type": "string", "enum": ["draft", "published", "matched", "cancelled", "expired", "all"], "description": "Фильтр по статусу"},
            },
            "required": [],
        },
    },
    {
        "name": "create_batch",
        "description": (
            "Создать батч (партию) на продажу. "
            "ТРЕБУЕТ подтверждения (P-AI-3). Проверяет health restrictions."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "farm_id": {"type": "string", "description": "UUID фермы"},
                "sku_id": {"type": "string", "description": "UUID категории ТСП"},
                "heads": {"type": "integer", "description": "Количество голов"},
                "target_month": {"type": "string", "description": "YYYY-MM-01"},
                "avg_weight_kg": {"type": "number", "description": "Средний вес (необязательно)"},
            },
            "required": ["farm_id", "sku_id", "heads", "target_month"],
        },
    },
    {
        "name": "publish_batch",
        "description": "Опубликовать батч на рынке. После публикации категория фиксируется.",
        "input_schema": {
            "type": "object",
            "properties": {
                "batch_id": {"type": "string", "description": "UUID батча"},
            },
            "required": ["batch_id"],
        },
    },
    {
        "name": "cancel_batch",
        "description": "Отменить батч. Возможно только для draft/published без матчей.",
        "input_schema": {
            "type": "object",
            "properties": {
                "batch_id": {"type": "string", "description": "UUID батча"},
                "reason": {"type": "string", "description": "Причина отмены"},
            },
            "required": ["batch_id"],
        },
    },
    {
        "name": "get_price_for_sku",
        "description": "Справочная цена для конкретной категории. Всегда показывай дисклеймер.",
        "input_schema": {
            "type": "object",
            "properties": {
                "sku_id": {"type": "string", "description": "UUID категории ТСП"},
                "region_id": {"type": "string", "description": "UUID региона (необязательно)"},
            },
            "required": ["sku_id"],
        },
    },
    {
        "name": "get_market_summary",
        "description": "Обзор рынка: предложение и спрос за месяц (анонимные данные).",
        "input_schema": {
            "type": "object",
            "properties": {
                "region_id": {"type": "string", "description": "UUID региона (необязательно)"},
                "month": {"type": "string", "description": "YYYY-MM-01 (необязательно)"},
            },
            "required": [],
        },
    },
]


def execute_market_tool(
    tool_name: str,
    tool_input: dict[str, Any],
    organization_id: str,
    supabase: Client,
    actor_id: Optional[str] = None,
) -> dict[str, Any]:
    """Execute a market tool via supabase.rpc(). P-AI-1 + P-AI-2."""
    try:
        handlers = {
            "get_price_grid": _get_price_grid,
            "get_aggregated_supply": _get_aggregated_supply,
            "get_aggregated_demand": _get_aggregated_demand,
            "get_org_batches": _get_org_batches,
            "create_batch": _create_batch,
            "publish_batch": _publish_batch,
            "cancel_batch": _cancel_batch,
            "get_price_for_sku": _get_price_for_sku,
            "get_market_summary": _get_market_summary,
        }
        handler = handlers.get(tool_name)
        if not handler:
            return {"error": f"Unknown market tool: {tool_name}"}
        return handler(tool_input, organization_id, supabase, actor_id)
    except Exception as e:
        logger.error("Market tool %s failed: %s", tool_name, e, exc_info=True)
        return {"error": str(e)}


def _get_price_grid(params: dict, org_id: str, sb: Client, _: Any) -> dict:
    r = sb.rpc("rpc_get_price_grid", {"p_organization_id": org_id, "p_region_id": params.get("region_id")}).execute()
    return r.data or {}

def _get_aggregated_supply(params: dict, org_id: str, sb: Client, _: Any) -> dict:
    r = sb.rpc("rpc_get_aggregated_supply", {"p_organization_id": org_id, "p_target_month": params.get("target_month"), "p_region_id": params.get("region_id")}).execute()
    return r.data or {}

def _get_aggregated_demand(params: dict, org_id: str, sb: Client, _: Any) -> dict:
    r = sb.rpc("rpc_get_aggregated_demand", {"p_organization_id": org_id, "p_target_month": params.get("target_month"), "p_region_id": params.get("region_id")}).execute()
    return r.data or {}

def _get_org_batches(params: dict, org_id: str, sb: Client, _: Any) -> dict:
    rpc_params: dict[str, Any] = {"p_organization_id": org_id}
    if params.get("status_filter") and params["status_filter"] != "all":
        rpc_params["p_status"] = params["status_filter"]
    r = sb.rpc("rpc_get_org_batches", rpc_params).execute()
    return r.data or {}

def _create_batch(params: dict, org_id: str, sb: Client, actor_id: Any) -> dict:
    r = sb.rpc("rpc_create_batch", {
        "p_organization_id": org_id, "p_farm_id": params.get("farm_id"),
        "p_tsp_sku_id": params["sku_id"], "p_heads": params["heads"],
        "p_target_month": params["target_month"],
        "p_avg_weight_kg": params.get("avg_weight_kg"),
        "p_actor_id": actor_id,
    }).execute()
    return r.data or {}

def _publish_batch(params: dict, org_id: str, sb: Client, actor_id: Any) -> dict:
    r = sb.rpc("rpc_publish_batch", {
        "p_organization_id": org_id, "p_batch_id": params["batch_id"],
        "p_actor_id": actor_id,
    }).execute()
    return r.data or {}

def _cancel_batch(params: dict, org_id: str, sb: Client, _: Any) -> dict:
    r = sb.rpc("rpc_cancel_batch", {
        "p_organization_id": org_id, "p_batch_id": params["batch_id"],
        "p_reason": params.get("reason"),
    }).execute()
    return r.data or {}

def _get_price_for_sku(params: dict, org_id: str, sb: Client, _: Any) -> dict:
    r = sb.rpc("rpc_get_price_for_sku", {
        "p_organization_id": org_id, "p_sku_id": params["sku_id"],
        "p_region_id": params.get("region_id"),
    }).execute()
    return r.data or {}

def _get_market_summary(params: dict, org_id: str, sb: Client, _: Any) -> dict:
    r = sb.rpc("rpc_get_market_summary", {
        "p_organization_id": org_id, "p_region_id": params.get("region_id"),
        "p_month": params.get("month"),
    }).execute()
    return r.data or {}
