import importlib.util
from pathlib import Path
import unittest


MODULE = Path(__file__).resolve().parents[1] / "scripts" / "agos_db.py"
SPEC = importlib.util.spec_from_file_location("agos_db", MODULE)
db = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(db)


class FunctionDefinitionParserTest(unittest.TestCase):
    def test_overloads_are_keyed_by_identity_types(self):
        sql = """
        create or replace function public.demo(p_id uuid, p_limit int default 10)
        returns int language plpgsql as $$ begin return 1; end; $$;
        create or replace function public.demo(p_value text)
        returns int language plpgsql as $$ begin return 2; end; $$;
        """
        definitions = db.extract_function_definitions(sql)
        self.assertEqual(
            [(name, types) for name, types, _body in definitions],
            [("demo", ("uuid", "integer")), ("demo", ("text",))],
        )
        self.assertIn("return 1", definitions[0][2])
        self.assertIn("return 2", definitions[1][2])

    def test_defaults_with_commas_do_not_split_arguments(self):
        args = "p_values int[] default array[1,2], p_seen timestamptz default now()"
        self.assertEqual(
            db.identity_arg_types(args),
            ("integer[]", "timestamp with time zone"),
        )

    def test_comments_with_apostrophes_and_commas_do_not_change_signature(self):
        sql = """
        create or replace function public.demo(
          p_data jsonb default '{"a": 1, "b": 2}'::jsonb,
          p_note text -- expert's note, not another argument
        ) returns int language plpgsql as $$ begin return 1; end; $$;
        """
        definitions = db.extract_function_definitions(sql)
        self.assertEqual(definitions[0][1], ("jsonb", "text"))

    def test_drop_removes_only_matching_overload(self):
        sql = """
        create or replace function public.demo(p_value text)
        returns int language plpgsql as $$ begin return 1; end; $$;
        create or replace function public.demo(p_value uuid)
        returns int language plpgsql as $$ begin return 2; end; $$;
        drop function if exists public.demo(text);
        """
        operations = db.extract_function_operations(sql)
        self.assertEqual(
            [(action, name, types) for action, name, types, _body in operations],
            [
                ("create", "demo", ("text",)),
                ("create", "demo", ("uuid",)),
                ("drop", "demo", ("text",)),
            ],
        )

    def test_named_drop_keeps_multiword_type(self):
        sql = "drop function if exists public.demo(p_seen timestamp with time zone);"
        operation = db.extract_function_operations(sql)[0]
        self.assertEqual(operation[:3], ("drop", "demo", ("timestamp with time zone",)))

    def test_acl_is_overload_safe(self):
        sql = """
        revoke execute on function public.demo(uuid) from public, anon;
        grant execute on function public.demo(text) to authenticated;
        """
        acl = db.extract_acl_definitions(sql)
        self.assertEqual(acl[("demo", ("uuid",))], {"public": False, "anon": False})
        self.assertEqual(acl[("demo", ("text",))], {"authenticated": True})


if __name__ == "__main__":
    unittest.main()
