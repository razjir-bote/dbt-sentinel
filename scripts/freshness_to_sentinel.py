#!/usr/bin/env python3
"""
Convert dbt's target/sources.json (from `dbt source freshness`) into
`sentinel_record_freshness_batch` calls.

`dbt source freshness` does not run on-run-end hooks, so freshness results do
not reach Sentinel on their own. Run this afterwards:

    python scripts/freshness_to_sentinel.py target/sources.json            # print commands
    python scripts/freshness_to_sentinel.py target/sources.json --execute  # run them

Options:
    --chunk N            max results per run-operation call (default 25). Calls
                         are also split so the --args JSON stays under
                         --max-args-chars (default 6000), well below the
                         Windows command-line limit even after quote escaping
    --max-args-chars N   size budget for one call's --args JSON
    --pipeline-run-id ID overrides the run id (default: BUILD_BUILDID / SENTINEL_PIPELINE_RUN_ID)
    --dbt PATH           dbt executable (default: dbt)
    --no-messages        omit error text from runtime errors
    other arguments      passed through to dbt, e.g. --target prod

Exit code: 0 on success, 1 if any dbt call failed, 2 for unusable input.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys

PERIOD_MINUTES = {"minute": 1, "hour": 60, "day": 1440}
MESSAGE_MAX = 1000


def chunk_checks(checks: list[dict], max_count: int, max_chars: int) -> list[list[dict]]:
    """Greedy split by count and by serialized --args size. A single check
    larger than the budget gets its message trimmed so it fits on its own."""
    chunks: list[list[dict]] = []
    current: list[dict] = []
    for check in checks:
        size = len(json.dumps({"checks": [check]}))
        if size > max_chars and check.get("message"):
            keep = max(0, len(check["message"]) - (size - max_chars) - 3)
            check = dict(check, message=check["message"][:keep] + "...")
        candidate = current + [check]
        if current and (len(candidate) > max_count or len(json.dumps({"checks": candidate})) > max_chars):
            chunks.append(current)
            candidate = [check]
        current = candidate
    if current:
        chunks.append(current)
    return chunks


def format_command(cmd: list[str]) -> str:
    """Quote for the shell the user is likely to paste into: cmd.exe rules on
    Windows (also what CreateProcess uses), POSIX shell elsewhere."""
    return subprocess.list2cmdline(cmd) if os.name == "nt" else shlex.join(cmd)


def threshold_minutes(criteria: dict) -> float | None:
    """Prefer error_after, fall back to warn_after."""
    for key in ("error_after", "warn_after"):
        rule = (criteria or {}).get(key) or {}
        count, period = rule.get("count"), rule.get("period")
        if count is not None and period in PERIOD_MINUTES:
            return float(count) * PERIOD_MINUTES[period]
    return None


def to_check(result: dict, run_id: str | None, include_messages: bool) -> dict | None:
    source_id = result.get("unique_id")
    status = result.get("status")
    if not source_id or not status:
        return None
    check = {"source_id": source_id, "status": status}
    age = result.get("max_loaded_at_time_ago_in_s")
    if age is not None:
        check["age_minutes"] = round(float(age) / 60.0, 3)
    thr = threshold_minutes(result.get("criteria") or {})
    if thr is not None:
        check["threshold_minutes"] = thr
    for src, dst in (("max_loaded_at", "max_loaded_at"), ("snapshotted_at", "checked_at")):
        value = result.get(src)
        if value:
            # dbt writes e.g. 2026-11-15T03:20:30.123456+00:00 - Sentinel accepts UTC offsets only.
            check[dst] = value.replace("+00:00", "Z")
    if include_messages and status == "runtime error" and result.get("error"):
        check["message"] = str(result["error"])[:MESSAGE_MAX]
    if run_id:
        check["pipeline_run_id"] = run_id
    return check


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sources_json")
    ap.add_argument("--execute", action="store_true")
    ap.add_argument("--chunk", type=int, default=25)
    ap.add_argument("--max-args-chars", type=int, default=6000)
    ap.add_argument("--pipeline-run-id")
    ap.add_argument("--dbt", default="dbt")
    ap.add_argument("--no-messages", action="store_true")
    args, extra = ap.parse_known_args()
    args.dbt_args = extra  # anything else (e.g. --target prod) is passed through to dbt

    try:
        with open(args.sources_json, encoding="utf-8") as fh:
            payload = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"cannot read {args.sources_json}: {exc}", file=sys.stderr)
        return 2

    run_id = args.pipeline_run_id or os.environ.get("SENTINEL_PIPELINE_RUN_ID") or os.environ.get("BUILD_BUILDID")
    checks = [c for c in (to_check(r, run_id, not args.no_messages) for r in payload.get("results", [])) if c]
    if not checks:
        print("no freshness results found")
        return 0

    failed = 0
    chunks = chunk_checks(checks, max(1, args.chunk), max(500, args.max_args_chars))
    for chunk in chunks:
        cmd = [args.dbt, "run-operation", "sentinel_record_freshness_batch",
               "--args", json.dumps({"checks": chunk}), *args.dbt_args]
        if args.execute:
            try:
                rc = subprocess.call(cmd)
            except OSError as exc:  # e.g. dbt not found, command line too long
                print(f"could not run dbt for {len(chunk)} result(s): {exc}", file=sys.stderr)
                rc = 1
            failed += rc != 0
        else:
            print(format_command(cmd))
    if args.execute:
        print(f"recorded {len(checks)} freshness results in {len(chunks)} call(s); failed calls: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
