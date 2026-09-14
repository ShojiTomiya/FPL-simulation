-- scoring chain: fixture -> gameweek -> lineup -> entry -> standings
-- re-runnable: materialized views are dropped first (CASCADE takes the plain views with them)

DROP MATERIALIZED VIEW IF EXISTS mv_standings;
DROP MATERIALIZED VIEW IF EXISTS mv_player_gw_points CASCADE;

-- 1. points of one player in one fixture, rule by rule
CREATE OR REPLACE VIEW v_player_fixture_points AS
WITH base AS (
    SELECT s.*, f.season_id, f.gw_no, ps.position_id
    FROM player_fixture_stats s
    JOIN fixtures f USING (fixture_id)
    JOIN player_seasons ps ON ps.season_id = f.season_id AND ps.player_code = s.player_code
),
unpivot AS (
    SELECT b.player_code, b.fixture_id, b.position_id, v.stat, v.value
    FROM base b
    CROSS JOIN LATERAL (VALUES
        ('minutes',                b.minutes),
        ('goals_scored',           b.goals_scored),
        ('assists',                b.assists),
        ('clean_sheets',           b.clean_sheets),
        ('goals_conceded',         b.goals_conceded),
        ('saves',                  b.saves),
        ('penalties_saved',        b.penalties_saved),
        ('penalties_missed',       b.penalties_missed),
        ('yellow_cards',           b.yellow_cards),
        ('red_cards',              b.red_cards),
        ('own_goals',              b.own_goals),
        ('bonus',                  b.bonus),
        ('defensive_contribution', b.defensive_contribution)
    ) AS v(stat, value)
),
scored AS (
    SELECT u.player_code, u.fixture_id, u.stat,
           r.points * LEAST(COALESCE(r.cap, 32767), u.value / r.per_units) AS pts
    FROM unpivot u
    JOIN scoring_rules r
      ON r.stat = u.stat
     AND (r.position_id IS NULL OR r.position_id = u.position_id)
     AND u.value >= r.min_value
),
agg AS (
    SELECT player_code, fixture_id,
           sum(pts)                                                          AS points,
           sum(pts) FILTER (WHERE stat = 'minutes')                          AS pts_appearance,
           sum(pts) FILTER (WHERE stat = 'goals_scored')                     AS pts_goals,
           sum(pts) FILTER (WHERE stat = 'assists')                          AS pts_assists,
           sum(pts) FILTER (WHERE stat = 'clean_sheets')                     AS pts_clean_sheet,
           sum(pts) FILTER (WHERE stat = 'goals_conceded')                   AS pts_conceded,
           sum(pts) FILTER (WHERE stat = 'saves')                            AS pts_saves,
           sum(pts) FILTER (WHERE stat IN ('penalties_saved','penalties_missed')) AS pts_penalties,
           sum(pts) FILTER (WHERE stat IN ('yellow_cards','red_cards'))      AS pts_cards,
           sum(pts) FILTER (WHERE stat = 'own_goals')                        AS pts_own_goals,
           sum(pts) FILTER (WHERE stat = 'bonus')                            AS pts_bonus,
           sum(pts) FILTER (WHERE stat = 'defensive_contribution')           AS pts_defcon
    FROM scored
    GROUP BY player_code, fixture_id
)
SELECT b.player_code, b.fixture_id, b.season_id, b.gw_no, b.position_id, b.club_code, b.minutes,
       COALESCE(a.points, 0)::smallint AS points,
       b.official_points,
       COALESCE(a.pts_appearance, 0)::smallint  AS pts_appearance,
       COALESCE(a.pts_goals, 0)::smallint       AS pts_goals,
       COALESCE(a.pts_assists, 0)::smallint     AS pts_assists,
       COALESCE(a.pts_clean_sheet, 0)::smallint AS pts_clean_sheet,
       COALESCE(a.pts_conceded, 0)::smallint    AS pts_conceded,
       COALESCE(a.pts_saves, 0)::smallint       AS pts_saves,
       COALESCE(a.pts_penalties, 0)::smallint   AS pts_penalties,
       COALESCE(a.pts_cards, 0)::smallint       AS pts_cards,
       COALESCE(a.pts_own_goals, 0)::smallint   AS pts_own_goals,
       COALESCE(a.pts_bonus, 0)::smallint       AS pts_bonus,
       COALESCE(a.pts_defcon, 0)::smallint      AS pts_defcon
