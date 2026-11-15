#!/usr/bin/env python3
"""
dbt Sentinel - static macro/view validation and mock-context render tests.

    python tests/check_package.py            # all checks
    python tests/check_package.py --verbose  # also print rendered SQL
    python tests/check_package.py --dump-sql out_dir   # write rendered SQL files

What this does (no database or dbt installation required; needs jinja2,
optionally sqlglot for T-SQL syntax parsing):

  1. File layout and dbt_project.yml sanity.
  2. Splits every macro the way dbt does (one template per macro), checks
     names are unique and that every template parses with dbt's Jinja
     extensions.
  3. Cross-checks the README: every documented view and operation exists.
  4. Renders the operations and hooks against a mock dbt context (target,
     vars, graph, results, run_query) and asserts on the SQL they issue,
     including input validation and escaping.
  5. Applies Dedicated SQL Pool dialect rules to every rendered statement and,
     if sqlglot is installed, parses each statement as T-SQL.

It is NOT a substitute for the integration tests in integration_tests/ against
a development Dedicated SQL Pool.
"""
from __future__ import annotations

import argparse
import datetime as dt
import math
import re
import sys
import uuid
from pathlib import Path
from types import SimpleNamespace

try:
    import jinja2
    import jinja2.sandbox
except ImportError:  # pragma: no cover
    print("jinja2 is required (pip install jinja2)")
    sys.exit(2)

try:
    import sqlglot
    from sqlglot.errors import ParseError
except ImportError:  # pragma: no cover
    sqlglot = None

ROOT = Path(__file__).resolve().parent.parent
MACRO_DIR = ROOT / "macros"

EXPECTED_FILES = [
    "dbt_project.yml",
    "README.md",
    "macros/helpers.sql",
    "macros/install.sql",
    "macros/collect.sql",
    "macros/views.sql",
    "examples/packages.yml",
    "examples/dbt_project_fragment.yml",
    "examples/azure-pipelines-steps.yml",
    "examples/powerbi_measures.dax",
    "tests/check_package.py",
    "tests/dbt_fake_pool.py",
    "scripts/freshness_to_sentinel.py",
    "integration_tests/dbt_project.yml",
    "integration_tests/acceptance_queries.sql",
]

MACRO_RE = re.compile(
    r"{%-?\s*macro\s+(\w+)\s*\((.*?)\)\s*-?%}(.*?){%-?\s*endmacro\s*-?%}", re.S
)


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #
class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []
        self.passed = 0

    def ok(self, cond: bool, label: str) -> bool:
        if cond:
            self.passed += 1
        else:
            self.failures.append(label)
            print(f"  FAIL  {label}")
        return cond

    def warn(self, label: str) -> None:
        self.warnings.append(label)
        print(f"  WARN  {label}")


R = Report()


# --------------------------------------------------------------------------- #
# Mock dbt runtime
# --------------------------------------------------------------------------- #
class MacroReturn(Exception):
    def __init__(self, value):
        super().__init__("return")
        self.value = value


class CompilerError(Exception):
    pass


def _return(value):
    raise MacroReturn(value)


class MockTable:
    def __init__(self, rows=None):
        self.rows = [tuple(r) for r in (rows or [])]


class MockDb:
    """Records statements and answers the catalogue queries the macros issue."""

    def __init__(self, schema_exists=True, columns=None, objects=None,
                 try_error_for=None, purge_count=3, watermark=None, missing_tables=None,
                 missing_columns=None, principals=None):
        self.statements: list[str] = []
        self.catalog: list[str] = []  # readiness / principal lookups, kept apart from the work statements
        self.schema_exists = schema_exists
        self.columns = columns if columns is not None else {}
        self.objects = objects if objects is not None else []
        self.try_error_for = try_error_for or []
        self.purge_count = purge_count
        self.watermark = watermark
        self.missing_tables = missing_tables or []
        self.missing_columns = missing_columns or {}
        self.principals = principals if principals is not None else ["powerbi_readers", "PBI-Readers]x"]

    def run_query(self, sql):
        sql = str(sql)
        if "AS table_found" in sql or "FROM sys.database_principals" in sql:
            self.catalog.append(sql)
        else:
            self.statements.append(sql)
        if "FROM sys.schemas WHERE name" in sql:
            return MockTable([[1 if self.schema_exists else 0]])
        if "JOIN sys.columns" in sql:
            return MockTable([[t, c] for t, cols in self.columns.items() for c in cols])
        if "AS table_found" in sql:
            name = sql.split("AND t.name = N'")[1].split("'")[0]
            in_list = sql.split("LOWER(c.name) IN (")[1].split(")")[0]
            expected = in_list.count("N'")
            if name in self.missing_tables:
                return MockTable([[0, 0]])
            return MockTable([[1, expected - len(self.missing_columns.get(name, []))]])
        if "FROM sys.database_principals" in sql:
            name = sql.split("name = N'")[1][:-1].replace("''", "'")
            return MockTable([[1 if name in self.principals else 0]])
        if "FROM sys.objects" in sql:
            return MockTable([[o] for o in self.objects])
        if "CONVERT(nvarchar(30), MAX(" in sql:
            return MockTable([[self.watermark]])
        if "COUNT_BIG(*)" in sql:
            return MockTable([[self.purge_count]])
        if "BEGIN TRY" in sql:
            if any(tok in sql for tok in self.try_error_for):
                return MockTable([[229, "The SELECT permission was denied"]])
            return MockTable([[0, None]])
        return MockTable([])


class MacroGen:
    def __init__(self, runtime, name, template):
        self.runtime, self.name, self.template = runtime, name, template

    def __call__(self, *args, **kwargs):
        module = self.template.make_module(vars=self.runtime.ctx)
        try:
            out = getattr(module, self.name)(*args, **kwargs)
        except MacroReturn as r:
            return r.value
        return str(out)


