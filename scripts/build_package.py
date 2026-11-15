#!/usr/bin/env python3
"""
Build a versioned, installable dbt Sentinel release archive.

    python scripts/build_package.py            # -> dist/dbt_sentinel-<version>.zip (+ .sha256)
    python scripts/build_package.py --check    # also run tests/check_package.py first

The archive contains a single top-level folder, dbt_sentinel/, holding only what
a host project needs (dbt_project.yml, macros, examples, the freshness script,
README, CHANGELOG). Development tooling (tests/, integration_tests/) is left out.

Install locally: unzip anywhere, then in the host project's packages.yml

    packages:
      - local: "C:/dbt-packages/dbt_sentinel"     # the unzipped dbt_sentinel folder

and run `dbt deps`. See README "Install from a release archive".
"""
from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INCLUDE = [
    "dbt_project.yml",
    "README.md",
    "CHANGELOG.md",
    "macros",
    "examples",
    "scripts/freshness_to_sentinel.py",
]
EXCLUDE_PARTS = {"__pycache__", "target", "dbt_packages", "logs"}


def version() -> str:
    text = (ROOT / "dbt_project.yml").read_text(encoding="utf-8")
    m = re.search(r'^version:\s*"?([0-9][^"\s]*)"?', text, re.M)
    if not m:
        sys.exit("cannot find version in dbt_project.yml")
    return m.group(1)


def files():
    for item in INCLUDE:
        path = ROOT / item
        if path.is_file():
            yield path
        elif path.is_dir():
            for f in sorted(path.rglob("*")):
                if f.is_file() and not (set(f.relative_to(ROOT).parts) & EXCLUDE_PARTS):
                    yield f
        else:
            sys.exit(f"missing package file: {item}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="run tests/check_package.py before building")
    ap.add_argument("--out", default=str(ROOT / "dist"), help="output folder (default: dist/)")
    args = ap.parse_args()

    if args.check:
        rc = subprocess.call([sys.executable, str(ROOT / "tests" / "check_package.py")])
        if rc != 0:
            print("checks failed - archive not built")
            return rc

    ver = version()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / f"dbt_sentinel-{ver}.zip"
    count = 0
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files():
            arcname = "dbt_sentinel/" + f.relative_to(ROOT).as_posix()
            info = zipfile.ZipInfo(arcname, date_time=(2026, 1, 1, 0, 0, 0))  # reproducible
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, f.read_bytes())
            count += 1
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out / f"{archive.name}.sha256").write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
    print(f"built {archive} ({count} files)\nsha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
