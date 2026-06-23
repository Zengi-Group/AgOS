#!/usr/bin/env python3
"""
TARGETED deployer — TSP-MATCH-HAPPY-PATH (2026-06-23, PR #6 c5b1ddb).
Applies ONLY the three changed TSP functions + the rpc_set_batch_terms registry
upsert to Supabase project mwtbozflyldcadypherr, in ONE transaction, then verifies
the deployed bodies on prod via pg_get_functiondef.

Why targeted (not deploy_sql.py): a focused matching-engine fix should not
re-apply all canonical files (d01..d11). CREATE OR REPLACE FUNCTION is atomic.

Password resolution (plaintext never on argv / never in chat):
    1. ./.db_password  (gitignored file, first line)   <- preferred
    2. AGOS_DB_PASSWORD env var
    3. argv[1]  (last resort)
"""
import os
import sys
import psycopg2

DB_HOST = "aws-1-ap-south-1.pooler.supabase.com"
DB_PORT = 5432
DB_NAME = "postgres"
DB_USER = "postgres.mwtbozflyldcadypherr"
SRC = "d02_tsp.sql"

FUNCS = ["rpc_retry_match_pool", "rpc_accept_offer", "rpc_set_batch_terms"]

# (regprocedure signature, list of substrings the DEPLOYED body must contain)
VERIFY = {
    "rpc_retry_match_pool": (
        "public.rpc_retry_match_pool(uuid,uuid)",
        ["'offering'", "b.status = 'published'"],          # published -> offering transition
    ),
    "rpc_accept_offer": (
        "public.rpc_accept_offer(uuid,uuid)",
        [">= v_offer.offered_price_per_kg",                # C1 price-direction
         "deal_price_per_kg = v_pool_line.pl_price"],      # D-M6-DEALPRICE (farmer gets MPK bid)
    ),
    "rpc_set_batch_terms": (
        "public.rpc_set_batch_terms(uuid,uuid,integer,date,date)",
        ["ready_to (%) must be >= ready_from", "farmer_price_per_kg"], # new additive RPC present
    ),
}


def read_password() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    pwfile = os.path.join(here, ".db_password")
    if os.path.exists(pwfile):
        pw = open(pwfile, encoding="utf-8").read().strip()
        if pw:
            return pw
    return os.environ.get("AGOS_DB_PASSWORD") or (sys.argv[1] if len(sys.argv) > 1 else "")


def extract_function(text: str, name: str) -> str:
    sig = f"create or replace function public.{name}("
    start = text.find(sig)
    if start == -1:
        sys.exit(f"FATAL: {sig!r} not found in {SRC}")
    # closing dollar-quote delimiter for the body. These functions end with
    # 'end; $$;' (same line), so match '$$;' directly (the opening is 'as $$',
    # no semicolon, so it won't false-match).
    end = text.find("$$;", start)
    if end == -1:
        sys.exit(f"FATAL: closing $$; not found for {name}")
    block = text[start:end + len("$$;")]
    if block.count(sig) != 1:
        sys.exit(f"FATAL: extracted {name} block is not a single definition")
    return block


# Hardcoded (idempotent) — the notes string in the source contains a ';', which
# defeats regex extraction. This mirrors the d02_tsp.sql registry upsert for
# rpc_set_batch_terms; it is naming metadata (D-NEW-A), not runtime-critical.
REGISTRY_SQL = (
    "insert into public.rpc_name_registry "
    "(sql_name, dok3_name, dok5_tool_name, created_in, notes) values "
    "('rpc_set_batch_terms', 'rpc_set_batch_terms', null, "
    "'d02_tsp.sql (TSP-FLOW-03 / Phase 2)', "
    "'Set farmer_price_per_kg + ready window on draft|published batch; unblocks matching eligibility') "
    "on conflict (sql_name) do update set "
    "dok3_name = excluded.dok3_name, notes = excluded.notes, created_in = excluded.created_in;"
)


def main():
    pw = read_password()
    if not pw:
        sys.exit("FATAL: no password (create ./.db_password, or set AGOS_DB_PASSWORD).")

    here = os.path.dirname(os.path.abspath(__file__))
    text = open(os.path.join(here, SRC), encoding="utf-8").read()

    blocks = [extract_function(text, n) for n in FUNCS]
    registry = REGISTRY_SQL
    # pre-apply sanity on the extracted source (catch a bad checkout before touching prod)
    assert "'offering'" in blocks[0] and "b.status = 'published'" in blocks[0], "retry_match block missing offering transition"
    assert ">= v_offer.offered_price_per_kg" in blocks[1], "accept_offer block missing C1 >= fix"
    assert "deal_price_per_kg = v_pool_line.pl_price" in blocks[1], "accept_offer block missing deal-price policy"
    print(f"Extracted {len(blocks)} functions + registry insert; source markers OK.")

    print(f"Connecting to {DB_HOST}:{DB_PORT}/{DB_NAME} ...")
    conn = psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
                            password=pw, connect_timeout=30, sslmode="require")
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            for n, b in zip(FUNCS, blocks):
                cur.execute(b)
                print(f"  applied {n}")
            cur.execute(registry)
            print("  applied rpc_set_batch_terms registry upsert")
        conn.commit()
        print("COMMITTED.")

        print("Verifying deployed bodies on prod ...")
        ok = True
        with conn.cursor() as cur:
            for name, (sig, markers) in VERIFY.items():
                cur.execute("SELECT pg_get_functiondef(%s::regprocedure)", (sig,))
                body = cur.fetchone()[0]
                miss = [m for m in markers if m not in body]
                if miss:
                    ok = False
                    print(f"  ✗ {name}: MISSING {miss}")
                else:
                    print(f"  ✓ {name}: all markers present")
        if not ok:
            sys.exit("FATAL: a deployed function is missing expected markers — investigate!")
    except Exception as e:
        conn.rollback()
        sys.exit(f"FAILED (rolled back): {e}")
    finally:
        conn.close()
    print("\nDone. TSP matching happy-path fix is live on mwtbozflyldcadypherr.")


if __name__ == "__main__":
    main()
