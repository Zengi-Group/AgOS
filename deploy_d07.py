#!/usr/bin/env python3
"""
Targeted deployer — d07_ai_gateway.sql (2026-06-23).
Applies the entire file in ONE transaction (all CREATE OR REPLACE FUNCTION),
then spot-checks 4 key functions via pg_get_functiondef.

Password: .db_password (gitignored) → AGOS_DB_PASSWORD env var → argv[1].
"""
import os
import sys
import psycopg2

DB_HOST = "aws-1-ap-south-1.pooler.supabase.com"
DB_PORT = 5432
DB_NAME = "postgres"
DB_USER = "postgres.mwtbozflyldcadypherr"
SRC = "d07_ai_gateway.sql"

# (function name, markers that MUST be in the deployed body)
# Lookup by name (not regprocedure) to avoid signature guessing.
VERIFY = {
    "rpc_create_batch":      ["p_organization_id", "_ai_check_farm_org"],
    "rpc_publish_batch":     ["p_organization_id", "farmer_price_per_kg"],
    "fn_my_org_ids":         ["auth.uid()", "organization_id"],
    "rpc_get_ai_farm_context": ["p_organization_id", "p_farm_id"],
}


def read_password() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    pwfile = os.path.join(here, ".db_password")
    if os.path.exists(pwfile):
        pw = open(pwfile, encoding="utf-8").read().strip()
        if pw:
            return pw
    return os.environ.get("AGOS_DB_PASSWORD") or (sys.argv[1] if len(sys.argv) > 1 else "")


def main():
    pw = read_password()
    if not pw:
        sys.exit("FATAL: no password (create ./.db_password, or set AGOS_DB_PASSWORD).")

    here = os.path.dirname(os.path.abspath(__file__))
    sql = open(os.path.join(here, SRC), encoding="utf-8").read()
    print(f"Loaded {SRC} ({len(sql)} chars, {sql.count(chr(10))+1} lines).")

    print(f"Connecting to {DB_HOST}:{DB_PORT}/{DB_NAME} ...")
    conn = psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
                            password=pw, connect_timeout=30, sslmode="require")
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            print("  d07_ai_gateway.sql executed (pre-commit).")
        conn.commit()
        print("COMMITTED.")

        print("Verifying deployed bodies on prod ...")
        ok = True
        with conn.cursor() as cur:
            for name, markers in VERIFY.items():
                try:
                    cur.execute(
                        "SELECT pg_get_functiondef(p.oid) FROM pg_proc p "
                        "JOIN pg_namespace n ON p.pronamespace = n.oid "
                        "WHERE n.nspname = 'public' AND p.proname = %s LIMIT 1",
                        (name,),
                    )
                    row = cur.fetchone()
                    if not row:
                        ok = False
                        print(f"  ✗ {name}: function not found in pg_proc")
                        continue
                    body = row[0]
                    miss = [m for m in markers if m not in body]
                    if miss:
                        ok = False
                        print(f"  ✗ {name}: MISSING {miss}")
                    else:
                        print(f"  ✓ {name}: all markers present")
                except Exception as e:
                    ok = False
                    print(f"  ✗ {name}: lookup error — {e}")
        if not ok:
            sys.exit("FATAL: a deployed function is missing expected markers — investigate!")
    except Exception as e:
        conn.rollback()
        sys.exit(f"FAILED (rolled back): {e}")
    finally:
        conn.close()
    print("\nDone. d07_ai_gateway.sql is live on mwtbozflyldcadypherr.")


if __name__ == "__main__":
    main()
