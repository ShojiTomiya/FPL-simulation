-- analytical queries; each header names the SQL construct it exercises
-- plain SQL, runs in psql or DBeaver; parameters are literals marked with <--


-- Q01 · RANK() OVER (PARTITION BY) · top 5 scorers per position
WITH totals AS (
    SELECT p.player_code, p.web_name, ps.position_id, sum(g.points) AS points
    FROM mv_player_gw_points g
    JOIN players p USING (player_code)
    JOIN player_seasons ps ON ps.season_id = g.season_id AND ps.player_code = g.player_code
    WHERE g.season_id = fn_current_season()
    GROUP BY 1, 2, 3
)
SELECT pos.code, t.web_name, t.points,
       rank() OVER (PARTITION BY t.position_id ORDER BY t.points DESC) AS rank_in_position
FROM totals t
JOIN positions pos USING (position_id)
ORDER BY t.position_id, rank_in_position
FETCH FIRST 20 ROWS WITH TIES;


-- Q02 · window frame ROWS BETWEEN · 5-gameweek rolling form, best entering gw 30
WITH form AS (
    SELECT player_code, gw_no, points,
           avg(points) OVER (PARTITION BY player_code ORDER BY gw_no
                             ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS form5,
           count(*)    OVER (PARTITION BY player_code ORDER BY gw_no
                             ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) AS n
    FROM mv_player_gw_points
    WHERE season_id = fn_current_season()
)
SELECT p.web_name, f.gw_no, round(f.form5, 1) AS form5
FROM form f
JOIN players p USING (player_code)
WHERE f.gw_no = 29 AND f.n = 5                                   -- <-- gameweek before the one you pick for
ORDER BY f.form5 DESC
LIMIT 10;


-- Q03 · LATERAL · points per million at final price
SELECT p.web_name, pos.code, sum(g.points) AS points, round(pr.price / 10.0, 1) AS price_m,
       round(sum(g.points) / (pr.price / 10.0), 1) AS pts_per_m
FROM mv_player_gw_points g
JOIN players p USING (player_code)
JOIN player_seasons ps ON ps.season_id = g.season_id AND ps.player_code = g.player_code
JOIN positions pos ON pos.position_id = ps.position_id
CROSS JOIN LATERAL (
    SELECT price FROM player_gw_prices x
    WHERE x.season_id = g.season_id AND x.player_code = g.player_code
    ORDER BY gw_no DESC LIMIT 1
) pr
WHERE g.season_id = fn_current_season()
GROUP BY 1, 2, pr.price
HAVING sum(g.minutes) >= 1500
ORDER BY pts_per_m DESC
LIMIT 15;


-- Q04 · NTILE + PERCENTILE_CONT · price quartiles vs points
WITH per_player AS (
    SELECT g.player_code, sum(g.points) AS points,
           (SELECT price FROM player_gw_prices x
             WHERE x.season_id = g.season_id AND x.player_code = g.player_code AND x.gw_no = 1) AS start_price
    FROM mv_player_gw_points g
    WHERE g.season_id = fn_current_season()
    GROUP BY g.player_code, g.season_id
    HAVING sum(g.minutes) >= 900
),
binned AS (
    SELECT *, ntile(4) OVER (ORDER BY start_price) AS price_quartile FROM per_player
)
SELECT price_quartile,
       count(*)                                                     AS players,
       round(min(start_price) / 10.0, 1)                            AS min_price_m,
       round(max(start_price) / 10.0, 1)                            AS max_price_m,
       round(avg(points), 1)                                        AS avg_points,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY points)::numeric, 1) AS median_points,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY points)::numeric, 1) AS p90_points
FROM binned
GROUP BY price_quartile
ORDER BY price_quartile;


