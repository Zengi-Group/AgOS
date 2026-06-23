#!/usr/bin/env bash
# ============================================================
# AgOS Cross-Check Script
# Validates SQL ↔ Dok 3 ↔ rpc_name_registry consistency
# Owner: QA Agent
# Usage: bash cross_check.sh
# Exit: 0 if no critical errors, 1 otherwise
# ============================================================

set -uo pipefail
# Note: no -e because grep returns 1 on no-match which would kill the script

CRITICAL=0
SIGNIFICANT=0
MINOR=0
SQL_FILES=(d01_kernel.sql d02_tsp.sql d03_feed.sql d04_vet.sql d05_ops_edu.sql d07_ai_gateway.sql d08_epidemic.sql d09_consulting.sql d10_public_site.sql supabase/migrations/20260622120000_tsp_canonical_rebind.sql)
# TSP canonical trade layer = self-serve adapter migration (D-TSP-CANON-01, 2026-06-23).
# Brought into cross_check scope per convergence Slice A. The adapter intentionally
# redefines rpc_create_batch / rpc_get_org_batches (text-sig) over the d07 uuid-sig —
# whitelisted in CHECK 1, guarded against PGRST203 in CHECK 9, and its self-serve
# rpc_self_*/read RPCs are excepted in CHECK 5/7 until registered in Slice B.
# NOTE (flagged, not fixed here): d10_public_site.sql is in cross_check but NOT in
# deploy_sql.py; d11_norms.sql is in deploy_sql.py but NOT here — reconcile separately.

echo "========================================"
echo "AgOS Cross-Check — $(date '+%Y-%m-%d %H:%M')"
echo "========================================"
echo ""

# ----------------------------------------------------------
# CHECK 1: Duplicate function definitions across SQL files
# Severity: CRITICAL (consolidation regression risk)
# ----------------------------------------------------------
echo "--- CHECK 1: Duplicate function definitions ---"

# Known intentional cross-file duplicates (upgraded versions — last file wins by design)
# fn_my_org_ids, fn_is_admin, fn_is_expert: defined in d01_kernel.sql (basic SQL),
# then upgraded in d07_ai_gateway.sql with D-NEW-1 JWT fast path. d07 version is canonical.
# rpc_list_animal_categories: ADR-ANIMAL-01 DEF-TAXONOMY-01 option D — d01 canonical
# temporal overload (p_at_date, p_include_deprecated) + d03 legacy no-arg wrapper for
# Calculator.tsx / RationTab.tsx. Different signatures, PostgreSQL overload-safe.
# @deprecated removal of d03 wrapper: after TAXONOMY-M3c UI cut-over.
# rpc_create_batch, rpc_get_org_batches: the TSP adapter migration (D-TSP-CANON-01)
# redefines these as the text-sig / no-arg canonical trade layer, dropping the d07
# uuid-sig at deploy time. They coexist in source until the d07 uuid-sig is physically
# retired in convergence Slice D. The PGRST203 overload risk is guarded by CHECK 9.
# rpc_cancel_batch: adapter 1-arg (p_batch_id) overrides the d02 canonical 3-arg
# (p_organization_id, p_batch_id, p_reason). UNLIKE create_batch the adapter does NOT
# drop the d02 sig, so both coexist — a latent overload also tracked by CHECK 9 and
# retired (d02 sig) in convergence Slice D.
DUP_WHITELIST="fn_my_org_ids|fn_is_admin|fn_is_expert|rpc_list_animal_categories|rpc_create_batch|rpc_get_org_batches|rpc_cancel_batch"

# Extract all function names from CREATE OR REPLACE FUNCTION lines
# BSD-safe: use [[:space:]]+ instead of \s+; case-insensitive via tr
all_funcs=$(grep -h -i '^create or replace function' "${SQL_FILES[@]}" 2>/dev/null \
  | sed -E 's/^[Cc][Rr][Ee][Aa][Tt][Ee][[:space:]]+[Oo][Rr][[:space:]]+[Rr][Ee][Pp][Ll][Aa][Cc][Ee][[:space:]]+[Ff][Uu][Nn][Cc][Tt][Ii][Oo][Nn][[:space:]]+(public\.)?//' \
  | sed -E 's/[[:space:]]*\(.*$//' \
  | sort)

