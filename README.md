# FPL in PostgreSQL

A Fantasy Premier League engine where the database is the game. Squad rules,
deadlines, transfers and scoring live in triggers, procedures and views.
Python only downloads files and copies them into a staging table.

Two ways to play, same code:

- **Replay** a finished season. The clock is virtual; you build a squad at the
  prices of August, close gameweeks one by one and score what the players
  really did that week.
- **Live** on the current season from the official FPL API. Real deadlines,
  today's prices, load fresh stats after each round.

Scoring is verified against FPL's own numbers: every one of the 29 747
player-fixture rows of 2025/26 gets exactly the points FPL awarded.

## Quick start

Requirements: PostgreSQL 14+ (built on 17), Python 3.11+ (stdlib only), `make`.

```bash
make all replay        # create db, apply sql, download 2025/26, load, start the clock
make status            # game time, current gameweek, mode
make test              # 44 checks, rolled back afterwards
make psql              # console
```

## How to play

Everything below is plain SQL in `psql` or DBeaver. Prices are tenths of a
million (55 = 5.5m), the budget is 1000. All rules are enforced by the
database, so a wrong move fails with a message saying why:

```
ERROR:  invalid squad for gameweek 1: more than 3 players from one club: ARS x4
ERROR:  gameweek 4 is locked, current gameweek is 5 (deadline 2026-09-18 19:30:00+02)
ERROR:  invalid lineup for gameweek 1: illegal formation: GKP=2
ERROR:  transfer must keep the position (out: 2, in: 4)
```

**1. Find player codes.** Codes are stable across seasons and identify players
everywhere in the schema.

```sql
SELECT p.player_code, p.web_name, pos.code AS pos, c.short_name AS club, pr.price
FROM player_seasons ps
JOIN players p USING (player_code)
JOIN positions pos USING (position_id)
JOIN clubs c ON c.club_code = fn_club_at(ps.season_id, ps.player_code, fn_current_gw())
JOIN player_gw_prices pr ON pr.season_id = ps.season_id AND pr.player_code = ps.player_code
                        AND pr.gw_no = fn_current_gw()
WHERE ps.season_id = fn_current_season()
ORDER BY pos.position_id, pr.price DESC;
```

**2. Create a team.** The array holds 15 codes: 11 starters in the order
GKP, DEF, MID, FWD, then the 4 bench players in bench order. The last two
arguments are captain and vice. The function returns your `entry_id`.

```sql
SELECT create_entry('michal', 'My Team',
    ARRAY[gk1, def1, def2, def3, def4, mid1, mid2, mid3, mid4, fwd1, fwd2,
          gk2, def5, mid5, fwd3],
    fwd1, mid1);
```

The squad needs 2 GKP, 5 DEF, 5 MID, 3 FWD, at most 3 from one club, within
budget. The starting eleven needs 1 GKP, 3 to 5 DEF, 2 to 5 MID, 1 to 3 FWD.

Your `entry_id` is not necessarily 1 - IDENTITY counters don't roll back, so an
earlier attempt (even a failed or rolled-back one) can bump it. If you forget
it: `SELECT entry_id, name FROM entries;`. The rest of this guide uses `1` as
a placeholder - substitute your own.

**3. Look at your team and its points for the current gameweek.**

```sql
SELECT p.web_name, l.is_starter, l.is_captain, l.is_vice, lp.points, lp.multiplier
FROM lineups l
JOIN players p USING (player_code)
LEFT JOIN v_lineup_points lp USING (entry_id, gw_no, player_code)
WHERE l.entry_id = 1 AND l.gw_no = fn_current_gw()
ORDER BY l.is_starter DESC, l.bench_order;
```

**4. Change the captain.**

```sql
UPDATE lineups SET is_captain = false WHERE entry_id = 1 AND gw_no = fn_current_gw() AND is_captain;
UPDATE lineups SET is_captain = true  WHERE entry_id = 1 AND gw_no = fn_current_gw() AND player_code = 233;
```

**5. Swap a starter with a bench player.** Two changes in one transaction:
in between, the lineup has 10 or 12 starters, and the whole-lineup check runs
at `COMMIT`. The outgoing starter takes the bench slot the incoming player
leaves.

```sql
BEGIN;
UPDATE lineups SET is_starter = true,  bench_order = NULL WHERE entry_id = 1 AND gw_no = fn_current_gw() AND player_code = 351;
UPDATE lineups SET is_starter = false, bench_order = 2    WHERE entry_id = 1 AND gw_no = fn_current_gw() AND player_code = 233;
COMMIT;
```

**6. Make a transfer.** One insert; the trigger fills prices, rewrites the
squad history, swaps the player in your lineup and counts the transfer.
Player in and player out must share a position. Selling returns the purchase
price, buying costs the current price.

```sql
INSERT INTO transfers (entry_id, gw_no, player_out, player_in)
VALUES (1, fn_current_gw(), 233, 351);
```

