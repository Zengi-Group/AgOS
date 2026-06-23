#!/usr/bin/env python3
"""
TARGETED hotfix deployer — DEF-VET-F11-ISOLATION (2026-06-22).
Applies ONLY public.rpc_get_vet_case_detail (the ownership-guard fix) to
Supabase project mwtbozflyldcadypherr, then verifies the guard is live.

Why targeted (not deploy_sql.py): a one-function security hotfix should not
re-apply all canonical files (d01..d11) to prod. CREATE OR REPLACE FUNCTION is
atomic and safe.

Usage (password via env, NOT argv — stays out of shell history / process list):
    export AGOS_DB_PASSWORD='...'   # Supabase Dashboard -> Settings -> Database
    python3 deploy_vet_isolation_fix.py
"""
import os
import sys
import psycopg2

DB_HOST = "aws-1-ap-south-1.pooler.supabase.com"
DB_PORT = 5432
DB_NAME = "postgres"
DB_USER = "postgres.mwtbozflyldcadypherr"
SRC_FILE = "d04_vet.sql"
FN_SIGNATURE = "create or replace function public.rpc_get_vet_case_detail("
GUARD_MARKER = "caller does not belong to organization"


def extract_function(path: str) -> str:
    """Pull the single rpc_get_vet_case_detail DDL block (from the
    CREATE OR REPLACE line through its closing $$;)."""
    text = open(path, "r", encoding="utf-8").read()
    start = text.find(FN_SIGNATURE)
    if start == -1:
        sys.exit(f"FATAL: {FN_SIGNATURE!r} not found in {path}")
    # closing delimiter for this function body
    end = text.find("\n$$;", start)
    if end == -1:
        sys.exit("FATAL: closing $$; not found for function body")
    block = text[start:end + len("\n$$;")]
    if block.count(FN_SIGNATURE) != 1:
        sys.exit("FATAL: extracted block does not contain exactly one definition")
    if GUARD_MARKER not in block:
        sys.exit("FATAL: extracted block is missing the ownership guard — aborting")
    return block


def main():
    password = os.environ.get("AGOS_DB_PASSWORD") or (sys.argv[1] if len(sys.argv) > 1 else None)
    if not password:
        sys.exit("FATAL: set AGOS_DB_PASSWORD env var (or pass password as argv[1])")

    proj_dir = os.path.dirname(os.path.abspath(__file__))
    ddl = extract_function(os.path.join(proj_dir, SRC_FILE))
    print(f"Extracted rpc_get_vet_case_detail DDL ({len(ddl)} chars, guard present).")

    print(f"Connecting to {DB_HOST}:{DB_PORT}/{DB_NAME} ...")
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
        password=password, connect_timeout=30, sslmode="require",
    )
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            cur.execute(ddl)
        conn.commit()
        print("Applied: CREATE OR REPLACE FUNCTION committed.")

        # Verify the deployed function body actually contains the guard.
        with conn.cursor() as cur:
            cur.execute(
                "SELECT pg_get_functiondef('public.rpc_get_vet_case_detail(uuid,uuid)'::regprocedure)"
            )
            deployed = cur.fetchone()[0]
        if GUARD_MARKER in deployed and "fn_my_org_ids" in deployed:
            print("VERIFIED on prod: ownership guard is present in the deployed function.")
        else:
            sys.exit("FATAL: deployed function does NOT contain the guard — investigate!")
    except Exception as e:
        conn.rollback()
        sys.exit(f"FAILED (rolled back): {e}")
    finally:
        conn.close()

    print("\nDone. rpc_get_vet_case_detail hotfix is live on mwtbozflyldcadypherr.")


if __name__ == "__main__":
    main()