class Runtime:
    def __init__(self, macros, *, db=None, vars=None, env=None, target_type="synapse",
                 which="build", execute=True, graph=None, results=None, project="tdi"):
        self.db = db or MockDb()
        self.logs: list[str] = []
        self.warnings: list[str] = []
        user_vars = {"sentinel_schema": "sentinel"}
        user_vars.update(vars or {})
        env = env or {}
        self.env = jinja2.sandbox.SandboxedEnvironment(extensions=["jinja2.ext.do"])

        def var(name, default=None):
            return user_vars.get(name, default)

        def env_var(name, default=None):
            if name in env:
                return env[name]
            if default is None:
                raise CompilerError(f"env var {name} not set")
            return default

        def raise_compiler_error(msg):
            raise CompilerError(msg)

        def warn(msg):
            self.warnings.append(msg)
            return ""

        def log(msg, info=False):
            self.logs.append(str(msg))
            return ""

        def run_query(sql):
            return self.db.run_query(sql)

        self.ctx = {
            "return": _return,
            "var": var,
            "env_var": env_var,
            "log": log,
            "run_query": run_query,
            "execute": execute,
            "exceptions": SimpleNamespace(raise_compiler_error=raise_compiler_error, warn=warn),
            # Same shape as dbt's context: dicts of whitelisted members only.
            "modules": {
                "re": {n: getattr(re, n) for n in re.__all__},
                "datetime": {n: getattr(dt, n) for n in ["date", "datetime", "time", "timedelta", "tzinfo"]},
                "pytz": {"utc": dt.timezone.utc, "UTC": dt.timezone.utc},
            },
            "target": SimpleNamespace(type=target_type, name="prod", schema="dbo", database="tdi_dw"),
            "flags": SimpleNamespace(WHICH=which, FULL_REFRESH=False),
            "invocation_args_dict": {"which": which, "select": ["tag:silver", "tag:gold"]},
            "invocation_id": str(uuid.uuid4()),
            "run_started_at": dt.datetime(2026, 11, 15, 6, 30, 0, 123456, tzinfo=dt.timezone.utc),
            "dbt_version": "1.12.6",
            "project_name": project,
            "graph": graph or {"nodes": {}, "sources": {}},
        }
        if results is not None:
            self.ctx["results"] = results
        for name, (template, _src) in macros.items():
            self.ctx[name] = MacroGen(self, name, self.env.from_string(template))
        self.ctx["dbt_sentinel"] = SimpleNamespace(**{n: self.ctx[n] for n in macros})

    def call(self, name, *args, **kwargs):
        return self.ctx[name](*args, **kwargs)


def load_macros():
    macros = {}
    for path in sorted(MACRO_DIR.glob("*.sql")):
        text = path.read_text(encoding="utf-8")
        for m in MACRO_RE.finditer(text):
            name = m.group(1)
            R.ok(name not in macros, f"macro name unique: {name}")
            macros[name] = (m.group(0), path.name)
    return macros


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #
def make_result(uid, rtype, status, seconds=1.5, materialized="table", message=None, failures=None):
    start = dt.datetime(2026, 11, 15, 6, 31, 0)
    return SimpleNamespace(
        node=SimpleNamespace(
            unique_id=uid, resource_type=rtype, name=uid.split(".")[-1], package_name="tdi",
            schema="silver", alias=uid.split(".")[-1], config=SimpleNamespace(materialized=materialized),
        ),
        status=status,
        timing=[
            SimpleNamespace(name="compile", started_at=start, completed_at=start),
            SimpleNamespace(name="execute", started_at=start,
                            completed_at=start + dt.timedelta(seconds=seconds)),
        ],
        execution_time=seconds,
        adapter_response={"_message": "OK", "rows_affected": 10},
        message=message,
        failures=failures,
        thread_id="Thread-1",
    )


def make_graph():
    def node(uid, rtype, **kw):
        base = {
            "unique_id": uid, "resource_type": rtype, "name": uid.split(".")[-1],
            "package_name": kw.pop("package", "tdi"), "database": "tdi_dw", "schema": "silver",
            "alias": uid.split(".")[-1], "description": kw.pop("description", ""),
            "tags": kw.pop("tags", []), "original_file_path": f"models/{uid.split('.')[-1]}.sql",
            "config": {"materialized": kw.pop("materialized", "table"), "meta": kw.pop("meta", {})},
            "meta": {}, "depends_on": {"nodes": kw.pop("parents", [])},
        }
        base.update(kw)
        return base

    nodes = {
        "model.tdi.dim_org": node("model.tdi.dim_org", "model", description="Organisations",
                                  meta={"owner": "data-ops"}, parents=["source.tdi.abr.organisations"]),
        "model.tdi.fct_trade": node("model.tdi.fct_trade", "model", parents=["model.tdi.dim_org"],
                                    description="It's the trade fact"),
        "test.tdi.not_null_dim_org_id": node(
            "test.tdi.not_null_dim_org_id", "test", materialized="test", parents=["model.tdi.dim_org"],
            test_metadata={"name": "not_null", "kwargs": {}}, attached_node="model.tdi.dim_org"),
        "test.tdi.assert_trade_positive": node(
            "test.tdi.assert_trade_positive", "test", materialized="test", parents=["model.tdi.fct_trade"]),
        "model.other_pkg.pkg_model": node("model.other_pkg.pkg_model", "model", package="other_pkg"),
    }
    sources = {
        "source.tdi.abr.organisations": {
            "unique_id": "source.tdi.abr.organisations", "resource_type": "source", "name": "organisations",
            "source_name": "abr", "package_name": "tdi", "database": "tdi_dw", "schema": "bronze",
            "identifier": "abr_organisations", "description": "", "tags": [], "meta": {"owner": ["a", "b"]},
            "config": {}, "original_file_path": "models/sources.yml", "loaded_at_field": "_loaded_at",
            "freshness": {"warn_after": {"count": 12, "period": "hour"}, "error_after": {"count": None, "period": None}},
        }
    }
    return {"nodes": nodes, "sources": sources}


def all_columns(rt):
    return {t: [c[0].lower() for c in cols] for t, cols in rt.call("sentinel_table_columns").items()}


def expect_error(label, fn, contains=None):
    try:
        fn()
    except CompilerError as e:
        R.ok(contains is None or contains in str(e), f"{label} (error text contains {contains!r})")
        return
    R.ok(False, f"{label} should raise")


# --------------------------------------------------------------------------- #
# Checks
# --------------------------------------------------------------------------- #
def check_layout():
    print("\n[1] File layout")
    for f in EXPECTED_FILES:
        R.ok((ROOT / f).exists(), f"exists: {f}")
    proj = (ROOT / "dbt_project.yml").read_text(encoding="utf-8")
    R.ok("name: dbt_sentinel" in proj, "dbt_project.yml name is dbt_sentinel")
    R.ok('version: "0.2.3"' in proj, "dbt_project.yml version 0.2.3")
    R.ok('macro-paths: ["macros"]' in proj, "macro-paths configured")


def check_templates(macros):
    print("\n[2] Macro templates")
    env = jinja2.sandbox.SandboxedEnvironment(extensions=["jinja2.ext.do"])
    for name, (src, fname) in macros.items():
        try:
            env.parse(src)
            R.ok(True, name)
        except jinja2.TemplateSyntaxError as e:
            R.ok(False, f"{fname}:{name} Jinja syntax error line {e.lineno}: {e.message}")
    print(f"  {len(macros)} macros parsed")
    for path in MACRO_DIR.glob("*.sql"):
        text = path.read_text(encoding="utf-8")
        R.ok(text.count("{% macro") + text.count("{%- macro") == text.count("endmacro"),
             f"{path.name}: macro/endmacro balanced")


