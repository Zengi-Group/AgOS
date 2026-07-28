#!/usr/bin/env bash
# SessionStart-хук: делает состояние графа ПЕРВЫМ, что видит сессия.
#
# Зачем: graphify-out/ вне git (ретро ARS-152) → каждый свежий клон/worktree стартует без
# графа, а регенерацию делает scripts/worktree-bootstrap.sh, который никто не звал
# автоматически. Итог: на 2026-07-28 граф был лишь в 2 из 9 worktrees и отсутствовал в
# основном чекауте — инструмент был куплен, но по факту выключен в большинстве сессий.
# Этот хук закрывает разрыв: сессия либо стартует с рабочим графом, либо получает прямую
# директиву собрать его до исследования кода. Само лечение — одна команда, ~90 c, без API.
#
# Три исхода: графа нет → директива собрать; граф протух → директива обновить;
# граф свежий → одна компактная строка-праймер с инструментарием (дёшево, задаёт рамку
# «граф первым» в начале каждой сессии, а не только в CLAUDE.md §graphify).
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
GRAPH="$ROOT/graphify-out/graph.json"
REPORT="$ROOT/graphify-out/GRAPH_REPORT.md"

emit() { python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                  "additionalContext": sys.stdin.read()}}))' ; }

if [ ! -f "$GRAPH" ]; then
  emit <<'TXT'
GRAPH STATUS: NOT BUILT — graphify-out/graph.json is missing in this checkout.

graphify-out/ is gitignored (retro ARS-152: a committed graph.json conflicted on every pair
of parallel PRs), so a fresh clone/worktree always starts without it. This is expected and
self-healing, but until you build it you are exploring this repo raw — slower, more tokens,
and blind to the cross-file and code↔Docs relationships the graph makes explicit.

BUILD IT AS YOUR FIRST ACTION if this session will touch code, architecture, or the Doks:
  bash scripts/worktree-bootstrap.sh    # worktree: node_modules + env + graph
  graphify update .                     # main checkout: ~90 s, AST-only, no LLM, no API cost
Say out loud that you are building the graph first. Then orient via
`graphify query "<question>"` before reading files, and pass the same rule to every subagent.
TXT
  exit 0
fi

# Протух ли граф: код/доки новее индекса. Тот же критерий, что в scripts/check-setup.sh
# («граф протух (код новее)»), расширенный на consulting_engine и корневые d*.sql.
STALE=$(find "$ROOT/src" "$ROOT/ai_gateway" "$ROOT/consulting_engine" "$ROOT/Docs" \
             "$ROOT/supabase" -type f -newer "$GRAPH" 2>/dev/null | head -1)
if [ -z "$STALE" ]; then
  STALE=$(find "$ROOT" -maxdepth 1 -name 'd*.sql' -newer "$GRAPH" 2>/dev/null | head -1)
fi

SUMMARY=$(grep -m1 -e 'nodes · ' "$REPORT" 2>/dev/null | sed 's/^- *//' || true)
BUILT=$(grep -m1 'Built from commit' "$REPORT" 2>/dev/null | sed 's/.*`\(.*\)`.*/\1/' || true)

if [ -n "$STALE" ]; then
  { printf 'GRAPH STATUS: STALE — code/docs changed after the graph was built (from commit %s).\n' "${BUILT:-?}"
    printf 'Refresh it before relying on it: `graphify update .` (incremental, AST-only, no API cost).\n'
    printf 'Then work graph-first: `graphify query "<question>"` / `explain "<concept>"` / `path "<A>" "<B>"`.\n'
  } | emit
  exit 0
fi

{ printf 'GRAPH STATUS: READY — %s, built from commit %s.\n' "${SUMMARY:-graph present}" "${BUILT:-?}"
  printf 'Work graph-first, including in subagent prompts: `graphify query "<question>"` (scoped subgraph)\n'
  printf '· `graphify explain "<concept>"` · `graphify path "<A>" "<B>"` · `graphify affected "<X>"` (blast radius).\n'
  printf 'Nodes carry `src=<file> loc=L<n>` and cover Docs/ as well as code — read the addressed section, not the whole Dok.\n'
} | emit
exit 0
