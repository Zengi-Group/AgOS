#!/usr/bin/env bash
# AgOS — проверка сетапа продукт-инженера (parallel-dev).
# Запускать из чекаута AgOS:  bash scripts/check-setup.sh
# Сверяет машинно-локальную часть (~/.claude + мозг + tooling), которая НЕ едет через git.
# НЕ проверяет (печатает ручной чек-лист): MCP-авторизации и внешние доступы — их подтверждаешь сам.

# намеренно без `set -e`: гоним ВСЕ проверки, не падаем на первой

PASS=0; WARN=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

hdr "0. Где мы"
if git -C "$REPO" remote -v 2>/dev/null | grep -qi 'AgOS'; then
  ok "репо AgOS: $REPO"
else
  bad "это не чекаут AgOS (запусти из корня репозитория AgOS)";
fi

hdr "A. Едет через git — проверяем, что подтянуто"
git -C "$REPO" fetch --quiet origin 2>/dev/null
LOCAL=$(git -C "$REPO" rev-parse @ 2>/dev/null)
REMOTE=$(git -C "$REPO" rev-parse '@{u}' 2>/dev/null || echo "")
if [ -n "$REMOTE" ] && [ "$LOCAL" = "$REMOTE" ]; then ok "ветка на уровне origin (свежий git pull)"
elif [ -z "$REMOTE" ]; then warn "нет upstream у ветки — проверь, что трекает origin/main"
else warn "ветка отстаёт/разошлась с origin → сделай git pull"; fi

for f in .claude/settings.json .mcp.json graphify-out/graph.json .env.example \
         .claude/skills/architect/SKILL.md .claude/skills/db-agent/SKILL.md \
         .claude/skills/backend-agent/SKILL.md .claude/skills/ui-agent/SKILL.md \
         .claude/skills/qa-agent/SKILL.md .claude/skills/feature/SKILL.md; do
  [ -e "$REPO/$f" ] && ok "репо-файл: $f" || bad "репо-файл отсутствует: $f (git pull?)"
done
# graphify-хуки реально включены в repo settings
grep -q 'graphify' "$REPO/.claude/settings.json" 2>/dev/null \
  && ok "graphify always-on хуки в .claude/settings.json" \
  || bad "в .claude/settings.json нет graphify-хуков"
[ -f "$REPO/.env" ] && ok ".env создан локально" || warn ".env отсутствует → cp .env.example .env и заполнить"

hdr "B. Машинно-локальное — главное, что надо ставить руками"

# 1+4. глобальный CLAUDE.md и graphify-скилл
[ -f "$CLAUDE_HOME/CLAUDE.md" ] && ok "~/.claude/CLAUDE.md есть" || bad "~/.claude/CLAUDE.md отсутствует (глобальные правила мозга + /graphify)"
[ -f "$CLAUDE_HOME/skills/graphify/SKILL.md" ] && ok "глобальный скилл graphify установлен" || bad "нет ~/.claude/skills/graphify/SKILL.md"

# 2. мозг apex-brain: найти путь (из additionalDirectories, иначе из CLAUDE.md, иначе соседняя папка)
BRAIN=$(python3 - "$CLAUDE_HOME" <<'PY' 2>/dev/null
import json,sys,os
home=sys.argv[1]
for fn in ("settings.json","settings.local.json"):
    p=os.path.join(home,fn)
    try:
        d=json.load(open(p))
        for x in d.get("permissions",{}).get("additionalDirectories",[]):
            if "apex" in x.lower() or "brain" in x.lower(): print(x); sys.exit()
    except Exception: pass
PY
)
[ -z "$BRAIN" ] && BRAIN=$(grep -oE '/[^ ]*apex[^ ]*brain' "$CLAUDE_HOME/CLAUDE.md" 2>/dev/null | head -1)
if [ -n "$BRAIN" ] && [ -d "$BRAIN" ]; then
  ok "мозг найден: $BRAIN"
  git -C "$BRAIN" remote -v 2>/dev/null | grep -qi 'apex' \
    && ok "мозг — это клон Zengi-Group/apex" \
    || warn "папка мозга есть, но remote не похож на Zengi-Group/apex"
else
  bad "apex-brain не найден: склонируй github.com/Zengi-Group/apex и пропиши путь в additionalDirectories + ~/.claude/CLAUDE.md"
fi

# 3. additionalDirectories покрывает мозг + ключевые плагины включены
python3 - "$CLAUDE_HOME" <<'PY'
import json,os,sys
home=sys.argv[1]
need={"superpowers","context7","supabase","code-review","feature-dev","claude-md-management"}
try:
    d=json.load(open(os.path.join(home,"settings.json")))
except Exception:
    print("FAIL ~/.claude/settings.json не читается"); sys.exit()
ad=d.get("permissions",{}).get("additionalDirectories",[])
print("OK additionalDirectories: "+(", ".join(ad) if ad else "ПУСТО — мозг не примонтирован"))
plugs={k.split("@")[0] for k,v in d.get("enabledPlugins",{}).items() if v}
miss=need-plugs
print("OK плагины: "+", ".join(sorted(plugs)) if plugs else "FAIL плагины не включены")
if miss: print("WARN не включены плагины: "+", ".join(sorted(miss)))
PY

# 5. uv/uvx — для MCP graphify и для `graphify update`
command -v uvx >/dev/null 2>&1 && ok "uvx на PATH (нужен для MCP graphify + graphify update)" || bad "uvx не установлен → curl -LsSf https://astral.sh/uv/install.sh | sh"
command -v graphify >/dev/null 2>&1 && ok "graphify CLI на PATH" || warn "graphify CLI не на PATH (ок, если зовёшь через uvx)"

# свежесть графа: код новее графа → пора graphify update (якорь 7)
if [ -f "$REPO/graphify-out/graph.json" ]; then
  STALE=$(find "$REPO/src" "$REPO/ai_gateway" "$REPO/Docs" "$REPO/supabase" \
          -type f -newer "$REPO/graphify-out/graph.json" 2>/dev/null | head -1)
  [ -z "$STALE" ] && ok "граф свежий относительно кода" || warn "граф протух (код новее) → запусти graphify update перед якорем 7"
fi

hdr "C. Руками (скрипт это подтвердить не может)"
cat <<'EOF'
  [ ] Supabase MCP авторизован    — спроси Claude: "list_tables" должен вернуть схему (project mwtbozflyldcadypherr)
  [ ] Linear MCP rw + команда ARS — нужно для feature-flow (якоря 2 и 8); проверь list_issues по ARS
  [ ] context7 MCP отвечает       — resolve-library-id на любой либе
  [ ] push в Zengi-Group/AgOS     — git push с тестовой ветки проходит (main защищён, только через PR)
  [ ] Vercel zengi/ag-os          — видишь Preview-деплои на свои ветки
  [ ] Supabase staging + prod     — доступ к обоим (накатка: staging → cross_check.sh → prod)
  [ ] worktree-изоляция как дефолт — каждая параллельная сессия в своём git worktree (D-WORKTREE-01)
EOF

hdr "Итог"
printf '  PASS=%d  WARN=%d  FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
[ "$FAIL" -gt 0 ] && { echo "  → есть FAIL: сетап неполный, чини блокеры выше"; exit 1; }
[ "$WARN" -gt 0 ] && { echo "  → FAIL нет, но глянь WARN"; exit 0; }
echo "  → всё на месте ✅"; exit 0
