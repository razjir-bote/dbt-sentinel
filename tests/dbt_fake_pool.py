#!/usr/bin/env python3
"""
dbt Sentinel - run REAL dbt (dbt-core + dbt-synapse) against a fake ODBC
connection that records SQL instead of sending it to Synapse.

This exercises the genuine dbt hook/run-operation context (results objects,
graph, flags, modules, run_query, warnings) without a database:

    cd integration_tests
    DBT_PROFILES_DIR=<dir with a synapse profile using authentication: sql> \
        python ../tests/dbt_fake_pool.py

Requires dbt-core, dbt-synapse and the unixODBC runtime (libodbc.so.2) so that
pyodbc imports; no SQL Server driver or network access is needed. Answers to
catalogue queries are simulated, so this complements - not replaces - a run
against a development pool.
"""
import json, re, sys, os
import pyodbc

LOG = []
STATE = {"schemas": set(), "tables": {}, "views": set(), "fail_tests": False, "fail_try": []}

class FakeCursor:
    def __init__(self): self.sets=[]; self.description=None; self.rowcount=-1; self._rows=[]
    def _set(self, sets):
        self.sets = list(sets)
        self._advance()
    def _advance(self):
        if self.sets:
            desc, rows = self.sets.pop(0)
            self.description = [(n, t, None, None, None, None, True) for n, t in desc] if desc else None
            self._rows = list(rows)
            return True
        self.description=None; self._rows=[]; return False
    def nextset(self):
        return self._advance() if self.sets else False
    def fetchall(self): r=self._rows; self._rows=[]; return [tuple(x) for x in r]
    def fetchone(self): return tuple(self._rows.pop(0)) if self._rows else None
    def fetchmany(self, n): r=self._rows[:n]; self._rows=self._rows[n:]; return r
    def close(self): pass
    def execute(self, sql, *bindings):
        LOG.append(sql)
        self._set(respond(sql))
        return self

def respond(sql):
    s = sql
    sch = os.environ.get("SENTINEL_SCHEMA","sentinel_it_telemetry")
    if "count(*) as failures" in s:
        fail = 1 if ("sentinel_it_passing" in s and "where 1 = 0" not in s and "Fails only" in s) else 0
        return [([("failures", int), ("should_warn", str), ("should_error", str)], [(fail, "true" if fail else "false", "true" if fail else "false")])]
    m = re.search(r"CREATE SCHEMA \[(\w+)\]", s)
    if m: STATE["schemas"].add(m.group(1)); return []
    m = re.search(r"CREATE TABLE \[(\w+)\]\.\[(\w+)\] \((.*?)\)\nWITH", s, re.S)
    if m:
        STATE["tables"][m.group(2).lower()] = [c.strip().split("]")[0].strip("[").lower() for c in m.group(3).split(",\n")]
        return []
    m = re.search(r"CREATE VIEW \[(\w+)\]\.\[(\w+)\]", s)
    if m: STATE["views"].add(m.group(2).lower()); return []
    if "FROM sys.schemas WHERE name" in s:
        n = 1 if sch in STATE["schemas"] else 0
        return [([("n", int)], [(n,)])]
    if "JOIN sys.columns" in s:
        return [([("table_name", str), ("column_name", str)], [(t, c) for t, cols in STATE["tables"].items() for c in cols])]
    if "FROM sys.objects" in s:
        return [([("object_name", str)], [(o,) for o in list(STATE["tables"]) + list(STATE["views"])])]
    if "COUNT_BIG(*)" in s:
        return [([("n", int)], [(3,)])]
    if "BEGIN TRY" in s:
        if any(t in s for t in STATE["fail_try"]):
            return [([("e", int), ("m", str)], [(229, "permission denied")])]
        return [([("e", int), ("m", str)], [(0, None)])]
    if re.match(r"\s*(/\*.*?\*/\s*)?(select|SELECT|with|WITH)", s, re.S):
        return [([("c", str)], [])]
    return []

class FakeConn:
    timeout = 0
    def cursor(self): return FakeCursor()
    def add_output_converter(self, *a): pass
    def close(self): pass
    def commit(self): pass
    def rollback(self): pass

pyodbc.connect = lambda *a, **k: FakeConn()

from dbt.cli.main import dbtRunner

