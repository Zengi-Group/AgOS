#!/usr/bin/env python3
"""Общий слой доступа к прод-БД AgOS: пароль, коннект, парсинг функций из SQL.

Используют scripts/deploy.py (пишет) и scripts/prod_diff.py (только читает).
Вынесено в модуль, чтобы правила «где брать пароль» и «как нормализовать тело
функции» существовали в ОДНОМ месте (P4): расхождение нормализации между
деплоером и дрейф-детектором давало бы ложные «divergent».
"""
import hashlib
import os
import re
import subprocess
import sys

DB_HOST = "aws-1-ap-south-1.pooler.supabase.com"
DB_PORT = 5432  # session mode (не 6543 transaction mode — DDL требует session)
DB_NAME = "postgres"
DB_USER = "postgres.mwtbozflyldcadypherr"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Канонический порядок применения (CLAUDE.md §Code Rules).
# d10 включён — DEPLOY-PIPE-01: его отсутствие в старом deploy_sql.py означало,
# что свежий полный деплой молча пропускал storage-политики (SEC-STORAGE-01).
DOMAIN_FILES = [
    "d01_kernel.sql",
    "d02_tsp.sql",
    "d03_feed.sql",
    "d04_vet.sql",
    "d05_ops_edu.sql",
    "d07_ai_gateway.sql",
    "d08_epidemic.sql",
    "d09_consulting.sql",
    "d10_public_site.sql",
    "d11_norms.sql",
    "d12_messaging.sql",
    "d13_billing.sql",
    "d14_governance.sql",
]

MIGRATIONS_DIR = "supabase/migrations"

# Миграции, которые НЕЛЬЗЯ применять на прод автоматически (арм-DDL и подобное).
# D-BILL-CRON-STAGING-01: pg_cron-арм движка продлений раздал бы бесплатные
# продления живым организациям при stub-провайдере — включение только вручную
# после платёжного провайдера (ARS-270) и отдельного G3.
MIGRATION_DENYLIST = {
    "20260717120000_membership_renewals_pg_cron.sql",
}

FUNC_RE = re.compile(
    r"create\s+or\s+replace\s+function\s+(?:public\.)?(\w+)\s*\(", re.IGNORECASE
)


def read_password() -> str:
    """.db_password (gitignored) → AGOS_DB_PASSWORD. Никогда не argv:
    пароль в argv виден в `ps` и остаётся в истории шелла."""
    pwfile = os.path.join(REPO_ROOT, ".db_password")
    if os.path.exists(pwfile):
        pw = open(pwfile, encoding="utf-8").read().strip()
        if pw:
            return pw
    return os.environ.get("AGOS_DB_PASSWORD", "")


def connect(readonly: bool = False):
    try:
        import psycopg2
    except ImportError:
        sys.exit("FATAL: нет psycopg2 — pip install psycopg2-binary")

    pw = read_password()
    if not pw:
        sys.exit(
            "FATAL: нет пароля БД. Создай ./.db_password (gitignored) "
            "или export AGOS_DB_PASSWORD=... (Supabase → Settings → Database)."
        )
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
        password=pw, connect_timeout=30, sslmode="require",
    )
    conn.autocommit = False
    if readonly:
        with conn.cursor() as cur:
            cur.execute("set default_transaction_read_only = on")
        conn.commit()
    return conn


def git_state() -> tuple:
    """(sha, dirty) рабочей копии. Грязное дерево => sha не описывает применённое."""
    def run(args):
        try:
            return subprocess.run(
                args, cwd=REPO_ROOT, capture_output=True, text=True, timeout=10
            ).stdout.strip()
        except Exception:
            return ""
    return run(["git", "rev-parse", "HEAD"]), bool(run(["git", "status", "--porcelain"]))


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def normalize_body(body: str) -> str:
    """Схлопывает пробелы и регистр — чтобы форматирование не давало ложный дрейф.
    Комментарии НЕ выкидываем: они часть тела в pg_proc.prosrc и отличие в них
    (например утерянный маркер guard) — настоящий сигнал."""
    return re.sub(r"\s+", " ", body).strip().lower()


def extract_functions(sql_text: str) -> dict:
    """{имя: [нормализованное тело, ...]} в порядке появления.

    Тело = текст между парой dollar-quote ($$ / $function$ / $body$) сразу после
    заголовка. Именно он попадает в pg_proc.prosrc, поэтому сравним с прод-стороной.
    Порядок важен: при нескольких определениях одного имени выигрывает ПОСЛЕДНЕЕ
    (семантика L-1 и порядка применения PostgreSQL)."""
    out = {}
    for m in FUNC_RE.finditer(sql_text):
        name = m.group(1).lower()
        dq = re.search(r"\$(\w*)\$", sql_text[m.end():m.end() + 4000])
        if not dq:
            continue
        tag = f"${dq.group(1)}$"
        start = m.end() + dq.end()
        end = sql_text.find(tag, start)
        if end == -1:
            continue
        out.setdefault(name, []).append(normalize_body(sql_text[start:end]))
    return out


GRANT_RE = re.compile(
    r"\b(grant|revoke)\s+execute\s+on\s+function\s+(?:public\.)?(\w+)\s*\([^)]*\)\s*"
    r"(?:to|from)\s+([^;]+);", re.IGNORECASE
)


def extract_acl(sql_text: str) -> dict:
    """{имя: {роль: True|False}} — ожидаемое право execute по git.

    True = канон явно грантит роли, False = канон явно отзывает. Позднее указание
    в порядке применения выигрывает (как и в PostgreSQL)."""
    out = {}
    for m in GRANT_RE.finditer(sql_text):
        action, name, roles = m.group(1).lower(), m.group(2).lower(), m.group(3)
        for role in (r.strip().lower() for r in roles.split(",")):
            if role in ("public", "anon", "authenticated", "service_role"):
                out.setdefault(name, {})[role] = (action == "grant")
    return out


def canonical_sources() -> list:
    """[(логическое_имя, абсолютный_путь)] — d-файлы, затем миграции по времени.
    Порядок = порядок применения (TSP-ADAPTER-02: adapter поверх d-файлов)."""
    src = []
    for f in DOMAIN_FILES:
        p = os.path.join(REPO_ROOT, f)
        if os.path.exists(p):
            src.append((f, p))
    mig_dir = os.path.join(REPO_ROOT, MIGRATIONS_DIR)
    if os.path.isdir(mig_dir):
        for f in sorted(os.listdir(mig_dir)):
            if f.endswith(".sql"):
                src.append((f"{MIGRATIONS_DIR}/{f}", os.path.join(mig_dir, f)))
    return src
