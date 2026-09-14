#!/usr/bin/env python3
"""Прогон SQL-файла на боевой базе В ОТКАТЫВАЕМОЙ ТРАНЗАКЦИИ.

По умолчанию — всегда ROLLBACK: файл выполняется целиком, NOTICE печатаются, база
остаётся нетронутой. Это способ ПОСМОТРЕТЬ, что скрипт сделает, до того как он это
сделает — и он же позволяет прогонять тесты и ремонты, когда staging-среды нет
(IMPL_DEBT QA-ENV-ISOLATION-01).

    python3 scripts/run_sql_rollback.py <file.sql>            # посмотреть (ROLLBACK)
    python3 scripts/run_sql_rollback.py <file.sql> --apply    # применить (COMMIT)

`--apply` требует отдельного подтверждения словом и печатает, что именно коммитит:
это необратимая запись в единственную боевую базу.

Транзакцию открываем ОТДЕЛЬНЫМ запросом до основного: сторожа в тестовых файлах
проверяют `transaction_timestamp() < statement_timestamp()`, чтобы отличить явную
транзакцию от автокоммита.

Пароль берётся только из .db_password / AGOS_DB_PASSWORD (через agos_db) и никогда
не передаётся аргументом командной строки — argv виден в ps и в истории шелла.
"""
import io
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, "scripts")
import agos_db as db  # noqa: E402


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    apply_mode = "--apply" in sys.argv
    if len(args) != 1:
        print(__doc__)
        return 2

    path = args[0]
    sql = io.open(path, encoding="utf-8").read()
    # psql-мета-команды (\set, \i) сервер не понимает — выполняем только SQL.
    body = "\n".join(
        l for l in sql.splitlines()
        if not l.startswith("\\") and l.strip() not in ("begin;", "rollback;", "commit;")
    )

    mode = "ПРИМЕНЕНИЕ (COMMIT)" if apply_mode else "ПРОСМОТР (ROLLBACK)"
    print(f"файл : {path}")
    print(f"режим: {mode}")
    print(f"база : {db.DB_USER}@{db.DB_HOST}")
    print("-" * 70)

    if apply_mode:
        print("Это необратимая запись в боевую базу.")
        try:
            answer = input("Введите ПРИМЕНИТЬ для подтверждения: ").strip()
        except EOFError:
            print("ОТМЕНА: подтверждение невозможно в неинтерактивном режиме.")
            return 1
        if answer != "ПРИМЕНИТЬ":
            print("ОТМЕНА: подтверждение не получено.")
            return 1

    conn = db.connect()
    conn.autocommit = False
    cur = conn.cursor()
    failed = False
    try:
        cur.execute("select 1")   # открыть транзакцию до основного запроса
        cur.execute(body)
        print("SQL выполнен без ошибок.")
    except Exception as exc:
        failed = True
        print(f"ОШИБКА: {type(exc).__name__}")
        print(str(exc)[:3000])
    finally:
        for note in conn.notices:
            print("  ", note.rstrip())
        if failed or not apply_mode:
            conn.rollback()
            print("-" * 70)
            print("ROLLBACK выполнен — база не изменена.")
        else:
            conn.commit()
            print("-" * 70)
            print("COMMIT выполнен — изменения применены.")
        conn.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