-- Q05 · LATERAL + string_agg · next 5 fixtures per club from gw 20 with opponent defence rating
WITH conceded AS (
    SELECT club_code, round(avg(goals_against), 2) AS avg_conceded
    FROM (
        SELECT home_club AS club_code, away_score AS goals_against FROM fixtures WHERE finished
        UNION ALL
        SELECT away_club, home_score FROM fixtures WHERE finished
    ) x
    GROUP BY club_code
)
SELECT c.short_name,
       string_agg(format('%s %s(%s) %s', nf.gw_no, o.short_name, CASE WHEN nf.home THEN 'H' ELSE 'A' END, cd.avg_conceded),
                  ' | ' ORDER BY nf.gw_no) AS next_5,
       round(avg(cd.avg_conceded), 2) AS avg_opp_conceded
FROM clubs c
CROSS JOIN LATERAL (
    SELECT f.gw_no,
           CASE WHEN f.home_club = c.club_code THEN f.away_club ELSE f.home_club END AS opponent,
           f.home_club = c.club_code AS home
    FROM fixtures f
    WHERE f.season_id = fn_current_season() AND f.gw_no >= 20                   -- <-- from gameweek
      AND c.club_code IN (f.home_club, f.away_club)
    ORDER BY f.gw_no LIMIT 5
) nf
JOIN clubs o ON o.club_code = nf.opponent
JOIN conceded cd ON cd.club_code = nf.opponent
GROUP BY c.short_name
ORDER BY avg_opp_conceded DESC;


-- Q06 · GROUPING SETS · club points home / away / total
SELECT c.short_name,
       CASE WHEN grouping(s.home) = 1 THEN 'total' WHEN s.home THEN 'home' ELSE 'away' END AS venue,
       sum(s.points) AS points,
       count(DISTINCT s.fixture_id) AS fixtures
FROM (
    SELECT pf.club_code, pf.fixture_id, pf.points, f.home_club = pf.club_code AS home
    FROM v_player_fixture_points pf
    JOIN fixtures f USING (fixture_id)
    WHERE f.season_id = fn_current_season()
) s
JOIN clubs c USING (club_code)
GROUP BY GROUPING SETS ((c.short_name, s.home), (c.short_name))
ORDER BY c.short_name, grouping(s.home), s.home DESC;


-- Q07 · CROSS JOIN + LEFT JOIN + HAVING · double and blank gameweeks
SELECT gw.gw_no, c.short_name, count(f.fixture_id) AS fixtures
FROM gameweeks gw
CROSS JOIN clubs c
LEFT JOIN fixtures f ON f.season_id = gw.season_id AND f.gw_no = gw.gw_no
                    AND c.club_code IN (f.home_club, f.away_club)
WHERE gw.season_id = fn_current_season()
GROUP BY gw.gw_no, c.short_name
HAVING count(f.fixture_id) <> 1
ORDER BY gw.gw_no, c.short_name;


-- Q08 · anti-join NOT EXISTS · top-30 scorers nobody ever owned
WITH top30 AS (
    SELECT player_code, sum(points) AS points
    FROM mv_player_gw_points WHERE season_id = fn_current_season()
    GROUP BY player_code ORDER BY points DESC LIMIT 30
)
SELECT p.web_name, t.points
FROM top30 t
JOIN players p USING (player_code)
WHERE NOT EXISTS (SELECT 1 FROM squad_slots s WHERE s.player_code = t.player_code)
ORDER BY t.points DESC;


-- Q09 · FULL OUTER JOIN · compare two squads in one gameweek
SELECT COALESCE(a.player_code, b.player_code) AS player_code, p.web_name,
       CASE WHEN a.player_code IS NULL THEN 'only B'
            WHEN b.player_code IS NULL THEN 'only A'
            ELSE 'both' END AS owned_by
FROM fn_squad_at(1, 38) a                                                   -- <-- entry A, gameweek
FULL OUTER JOIN fn_squad_at(2, 38) b ON a.player_code = b.player_code       -- <-- entry B
JOIN players p ON p.player_code = COALESCE(a.player_code, b.player_code)
ORDER BY owned_by, p.web_name;


