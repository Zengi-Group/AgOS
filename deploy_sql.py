#!/usr/bin/env python3
"""
AgOS SQL Migration Deployer
Applies d01→d02→d03→d04→d05→d07→d08→d09→d11→d12 to Supabase project mwtbozflyldcadypherr
NOTE: d10_public_site.sql is NOT in the list — see IMPL_DEBT DEPLOY-PIPE-01 before adding.
Usage: python3 deploy_sql.py <DB_PASSWORD>
"""

import sys
import os
import psycopg2
from psycopg2 import sql as psql

DB_HOST = "aws-1-ap-south-1.pooler.supabase.com"
DB_PORT = 5432  # Session mode (not 6543 transaction mode)
DB_NAME = "postgres"
DB_USER = "postgres.mwtbozflyldcadypherr"

SQL_FILES = [
    "d01_kernel.sql",
    "d02_tsp.sql",
    "d03_feed.sql",
    "d04_vet.sql",
    "d05_ops_edu.sql",
    "d07_ai_gateway.sql",
    "d08_epidemic.sql",
    "d09_consulting.sql",
    # d10_public_site.sql intentionally absent? — undecided; flagged as DEPLOY-PIPE-01 in IMPL_DEBT.md
    "d11_norms.sql",
    "d12_messaging.sql",    # ARS-223: messaging domain (comm_channels/participants/messages)
    "d13_billing.sql",      # ARS-203: membership billing (depends on d01)
    "d14_governance.sql",   # ARS-204: feature governance / M3 (depends on d01, d13)
]

def deploy(password: str):
    project_dir = os.path.dirname(os.path.abspath(__file__))

    print(f"Connecting to {DB_HOST}:{DB_PORT}/{DB_NAME} ...")
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=password,
            connect_timeout=30,
            sslmode="require",
        )
        conn.autocommit = False
        print("Connected OK.\n")
    except Exception as e:
        print(f"Connection failed: {e}")
        sys.exit(1)

    for filename in SQL_FILES:
        filepath = os.path.join(project_dir, filename)
        if not os.path.exists(filepath):
            print(f"SKIP  {filename} (file not found)")
            continue

        size_kb = os.path.getsize(filepath) // 1024
        print(f"Applying {filename} ({size_kb}KB) ...", end=" ", flush=True)

        with open(filepath, "r", encoding="utf-8") as f:
            sql_content = f.read()

        try:
            with conn.cursor() as cur:
                cur.execute(sql_content)
            conn.commit()
            print("OK")
        except Exception as e:
            conn.rollback()
            print(f"FAILED\n  Error: {e}")
            print(f"  Stopping. Fix the error in {filename} and re-run.")
            conn.close()
            sys.exit(1)

    conn.close()
    print("\nAll migrations applied successfully.")
    print("Next step: run verify step (SELECT count(*) FROM information_schema.tables WHERE table_schema='public')")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 deploy_sql.py <DB_PASSWORD>")
        print("DB Password: Supabase Dashboard → Settings → Database → Database password")
        sys.exit(1)
    deploy(sys.argv[1])