You get 1 free transfer a week, unused ones roll over up to 5, each extra
costs 4 points. The week you join is free.

**7. Close the gameweek.**

```bash
make advance
```

Penalties are applied, free transfers carried forward, the clock jumps to the
day before the next deadline, your lineup is copied to the next week and the
table is refreshed. From now on you edit the next gameweek; the previous one is
locked.

**8. Follow the season.**

```sql
SELECT gw_no, points, total_points, rank, rank_change
FROM mv_standings WHERE entry_id = 1 ORDER BY gw_no;

SELECT gw_no, raw_points, penalty_points, points
FROM v_entry_gw_points WHERE entry_id = 1 ORDER BY gw_no;
```

To see whether your squad or lineup is legal in plain English, at the current
gameweek or any past one - mainly useful for debugging or checking history,
since the database already refuses anything invalid at the moment you try it:

```sql
SELECT fn_squad_error(1, 12), fn_lineup_error(1, 12);   -- NULL, NULL = all fine
```

**9. Play with friends in a mini-league.** Anyone with an entry can create one
and invite others by sharing the join code.

```sql
INSERT INTO mini_leagues (season_id, name, owner_user_id, join_code)
VALUES (fn_current_season(), 'Office League', 1, 'ABC123');

INSERT INTO mini_members (league_id, entry_id) VALUES (1, 1), (1, 2), (1, 3);

SELECT e.name, st.total_points,
       dense_rank() OVER (ORDER BY st.total_points DESC) AS pos
FROM mini_members mm
JOIN entries e USING (entry_id)
JOIN mv_standings st ON st.entry_id = e.entry_id
WHERE mm.league_id = 1 AND st.gw_no = (SELECT max(gw_no) FROM mv_standings)
ORDER BY pos;
```

`make reset-game` wipes all teams, mini-leagues included, keeps the loaded
data, and resets `entry_id` numbering back to 1. `make replay` puts the clock
back to gameweek 1.

## How it works

**Data.** `make fetch` downloads four csv files of the season into
`data/cache/`. `make load` turns each row into a JSON object and copies it
into `stg_raw`, then calls `load_season()`. The procedure fills clubs,
players, gameweeks, fixtures, stats and prices with idempotent upserts,
derives deadlines as 90 minutes before the first kickoff of the round, and
refreshes `mv_player_gw_points`, the points of every player in every
gameweek.

**Points.** `v_player_fixture_points` unpivots a stats row into 13
stat-value pairs with `LATERAL (VALUES ...)`, joins `scoring_rules` by stat
and position, applies one formula per rule and aggregates back with `FILTER`.
Rules are rows, not code:

```
points * LEAST(cap, value / per_units)   when value >= min_value
```

**Clock.** `fn_now()` returns the virtual time from `app_settings` if set,
otherwise `now()`. `fn_current_gw()` is the first gameweek whose deadline is
later than `fn_now()`, and it is the only gameweek anyone may edit. Replay sets
the virtual time to one day before deadline 1; the fact that the whole season's
stats already sit in the database does not matter, because lineups and
transfers are only accepted for the current gameweek.

**Squad history.** A row in `squad_slots` lives from `from_gw` to `to_gw`.
A transfer closes one row and opens another. Points for gameweek 12 are
computed against the squad of gameweek 12, so later changes never rewrite the
past. An `EXCLUDE` constraint on `int4range(from_gw, to_gw)` makes overlapping
ownership impossible.

**Triggers.** Row-level `BEFORE` triggers check the deadline and simple facts
immediately. Whole-squad and whole-lineup rules run as constraint triggers
`DEFERRABLE INITIALLY DEFERRED`, at `COMMIT`, because "exactly 15 players" is
meaningless after the first inserted row. The transfer trigger does the most:
deadline, ownership, position, prices, squad history, lineup swap, transfer
counter.

**Closing a gameweek.** `advance_gameweek()` writes the penalty into
`entry_gw_state`, creates next week's state with the rolled-over free
transfers, marks the gameweek finished, moves the clock, copies lineups
forward and refreshes `mv_standings`. In live mode it refuses to close a
gameweek whose deadline has not passed or whose fixtures are not all played.

**Scoring chain.**

```
player_fixture_stats x scoring_rules
  -> v_player_fixture_points     one player, one match, per-stat breakdown
  -> mv_player_gw_points         per gameweek; refreshed on load
  -> v_lineup_points             starters with multiplier (captain x2, vice if captain has 0 minutes)
  -> v_entry_gw_points           team total minus transfer penalty
  -> mv_standings                cumulative table, rank, rank change; refreshed by advance_gameweek()
```

## Data sources

