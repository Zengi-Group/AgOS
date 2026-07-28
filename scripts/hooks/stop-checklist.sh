#!/usr/bin/env bash
# Stop-hook: чек-лист синка перед завершением сессии (feature-flow hardening такт 1, 3b).
# Сессия меняла код (dirty tree или незапушенные коммиты) → блокируем стоп ОДИН раз
# и просим агента явно закрыть/объяснить пункты синка. Повторный стоп (stop_hook_active)
# пропускаем — никаких вечных циклов.
INPUT=$(cat 2>/dev/null || true)
PARSED=$(printf '%s' "$INPUT" | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get('stop_hook_active', False)); print(d.get('session_id', ''))
except Exception:
    print(False); print('')" 2>/dev/null)
ACTIVE=$(printf '%s\n' "$PARSED" | sed -n 1p)
SID=$(printf '%s\n' "$PARSED" | sed -n 2p)
[ "$ACTIVE" = "True" ] && exit 0

# «Один раз за сессию» буквально: stop_hook_active гасит только повтор внутри одного
# стоп-цикла; между ходами Stop-евент приходит свежим → маркер по session_id.
MARK="${TMPDIR:-/tmp}/agos-stop-checklist-${SID:-nosid}"
[ -f "$MARK" ] && exit 0

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
DIRTY=$(git -C "$ROOT" status --porcelain 2>/dev/null | head -1)
AHEAD=$(git -C "$ROOT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)

if [ -n "$DIRTY" ] || [ "${AHEAD:-0}" -gt 0 ]; then
  touch "$MARK" 2>/dev/null || true
  cat <<'JSON'
{"decision":"block","reason":"Чек-лист синка перед выходом (сессия меняла код; это одноразовое напоминание). Пройди пункты и явно скажи по каждому «сделано» или почему не нужно: 1) Linear-статус задачи двинут (или двинет интеграция — PR несёт Closes ARS-NNN)? 2) DECISIONS_LOG.md — запись what/why/files есть? 3) Мозг (apex-brain spec/log) обновлён, если менялся замысел? 4) PR открыт/обновлён? 5) `graphify update .` прогнан, если менялся код/доки (D-GRAPH-FIRST-01 — иначе следующая сессия стартует на протухшем графе и graph-first работает хуже grep)? После этого завершайся."}
JSON
  exit 0
fi
exit 0
