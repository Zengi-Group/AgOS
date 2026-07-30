#!/usr/bin/env python3
"""Единый деплоер SQL на прод AgOS + учётная книга ops_deploy_log.

Заменяет 4 канала деплоя (deploy_sql.py, deploy_d07.py, deploy_tsp_matchfix.py,
deploy_vet_isolation_fix.py), ни один из которых не оставлял следа на проде.

  python3 scripts/deploy.py --list                  # что применено / что pending
  python3 scripts/deploy.py --files d05_ops_edu.sql # точечно (обычный случай)
  python3 scripts/deploy.py --migrations            # только новые миграции
  python3 scripts/deploy.py --all                   # d-файлы + миграции (полный реплей)
  python3 scripts/deploy.py --files d05 --dry-run   # план без применения
  python3 scripts/deploy.py --files d05 --rollback-only  # выполнить и откатить

Гарантии:
  * файл применяется в ОДНОЙ транзакции вместе со строкой ops_deploy_log —
    журнал не может разойтись с реальностью (нет коммита = нет строки);
  * после коммита тела функций из файла сверяются с pg_proc (ловит L-1: более
    позднее определение той же сигнатуры молча перетирает фикс);
  * --rollback-only исполняет весь выбранный набор в одной транзакции, чтобы
    проверить межфайловый apply-order, и затем полностью откатывает её;
  * порядок --all = d01..d14, затем миграции по timestamp (TSP-ADAPTER-02:
    adapter обязан лечь ПОВЕРХ d-файлов, иначе воскресает uuid-overload);
  * пароль только из .db_password / AGOS_DB_PASSWORD, никогда не из argv.

Пароль: Supabase → Settings → Database. Дрейф прод↔git: scripts/prod_diff.py.
"""
import argparse
import getpass
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agos_db as db  # noqa: E402

BOOTSTRAP = """
create table if not exists public.ops_deploy_log (
    id uuid primary key default gen_random_uuid(),
    file_name text not null,
    kind text not null default 'domain' check (kind in ('domain','migration','adhoc')),
    sha256 text not null,
    git_sha text,
    git_dirty boolean not null default false,
    applied_at timestamptz not null default now(),
    applied_by text not null default current_user,
    host_user text,
    note text
);
create index if not exists idx_ops_deploy_log_file_time
    on public.ops_deploy_log (file_name, applied_at desc);
alter table public.ops_deploy_log enable row level security;
revoke all on table public.ops_deploy_log from public, anon, authenticated;
"""  # копия канона из d01_kernel.sql — чтобы первый запуск работал до реплея d01


def applied_map(conn) -> dict:
    """{file_name: (sha256, applied_at)} по последней записи каждого файла."""
    with conn.cursor() as cur:
        cur.execute("""
            select distinct on (file_name) file_name, sha256, applied_at
            from public.ops_deploy_log order by file_name, applied_at desc
        """)
        return {r[0]: (r[1], r[2]) for r in cur.fetchall()}


def verify_bodies(conn, logical_name: str, sql_text: str) -> list:
    """Сверяет тела функций файла с pg_proc. Возвращает список расхождений.

    Расхождение = каноническое (последнее в файле) тело не найдено ни в одном
    прод-определении этого имени. Это ровно сигнатура L-1 «тихого отката»."""
    operations = db.extract_function_operations(sql_text)
    canonical = {}
    for action, name, types, body in operations:
        key = (name, types)
        if action == "drop":
            canonical.pop(key, None)
        else:
            canonical[key] = body
    if not canonical:
        return []
    problems = []
    with conn.cursor() as cur:
        cur.execute("""
            select p.proname, pg_get_function_identity_arguments(p.oid), p.prosrc
            from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = any(%s)
        """, (sorted({name for name, _types in canonical}),))
        prod = {}
        for name, args, src in cur.fetchall():
            prod[(name.lower(), db.identity_arg_types(args))] = db.normalize_body(src)
    for (name, types), body in canonical.items():
        signature = ",".join(types)
        if (name, types) not in prod:
            problems.append(f"{name}({signature}): НЕТ на проде после применения {logical_name}")
        elif body != prod[(name, types)]:
            problems.append(
                f"{name}({signature}): тело на проде ≠ каноническому из {logical_name} "
                f"(перетёрто более поздним определением? L-1)"
            )
    return problems


def apply_one(conn, logical_name: str, path: str, kind: str, note: str,
              git_sha: str, git_dirty: bool, dry_run: bool) -> bool:
    sql_text = open(path, encoding="utf-8").read()
    digest = db.sha256(sql_text)
    kb = len(sql_text.encode()) // 1024
    if dry_run:
        print(f"  [dry-run] {logical_name} ({kb}KB, sha {digest[:12]})")
        return True

    print(f"  {logical_name} ({kb}KB) ...", end=" ", flush=True)
    try:
        with conn.cursor() as cur:
            cur.execute(sql_text)
            # Та же транзакция: журнал появится ТОЛЬКО при успешном commit.
            cur.execute("""
                insert into public.ops_deploy_log
                    (file_name, kind, sha256, git_sha, git_dirty, host_user, note)
                values (%s, %s, %s, %s, %s, %s, %s)
            """, (logical_name, kind, digest, git_sha, git_dirty,
                  getpass.getuser(), note))
        conn.commit()
        print("OK")
    except Exception as e:
        conn.rollback()
        print(f"FAILED\n    {e}")
        print(f"    Транзакция откачена, запись в журнал не сделана. Чини {logical_name} и повтори.")
        return False

    for p in verify_bodies(conn, logical_name, sql_text):
        print(f"    ⚠ VERIFY: {p}")
    return True