def check_readme(macros, rt):
    print("\n[3] README cross-check")
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    documented_views = set(re.findall(r"^\| `(v_\w+)` \|", readme, re.M))
    defined_views = set(rt.call("sentinel_view_names"))
    R.ok(documented_views == defined_views,
         f"README views == defined views (missing={sorted(documented_views - defined_views)}, "
         f"undocumented={sorted(defined_views - documented_views)})")
    ops = set(re.findall(r"run-operation (\w+)", readme)) | set(re.findall(r"dbt_sentinel\.(\w+)\(", readme))
    for op in sorted(ops):
        R.ok(op in macros, f"README operation exists: {op}")


# ---- dialect rules --------------------------------------------------------- #
def _spans(sql, opener_re):
    spans = []
    for m in opener_re.finditer(sql):
        depth, i = 0, m.end() - 1
        for j in range(i, len(sql)):
            if sql[j] == "(":
                depth += 1
            elif sql[j] == ")":
                depth -= 1
                if depth == 0:
                    spans.append((i, j))
                    break
    return spans


# learn.microsoft.com/sql/t-sql/language-elements/reserved-keywords-transact-sql
TSQL_RESERVED = set("""ADD ALL ALTER AND ANY AS ASC AUTHORIZATION BACKUP BEGIN BETWEEN BREAK BROWSE BULK BY CASCADE CASE CHECK CHECKPOINT CLOSE CLUSTERED COALESCE COLLATE COLUMN COMMIT COMPUTE CONSTRAINT CONTAINS CONTAINSTABLE CONTINUE CONVERT CREATE CROSS CURRENT CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR DATABASE DBCC DEALLOCATE DECLARE DEFAULT DELETE DENY DESC DISK DISTINCT DISTRIBUTED DOUBLE DROP DUMP ELSE END ERRLVL ESCAPE EXCEPT EXEC EXECUTE EXISTS EXIT EXTERNAL FETCH FILE FILLFACTOR FOR FOREIGN FREETEXT FREETEXTTABLE FROM FULL FUNCTION GOTO GRANT GROUP HAVING HOLDLOCK IDENTITY IDENTITY_INSERT IDENTITYCOL IF IN INDEX INNER INSERT INTERSECT INTO IS JOIN KEY KILL LABEL LEFT LIKE LINENO LOAD MERGE NATIONAL NOCHECK NONCLUSTERED NOT NULL NULLIF OF OFF OFFSETS ON OPEN OPENDATASOURCE OPENQUERY OPENROWSET OPENXML OPTION OR ORDER OUTER OVER PERCENT PIVOT PLAN PRECISION PRIMARY PRINT PROC PROCEDURE PUBLIC RAISERROR READ READTEXT RECONFIGURE REFERENCES REPLICATION RESTORE RESTRICT RETURN REVERT REVOKE RIGHT ROLLBACK ROWCOUNT ROWGUIDCOL RULE SAVE SCHEMA SECURITYAUDIT SELECT SEMANTICKEYPHRASETABLE SEMANTICSIMILARITYDETAILSTABLE SEMANTICSIMILARITYTABLE SESSION_USER SET SETUSER SHUTDOWN SOME STATISTICS SYSTEM_USER TABLE TABLESAMPLE TEXTSIZE THEN TO TOP TRAN TRANSACTION TRIGGER TRUNCATE TRY_CONVERT TSEQUAL UNION UNIQUE UNPIVOT UPDATE UPDATETEXT USE USER VALUES VARYING VIEW WAITFOR WHEN WHERE WHILE WITH WITHIN WRITETEXT""".split())


def dialect_problems(sql):
    problems = []
    up = re.sub(r"N?'(?:[^']|'')*'", "''", sql).upper()  # blank out literals
    if re.search(r"\bVALUES\s*\(", up):
        problems.append("INSERT ... VALUES (use INSERT ... SELECT)")
    if "CREATE OR ALTER" in up:
        problems.append("CREATE OR ALTER")
    if re.search(r"DROP\s+\w+\s+IF\s+EXISTS", up):
        problems.append("DROP ... IF EXISTS")
    if "NVARCHAR(MAX)" in up or "VARCHAR(MAX)" in up:
        problems.append("(n)varchar(max)")
    if re.search(r"\[\w+\]\.\[\w+\]\.\[\w+\]", sql):
        problems.append("three-part name")
    if re.search(r"\bSELECT\s+@\w+\s*=", up):
        problems.append("SELECT @var = (unsupported in Dedicated SQL Pool)")
    if re.search(r"\bMERGE\b", up):
        problems.append("MERGE")
    # Reserved words (SQL Server + Synapse-only LABEL) used as column names
    # must be delimited: r.label fails to parse, r.[label] works.
    for m in re.finditer(r"\w\.([A-Z_]+)\b", up):
        if m.group(1) in TSQL_RESERVED:
            problems.append("unquoted reserved word ." + m.group(1).lower() + " (use .[" + m.group(1).lower() + "])")
    for m in re.finditer(r"\bAS[ \t]+([A-Z_]+)[ \t]*(?=,|\)|$)", up, re.M):
        if m.group(1) in TSQL_RESERVED:
            problems.append("reserved word used as alias: AS " + m.group(1).lower())
    if up.lstrip().startswith("CREATE VIEW"):
        if re.search(r"\bAS\s*\n\s*WITH\b", up):
            problems.append("CTE in view")
        over = _spans(up, re.compile(r"\bOVER\s*\("))
        for m in re.finditer(r"\bORDER BY\b", up):
            if not any(a < m.start() < b for a, b in over):
                problems.append("ORDER BY outside OVER() in a view")
                break
    if up.count("(") != up.count(")"):
        problems.append("unbalanced parentheses")
    return problems


def tsql_parse_problem(sql):
    if sqlglot is None:
        return None
    body = sql.strip()
    # sqlglot does not model T-SQL control flow; parse the inner statements.
    if body.startswith("SET NOCOUNT ON"):
        m = re.search(r"BEGIN TRY\n(.*?);\nSELECT CAST\(0 AS int\)", body, re.S)
        body = m.group(1) if m else body
    if body.startswith("IF OBJECT_ID"):
        return None
    if body.startswith("DECLARE"):
        body = body.split("\n", 1)[1]
    try:
        parsed = sqlglot.parse(body, read="tsql")
        if not parsed or any(p is None for p in parsed):
            return "empty parse"
    except ParseError as e:
        return str(e).splitlines()[0][:200]
    return None


