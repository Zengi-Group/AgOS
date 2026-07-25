#!/usr/bin/env bash
# Уборка влитых worktree и веток (process-audit 2026-07-25).
# Удаляет только безопасное: worktree с ЧИСТЫМ деревом, чья ветка полностью
# в main (0 уникальных коммитов), и влитые ветки без worktree.
# Грязные, ушедшие вперёд main, detached-HEAD, main-чекаут и текущий worktree —
# не трогает, только перечисляет.
# Использование: bash scripts/sweep_worktrees.sh [--dry-run]
# Подключить алиасом: git config --local alias.sweep '!bash scripts/sweep_worktrees.sh'
set -uo pipefail

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
CUR_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "не git-репо"; exit 1; }

git fetch --prune origin >/dev/null 2>&1 || true

MAIN_WT=$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print; exit}')

removed=0
skipped=""

WT=""; BR=""
while IFS= read -r line; do
  if [ "${line#worktree }" != "$line" ]; then WT=${line#worktree }; BR=""
  elif [ "${line#branch refs/heads/}" != "$line" ]; then BR=${line#branch refs/heads/}
  elif [ -z "$line" ] && [ -n "$WT" ]; then
    if [ "$WT" != "$MAIN_WT" ] && [ "$WT" != "$CUR_TOP" ] && [ -n "$BR" ] && [ "$BR" != "main" ]; then
      dirty=$(git -C "$WT" status --porcelain 2>/dev/null | head -1)
      ahead=$(git rev-list --count "main..$BR" 2>/dev/null || echo "?")
      if [ -z "$dirty" ] && [ "$ahead" = "0" ]; then
        echo "remove: $WT ($BR)"
        if [ "$DRY" -eq 0 ]; then
          git worktree remove "$WT" 2>/dev/null && git branch -d "$BR" 2>/dev/null \
            || echo "  WARN: не удалилось чисто — разбери руками"
        fi
        removed=$((removed + 1))
      else
        skipped="$skipped
  skip: $WT ($BR, dirty=$([ -n "$dirty" ] && echo yes || echo no), ahead=$ahead)"
      fi
    fi
    WT=""; BR=""
  fi
done <<EOF
$(git worktree list --porcelain)

EOF

[ "$DRY" -eq 0 ] && git worktree prune

# Влитые ветки без worktree (ветки в worktree удалены парой выше; checked-out
# ветку git branch -d сам не даст удалить)
for br in $(git branch --format='%(refname:short)' --merged main | grep -v '^main$'); do
  if ! git worktree list --porcelain | grep -q "^branch refs/heads/$br\$"; then
    echo "branch -d: $br"
    [ "$DRY" -eq 0 ] && { git branch -d "$br" 2>/dev/null || echo "  WARN: $br не удалилась"; }
  fi
done

echo ""
echo "Итог: worktree к удалению/удалено: $removed$([ "$DRY" -eq 1 ] && echo ' (dry-run)')"
[ -n "$skipped" ] && printf "Пропущено (не трогаем):%s\n" "$skipped"
exit 0