FROM base b
LEFT JOIN agg a USING (player_code, fixture_id);


-- 2. per gameweek (double gameweeks sum up, blank gameweeks have no row)
--    materialized: player points only change on load, and every game view below reads this
CREATE MATERIALIZED VIEW mv_player_gw_points AS
SELECT player_code, season_id, gw_no,
       count(*)::smallint             AS fixtures,
       sum(minutes)::smallint         AS minutes,
       sum(points)::smallint          AS points,
       sum(official_points)::smallint AS official_points
FROM v_player_fixture_points
GROUP BY player_code, season_id, gw_no;

CREATE UNIQUE INDEX uq_player_gw_points ON mv_player_gw_points (player_code, season_id, gw_no);


-- 3. starters with their multiplier; armband passes to vice when captain has 0 minutes
CREATE OR REPLACE VIEW v_lineup_points AS
WITH starters AS (
    SELECT l.entry_id, l.gw_no, e.season_id, l.player_code, l.is_captain, l.is_vice,
           COALESCE(p.points, 0)  AS points,
           COALESCE(p.minutes, 0) AS minutes
    FROM lineups l
    JOIN entries e USING (entry_id)
    LEFT JOIN mv_player_gw_points p
           ON p.player_code = l.player_code AND p.season_id = e.season_id AND p.gw_no = l.gw_no
    WHERE l.is_starter
),
armband AS (
    SELECT entry_id, gw_no, bool_or(is_captain AND minutes > 0) AS captain_played
    FROM starters
    GROUP BY entry_id, gw_no
)
SELECT s.entry_id, s.season_id, s.gw_no, s.player_code, s.points, s.minutes,
       CASE WHEN s.is_captain AND a.captain_played     THEN 2
            WHEN s.is_vice    AND NOT a.captain_played THEN 2
            ELSE 1 END AS multiplier
FROM starters s
JOIN armband a USING (entry_id, gw_no);


-- 4. entry total per gameweek, minus transfer penalty
CREATE OR REPLACE VIEW v_entry_gw_points AS
SELECT lp.entry_id, lp.season_id, lp.gw_no,
       sum(lp.points * lp.multiplier)::smallint                            AS raw_points,
       COALESCE(st.penalty_points, 0)                                       AS penalty_points,
       (sum(lp.points * lp.multiplier) - COALESCE(st.penalty_points, 0))::smallint AS points
FROM v_lineup_points lp
LEFT JOIN entry_gw_state st USING (entry_id, gw_no)
GROUP BY lp.entry_id, lp.season_id, lp.gw_no, st.penalty_points;


-- 5. cumulative table; refreshed by advance_gameweek()
CREATE MATERIALIZED VIEW mv_standings AS
WITH cum AS (
    SELECT entry_id, season_id, gw_no, points,
           sum(points) OVER (PARTITION BY entry_id ORDER BY gw_no) AS total_points
    FROM v_entry_gw_points
),
ranked AS (
    SELECT *, rank() OVER (PARTITION BY season_id, gw_no ORDER BY total_points DESC) AS rank
    FROM cum
)
SELECT *,
       lag(rank) OVER (PARTITION BY entry_id ORDER BY gw_no) - rank AS rank_change
FROM ranked;

CREATE UNIQUE INDEX uq_standings ON mv_standings (entry_id, gw_no);   -- required by REFRESH CONCURRENTLY

REFRESH MATERIALIZED VIEW mv_player_gw_points;