# ---- scenarios ------------------------------------------------------------- #
def scenarios(macros, verbose, dump_dir):
    collected: list[tuple[str, str]] = []

    def keep(label, rt):
        for i, s in enumerate(rt.db.statements):
            collected.append((f"{label}#{i}", s))

    print("\n[4] Mock-context rendering")

    # -- fresh install
    rt = Runtime(macros, db=MockDb(schema_exists=False, columns={}))
    rt.call("sentinel_install")
    stmts = rt.db.statements
    table_names = list(rt.call("sentinel_table_columns").keys())
    views = rt.call("sentinel_view_names")
    R.ok(any(s.strip() == "CREATE SCHEMA [sentinel]" for s in stmts), "install: creates schema alone in its batch")
    R.ok(sum(s.startswith("CREATE TABLE") for s in stmts) == len(table_names), "install: creates every table")
    R.ok(all("DISTRIBUTION = ROUND_ROBIN, HEAP" in s for s in stmts if s.startswith("CREATE TABLE")),
         "install: tables are ROUND_ROBIN HEAP")
    R.ok(sum(s.startswith("CREATE VIEW") for s in stmts) == len(views) == 28, "install: creates 28 views")
    R.ok(sum(s.startswith("IF OBJECT_ID") and "DROP VIEW" in s for s in stmts) == len(views),
         "install: drops each view before create")
    first_create = next(i for i, s in enumerate(stmts) if s.startswith("CREATE VIEW"))
    last_drop = max(i for i, s in enumerate(stmts) if "DROP VIEW" in s)
    R.ok(last_drop < first_create, "install: all drops precede creates")
    order = [re.search(r"CREATE VIEW \[sentinel\]\.\[(\w+)\]", s).group(1) for s in stmts if s.startswith("CREATE VIEW")]
    for i, v in enumerate(order):
        later = order[i + 1:]
        body = next(s for s in stmts if s.startswith(f"CREATE VIEW [sentinel].[{v}]"))
        refs = set(re.findall(r"\[sentinel\]\.\[(v_\w+)\]", body)) - {v}
        R.ok(not (refs & set(later)), f"view {v} only references views created before it")
    R.ok(any(s.startswith("INSERT INTO [sentinel].[install_log]") for s in stmts), "install: writes install_log")
    R.ok(not any("DROP TABLE" in s or "TRUNCATE" in s for s in stmts), "install: never drops/truncates tables")
    keep("install_fresh", rt)

    # -- redeploy with one missing column
    cols = all_columns(rt)
    cols["node_results"] = [c for c in cols["node_results"] if c != "thread_id"]
    rt = Runtime(macros, db=MockDb(schema_exists=True, columns=cols),
                 vars={"sentinel_view_reader_role": "powerbi_readers"})
    rt.call("sentinel_install")
    stmts = rt.db.statements
    R.ok(not any(s.startswith("CREATE SCHEMA") or s.startswith("CREATE TABLE") for s in stmts),
         "redeploy: no schema/table re-creation (idempotent)")
    R.ok(any(s == "ALTER TABLE [sentinel].[node_results] ADD [thread_id] nvarchar(64) NULL" for s in stmts),
         "redeploy: adds missing column as nullable")
    R.ok(sum(s.startswith("GRANT SELECT") for s in stmts) == 28, "redeploy: reapplies view grants when configured")
    keep("install_redeploy", rt)

    # -- reader role: Entra ID style names are quoted; bad names fail before any DROP
    rt = Runtime(macros, vars={"sentinel_view_reader_role": "PBI-Readers]x"})
    rt.call("sentinel_deploy_views")
    R.ok(any(s.endswith("TO [PBI-Readers]]x]") for s in rt.db.statements), "reader role bracket-quoted and escaped")
    rt = Runtime(macros, vars={"sentinel_view_reader_role": "bad\nrole"})
    expect_error("reader role validated", lambda: rt.call("sentinel_deploy_views"), "printable")
    R.ok(not any("DROP VIEW" in s for s in rt.db.statements), "invalid reader role fails before views are dropped")
    rt = Runtime(macros, vars={"sentinel_view_reader_role": "powerbi_reader"})
    expect_error("unknown reader role rejected", lambda: rt.call("sentinel_deploy_views"), "does not exist")
    R.ok(not any("DROP VIEW" in s for s in rt.db.statements), "unknown reader role fails before views are dropped")

    # -- check
    objs = table_names + views
    rt = Runtime(macros, db=MockDb(objects=objs, try_error_for=["[v_warehouse_waits]"]))
    rt.call("sentinel_check")
    R.ok(any("v_warehouse_waits" in l and l.startswith("[WARNING]") for l in rt.logs),
         "check: DMV permission failure is a logged warning")
    R.ok(not any("telemetry write" in l for l in rt.logs), "check: probe failures are not labelled as telemetry writes")
    R.ok(any(s.startswith("SET NOCOUNT") and "EXEC sp_executesql N'" in s for s in rt.db.statements),
         "check: probes run through sp_executesql so binding errors are catchable")
    rt = Runtime(macros, db=MockDb(objects=[o for o in objs if o != "run_events"]))
    expect_error("check: missing table fails", lambda: rt.call("sentinel_check"), "run_events")
    rt = Runtime(macros, db=MockDb(objects=objs, try_error_for=["[v_run_history]"]))
    expect_error("check: non-DMV view failure fails", lambda: rt.call("sentinel_check"), "v_run_history")

    # -- start hook
    env = {"BUILD_BUILDID": "4321", "BUILD_SOURCEVERSION": "abc123", "BUILD_DEFINITIONNAME": "TDI-nightly",
           "BUILD_SOURCEBRANCH": "refs/heads/main", "BUILD_REASON": "Schedule"}
    rt = Runtime(macros, env=env, vars={"sentinel_hook_on_error": "fail"})
    out = rt.call("sentinel_start_run")
    R.ok(out == "", "start hook returns empty SQL")
    R.ok(len(rt.db.statements) == 1 and "[run_events]" in rt.db.statements[0], "start hook writes one run event")
    s0 = rt.db.statements[0]
    for tok in ["N'start'", "N'running'", "N'4321'", "N'abc123'", "N'2026-11-15 06:30:00.123456'",
                "N'select=tag:silver tag:gold'", "CAST(SYSUTCDATETIME() AS datetime2(6))"]:
        R.ok(tok in s0, f"start event contains {tok}")
    keep("start_run", rt)

    # -- start hook in warn mode wraps in TRY/CATCH
    rt = Runtime(macros)
    rt.call("sentinel_start_run")
    R.ok(len(rt.db.catalog) == 1 and "N'run_events'" in rt.db.catalog[0] and "N'build_reason'" in rt.db.catalog[0],
         "hook checks the table and all its columns first")
    R.ok("BEGIN TRY" in rt.db.statements[0] and "BEGIN CATCH" in rt.db.statements[0],
         "hook default mode wraps writes in TRY/CATCH")
    rt = Runtime(macros, db=MockDb(try_error_for=["[run_events]"]))
    rt.call("sentinel_start_run")
    R.ok(any("telemetry write failed" in l for l in rt.logs), "hook write error is logged")
    R.ok(rt.warnings == [], "hook write error never uses exceptions.warn (safe under --warn-error)")

    # -- Sentinel not installed in this target: warn mode skips, never raises
    rt = Runtime(macros, db=MockDb(missing_tables=["run_events", "node_results"]),
                 results=[make_result("model.tdi.a", "model", "success")])
    rt.call("sentinel_start_run")
    rt.call("sentinel_capture_run")
    R.ok(not any(s.startswith("SET NOCOUNT") or s.startswith("INSERT") for s in rt.db.statements),
         "hooks write nothing when Sentinel tables are missing")
    R.ok(any("not found" in l and "sentinel_install" in l for l in rt.logs), "missing table is logged with a fix")
    R.ok(rt.warnings == [], "missing table does not use exceptions.warn")

    # -- Sentinel installed from an older version (missing new columns)
    rt = Runtime(macros, db=MockDb(missing_columns={"run_events": ["build_reason"]}))
    rt.call("sentinel_start_run")
    R.ok(not any(s.startswith("SET NOCOUNT") or s.startswith("INSERT") for s in rt.db.statements),
         "hooks write nothing when Sentinel tables lack new columns")
    R.ok(any("missing 1 column" in l for l in rt.logs), "missing columns are logged with a fix")
    rt = Runtime(macros, db=MockDb(missing_columns={"freshness_events": ["target_name"]}))
    expect_error("operation fails clearly when columns are missing",
                 lambda: rt.call("sentinel_record_freshness", source_id="x", status="pass"), "sentinel_install")
    R.ok(not any(s.startswith("INSERT") for s in rt.db.statements), "no insert attempted against an outdated table")

    # -- failed node batch: completion event is not written
    rt = Runtime(macros, db=MockDb(try_error_for=["[node_results]"]),
                 results=[make_result("model.tdi.a", "model", "success")])
    rt.call("sentinel_capture_run")
    R.ok(not any("[run_events]" in s for s in rt.db.statements), "failed node batch skips the completion event")
    R.ok(any("completion event skipped" in l for l in rt.logs), "skipped completion is logged")

    # -- boolean vars given as strings (env_var / quoted --vars)
    for raw in ["false", "False", "0", "no"]:
        rt = Runtime(macros, vars={"sentinel_enabled": raw})
        rt.call("sentinel_start_run")
        R.ok(rt.db.statements == [], f"sentinel_enabled={raw!r} disables hooks")
    rt = Runtime(macros, vars={"sentinel_capture_query_text": "false", "sentinel_expose_command_text": "false"})
    R.ok("LEFT(r.command" not in rt.call("sentinel_view_sql", "v_user_queries"), "capture_query_text='false' stores no SQL")
    R.ok("LEFT(r.command" not in rt.call("sentinel_view_sql", "v_warehouse_requests"), "expose_command_text='false' shows no SQL")
    rt = Runtime(macros, vars={"sentinel_capture_query_text": "true"})
    R.ok("LEFT(r.command" in rt.call("sentinel_view_sql", "v_user_queries"), "capture_query_text='true' enables capture")
    rt_bad = Runtime(macros, vars={"sentinel_capture_query_text": "maybe"})
    expect_error("boolean var validated", lambda: rt_bad.call("sentinel_view_sql", "v_user_queries"), "must be a boolean")

    # -- hooks skipped for compile, docs, disabled, other adapters, parse time
    for label, kw in [("compile", {"which": "compile"}), ("docs", {"which": "generate"}),
                      ("parse-time", {"execute": False}), ("postgres", {"target_type": "postgres"})]:
        rt = Runtime(macros, **kw)
        rt.call("sentinel_start_run")
        rt.call("sentinel_capture_run")
        R.ok(rt.db.statements == [], f"hooks are no-ops for {label}")
    rt = Runtime(macros, vars={"sentinel_enabled": False})
    rt.call("sentinel_start_run")
    R.ok(rt.db.statements == [], "hooks are no-ops when sentinel_enabled is false")

    # -- end hook
    results = [make_result(f"model.tdi.m{i}", "model", "success", seconds=i + 0.25) for i in range(38)]
    results += [
        make_result("test.tdi.t_fail", "test", "fail", materialized="test", failures=3,
                    message="Got 3 results, configured to fail if != 0 -- O'Brien\nline2"),
        make_result("test.tdi.t_warn", "test", "warn", materialized="test", failures=1),
        make_result("model.tdi.m_err", "model", "error", message="Database Error: invalid column"),
        make_result("model.tdi.m_skip", "model", "skipped"),
    ]
    rt = Runtime(macros, results=results, vars={"sentinel_hook_on_error": "fail"})
    out = rt.call("sentinel_capture_run")
    stmts = rt.db.statements
    nr = [s for s in stmts if s.startswith("INSERT INTO [sentinel].[node_results]")]
    R.ok(out == "", "end hook returns empty SQL")
    R.ok(len(nr) == math.ceil(len(results) / 35), f"end hook batches node rows ({len(nr)} inserts for {len(results)} rows)")
    R.ok(sum(s.count("\nUNION ALL\n") + 1 for s in nr) == len(results), "end hook writes one row per result")
    R.ok(stmts[-1].startswith("INSERT INTO [sentinel].[run_events]"), "end event written after node rows")
    end = stmts[-1]
    for tok in ["N'end'", "CAST(N'error' AS nvarchar(32))", "CAST(42 AS int)", "CAST(38 AS int)",
                "CAST(1 AS int)", "DATEDIFF(millisecond"]:
        R.ok(tok in end, f"end event contains {tok}")
    joined = "\n".join(nr)
    R.ok("O''Brien line2" in joined, "messages: quotes escaped, newlines flattened")
    R.ok("CAST(N'2026-11-15 06:31:00.000000' AS datetime2(6))" in joined, "node timing rendered as UTC datetime2")
    R.ok("CAST(NULL AS nvarchar(256))" in joined or "CAST(NULL AS" in joined, "nulls are typed")
    keep("capture_run", rt)

    rt = Runtime(macros, vars={"sentinel_hook_on_error": "fail"}, results=[make_result("model.tdi.a", "model", "success")])
    rt.call("sentinel_capture_run", run_results=[make_result("seed.tdi.s", "seed", "success", materialized="seed")])
    R.ok("seed.tdi.s" in rt.db.statements[0] and "model.tdi.a" not in rt.db.statements[0],
         "end hook prefers explicitly passed results")
    rt = Runtime(macros, vars={"sentinel_hook_on_error": "fail", "sentinel_capture_messages": "false"},
                 results=[make_result("model.tdi.a", "model", "error", message="secret-ish text")])
    rt.call("sentinel_capture_run")
    R.ok("secret-ish" not in rt.db.statements[0], "sentinel_capture_messages=false drops messages")
    rt = Runtime(macros, vars={"sentinel_hook_on_error": "fail"}, results=[])
    rt.call("sentinel_capture_run")
    R.ok(len(rt.db.statements) == 1 and "N'success'" in rt.db.statements[0], "empty run still writes completion")

    # -- manifest
    rt = Runtime(macros, graph=make_graph())
    rt.call("sentinel_sync_manifest")
    stmts = rt.db.statements
    R.ok([s.split("]")[1] for s in stmts] == [".[manifest_nodes", ".[manifest_edges", ".[manifest_snapshots"],
         "manifest: nodes, edges, then snapshot header")
    nodes_sql = stmts[0]
    R.ok("pkg_model" not in nodes_sql, "manifest: package nodes excluded by default")
    R.ok("N'data-ops'" in nodes_sql and "N'a, b'" in nodes_sql, "manifest: owners from meta (string and list)")
    R.ok("N'not_null'" in nodes_sql and "N'singular'" in nodes_sql, "manifest: generic and singular test types")
    R.ok("N'It''s the trade fact'" in nodes_sql, "manifest: description escaped")
    R.ok(stmts[1].count("UNION ALL") + 1 == 4, "manifest: one edge per dependency")
    R.ok("CAST(5 AS int)" in stmts[2] and "CAST(4 AS int)" in stmts[2], "manifest: snapshot counts")
    keep("sync_manifest", rt)
    rt = Runtime(macros, graph=make_graph(), vars={"sentinel_manifest_include_packages": True})
    rt.call("sentinel_sync_manifest")
    R.ok("pkg_model" in rt.db.statements[0], "manifest: package nodes included when configured")
    rt = Runtime(macros, graph=make_graph(), vars={"sentinel_manifest_include_packages": "false"})
    rt.call("sentinel_sync_manifest")
    R.ok("pkg_model" not in rt.db.statements[0], "manifest: include_packages='false' is false")

    # -- unit tests (dbt >= 1.8) are synced and linked to their model
    g = make_graph()
    g["unit_tests"] = {"unit_test.tdi.fct_trade.test_sign": {
        "unique_id": "unit_test.tdi.fct_trade.test_sign", "resource_type": "unit_test", "name": "test_sign",
        "package_name": "tdi", "database": "tdi_dw", "schema": "silver", "description": "", "tags": [],
        "config": {}, "original_file_path": "models/fct_trade.yml", "model": "fct_trade",
        "depends_on": {"nodes": ["model.tdi.fct_trade"]}}}
    rt = Runtime(macros, graph=g)
    rt.call("sentinel_sync_manifest")
    R.ok("N'unit_test.tdi.fct_trade.test_sign'" in rt.db.statements[0] and "N'unit'" in rt.db.statements[0],
         "manifest: unit tests stored with test_type 'unit'")
    R.ok("N'unit_test.tdi.fct_trade.test_sign'" in rt.db.statements[1], "manifest: unit test edge to its model")
    keep("sync_manifest_unit_tests", rt)
    rt = Runtime(macros)
    R.ok("h.resource_type IN ('test', 'unit_test')" in rt.call("sentinel_view_sql", "v_test_failures"),
         "v_test_failures includes unit tests")
    R.ok("t.resource_type IN ('test', 'unit_test')" in rt.call("sentinel_view_sql", "v_model_health"),
         "v_model_health counts failing unit tests")

    # -- partial manifest load: header is not written
    rt = Runtime(macros, graph=make_graph(), vars={"sentinel_operation_on_error": "warn"},
                 db=MockDb(try_error_for=["[manifest_edges]"]))
    rt.call("sentinel_sync_manifest")
    R.ok(not any("[manifest_snapshots]" in s for s in rt.db.statements), "manifest: failed batch skips snapshot header")

    # -- samplers
    rt = Runtime(macros, vars={"sentinel_storage_exclude_schemas": ["sentinel", "staging"]})
    rt.call("sentinel_sample_warehouse")
    rt.call("sentinel_sample_storage")
    R.ok("sys.dm_pdw_exec_requests" in rt.db.statements[0], "warehouse sample reads DMVs")
    R.ok("NOT IN (N'sentinel', N'staging')" in rt.db.statements[1], "storage sample applies schema exclusions")
    keep("samplers", rt)

    # -- table health sampler + thresholds
    rt = Runtime(macros)
    rt.call("sentinel_sample_table_health")
    ins = rt.db.statements[-1]
    R.ok(ins.startswith("INSERT INTO [sentinel].[table_health_samples]"), "table health sampler inserts samples")
    for tok in ["sys.pdw_column_distribution_properties", "sys.dm_pdw_nodes_db_column_store_row_group_physical_stats",
                "STATS_DATE(", "sys.partitions", "tdp.distribution_policy_desc <> 'REPLICATE'"]:
        R.ok(tok in ins, f"table health reads {tok}")
    R.ok("k.skew_pct >= 10" in ins and "k.actual_row_count >= 1000000" in ins, "default skew thresholds rendered")
    R.ok("x.stats_row_diff_pct >= 20" in ins, "default stats drift threshold rendered")
    keep("sample_table_health", rt)
    rt = Runtime(macros, vars={"sentinel_skew_threshold_pct": 25, "sentinel_stats_max_diff_pct": 5,
                               "sentinel_cci_min_avg_rows": 250000})
    sql = rt.call("sentinel_view_sql", "v_table_health")
    R.ok("k.skew_pct >= 25" in sql and "x.stats_row_diff_pct >= 5" in sql and "< 250000" in sql,
         "table health thresholds configurable")
    rt_bad = Runtime(macros, vars={"sentinel_skew_threshold_pct": "10 OR 1=1"})
    expect_error("skew threshold validated", lambda: rt_bad.call("sentinel_view_sql", "v_table_skew"), "non-negative number")

    # -- query sampler (login-level history)
    rt = Runtime(macros)
    rt.call("sentinel_sample_requests")
    ins = rt.db.statements[-1]
    R.ok(ins.startswith("INSERT INTO [sentinel].[query_samples]"), "query sampler inserts into query_samples")
    R.ok("s.login_name" in ins and "sys.dm_pdw_exec_sessions" in ins, "query sampler records login names")
    R.ok("CAST(NULL AS nvarchar(4000)) AS command_text" in ins and "LEFT(r.command" not in ins,
         "query text not captured by default")
    R.ok("WHERE q.end_time_utc >" not in ins, "first sample takes everything retained")
    R.ok("r.status IN ('Completed', 'Failed', 'Cancelled')" in ins, "only finished requests are sampled")
    keep("sample_requests", rt)
    rt = Runtime(macros, db=MockDb(watermark="2026-11-15 06:00:01.123"),
                 vars={"sentinel_capture_query_text": True, "sentinel_query_text_max_length": 300,
                       "sentinel_query_exclude_logins": ["svc_powerbi", "o'brien"]})
    rt.call("sentinel_sample_requests")
    ins = rt.db.statements[-1]
    R.ok("CAST(q.end_time_utc AS datetime2(3)) > CAST(N'2026-11-15 06:00:01.123' AS datetime2(3))" in ins,
         "query sampler is incremental on end time at stored precision")
    R.ok("LEFT(r.command, 300)" in ins, "query text captured (truncated) when enabled")
    R.ok("NOT IN (N'System', N'svc_powerbi', N'o''brien')" in ins, "login exclusions applied and escaped")
    keep("sample_requests_incremental", rt)
    rt = Runtime(macros, db=MockDb(watermark="2026-11-15; DROP TABLE x"))
    expect_error("watermark validated", lambda: rt.call("sentinel_sample_requests"), "ISO-8601")

    # -- stage events
    rt = Runtime(macros, env={"BUILD_BUILDID": "999"})
    rt.call("sentinel_record_stage", pipeline_name="TDI", pipeline_run_id="1234", stage="Bronze",
            source_name="ABR", status="SucceededWithIssues", rows_loaded=100000,
            started_at="2026-11-15T01:00:00Z", completed_at="2026-11-15T01:05:30.5Z")
    s = rt.db.statements[0]
    for tok in ["N'warning'", "N'bronze'", "CAST(100000 AS bigint)", "N'2026-11-15 01:05:30.5'", "N'1234'"]:
        R.ok(tok in s, f"stage event contains {tok}")
    keep("record_stage", rt)
    rt = Runtime(macros, env={"BUILD_BUILDID": "999"})
    rt.call("sentinel_record_stage", pipeline_name="TDI", stage="landing", status="failed")
    R.ok("N'999'" in rt.db.statements[0] and "SYSUTCDATETIME()" in rt.db.statements[0],
         "stage event defaults run id from Azure DevOps and time to now")

    # -- freshness
    rt = Runtime(macros)
    rt.call("sentinel_record_freshness", source_id="source.tdi.abr.organisations", status="pass",
            age_minutes=45, threshold_minutes=180)
    rt.call("sentinel_record_freshness_batch", checks=[
        {"source_id": "source.tdi.a.b", "status": "warn", "age_minutes": 200.5, "threshold_minutes": 180,
         "max_loaded_at": "2026-11-15T00:00:00", "checked_at": "2026-11-15T03:20:30Z"},
        {"source_id": "source.tdi.a.c", "status": "runtime_error", "message": "Login failed"},
    ])
    R.ok("N'pass'" in rt.db.statements[0] and "CAST(45 AS float)" in rt.db.statements[0], "freshness row")
    R.ok(rt.db.statements[1].count("UNION ALL") == 1 and "N'runtime error'" in rt.db.statements[1],
         "freshness batch: one insert, statuses normalised")
    R.ok("CAST(N'prod' AS nvarchar(128))" in rt.db.statements[0] and "CAST(N'tdi' AS nvarchar(256))" in rt.db.statements[0],
         "freshness rows record project and target")
    sf = rt.call("sentinel_view_sql", "v_source_freshness")
    R.ok("PARTITION BY fe.source_id, fe.target_name" in sf and "src.target_name = f.target_name" in sf,
         "v_source_freshness is per target")
    keep("freshness", rt)

    # -- purge
    rt = Runtime(macros)
    rt.call("sentinel_purge_history", keep_days=180)
    deletes = [s for s in rt.db.statements if s.startswith("DELETE FROM")]
    R.ok(len(deletes) == 8 and all("DATEADD(day, -180, SYSUTCDATETIME())" in d for d in deletes),
         "purge deletes eight time-series tables")
    R.ok(not any("manifest" in d or "install_log" in d for d in deletes), "purge keeps manifest and install_log")
    rt = Runtime(macros)
    rt.call("sentinel_purge_history", keep_days=180, prune_manifests=True)
    mdel = [s for s in rt.db.statements if s.startswith("DELETE FROM [sentinel].[manifest")]
    R.ok([d.split("]")[1] for d in mdel] == [".[manifest_edges", ".[manifest_nodes", ".[manifest_snapshots"],
         "prune_manifests deletes edges, nodes, then headers")
    R.ok(all("x.rn > 1" in d and "DATEADD(day, -180" in d for d in mdel), "prune_manifests keeps the latest snapshot")
    keep("purge_manifests", rt)
    rt = Runtime(macros)
    rt.call("sentinel_purge_history", keep_days=30, dry_run=True)
    R.ok(not any(s.startswith("DELETE") for s in rt.db.statements), "purge dry run deletes nothing")
    keep("purge", rt)

    # -- validation / injection resistance
    print("\n[5] Input validation")
    rt = Runtime(macros)
    expect_error("unknown stage status", lambda: rt.call("sentinel_record_stage", pipeline_name="p", stage="s", status="meh"), "unknown stage status")
    expect_error("non-UTC timestamp", lambda: rt.call("sentinel_record_stage", pipeline_name="p", stage="s", status="success",
                                                      started_at="2026-11-15T10:00:00+10:00"), "ISO-8601")
    expect_error("numeric injection", lambda: rt.call("sentinel_record_stage", pipeline_name="p", stage="s", status="success",
                                                      rows_loaded="1); DROP TABLE x; --"), "not an integer")
    expect_error("mapping argument", lambda: rt.call("sentinel_record_stage", pipeline_name={"__sentinel_sql__": "1"}, stage="s", status="success"), "scalar")
    expect_error("freshness status", lambda: rt.call("sentinel_record_freshness", source_id="x", status="green"), "unknown freshness status")
    expect_error("freshness batch type", lambda: rt.call("sentinel_record_freshness_batch", checks="nope"), "list")
    expect_error("purge minimum", lambda: rt.call("sentinel_purge_history", keep_days=3), ">= 7")
    expect_error("purge non-integer", lambda: rt.call("sentinel_purge_history", keep_days="7; DROP"), ">= 7")
    rt_bad = Runtime(macros, vars={"sentinel_schema": "sentinel]; DROP TABLE x;--"})
    expect_error("schema identifier", lambda: rt_bad.call("sentinel_install"), "simple identifier")
    rt_bad = Runtime(macros, vars={"sentinel_batch_size": "0"})
    expect_error("batch size minimum", lambda: rt_bad.call("sentinel_record_freshness", source_id="x", status="pass"), ">= 1")
    rt_pg = Runtime(macros, target_type="postgres")
    expect_error("operations reject other adapters", lambda: rt_pg.call("sentinel_install"), "synapse")
    rt = Runtime(macros)
    rt.call("sentinel_record_stage", pipeline_name="p", stage="s", status="failed",
            message="N'; DROP TABLE x; -- \x00 tab\there")
    s = rt.db.statements[0]
    R.ok("N'N''; DROP TABLE x; --  tab here'" in s, "string literal injection is escaped")

    # -- view vars are rendered and validated
    rt = Runtime(macros, vars={"sentinel_model_slowdown_factor": 3.5, "sentinel_missing_completion_minutes": 45,
                               "sentinel_summary_target": "prod"})
    R.ok("* 3.5" in rt.call("sentinel_view_sql", "v_duration_anomalies"), "slowdown factor rendered")
    R.ok(">= 45 THEN 'missing_completion'" in rt.call("sentinel_view_sql", "v_run_history"), "missing completion minutes rendered")
    hs = rt.call("sentinel_view_sql", "v_health_summary")
    R.ok("(r.target_name = N'prod')" in hs, "summary target filter rendered")
    R.ok(hs.index("THEN 'red'") < hs.index("THEN 'unknown'") and hs.index("THEN 'amber'") < hs.index("THEN 'unknown'"),
         "summary: alerts are evaluated before 'unknown'")
    R.ok("runs_total, 0) = 0 THEN 'unknown'" in hs, "summary: 'unknown' only when no run was ever recorded")
    R.ok("f.freshness_state = 'not_checked' AND f.has_freshness_config = 1" in hs,
         "summary: unchecked sources only count when they have a freshness policy")
    R.ok(hs.count("[v_run_history]") == 1, "summary reads v_run_history once")
    al = rt.call("sentinel_view_sql", "v_operational_alerts")
    R.ok(al.count("[v_pipeline_health]") == 1, "alerts read v_pipeline_health once")
    ph = rt.call("sentinel_view_sql", "v_pipeline_health")
    R.ok(ph.count("[v_run_history]") == 1, "pipeline health reads v_run_history once")
    th = rt.call("sentinel_view_sql", "v_table_health_history")
    R.ok("PARTITION BY h.schema_name, h.table_name" in th, "table health is_latest is per table")
    mi = rt.call("sentinel_view_sql", "v_model_inventory")
    R.ok(mi.count("ls0.snapshot_id") >= 4, "inventory edge/test aggregations use only the latest snapshots")
    rt = Runtime(macros, vars={"sentinel_query_exclude_logins": "svc_powerbi, etl_user",
                               "sentinel_storage_exclude_schemas": "sentinel",
                               "sentinel_tracked_commands": "build"})
    R.ok("NOT IN (N'System', N'svc_powerbi', N'etl_user')" in rt.call("sentinel_view_sql", "v_user_queries"),
         "string list var is split on commas, not characters")
    rt.call("sentinel_sample_storage")
    R.ok("NOT IN (N'sentinel')" in rt.db.statements[-1], "storage exclusion accepts a plain string")
    rt = Runtime(macros, vars={"sentinel_tracked_commands": "build"}, which="run")
    rt.call("sentinel_start_run")
    R.ok(rt.db.statements == [], "tracked commands as a string: 'run' is not tracked when only 'build' is")
    rt = Runtime(macros, vars={"sentinel_supported_adapters": "synapse_x"})
    R.ok(rt.call("sentinel_is_supported_adapter") is False, "supported adapters string is not a substring match")
    rt_bad = Runtime(macros, vars={"sentinel_model_slowdown_factor": "2; DROP"})
    expect_error("view float var validated", lambda: rt_bad.call("sentinel_view_sql", "v_duration_anomalies"), "non-negative number")

    # -- dialect + parse over everything rendered
    print("\n[6] Dedicated SQL Pool dialect rules" + ("" if sqlglot else " (sqlglot not installed: T-SQL parse skipped)"))
    parse_failures = 0
    for label, sql in collected:
        for p in dialect_problems(sql):
            R.ok(False, f"{label}: {p}")
        prob = tsql_parse_problem(sql)
        if prob:
            parse_failures += 1
            R.warn(f"{label}: sqlglot could not parse: {prob}")
    R.ok(True, "dialect rules evaluated")
    print(f"  {len(collected)} statements checked; sqlglot parse issues: {parse_failures}")

    if verbose:
        for label, sql in collected:
            print(f"\n-- {label}\n{sql}")
    if dump_dir:
        out = Path(dump_dir)
        out.mkdir(parents=True, exist_ok=True)
        for label, sql in collected:
            (out / (re.sub(r"[^\w#.-]", "_", label) + ".sql")).write_text(sql + "\n", encoding="utf-8")
        print(f"  rendered SQL written to {out}")


