"""Download the current season from the official FPL API into the cache.

Writes data/cache/<season>/api/{events,teams,players,fixtures,gw_stats}.json in the
same row shape as the vaastav csv files, so load.py / load_season() need no branching.

usage: python3 etl/fetch_api.py [--resume]   (--resume keeps per-player history files already on disk)
"""
import json
import sys
import time
import urllib.error
import urllib.request

import config

BASE = "https://fantasy.premierleague.com/api"
HEADERS = {"User-Agent": "Mozilla/5.0 (fpl-sql-project)", "Accept": "application/json"}
PAUSE = 0.15          # seconds between element-summary calls; ~700 players -> ~2 min


def get(path, retries=3):
    url = f"{BASE}/{path}"
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == retries - 1:
                raise
            time.sleep(2 * (attempt + 1))


def season_of(events):
    """'2026-27' from the first deadline; used to check config matches what the API serves."""
    year = int(events[0]["deadline_time"][:4])
    return f"{year}-{(year + 1) % 100:02d}"


def dump(path, rows):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False)
    print(f"write {path.name:15s} {len(rows):>6} rows")


def main():
    cfg = config.load()
    resume = "--resume" in sys.argv
    out = cfg["cache"] / "api"
    hist_dir = out / "history"
    hist_dir.mkdir(parents=True, exist_ok=True)

    boot = get("bootstrap-static/")
    api_season = season_of(boot["events"])
    if api_season != cfg["season"]:
        sys.exit(f"config season is {cfg['season']} but the API serves {api_season}; fix config/season.toml")

    dump(out / "events.json", boot["events"])
    dump(out / "teams.json", boot["teams"])
    players = [e for e in boot["elements"] if e["element_type"] in (1, 2, 3, 4)]
    dump(out / "players.json", players)
    dump(out / "fixtures.json", get("fixtures/"))

    # per-player history = one row per played fixture, same fields as merged_gw.csv
    history = []
    for i, p in enumerate(players, 1):
        f = hist_dir / f"{p['id']}.json"
        if resume and f.exists():
            rows = json.load(open(f, encoding="utf-8"))
        else:
            rows = get(f"element-summary/{p['id']}/")["history"]
            json.dump(rows, open(f, "w", encoding="utf-8"))
            time.sleep(PAUSE)
        history.extend(rows)
        if i % 100 == 0:
            print(f"      history {i}/{len(players)} players")
    dump(out / "gw_stats.json", history)


if __name__ == "__main__":
    main()