-- Q10 · gaps and islands (ROW_NUMBER difference) · longest streak of 5+ point gameweeks
WITH hits AS (
    SELECT player_code, gw_no,
           gw_no - row_number() OVER (PARTITION BY player_code ORDER BY gw_no) AS grp
    FROM mv_player_gw_points
    WHERE season_id = fn_current_season() AND points >= 5
),
streaks AS (
    SELECT player_code, min(gw_no) AS from_gw, max(gw_no) AS to_gw, count(*) AS len
    FROM hits GROUP BY player_code, grp
)
SELECT p.web_name, s.from_gw, s.to_gw, s.len
FROM streaks s
JOIN players p USING (player_code)
ORDER BY s.len DESC, s.from_gw
LIMIT 10;


-- Q11 · recursive CTE · lineage of one squad slot: who replaced whom
WITH RECURSIVE chain AS (
    SELECT s.player_code, s.from_gw, 1 AS step, s.player_code::text AS path
    FROM squad_slots s
    WHERE s.entry_id = 1 AND s.from_gw = (SELECT created_gw FROM entries WHERE entry_id = 1)   -- <-- entry
    UNION ALL
    SELECT t.player_in, t.gw_no, c.step + 1, c.path || ' -> ' || t.player_in
    FROM chain c
    JOIN transfers t ON t.entry_id = 1 AND t.player_out = c.player_code AND t.gw_no >= c.from_gw
)
SELECT c.step, c.from_gw, p.web_name, c.path
FROM chain c
JOIN players p USING (player_code)
WHERE c.step > 1
ORDER BY c.path, c.step;


-- Q12 · numeric aggregates · goals vs expected goals, biggest over/under performers
SELECT p.web_name, pos.code,
       sum(s.goals_scored)                              AS goals,
       round(sum(s.expected_goals), 1)                  AS xg,
       round(sum(s.goals_scored) - sum(s.expected_goals), 1) AS diff
FROM player_fixture_stats s
JOIN fixtures f USING (fixture_id)
JOIN players p USING (player_code)
JOIN player_seasons ps ON ps.season_id = f.season_id AND ps.player_code = s.player_code
JOIN positions pos ON pos.position_id = ps.position_id
WHERE f.season_id = fn_current_season()
GROUP BY 1, 2
HAVING sum(s.expected_goals) >= 5
ORDER BY abs(sum(s.goals_scored) - sum(s.expected_goals)) DESC
LIMIT 10;


-- Q13 · LEAD() + corr() · does the crowd know? transfers in this week vs points next week
WITH x AS (
    SELECT pr.player_code, pr.gw_no, pr.transfers_in,
           lead(g.points) OVER (PARTITION BY pr.player_code ORDER BY pr.gw_no) AS next_points
    FROM player_gw_prices pr
    LEFT JOIN mv_player_gw_points g USING (season_id, player_code, gw_no)
    WHERE pr.season_id = fn_current_season()
)
SELECT round(corr(transfers_in, next_points)::numeric, 3) AS correlation,
       count(*) AS observations,
       round(avg(next_points) FILTER (WHERE transfers_in >= 100000), 2) AS avg_next_when_hyped,
       round(avg(next_points), 2)                                       AS avg_next_overall
FROM x
WHERE next_points IS NOT NULL;


-- Q14 · CASE aggregation over a view · captaincy report per entry
SELECT e.name,
       sum(lp.points) FILTER (WHERE lp.multiplier = 2)      AS armband_points_doubled,
       count(*) FILTER (WHERE lp.multiplier = 2)            AS armband_weeks,
       sum(CASE WHEN lp.multiplier = 2 AND l.is_vice THEN 1 ELSE 0 END) AS vice_took_over,
       max(lp.points * lp.multiplier)                       AS best_single_haul