def run(args):
    start = len(LOG)
    res = dbtRunner().invoke(args)
    return res, LOG[start:]

STEPS = [
    ["run-operation", "sentinel_install"],
    ["run-operation", "sentinel_install"],
    ["run-operation", "sentinel_check"],
    ["build"],
    ["build", "--vars", "{sentinel_it_force_failure: true}"],
    ["run-operation", "sentinel_sync_manifest"],
    ["run-operation", "sentinel_sample_warehouse"],
    ["run-operation", "sentinel_sample_storage"],
    ["run-operation", "sentinel_sample_requests"],
    ["run-operation", "sentinel_sample_table_health"],
    ["run-operation", "sentinel_record_stage", "--args",
     "{pipeline_name: IT, pipeline_run_id: '1', stage: bronze, source_name: ABR, status: Succeeded, rows_loaded: 10}"],
    ["run-operation", "sentinel_record_freshness", "--args", "{source_id: source.x.y.z, status: pass, age_minutes: 45}"],
    ["run-operation", "sentinel_purge_history", "--args", "{keep_days: 180, dry_run: true}"],
    ["!failtry", "[run_events]"],
    ["build", "--vars", "{sentinel_hook_on_error: warn}"],
    ["!failtry"],
    ["compile"],
]


def main():
    results = []
    for args in STEPS:
        if args[0] == "!failtry":
            STATE["fail_try"] = args[1:]
            continue
        res, sqls = run(args)
        results.append((args, res, sqls))

    failures = []

    def check(cond, label):
        print(("  ok    " if cond else "  FAIL  ") + label)
        if not cond:
            failures.append(label)

    def tele(sqls, table):
        return [q for q in sqls if f"].[{table}]" in q and "INSERT INTO" in q]

    print("\nResults")
    by = {i: r for i, r in enumerate(results)}
    check(by[0][1].success and by[1][1].success, "install twice succeeds")
    check(not any("CREATE TABLE" in q for q in by[1][2]), "second install creates no tables")
    check(by[2][1].success, "sentinel_check passes")
    ok_build = by[3]
    check(ok_build[1].success, "passing build succeeds")
    ev = tele(ok_build[2], "run_events")
    check(len(ev) == 2 and "N'start'" in ev[0] and "N'end'" in ev[1], "passing build: start + end events")
    check("CAST(N'success' AS nvarchar(32))" in ev[1], "passing build: run_status success")
    check(len(tele(ok_build[2], "node_results")) == 1, "passing build: node rows written")
    bad_build = by[4]
    check(not bad_build[1].success, "forced-failure build fails (dbt result authoritative)")
    ev = tele(bad_build[2], "run_events")
    check(len(ev) == 2 and "CAST(N'error' AS nvarchar(32))" in ev[1], "failed build: run_status error recorded")
    check("CAST(N'fail' AS nvarchar(32))" in tele(bad_build[2], "node_results")[0], "failed build: test status fail recorded")
    m = by[5][2]
    check([t for t in ("manifest_nodes", "manifest_edges", "manifest_snapshots") if tele(m, t)] ==
          ["manifest_nodes", "manifest_edges", "manifest_snapshots"], "manifest sync writes nodes, edges, header")
    for i, t in ((6, "warehouse_samples"), (7, "storage_samples"), (8, "query_samples"), (9, "table_health_samples"), (10, "stage_events"), (11, "freshness_events")):
        check(by[i][1].success and len(tele(by[i][2], t)) == 1, f"{by[i][0][1]} writes {t}")
    check(by[12][1].success and not any(q.lstrip().startswith("DELETE") for q in by[12][2]), "purge dry run deletes nothing")
    check(by[13][1].success, "warn mode: telemetry write failure does not fail the build")
    check(by[14][1].success and not any("sentinel_it_telemetry" in q for q in by[14][2]), "compile writes no telemetry")
    print(f"\n{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    # Keep this script's folder off sys.path while dbt runs: otherwise modules
    # in tests/ can be imported a second time and the fake connection, with its
    # own statement log, is installed from that copy instead.
    _here = os.path.dirname(os.path.abspath(__file__))
    sys.path[:] = [p for p in sys.path if os.path.abspath(p or ".") != _here]
    main()
