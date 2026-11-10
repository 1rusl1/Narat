#!/usr/bin/env python3
"""Run the accepted private PG17 fixtures with explicit CI dependency paths.

The original controller gate owns every SQL assertion, seed, race and cleanup.
This adapter only supplies portable installation locations; it never connects to
an existing database or changes the accepted gate's business checks.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pg-bin', required=True, type=Path)
    parser.add_argument('--pgtap-sql', required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        pg_bin = args.pg_bin.resolve(strict=True)
        pgtap = args.pgtap_sql.resolve(strict=True)
    except OSError as error:
        parser.error(str(error))
    if not pgtap.is_file() or not all((pg_bin / name).is_file() for name in ('initdb', 'pg_ctl', 'psql')):
        parser.error('Explicit PostgreSQL17 binaries and generated pgTAP SQL are required')
    version = subprocess.run([str(pg_bin / 'initdb'), '--version'], capture_output=True, text=True, check=True)
    if not re.search(r'\(PostgreSQL\)\s+17(?:[.\s]|$)', version.stdout):
        parser.error('The SQL fixture contract requires PostgreSQL17')
    import parallel_backend_quota_gate as accepted
    accepted.BIN = pg_bin
    accepted.PGTAP = pgtap
    original_argv = sys.argv
    try:
        sys.argv = [str(Path(accepted.__file__)), '--accounting', '--legacy-guard', '--cap-regression']
        return accepted.main()
    finally:
        sys.argv = original_argv


if __name__ == '__main__':
    raise SystemExit(main())