FROM v_lineup_points lp
JOIN lineups l USING (entry_id, gw_no, player_code)
JOIN entries e USING (entry_id)
GROUP BY e.name
ORDER BY armband_points_doubled DESC;


-- Q15 · LEFT JOIN on materialized view · points left on the bench
SELECT e.name, l.gw_no,
       sum(COALESCE(g.points, 0)) AS bench_points,
       string_agg(p.web_name || ' ' || COALESCE(g.points, 0), ', ' ORDER BY l.bench_order) AS bench
FROM lineups l
JOIN entries e USING (entry_id)
JOIN players p USING (player_code)
LEFT JOIN mv_player_gw_points g ON g.player_code = l.player_code AND g.season_id = e.season_id AND g.gw_no = l.gw_no
WHERE NOT l.is_starter
GROUP BY e.name, l.gw_no
ORDER BY bench_points DESC
LIMIT 10;


-- Q16 · ROW_NUMBER per group + filter · hindsight dream team of one gameweek (1-3-4-3)
WITH ranked AS (
    SELECT g.player_code, ps.position_id, g.points,
           row_number() OVER (PARTITION BY ps.position_id ORDER BY g.points DESC, g.player_code) AS rn
    FROM mv_player_gw_points g
    JOIN player_seasons ps ON ps.season_id = g.season_id AND ps.player_code = g.player_code
    WHERE g.season_id = fn_current_season() AND g.gw_no = 10                           -- <-- gameweek
)
SELECT pos.code, p.web_name, r.points
FROM ranked r
JOIN positions pos USING (position_id)
JOIN players p USING (player_code)
WHERE r.rn <= CASE pos.code WHEN 'GKP' THEN 1 WHEN 'DEF' THEN 3 WHEN 'MID' THEN 4 ELSE 3 END
ORDER BY r.position_id, r.points DESC;


