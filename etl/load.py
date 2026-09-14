"""Push cached files into stg_raw as jsonb, then CALL load_season().

Python does no parsing beyond csv -> dict; every cast and mapping is in sql/load.sql.
usage: python3 etl/load.py
"""
import csv
import io
import json
import subprocess
import sys

import config

# stg_raw.kind -> cache file
CSV_KINDS = {
    "teams": "teams.csv",
    "players": "players_raw.csv",
    "fixtures": "fixtures.csv",
    "gw_stats": "merged_gw.csv",
}
JSON_KINDS = {
    "events": "events.json",
    "teams": "teams.json",
    "players": "players.json",
    "fixtures": "fixtures.json",
    "gw_stats": "gw_stats.json",
}


def psql(cfg, *args, stdin=None):
    cmd = ["psql", "-d", cfg["db"], "-v", "ON_ERROR_STOP=1", "-q", *args]
    res = subprocess.run(cmd, input=stdin, text=True, capture_output=True)
    if res.returncode != 0:
        sys.exit(res.stderr)
    return res.stderr + res.stdout   # RAISE NOTICE goes to stderr


def rows_from_csv(path):
    with open(path, newline="", encoding="utf-8") as f:
        yield from csv.DictReader(f)


def rows_from_json(path):
    with open(path, encoding="utf-8") as f:
        yield from json.load(f)


def copy_kind(cfg, kind, rows):
    """Stream rows as CSV into stg_raw via \\copy; payload cell holds the JSON."""
    buf = io.StringIO()
    w = csv.writer(buf)
    n = 0
    for row in rows:
        w.writerow([cfg["season_name"], cfg["source"], kind, json.dumps(row, ensure_ascii=False)])
        n += 1
    psql(cfg, "-c", r"\copy stg_raw (season_name, source, kind, payload) FROM STDIN WITH (FORMAT csv)",
         stdin=buf.getvalue())
    print(f"stg_raw  {kind:9s} {n:>6} rows")


def main():
    cfg = config.load()
    src = cfg["source"]
    kinds = CSV_KINDS if src == "csv" else JSON_KINDS
    reader = rows_from_csv if src == "csv" else rows_from_json
    cache = cfg["cache"] / src

    psql(cfg, "-c", f"DELETE FROM stg_raw WHERE season_name = '{cfg['season_name']}'")
    for kind, fname in kinds.items():
        path = cache / fname
        if not path.exists():
            sys.exit(f"missing {path}; run fetch_{src}.py first")
        copy_kind(cfg, kind, reader(path))

    out = psql(cfg, "-c", f"CALL load_season('{cfg['season_name']}')")
    print(out.strip() or "load_season done")


if __name__ == "__main__":
    main()
