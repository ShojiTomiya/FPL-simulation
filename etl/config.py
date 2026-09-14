"""Shared config for etl scripts. Stdlib only."""
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load():
    with open(ROOT / "config" / "season.toml", "rb") as f:
        cfg = tomllib.load(f)
    cfg["cache"] = ROOT / cfg["cache_dir"] / cfg["season"]
    cfg["season_name"] = season_name(cfg["season"])
    return cfg


def season_name(dirname: str) -> str:
    """'2025-26' -> '2025/26' (name used inside the database)."""
    return dirname.replace("-", "/")