def check_freshness_script():
    print("\n[7] freshness_to_sentinel.py")
    import importlib.util
    import json as _json
    spec = importlib.util.spec_from_file_location("f2s", ROOT / "scripts" / "freshness_to_sentinel.py")
    f2s = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(f2s)
    checks = [{"source_id": f"source.tdi.s.t{i}", "status": "runtime error", "message": "x\"y" * 500}
              for i in range(60)]
    chunks = f2s.chunk_checks(checks, 25, 6000)
    R.ok(sum(len(c) for c in chunks) == 60, "chunking keeps every result")
    R.ok(all(len(_json.dumps({"checks": c})) <= 6000 for c in chunks), "every chunk fits the size budget")
    big = [{"source_id": "source.tdi.s.huge", "status": "runtime error", "message": "z" * 20000}]
    R.ok(len(_json.dumps({"checks": f2s.chunk_checks(big, 25, 6000)[0]})) <= 6000, "oversized message is trimmed")
    cmd = ["dbt", "run-operation", "x", "--args", '{"a": "it\'s"}']
    out = f2s.format_command(cmd)
    if f2s.os.name == "nt":
        ok = out == f2s.subprocess.list2cmdline(cmd) and "--args '" not in out
    else:
        ok = f2s.shlex.split(out) == cmd
    R.ok(ok, "printed command uses the platform's quoting and round-trips")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--dump-sql", metavar="DIR")
    args = ap.parse_args()

    check_layout()
    macros = load_macros()
    check_templates(macros)
    rt = Runtime(macros)
    check_readme(macros, rt)
    scenarios(macros, args.verbose, args.dump_sql)
    check_freshness_script()

    print(f"\n{R.passed} checks passed, {len(R.failures)} failed, {len(R.warnings)} warnings")
    sys.exit(1 if R.failures else 0)


if __name__ == "__main__":
    main()
