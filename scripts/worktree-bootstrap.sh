#!/usr/bin/env bash
# AgOS · Бутстрап git-worktree (ретро ARS-152, 2026-07-04).
# Claude-worktree создаётся голым: без node_modules, .env* (gitignored) и graphify-out
# (derived, вне git) — превью/тесты/graphify не работают, пока не прогнать этот скрипт.
# Запуск из корня worktree: bash scripts/worktree-bootstrap.sh
set -euo pipefail

MAIN_REPO="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
HERE="$(pwd)"
if [ "$MAIN_REPO" = "$HERE" ]; then
  echo "Это основной чекаут — бутстрап не нужен."
  exit 0
fi

# 1) node_modules — симлинк на основной чекаут (один npm install на все worktree).
#    Симлинк не попадает в git: .gitignore паттерн node_modules/ дополнен до node_modules.
if [ ! -e node_modules ]; then
  ln -s "$MAIN_REPO/node_modules" node_modules
  echo "node_modules → симлинк на основной чекаут"
fi

# 2) Локальные env (gitignored — git worktree их не приносит).
for f in .env .env.local; do
  if [ ! -f "$f" ] && [ -f "$MAIN_REPO/$f" ]; then
    cp "$MAIN_REPO/$f" "$f"
    echo "$f скопирован"
  fi
done

# 3) Свежая база: интейк-карта и фича-ветки — всегда от origin/main (не от HEAD worktree).
git fetch origin main

# 4) graphify-индекс — регенерация от текущего кода (в git его больше нет).
if command -v graphify >/dev/null 2>&1; then
  graphify update . >/dev/null 2>&1 && echo "graphify-out перегенерирован"
else
  echo "graphify не найден — индекс пропущен"
fi

echo "Worktree готов."