-- Q17 · FIRST_VALUE / LAST_VALUE with frame · biggest price movers
WITH pr AS (
    SELECT DISTINCT player_code,
           first_value(price) OVER w AS start_price,
           last_value(price)  OVER w AS end_price
    FROM player_gw_prices
    WHERE season_id = fn_current_season()
    WINDOW w AS (PARTITION BY player_code ORDER BY gw_no
                 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
)
SELECT p.web_name, round(pr.start_price / 10.0, 1) AS start_m, round(pr.end_price / 10.0, 1) AS end_m,
       round((pr.end_price - pr.start_price) / 10.0, 1) AS change_m
FROM pr
JOIN players p USING (player_code)
ORDER BY abs(pr.end_price - pr.start_price) DESC, p.web_name
LIMIT 10;


-- Q18 · UNION ALL + CASE · the real Premier League table from fixtures
WITH results AS (
    SELECT home_club AS club_code, home_score AS gf, away_score AS ga FROM fixtures WHERE finished AND season_id = fn_current_season()
    UNION ALL
    SELECT away_club, away_score, home_score FROM fixtures WHERE finished AND season_id = fn_current_season()
)
SELECT rank() OVER (ORDER BY sum(CASE WHEN gf > ga THEN 3 WHEN gf = ga THEN 1 ELSE 0 END) DESC,
                             sum(gf - ga) DESC, sum(gf) DESC) AS pos,
       c.short_name,
       count(*)                                        AS played,
       count(*) FILTER (WHERE gf > ga)                 AS won,
       count(*) FILTER (WHERE gf = ga)                 AS drawn,
       count(*) FILTER (WHERE gf < ga)                 AS lost,
       sum(gf) AS gf, sum(ga) AS ga, sum(gf - ga)      AS gd,
       sum(CASE WHEN gf > ga THEN 3 WHEN gf = ga THEN 1 ELSE 0 END) AS pts
FROM results r
JOIN clubs c USING (club_code)
GROUP BY c.short_name
ORDER BY pos;


-- Q19 · jsonb on audit_log · captaincy changes of one entry reconstructed from the log
SELECT a.game_time, a.op, (a.new_row ->> 'gw_no')::int AS gw_no,
       p_old.web_name AS was_captain, p_new.web_name AS now_captain
FROM audit_log a
LEFT JOIN players p_old ON p_old.player_code = (a.old_row ->> 'player_code')::int AND (a.old_row ->> 'is_captain')::boolean
LEFT JOIN players p_new ON p_new.player_code = (a.new_row ->> 'player_code')::int AND (a.new_row ->> 'is_captain')::boolean
WHERE a.table_name = 'lineups'
  AND (a.new_row ->> 'entry_id')::int = 1                                              -- <-- entry
  AND (a.new_row ->> 'is_captain')::boolean IS DISTINCT FROM (a.old_row ->> 'is_captain')::boolean
  AND ((a.new_row ->> 'is_captain')::boolean OR (a.old_row ->> 'is_captain')::boolean)
ORDER BY a.log_id
LIMIT 20;


-- Q20 · jsonb containment @> (GIN) · mid-season club changes straight from the raw feed
SELECT s.payload ->> 'name' AS player,
       string_agg(DISTINCT s.payload ->> 'team', ' -> ') AS clubs
FROM stg_raw s
WHERE s.kind = 'gw_stats' AND s.payload @> '{"was_home": "True"}'   -- home games only, hits the GIN index
GROUP BY s.payload ->> 'element', s.payload ->> 'name'
HAVING count(DISTINCT s.payload ->> 'team') > 1
ORDER BY player;


-- Q21 · DISTINCT ON · every club's top scorer
SELECT DISTINCT ON (c.short_name)
       c.short_name, p.web_name, sum(pf.points) AS points
FROM v_player_fixture_points pf
JOIN clubs c USING (club_code)
JOIN players p USING (player_code)
WHERE pf.season_id = fn_current_season()
GROUP BY c.short_name, p.web_name
ORDER BY c.short_name, points DESC;


-- Q22 · EXCEPT · squad churn: gameweek-1 players gone by gameweek 38
SELECT e.name, p.web_name
FROM entries e
JOIN LATERAL (
    SELECT player_code FROM fn_squad_at(e.entry_id, e.created_gw)
    EXCEPT
    SELECT player_code FROM fn_squad_at(e.entry_id, 38)
) gone ON true
JOIN players p USING (player_code)
ORDER BY e.name, p.web_name;


-- Q23 · DENSE_RANK over a materialized view · mini-league table at a gameweek
SELECT ml.name AS league, e.name AS entry, st.total_points,
       dense_rank() OVER (PARTITION BY ml.league_id ORDER BY st.total_points DESC) AS pos
FROM mini_leagues ml
JOIN mini_members mm USING (league_id)
JOIN entries e USING (entry_id)
JOIN mv_standings st ON st.entry_id = e.entry_id AND st.gw_no = 38                     -- <-- gameweek
ORDER BY ml.name, pos;


-- Q24 · bool_and / bool_or · players who never blanked (2+ points every time they played)
SELECT p.web_name, count(*) AS appearances, min(pf.points) AS worst, round(avg(pf.points), 2) AS avg_points
FROM v_player_fixture_points pf
JOIN players p USING (player_code)
WHERE pf.season_id = fn_current_season() AND pf.minutes > 0
GROUP BY p.web_name
HAVING bool_and(pf.points >= 2) AND count(*) >= 20
ORDER BY avg_points DESC;


-- Q25 · EXPLAIN-friendly index check · who owns a player right now (partial index idx_slots_current)
SELECT e.name, round(s.purchase_price / 10.0, 1) AS bought_at_m
FROM squad_slots s
JOIN entries e USING (entry_id)
WHERE s.player_code = (SELECT player_code FROM players WHERE web_name = 'Haaland')  -- <-- player
  AND s.to_gw IS NULL;
