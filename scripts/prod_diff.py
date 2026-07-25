#!/usr/bin/env python3
"""Дрейф-детектор прод ↔ git: механизация «merge ≠ deploy» и L-1/L-6.

  python3 scripts/prod_diff.py            # отчёт в консоль
  python3 scripts/prod_diff.py --json     # машинный вывод (для дозора/CI)
  python3 scripts/prod_diff.py --strict   # exit 1 при любом дрейфе

Читает прод в режиме read-only (set default_transaction_read_only) и сравнивает
нормализованные тела функций public с каноном (d-файлы → миграции, позднее
определение выигрывает — семантика применения PostgreSQL).

Четыре класса находок:
  merged-not-deployed  функция есть в git, на проде отсутствует    (ARS-266-класс)
  body-divergent       имя есть у обоих, каноническое тело не найдено на проде (L-1)
  prod-only            функция на проде, в git нет                 (hotfix мимо канона)
  extra-overloads      на проде сигнатур больше, чем определяет git (PGRST203-риск)

Плюс инфра-срез: extensions (pg_cron), publication supabase_realtime
(была пуста — postgres_changes молча инертны, ARS-269), ACL служебных функций.

Класс prod-only частично шумный: Supabase/расширения добавляют свои функции в
public. Известные системные префиксы отфильтрованы; остальное показываем — лучше
проверить лишнее, чем пропустить hotfix, который живёт только на проде.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agos_db as db  # noqa: E402

# Функции, которые кладут в public расширения/платформа, а не наш канон.
SYSTEM_PREFIXES = (
    "pgrst_", "graphql", "grpc_", "uuid_", "pg_stat", "crypto", "digest", "hmac",
    "gen_random", "gen_salt", "encrypt", "decrypt", "armor", "dearmor", "pgp_",
    "st_", "postgis", "citext", "unaccent", "algorithm_sign", "sign", "verify",
    "url_encode", "url_decode", "try_cast_double", "http_", "net_", "cron_",
)


def git_functions() -> tuple:
    """({имя: (каноническое_тело, источник, кол-во_определений)}, {имя: {роль: bool}})."""
    canon, acl = {}, {}
    for logical, path in db.canonical_sources():
        try:
            text = open(path, encoding="utf-8").read()
        except OSError:
            continue
        for name, bodies in db.extract_functions(text).items():
            prev = canon.get(name)
            count = (prev[2] if prev else 0) + len(bodies)
            canon[name] = (bodies[-1], logical, count)
        for name, roles in db.extract_acl(text).items():
            acl.setdefault(name, {}).update(roles)
    return canon, acl


def acl_divergence(conn, expected: dict) -> list:
    """Сверяет ожидаемый по канону execute с фактическим на проде.

    Класс NOTE-ANON-EXEC-01 / ARS-311: `revoke ... from anon` лежит в git,
    но на БД никогда не применён — тела совпадают, дыра открыта."""
    out = []
    names = list(expected.keys())
    if not names:
        return out
    with conn.cursor() as cur:
        cur.execute("""
            select p.proname, p.oid::regprocedure::text, p.oid
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = any(%s)
        """, (names,))
        rows = cur.fetchall()
        for proname, sig, oid in rows:
            for role, should_have in expected.get(proname.lower(), {}).items():
                try:
                    cur.execute("select has_function_privilege(%s, %s, 'execute')",
                                (role, oid))
                    has = cur.fetchone()[0]
                except Exception:
                    conn.rollback()
                    continue  # роли может не быть на этой БД
                if has != should_have:
                    out.append({
                        "function": sig, "role": role,
                        "expected": "grant" if should_have else "revoke",
                        "actual": "есть execute" if has else "нет execute",
                    })
    return out


def prod_functions(conn) -> dict:
    """{имя: [(нормализованное_тело, аргументы), ...]}."""
    with conn.cursor() as cur:
        cur.execute("""
            select p.proname, p.prosrc, pg_get_function_identity_arguments(p.oid)
            from pg_proc p
            join pg_namespace n on n.oid = p.pronamespace
            left join pg_depend d
                   on d.objid = p.oid and d.deptype = 'e'   -- принадлежит расширению
            where n.nspname = 'public' and p.prokind = 'f' and d.objid is null
        """)
        out = {}
        for name, src, args in cur.fetchall():
            out.setdefault(name.lower(), []).append((db.normalize_body(src or ""), args))
        return out


def infra(conn) -> dict:
    with conn.cursor() as cur:
        cur.execute("select extname from pg_extension order by 1")
        exts = [r[0] for r in cur.fetchall()]
        cur.execute("""
            select tablename from pg_publication_tables
            where pubname = 'supabase_realtime' order by 1
        """)
        pub = [r[0] for r in cur.fetchall()]
        cur.execute("select count(*) from public.ops_deploy_log")
        log_rows = cur.fetchone()[0]
    return {"extensions": exts, "realtime_tables": pub, "deploy_log_rows": log_rows}


def main():
    ap = argparse.ArgumentParser(description="Дрейф прод ↔ git (AgOS)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true", help="exit 1 при дрейфе")
    args = ap.parse_args()

    canon, expected_acl = git_functions()
    conn = db.connect(readonly=True)
    try:
        prod = prod_functions(conn)
        acl = acl_divergence(conn, expected_acl)
        try:
            inf = infra(conn)
        except Exception as e:  # ops_deploy_log ещё не создан на проде
            conn.rollback()
            inf = {"error": str(e).strip().splitlines()[0]}
    finally:
        conn.close()

    missing, divergent, overloads = [], [], []
    for name, (body, source, defs) in sorted(canon.items()):
        got = prod.get(name)
        if not got:
            missing.append({"function": name, "source": source})
            continue
        if body not in [b for b, _ in got]:
            divergent.append({"function": name, "source": source,
                              "prod_signatures": [a for _, a in got]})
        if len(got) > 1 and len(got) > defs:
            overloads.append({"function": name, "prod": len(got), "git_defs": defs,
                              "signatures": [a for _, a in got]})

    prod_only = sorted(
        n for n in prod
        if n not in canon and not n.startswith(SYSTEM_PREFIXES)
    )

    report = {
        "merged_not_deployed": missing,
        "body_divergent": divergent,
        "prod_only": [{"function": n, "signatures": [a for _, a in prod[n]]} for n in prod_only],
        "extra_overloads": overloads,
        "acl_divergent": acl,
        "infra": inf,
        "totals": {"git_functions": len(canon), "prod_functions": len(prod),
                   "acl_rules_checked": sum(len(v) for v in expected_acl.values())},
    }
    drift = len(missing) + len(divergent) + len(prod_only) + len(overloads) + len(acl)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print("=" * 60)
        print(f"AgOS prod-drift · git {len(canon)} функций · прод {len(prod)}")
        print("=" * 60)

        def section(title, items, fmt):
            print(f"\n--- {title}: {len(items)} ---")
            for i in items[:40]:
                print("  " + fmt(i))
            if len(items) > 40:
                print(f"  … ещё {len(items) - 40}")

        section("merged-not-deployed (в git, нет на проде)", missing,
                lambda i: f"{i['function']}  ← {i['source']}")
        section("body-divergent (тело прода ≠ канону, L-1)", divergent,
                lambda i: f"{i['function']}  ← {i['source']}  [{', '.join(i['prod_signatures'])[:70]}]")
        section("prod-only (на проде, нет в git — hotfix мимо канона)",
                report["prod_only"], lambda i: i["function"])
        section("extra-overloads (PGRST203-риск)", overloads,
                lambda i: f"{i['function']}: прод {i['prod']} сигнатур / git {i['git_defs']}")
        section("acl-divergent (грант на проде ≠ канону — класс ARS-311)", acl,
                lambda i: f"{i['function']} · {i['role']}: канон {i['expected']}, на проде {i['actual']}")

        print("\n--- инфра ---")
        if "error" in inf:
            print(f"  ops_deploy_log недоступен: {inf['error']}")
        else:
            print(f"  extensions: {', '.join(inf['extensions'])}")
            print(f"  pg_cron: {'ЕСТЬ' if 'pg_cron' in inf['extensions'] else 'НЕТ (продления не идут по расписанию)'}")
            print(f"  realtime-таблицы: {', '.join(inf['realtime_tables']) or 'ПУСТО (postgres_changes инертны)'}")
            print(f"  записей в ops_deploy_log: {inf['deploy_log_rows']}")
        print(f"\nИТОГО дрейф-позиций: {drift}")

    if args.strict and drift:
        sys.exit(1)


if __name__ == "__main__":
    main()
