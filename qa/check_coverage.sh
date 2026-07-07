#!/usr/bin/env bash
# Сверка qa/scenarios/ ↔ @case-теги в автотестах.
# Использование: ./qa/check_coverage.sh  (из корня репо или из qa/)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCEN="$ROOT/qa/scenarios"

# 1. Все ID кейсов из сценариев (#### <ID> · ...)
ids=$(grep -rhoE '^#### [A-Z0-9]+(-[A-Z0-9]+)+' "$SCEN" | awk '{print $2}' | sort -u)

# 2. Все @case-теги из автотестов
tags=$(grep -rhoE '@case[ :]+[A-Z0-9 -]+' \
  "$ROOT/tests" "$ROOT/src" "$ROOT/supabase/functions" 2>/dev/null \
  | sed -E 's/@case[ :]+//' | tr ' ' '\n' | grep -E '^[A-Z0-9]+(-[A-Z0-9]+)+$' | sort -u || true)

total=$(echo "$ids" | grep -c . || true)
covered=0; orphans=0

echo "=== Покрытие автотестами ==="
for id in $ids; do
  if echo "$tags" | grep -qx "$id"; then
    covered=$((covered+1))
    echo "  COVERED   $id"
  fi
done

echo ""
echo "=== Теги-сироты (тег есть, кейса нет) ==="
for t in $tags; do
  if ! echo "$ids" | grep -qx "$t"; then
    orphans=$((orphans+1))
    echo "  ORPHAN    $t"
  fi
done
[ "$orphans" -eq 0 ] && echo "  нет"

echo ""
echo "=== Статусы кейсов ==="
for s in active mock future; do
  n=$(grep -rhoE "\`status:$s\`" "$SCEN" | wc -l | tr -d ' ')
  echo "  $s: $n"
done
blocked=$(grep -rhoE '`status:blocked:[A-Z0-9-]+`' "$SCEN" | sed 's/.*blocked://;s/`//' | sort | uniq -c | sort -rn)
echo "  blocked (по долгам):"
echo "$blocked" | sed 's/^/    /'

echo ""
echo "ИТОГО: кейсов $total, покрыто автотестами $covered, тегов-сирот $orphans"