dupes=$(echo "$all_funcs" | uniq -d)

if [ -n "$dupes" ]; then
  crit_before=$CRITICAL
  while IFS= read -r fname; do
    # Skip known intentional upgrades
    if echo "$fname" | grep -qE "^(${DUP_WHITELIST})$"; then
      echo "  WHITELISTED: ${fname} (intentional upgrade — d07 JWT fast path version is canonical)"
      continue
    fi
    # Count occurrences per file (same-file duplicate = always critical)
    for f in "${SQL_FILES[@]}"; do
      count=$(grep -c -i "create or replace function.*${fname}" "$f" 2>/dev/null || true)
      if [ "$count" -gt 1 ]; then
        echo "  CRITICAL: ${fname} defined ${count} times in ${f}"
        ((CRITICAL++))
      fi
    done
    # Check cross-file duplicates
    locations=$(grep -l -i "create or replace function.*${fname}" "${SQL_FILES[@]}" 2>/dev/null | tr '\n' ', ')
    file_count=$(grep -l -i "create or replace function.*${fname}" "${SQL_FILES[@]}" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$file_count" -gt 1 ]; then
      echo "  CRITICAL: ${fname} defined in multiple files: ${locations}"
      ((CRITICAL++))
    fi
  done <<< "$dupes"
  if [ "$CRITICAL" -eq "$crit_before" ]; then
    echo "  OK: All duplicates are whitelisted intentional upgrades"
  fi
else
  echo "  OK: No duplicate function definitions found"
fi

echo ""

# ----------------------------------------------------------
# CHECK 2: SQL files exist and are non-empty
# Severity: CRITICAL
# ----------------------------------------------------------
echo "--- CHECK 2: SQL files exist and non-empty ---"

for f in "${SQL_FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "  CRITICAL: $f does not exist"
    ((CRITICAL++))
  elif [ ! -s "$f" ]; then
    echo "  CRITICAL: $f is empty"
    ((CRITICAL++))
  else
    lines=$(wc -l < "$f" | tr -d ' ')
    echo "  OK: $f (${lines} lines)"
  fi
done

echo ""

# ----------------------------------------------------------
# CHECK 3: All rpc_* functions use SECURITY DEFINER
# Severity: SIGNIFICANT
# ----------------------------------------------------------
echo "--- CHECK 3: SECURITY DEFINER on all rpc_* functions ---"

for f in "${SQL_FILES[@]}"; do
  # Find rpc_ function definitions and check for security definer
  while IFS= read -r line_num; do
    # Read the next 25 lines after the function definition to find security definer
    # (functions with 7+ parameters can span 15+ lines before the clause)
    func_name=$(sed -n "${line_num}p" "$f" | sed -E 's/^create or replace function\s+(public\.)?//i' | sed -E 's/\s*\(.*$//')
    has_sec_def=$(sed -n "$((line_num)),$((line_num+25))p" "$f" | grep -ci 'security definer' || true)
    if [ "$has_sec_def" -eq 0 ]; then
      echo "  SIGNIFICANT: ${func_name} in ${f}:${line_num} — missing SECURITY DEFINER"
      ((SIGNIFICANT++))
    fi
  done < <(grep -n -i '^create or replace function.*rpc_' "$f" 2>/dev/null | cut -d: -f1)
done

if [ "$SIGNIFICANT" -eq 0 ]; then
  echo "  OK: All rpc_* functions have SECURITY DEFINER"
fi

echo ""

# ----------------------------------------------------------
# CHECK 4: Advisory lock usage (should be SKIP LOCKED)
# Severity: SIGNIFICANT (L-NEW-2)
# ----------------------------------------------------------
echo "--- CHECK 4: No advisory locks (L-NEW-2) ---"

# Filter out SQL comments (lines starting with --) to avoid false positives
adv_locks=$(grep -rn -i 'pg_advisory_lock\|pg_try_advisory_lock' "${SQL_FILES[@]}" 2>/dev/null \
  | grep -v '^\([^:]*:[^:]*:\)\s*--' || true)
if [ -n "$adv_locks" ]; then
  echo "  SIGNIFICANT: Advisory lock usage found (should use SKIP LOCKED):"
  echo "$adv_locks" | while IFS= read -r line; do
    echo "    $line"
    ((SIGNIFICANT++))
  done
else
  echo "  OK: No advisory lock usage in executable code"
fi

echo ""

# ----------------------------------------------------------
# CHECK 5: All rpc_* functions have organization_id parameter
# Severity: SIGNIFICANT (P-AI-2)
# ----------------------------------------------------------
echo "--- CHECK 5: organization_id in rpc_* signatures (P-AI-2) ---"

# Intentional exceptions: global catalog functions (no org_id by design) and
# admin-guarded functions (fn_is_admin() enforces access, no org scoping needed).
# rpc_start_production_plan uses p_farm_id for isolation (recognized pattern).
exceptions="get_active_prompt|rpc_name_registry|\
rpc_list_animal_categories|rpc_list_feed_items|rpc_list_feed_categories|\
rpc_list_feed_prices|rpc_list_feed_consumption_norms|\
rpc_upsert_feed_item|rpc_upsert_feed_price|rpc_upsert_feed_consumption_norm|\
rpc_upsert_consulting_reference|rpc_start_production_plan|\
rpc_resolve_category|rpc_get_category_mappings|\
rpc_add_animal_category|rpc_deprecate_animal_category|rpc_migrate_animal_category|\
rpc_list_construction_materials|rpc_list_infrastructure_norms|\
rpc_upsert_construction_material|rpc_upsert_infrastructure_norm|\
rpc_list_capex_surcharges|\
rpc_list_livestock_prices|rpc_upsert_livestock_price|rpc_retire_livestock_price|\
rpc_admin_upsert_livestock_category|rpc_admin_deactivate_livestock_category|\
rpc_admin_set_category_rule|rpc_admin_activate_rule_version|\
rpc_admin_map_sku_to_category|\
rpc_admin_set_minimum_price|rpc_admin_set_reference_price|\
rpc_admin_list_categories_with_stats|rpc_admin_list_category_rules|\
rpc_admin_get_sku_coverage|rpc_admin_list_prices|\
rpc_create_batch|rpc_get_org_batches|rpc_cancel_batch|rpc_dispatch_batch|\
rpc_lower_price|rpc_update_price|rpc_submit_review|rpc_self_review_due_batches|\
rpc_self_auto_match_batch|rpc_get_market_batches|rpc_self_activate_pool_request|\
rpc_self_match_batch_to_pool|rpc_self_advance_pool_status|rpc_get_pool_matches|\
rpc_get_my_pools|rpc_self_close_due_pools|rpc_self_accept_offer"
# TSP self-serve adapter RPCs (D-TSP-CANON-01): web-JWT access class — org scoping is
# enforced inside via fn_my_org_ids(), not via an organization_id parameter (P-AI-2 is
# satisfied for the AI path by the canonical uuid-sig RPCs, which DO take org_id).
sig_count_before=$SIGNIFICANT

for f in "${SQL_FILES[@]}"; do
  while IFS= read -r match; do
    line_num=$(echo "$match" | cut -d: -f1)
    # BSD sed compatible: use [[:space:]]+ instead of \s+ (macOS sed treats \s as literal 's')
    func_name=$(echo "$match" | sed -E 's/^[0-9]+:create or replace function (public\.)?//' | sed -E 's/[[:space:]]*\(.*$//')

    # Skip known exceptions
    if echo "$func_name" | grep -qiE "$exceptions"; then
      continue
    fi

    # Skip internal helper functions (prefixed with _)
    if echo "$func_name" | grep -q '^_'; then
      continue
    fi

    # Check next 5 lines for organization_id parameter
    has_org_id=$(sed -n "$((line_num)),$((line_num+5))p" "$f" | grep -ci 'organization_id' || true)
    if [ "$has_org_id" -eq 0 ]; then
      echo "  SIGNIFICANT: ${func_name} in ${f}:${line_num} — missing organization_id parameter"
      ((SIGNIFICANT++))
    fi
  done < <(grep -n -i '^create or replace function.*rpc_' "$f" 2>/dev/null)
done

if [ "$SIGNIFICANT" -eq "$sig_count_before" ]; then
  echo "  OK: All rpc_* functions have organization_id"
fi

echo ""


echo ""
echo "--- CHECK 6: UI values match SQL CHECK constraints ---"
UI_ERRORS=0

# shelter_type
for val in $(grep -oP "value: '\K[^']*" src/pages/cabinet/FarmProfile.tsx 2>/dev/null | head -4); do
  if ! grep -q "'$val'" d01_kernel.sql 2>/dev/null; then
    echo "  CRITICAL: UI shelter_type '$val' not in SQL"
    UI_ERRORS=$((UI_ERRORS + 1))
  fi
done

# animal_category codes
for val in $(grep -oP "code: '\K[A-Z_]*" src/pages/cabinet/FarmProfile.tsx 2>/dev/null); do
  if ! grep -q "'$val'" d01_kernel.sql 2>/dev/null; then
    echo "  CRITICAL: UI animal_category '$val' not in SQL"
    UI_ERRORS=$((UI_ERRORS + 1))
  fi
done

if [ $UI_ERRORS -eq 0 ]; then
  echo "  OK: All UI values match SQL constraints"
else
  echo "  FOUND: $UI_ERRORS UI value mismatches"
  CRITICAL=$((CRITICAL + UI_ERRORS))
fi

echo ""

# ----------------------------------------------------------
# CHECK 7: All rpc_* functions appear in rpc_name_registry
# Severity: SIGNIFICANT
# ----------------------------------------------------------
echo "--- CHECK 7: rpc_name_registry coverage ---"
sig_count_before_7=$SIGNIFICANT

# Collect all rpc_ function names from SQL files (BSD sed compatible: no \s, no /i flag)
all_rpc_funcs=$(grep -h -i '^create or replace function.*rpc_' "${SQL_FILES[@]}" 2>/dev/null \
  | sed -E 's/^create or replace function (public\.)?//' \
  | sed -E 's/[[:space:]]*\(.*$//' \
  | sort -u)

# Collect all sql_names inserted into rpc_name_registry across all SQL files
registered_rpcs=$(grep -h -oE "'rpc_[a-z0-9_]+'" "${SQL_FILES[@]}" 2>/dev/null \
  | sort -u | tr -d "'")

# TSP self-serve adapter RPCs (D-TSP-CANON-01): registry rows are added when the
# adapter becomes the canonical trade layer in convergence Slice B; excepted until then.
registry_exceptions="rpc_dispatch_batch|rpc_get_market_batches|rpc_get_my_pools|rpc_get_pool_matches|rpc_lower_price|rpc_self_accept_offer|rpc_self_activate_pool_request|rpc_self_advance_pool_status|rpc_self_auto_match_batch|rpc_self_close_due_pools|rpc_self_create_pool_request|rpc_self_match_batch_to_pool|rpc_self_review_due_batches|rpc_submit_review|rpc_update_price"

while IFS= read -r func; do
  if echo "$func" | grep -qxE "$registry_exceptions"; then
    continue
  fi
  if ! echo "$registered_rpcs" | grep -qx "$func"; then
    echo "  SIGNIFICANT: ${func} — defined in SQL but NOT in rpc_name_registry"
    ((SIGNIFICANT++))
  fi
done <<< "$all_rpc_funcs"

if [ "$SIGNIFICANT" -eq "$sig_count_before_7" ]; then
  echo "  OK: All rpc_* functions are registered in rpc_name_registry"
fi

echo ""

# ----------------------------------------------------------
# CHECK 8: Article 171 disclaimer_text in rpc_list_feed_prices
# Severity: CRITICAL (legal compliance — ст.171 ПК РК)
# ----------------------------------------------------------
echo "--- CHECK 8: Article 171 disclaimer_text in rpc_list_feed_prices ---"

if grep -q "disclaimer_text" d03_feed.sql 2>/dev/null && \
   awk '/rpc_list_feed_prices/,/^\$\$;/' d03_feed.sql | grep -q "disclaimer_text"; then
  echo "  OK: rpc_list_feed_prices contains disclaimer_text (Article 171 compliant)"
else
  echo "  CRITICAL: rpc_list_feed_prices in d03_feed.sql is missing disclaimer_text (Article 171 violation)"
  ((CRITICAL++))
fi

echo ""

# ----------------------------------------------------------
# CHECK 9: PGRST203 overload-collision guard (D-TSP-CANON-01 / TSP-ADAPTER-02)
# Severity: SIGNIFICANT
# Two same-name functions differing only by parameter TYPES (uuid-sig in d07 vs
# text-sig in the adapter) cannot be resolved by PostgREST over REST → PGRST203.
# The adapter DROPs the d07 uuid-sig at deploy time, but a full deploy_sql.py run
# re-creates d07 → the mine re-arms unless the adapter is re-applied last (or the
# d07 uuid-sig is physically removed in convergence Slice D). This guard fails while
# both coexist in source, and stays green once the d07 uuid-sig is retired — making
# the mine impossible to re-arm silently.
# ----------------------------------------------------------
echo "--- CHECK 9: PGRST203 overload collision (adapter override vs canonical d-files) ---"
ADAPTER_MIG="supabase/migrations/20260622120000_tsp_canonical_rebind.sql"
pgrst_mine_before=$SIGNIFICANT
# Names the adapter redefines with a DIFFERENT signature than the canonical d-file def.
# While both coexist in the deployed set, PostgREST may fail to resolve the call → PGRST203.
# Each is retired (canonical sig dropped) in convergence Slice D; this guard then goes green.
for fn in rpc_create_batch rpc_get_org_batches rpc_cancel_batch; do
  in_canon=0; canon_file=""
  for cf in d02_tsp.sql d07_ai_gateway.sql; do
    c=$(grep -ciE "^create or replace function (public\.)?${fn}[[:space:]]*\(" "$cf" 2>/dev/null || true)
    if [ "$c" -gt 0 ]; then in_canon=1; canon_file="$cf"; fi
  done
  in_adapter=$(grep -ciE "^create or replace function (public\.)?${fn}[[:space:]]*\(" "$ADAPTER_MIG" 2>/dev/null || true)
  if [ "$in_canon" -gt 0 ] && [ "$in_adapter" -gt 0 ]; then
    echo "  SIGNIFICANT: ${fn} defined in canonical ${canon_file} AND (different sig) in adapter — PGRST203 overload risk (retire canonical sig in convergence Slice D)"
    ((SIGNIFICANT++))
  fi
done
if [ "$SIGNIFICANT" -eq "$pgrst_mine_before" ]; then
  echo "  OK: no adapter↔canonical overload collision"
fi

echo ""

# ----------------------------------------------------------
# SUMMARY
# ----------------------------------------------------------
echo "========================================"
echo "SUMMARY"
echo "========================================"
echo "  Critical:    $CRITICAL"
echo "  Significant: $SIGNIFICANT"
echo "  Minor:       $MINOR"
echo "========================================"

if [ "$CRITICAL" -gt 0 ]; then
  echo "RESULT: FAIL — $CRITICAL critical error(s)"
  exit 1
else
  echo "RESULT: $CRITICAL critical errors"
  exit 0
fi