| source | used for | what it gives |
|---|---|---|
| [vaastav/Fantasy-Premier-League](https://github.com/vaastav/Fantasy-Premier-League) | replay of any season since 2016/17 | per player per fixture: minutes, goals, assists, saves, bonus, xG, price, official points |
| [fantasy.premierleague.com/api](https://fantasy.premierleague.com/api/bootstrap-static/) | live | the same fields plus real deadlines and today's prices; no key needed |

Pick the season and source in `config/season.toml`:

```toml
season = "2025-26"   # directory name in the vaastav repo
source = "csv"       # csv = replay, api = live
db = "fpl"
cache_dir = "data/cache"
```

Both loaders write the same row shape into `stg_raw`, and one procedure turns
it into tables. Player and club identifiers in FPL change every season; the
stable `code` is the key here.

## Files

| file | contents |
|---|---|
| `sql/schema.sql` | 22 tables, 3 enums, keys. No logic. |
| `sql/constraints.sql` | 51 declarative rules: `CHECK`, partial unique indexes, `EXCLUDE` on gameweek ranges |
| `sql/seed.sql` | positions with squad limits, 22 scoring rules |
| `sql/load.sql` | `load_season()`: staging to tables |
| `sql/views.sql` | the scoring chain |
| `sql/game_logic.sql` | clock, validators, triggers, `create_entry`, `advance_gameweek`, `start_replay`, `go_live`, `reset_game` |
| `sql/indexes.sql` | 22 performance indexes |
| `sql/queries.sql` | 25 analytical queries, one SQL construct each |
| `etl/fetch_csv.py`, `etl/fetch_api.py` | download to `data/cache/` |
| `etl/load.py` | cache to `stg_raw` via `\copy`, then `CALL load_season()` |
| `tests/test_all.sql` | 44 checks: scoring against FPL, every rule rejected, three bots through 38 gameweeks; runs in a transaction and rolls back |
| `Makefile` | `setup fetch load all replay live advance status test logic reset-game reset psql` |

## Model

**Reference data** (loaded): `seasons`, `clubs`, `club_seasons`, `positions`,
`players`, `player_seasons`, `gameweeks`, `fixtures`, `player_fixture_stats`,
`player_gw_prices`, `scoring_rules`.

**Game** (written by managers, guarded by triggers): `users`, `entries`,
`squad_slots`, `lineups`, `transfers`, `entry_gw_state`, `mini_leagues`,
`mini_members`, `audit_log`.

**Technical**: `app_settings` (virtual clock, current season), `stg_raw`.

## Rules the database enforces

- squad: 15 players, 2/5/5/3 by position, at most 3 from one club, total cost within budget
- lineup: 15 rows matching the squad, 11 starters, formation within position limits, one captain, one vice, bench numbered 1 to 4
- time: only the current gameweek can be edited
- transfers: player out must be owned, player in must not, same position, sold at purchase price, bought at the current price; transfers are immutable
- penalties: 4 points per transfer beyond the free ones, unused free transfers roll over up to 5, a hit resets them to 1, the joining week is free
- captaincy: double points; if the captain has 0 minutes the vice gets them
- every change to the game tables is written to `audit_log` with the row before and after

## Analytical queries

`sql/queries.sql`, numbered, each header names the construct:

| construct | queries |
|---|---|
| window functions: `RANK`, `ROW_NUMBER`, `NTILE`, `LEAD`, `FIRST_VALUE`, frames | Q01 top per position, Q02 rolling form, Q04 price quartiles, Q13 crowd vs next-week points, Q16 dream team, Q17 price movers, Q23 mini-league |
| gaps and islands | Q10 longest streak of 5+ point weeks |
| `LATERAL` | Q03 points per million, Q05 next five fixtures, Q22 squad churn |
| `GROUPING SETS` | Q06 home / away / total |
| `FULL OUTER JOIN`, anti-join, `EXCEPT` | Q09 compare two squads, Q08 top scorers nobody owned, Q22 |
| recursive CTE | Q11 who replaced whom in a squad slot |
| `DISTINCT ON`, `bool_and`, `percentile_cont`, `corr` | Q21, Q24, Q04, Q13 |
| jsonb: `->>`, `@>` with GIN | Q19 captaincy history from the audit log, Q20 mid-season club moves from raw data |
| plain aggregation | Q12 goals vs xG, Q14 captaincy report, Q15 bench points, Q18 the real league table |

## Live mode

```bash
# config/season.toml: season = "2026-27", source = "api"
make fetch load          # ~4 minutes: one request per player for history
psql -d fpl -c "UPDATE app_settings SET value = '2' WHERE key = 'current_season'"
make live
```

`go_live()` drops the virtual clock and marks fully played gameweeks as closed.
Managers create entries at today's prices and edit lineups until the real
deadline. After the last match of a round: `make fetch load advance`.

## Simplifications

No automatic substitutions, no chips, no sell-on profit (players are sold at
purchase price), no web interface. Points for the current gameweek are visible
as soon as data is loaded, which in replay means before the virtual deadline;
the views do not look at the clock.
