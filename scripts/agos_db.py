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

TYPE_ALIASES = {
    "bool": "boolean",
    "decimal": "numeric",
    "float4": "real",
    "float8": "double precision",
    "int": "integer",
    "int2": "smallint",
    "int4": "integer",
    "int8": "bigint",
    "serial2": "smallint",
    "serial4": "integer",
    "serial8": "bigint",
    "time": "time without time zone",
    "timetz": "time with time zone",
    "timestamp": "timestamp without time zone",
    "timestamptz": "timestamp with time zone",
    "varchar": "character varying",
}

DROP_FUNC_RE = re.compile(
    r"drop\s+function\s+(?:if\s+exists\s+)?(?:public\.)?(\w+)\s*\(", re.IGNORECASE
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


def _split_sql_args(args: str) -> list:
    """Splits a function argument list without breaking defaults like ARRAY[1,2]."""
    out, start = [], 0
    parens = brackets = 0
    quote = None
    line_comment = block_comment = False
    i = 0
    while i < len(args):
        ch = args[i]
        nxt = args[i + 1] if i + 1 < len(args) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
        elif block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 1
        elif quote:
            if ch == quote:
                if i + 1 < len(args) and args[i + 1] == quote:
                    i += 2
                    continue
                quote = None
        elif ch == "-" and nxt == "-":
            line_comment = True
            i += 1
        elif ch == "/" and nxt == "*":
            block_comment = True
            i += 1
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "(":
            parens += 1
        elif ch == ")":
            parens -= 1
        elif ch == "[":
            brackets += 1
        elif ch == "]":
            brackets -= 1
        elif ch == "," and parens == 0 and brackets == 0:
            out.append(args[start:i].strip())
            start = i + 1
        i += 1
    tail = args[start:].strip()
    if tail:
        out.append(tail)
    return out


def _normalize_type(type_name: str) -> str:
    value = re.sub(r"\s+", " ", type_name.strip().lower())
    suffix = ""
    while value.endswith("[]"):
        suffix += "[]"
        value = value[:-2].rstrip()
    # PostgreSQL function identity ignores type modifiers: numeric(3,1) and
    # vector(1536) resolve as numeric and vector in pg_proc.
    value = re.sub(r"\(\s*\d+(?:\s*,\s*\d+)*\s*\)$", "", value).rstrip()
    return TYPE_ALIASES.get(value, value) + suffix


def identity_arg_types(args: str, declarations: bool = True) -> tuple:
    """Returns the PostgreSQL identity argument types for DDL or pg_proc text.

    ``declarations=True`` accepts ``p_id uuid default ...``.  ACL signatures use
    only types and therefore pass ``False``. OUT-only arguments are not part of
    a function identity and are skipped.
    """
    types = []
    for raw in _split_sql_args(args):
        value = re.sub(r"/\*.*?\*/", " ", raw, flags=re.S)
        value = re.sub(r"--[^\n]*", " ", value).strip()
        if not value:
            continue
        value = re.split(r"\bdefault\b|(?<![<>:])=(?!=)", value, maxsplit=1,
                         flags=re.I)[0].strip()
        mode = ""
        mode_match = re.match(r"^(inout|in|out|variadic)\s+", value, re.I)
        if mode_match:
            mode = mode_match.group(1).lower()
            value = value[mode_match.end():].strip()
        if mode == "out":
            continue
        if declarations:
            match = re.match(r'^(?:"(?:[^"]|"")+"|[A-Za-z_][\w$]*)\s+(.+)$',
                             value, re.S)
            if match:
                value = match.group(1).strip()
        types.append(_normalize_type(value))
    return tuple(types)


def _closing_paren(text: str, opening: int) -> int:
    depth = 0
    quote = None
    line_comment = block_comment = False
    i = opening
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
        elif block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 1
        elif quote:
            if ch == quote:
                if i + 1 < len(text) and text[i + 1] == quote:
                    i += 2
                    continue
                quote = None
        elif ch == "-" and nxt == "-":
            line_comment = True
            i += 1
        elif ch == "/" and nxt == "*":
            block_comment = True
            i += 1
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def _extract_definition(sql_text: str, match) -> tuple:
    name = match.group(1).lower()
    opening = match.end() - 1
    closing = _closing_paren(sql_text, opening)
    if closing == -1:
        return None
    types = identity_arg_types(sql_text[opening + 1:closing])
    dollar = re.search(r"\$(\w*)\$", sql_text[closing + 1:closing + 5000])
    if not dollar:
        return None
    tag = f"${dollar.group(1)}$"
    start = closing + 1 + dollar.end()
    end = sql_text.find(tag, start)
    if end == -1:
        return None
    return name, types, normalize_body(sql_text[start:end])


def extract_function_definitions(sql_text: str) -> list:
    """Returns ``[(name, identity_types, normalized_body), ...]`` in DDL order."""
    return [definition for match in FUNC_RE.finditer(sql_text)
            if (definition := _extract_definition(sql_text, match)) is not None]


def extract_function_operations(sql_text: str) -> list:
    """Returns ordered CREATE/DROP operations with overload-safe identities."""
    operations = []
    for match in FUNC_RE.finditer(sql_text):
        definition = _extract_definition(sql_text, match)
        if definition is not None:
            operations.append((match.start(), ("create",) + definition))
    for match in DROP_FUNC_RE.finditer(sql_text):
        opening = match.end() - 1
        closing = _closing_paren(sql_text, opening)
        if closing == -1:
            continue
        types = identity_arg_types(sql_text[opening + 1:closing], declarations=True)
        operations.append((match.start(), ("drop", match.group(1).lower(), types, None)))
    return [operation for _start, operation in sorted(operations)]


def extract_functions(sql_text: str) -> dict:
    """{имя: [нормализованное тело, ...]} в порядке появления.

    Тело = текст между парой dollar-quote ($$ / $function$ / $body$) сразу после
    заголовка. Именно он попадает в pg_proc.prosrc, поэтому сравним с прод-стороной.
    Порядок важен: при нескольких определениях одного имени выигрывает ПОСЛЕДНЕЕ
    (семантика L-1 и порядка применения PostgreSQL)."""
    out = {}
    for name, _types, body in extract_function_definitions(sql_text):
        out.setdefault(name, []).append(body)
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


def extract_acl_definitions(sql_text: str) -> dict:
    """{(name, identity_types): {role: bool}} with overload-safe ACL keys."""
    out = {}
    for match in GRANT_RE.finditer(sql_text):
        action, name, roles = match.group(1).lower(), match.group(2).lower(), match.group(3)
        opening = sql_text.find("(", match.start())
        closing = _closing_paren(sql_text, opening)
        if opening == -1 or closing == -1:
            continue
        types = identity_arg_types(sql_text[opening + 1:closing], declarations=False)
        key = (name, types)
        for role in (role.strip().lower() for role in roles.split(",")):
            if role in ("public", "anon", "authenticated", "service_role"):
                out.setdefault(key, {})[role] = (action == "grant")
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
