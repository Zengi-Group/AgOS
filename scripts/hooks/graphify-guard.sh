#!/usr/bin/env bash
# PreToolUse-guard: держит контракт «граф первым» на КАЖДОМ исследовании кода.
#
# Зачем отдельный скрипт (раньше две простыни inline-bash в .claude/settings.json):
# прежний guard был обёрнут в `[ -f graphify-out/graph.json ] && echo ... || true` —
# нет файла → нет напоминания, нет ошибки, нет следа. Граф вне git (ретро ARS-152),
# каждый свежий worktree рождается без него → защита выключалась МОЛЧА, и агент по
# действующим правилам обязан был читать репозиторий сырьём. Ровно этот режим CEO
# и наблюдал: «claude не обращается к графу, а изучает весь репозиторий сам».
# Инвариант теперь: нет графа → guard кричит громче, чем когда граф есть.
#
# Режимы: bash (матчер Bash — grep/rg/find/…) | read (матчеры Read/Glob по коду и докам).
# Вызов из .claude/settings.json: scripts/hooks/graphify-guard.sh <mode>
set -uo pipefail
MODE="${1:-read}"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

printf '%s' "$(cat 2>/dev/null || true)" | MODE="$MODE" ROOT="$ROOT" python3 -c '
import json, os, re, sys

MODE = os.environ.get("MODE", "read")
ROOT = os.environ.get("ROOT", ".")
GRAPH = os.path.join(ROOT, "graphify-out", "graph.json")

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = payload.get("tool_input", payload) or {}
sid = payload.get("session_id") or "nosid"

# --- срабатывает ли guard на этот вызов -------------------------------------
CODE_EXTS = ("py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "rb",
             "c", "h", "cpp", "hpp", "cc", "cs", "kt", "swift", "php",
             "scala", "lua", "sh", "sql")
# Расширение матчим по ГРАНИЦЕ токена, а не подстрокой. Прежний inline-хук проверял
# `".c" in path` — и ловил любой путь с ".claude/" (".c" + "laude"), т.е. напоминал про
# граф на чтении собственных настроек и скиллов. Ложные срабатывания обесценивают
# правило быстрее, чем его отсутствие.
EXT_RE = re.compile(r"\.(" + "|".join(sorted(CODE_EXTS, key=len, reverse=True)) + r")(?![0-9a-z])")
# .md намеренно НЕ в CODE_EXTS: канон-доки (Docs/, qa/scenarios/) граф индексирует
# по секциям с адресом loc=L<n> — там ориентация окупается сильнее всего. А CLAUDE.md /
# DECISIONS_LOG.md / IMPL_DEBT.md читаются целиком по обязанности (HS-3), напоминать
# про граф на них = шум, который обесценивает само напоминание.
DOC_DIRS = ("docs/", "qa/scenarios/")
SEARCH_CMDS = ("grep", "rg ", "ripgrep", "find ", "fd ", "ack ", "ag ")

if MODE == "bash":
    cmd = str(ti.get("command") or "")
    hit = any(c in cmd for c in SEARCH_CMDS)
else:
    s = (str(ti.get("file_path") or "") + " " + str(ti.get("pattern") or "")
         + " " + str(ti.get("path") or "")).lower().replace(chr(92), "/")
    # ".md" in s, не endswith: s — это склейка file_path + pattern + path, у одиночного
    # file_path остаётся хвостовой пробел и endswith(".md") молча даёт False.
    is_canon_doc = ".md" in s and any(d in s for d in DOC_DIRS)
    hit = "graphify-out/" not in s and (EXT_RE.search(s) is not None or is_canon_doc)

if not hit:
    sys.exit(0)


def emit(text):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "additionalContext": text}}))
    sys.exit(0)


# --- граф есть: обычный контракт «граф первым» -------------------------------
if os.path.isfile(GRAPH):
    if MODE == "bash":
        emit("MANDATORY: graphify-out/graph.json exists. You MUST run "
             "`graphify query \"<question>\"` before grepping raw files. Only grep after "
             "graphify has oriented you, or to modify/debug specific lines.")
    emit("MANDATORY: graphify-out/graph.json exists. You MUST run graphify before reading "
         "source files. Use: `graphify query \"<question>\"` (scoped subgraph), "
         "`graphify explain \"<concept>\"`, or `graphify path \"<A>\" \"<B>\"`. The graph indexes "
         "Docs/ too — nodes carry `src=<file> loc=L<n>`, so read the addressed section, not the "
         "whole Dok. Only read raw files after graphify has oriented you, or to modify/debug "
         "specific lines. This rule applies to subagents too — include it in every subagent "
         "prompt involving code exploration.")

# --- графа НЕТ: громко, а не молча (инвариант этого скрипта) -----------------
# Полный текст один раз за сессию, дальше короткий — чтобы напоминание не выродилось
# в шум, если сборка почему-то невозможна, но и не исчезло совсем.
mark = os.path.join(os.environ.get("TMPDIR", "/tmp"), "agos-graphify-missing-" + str(sid))
if os.path.exists(mark):
    emit("REMINDER: graphify-out/graph.json is still missing — you are exploring raw files "
         "without the graph. Build it: `bash scripts/worktree-bootstrap.sh` (worktree) or "
         "`graphify update .`")
try:
    open(mark, "w").close()
except Exception:
    pass
emit("STOP — THE KNOWLEDGE GRAPH IS NOT BUILT. graphify-out/graph.json is MISSING, so you are "
     "about to explore this repo raw: slower, more tokens, and you WILL miss cross-file and "
     "code↔Docs relationships the graph makes explicit.\n"
     "graphify-out/ is gitignored (retro ARS-152), so every fresh clone/worktree starts without "
     "it — this is expected and self-healing. BUILD IT NOW, before further exploration:\n"
     "  bash scripts/worktree-bootstrap.sh    # worktree: node_modules + env + graph\n"
     "  graphify update .                     # main checkout: ~90 s, AST-only, no LLM, no API cost\n"
     "Then orient with `graphify query \"<question>\"` / `explain \"<concept>\"` / "
     "`path \"<A>\" \"<B>\"` and read only the files it addresses. Tell the user you are building "
     "the graph first — do not silently fall back to raw exploration. This applies to subagents "
     "too: pass the same rule into every subagent prompt that explores code.")
' 2>/dev/null || true
exit 0