def rollback_replay(conn, targets: list) -> bool:
    """Executes the complete ordered target set in one transaction, then rolls back."""
    print("Rollback-only replay: изменения не будут сохранены.")
    try:
        with conn.cursor() as cur:
            for logical_name, path in targets:
                sql_text = open(path, encoding="utf-8").read()
                kb = len(sql_text.encode()) // 1024
                print(f"  {logical_name} ({kb}KB) ...", end=" ", flush=True)
                cur.execute(sql_text)
                print("OK")
        conn.rollback()
        print("Rollback-only replay: OK, транзакция полностью откачена.")
        return True
    except Exception as error:
        conn.rollback()
        print(f"FAILED\n    {error}")
        print("Rollback-only replay: транзакция полностью откачена.")
        return False


def main():
    ap = argparse.ArgumentParser(description="Единый деплоер AgOS SQL на прод")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--all", action="store_true", help="d-файлы + новые миграции")
    g.add_argument("--files", help="через запятую: d05_ops_edu.sql,d07_ai_gateway.sql (можно без .sql)")
    g.add_argument("--migrations", action="store_true", help="только непримененные миграции")
    g.add_argument("--list", action="store_true", help="что применено / что pending")
    ap.add_argument("--dry-run", action="store_true", help="показать план, ничего не применять")
    ap.add_argument("--rollback-only", action="store_true",
                    help="выполнить весь набор в одной транзакции и откатить")
    ap.add_argument("--note", default="", help="комментарий в журнал (ARS-NNN, PR #N)")
    ap.add_argument("--force", action="store_true",
                    help="применить даже если sha уже в журнале (обычно не нужно)")
    args = ap.parse_args()
    if args.dry_run and args.rollback_only:
        ap.error("--dry-run и --rollback-only взаимоисключающие")

    git_sha, git_dirty = db.git_state()
    conn = db.connect()
    with conn.cursor() as cur:
        cur.execute(BOOTSTRAP)
    conn.commit()
    applied = applied_map(conn)

    sources = db.canonical_sources()
    by_name = {n: p for n, p in sources}

    if args.list:
        print(f"{'файл':<58} {'статус':<12} применён")
        for name, path in sources:
            cur_sha = db.sha256(open(path, encoding="utf-8").read())
            rec = applied.get(name)
            if not rec:
                status, when = "PENDING", "—"
            elif rec[0] != cur_sha:
                status, when = "ИЗМЕНЁН", rec[1].strftime("%Y-%m-%d %H:%M")
            else:
                status, when = "ok", rec[1].strftime("%Y-%m-%d %H:%M")
            print(f"{name:<58} {status:<12} {when}")
        print("\nПусто/PENDING у старых файлов = журнал начат позже их деплоя,")
        print("не обязательно «не задеплоено». Правду о телах даёт scripts/prod_diff.py.")
        conn.close()
        return

    if args.files:
        targets = []
        for raw in args.files.split(","):
            token = raw.strip()
            if not token:
                continue
            hit = by_name.get(token) or by_name.get(f"{token}.sql")
            if not hit:
                hit_key = next((n for n in by_name if n.startswith(token)), None)
                hit = by_name.get(hit_key) if hit_key else None
                token = hit_key or token
            else:
                token = token if token in by_name else f"{token}.sql"
            if not hit:
                sys.exit(f"FATAL: не найден файл '{raw.strip()}' среди канонических источников")
            targets.append((token, hit))
    elif args.migrations:
        targets = [(n, p) for n, p in sources if n.startswith(db.MIGRATIONS_DIR)]
    else:  # --all
        targets = list(sources)

    # Денилист арм-DDL (D-BILL-CRON-STAGING-01) — только явным --files.
    if not args.files:
        skipped = [n for n, _ in targets if os.path.basename(n) in db.MIGRATION_DENYLIST]
        targets = [(n, p) for n, p in targets if os.path.basename(n) not in db.MIGRATION_DENYLIST]
        for s in skipped:
            print(f"SKIP (денилист арм-DDL, только вручную): {s}")

    if args.migrations or args.all:
        fresh = []
        for n, p in targets:
            rec = applied.get(n)
            if args.force or not rec or rec[0] != db.sha256(open(p, encoding="utf-8").read()):
                fresh.append((n, p))
            elif n.startswith(db.MIGRATIONS_DIR):
                continue  # миграция уже применена этим же содержимым — пропускаем молча
        if args.migrations:
            targets = [t for t in fresh if t[0].startswith(db.MIGRATIONS_DIR)]

    if not targets:
        print("Нечего применять.")
        conn.close()
        return

    print(f"Прод {db.DB_USER}@{db.DB_HOST} · git {git_sha[:8]}{' DIRTY' if git_dirty else ''}")
    if git_dirty and not args.dry_run:
        print("⚠ Рабочее дерево грязное — git_sha в журнале не описывает применённый текст точно.")
    print(f"К применению: {len(targets)}\n")

    if args.rollback_only:
        ok = rollback_replay(conn, targets)
        conn.close()
        if not ok:
            sys.exit(1)
        return

    ok = 0
    for name, path in targets:
        kind = "migration" if name.startswith(db.MIGRATIONS_DIR) else "domain"
        if apply_one(conn, name, path, kind, args.note, git_sha, git_dirty, args.dry_run):
            ok += 1
        else:
            print(f"\nОстановлено на {name}. Применено до этого: {ok}.")
            conn.close()
            sys.exit(1)

    conn.close()
    print(f"\nГотово: {ok}/{len(targets)}.")
    if not args.dry_run:
        print("Дальше: scripts/prod_diff.py (полная сверка прод↔git) + запись в DECISIONS_LOG (L-5).")


if __name__ == "__main__":
    main()
