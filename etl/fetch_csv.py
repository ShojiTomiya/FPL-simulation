"""Download one season from vaastav/Fantasy-Premier-League into the cache.

usage: python3 etl/fetch_csv.py [--force]
"""
import sys
import urllib.request

import config

BASE = "https://raw.githubusercontent.com/vaastav/Fantasy-Premier-League/master/data"
FILES = ["players_raw.csv", "teams.csv", "fixtures.csv", "gws/merged_gw.csv"]


def main():
    cfg = config.load()
    force = "--force" in sys.argv
    out_dir = cfg["cache"] / "csv"
    out_dir.mkdir(parents=True, exist_ok=True)

    for rel in FILES:
        target = out_dir / rel.split("/")[-1]
        if target.exists() and not force:
            print(f"skip  {target.name} (cached)")
            continue
        url = f"{BASE}/{cfg['season']}/{rel}"
        req = urllib.request.Request(url, headers={"User-Agent": "fpl-sql-project"})
        with urllib.request.urlopen(req, timeout=60) as resp, open(target, "wb") as f:
            f.write(resp.read())
        print(f"fetch {target.name} <- {url}")


if __name__ == "__main__":
    main()
