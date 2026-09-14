-- stg_raw -> reference tables; idempotent, re-run after every fetch

-- '' and missing keys become 0 (older seasons lack some stats)
CREATE OR REPLACE FUNCTION stg_int(p jsonb, k text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(NULLIF(p->>k, '')::integer, 0) $$;

CREATE OR REPLACE FUNCTION stg_num(p jsonb, k text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE(NULLIF(p->>k, '')::numeric, 0) $$;


CREATE OR REPLACE PROCEDURE load_season(p_season text)
LANGUAGE plpgsql AS $$
DECLARE
    v_season  smallint;
    v_source  source_kind;
    n         bigint;
BEGIN
    SELECT source INTO v_source
    FROM stg_raw WHERE season_name = p_season LIMIT 1;
    IF v_source IS NULL THEN
        RAISE EXCEPTION 'no staged rows for season %', p_season;
    END IF;
    ANALYZE stg_raw;   -- fresh COPY has no stats; without this the joins below take 30x longer

    INSERT INTO seasons (name, source) VALUES (p_season, v_source)
    ON CONFLICT (name) DO UPDATE SET source = EXCLUDED.source, loaded_at = now()
    RETURNING season_id INTO v_season;

    -- clubs
    INSERT INTO clubs (club_code, name, short_name)
    SELECT (payload->>'code')::int, payload->>'name', payload->>'short_name'
    FROM stg_raw WHERE season_name = p_season AND kind = 'teams'
    ON CONFLICT (club_code) DO UPDATE
        SET name = EXCLUDED.name, short_name = EXCLUDED.short_name;

    INSERT INTO club_seasons (season_id, club_code, fpl_team_id)
    SELECT v_season, (payload->>'code')::int, (payload->>'id')::smallint
    FROM stg_raw WHERE season_name = p_season AND kind = 'teams'
    ON CONFLICT (season_id, club_code) DO UPDATE SET fpl_team_id = EXCLUDED.fpl_team_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'clubs          %', n;

    -- players (element_type 5 = assistant manager chip, not a player)
    INSERT INTO players (player_code, first_name, second_name, web_name)
    SELECT DISTINCT ON (1)
           (payload->>'code')::int, payload->>'first_name', payload->>'second_name', payload->>'web_name'
    FROM stg_raw WHERE season_name = p_season AND kind = 'players'
      AND (payload->>'element_type')::int BETWEEN 1 AND 4
    ON CONFLICT (player_code) DO UPDATE
        SET first_name = EXCLUDED.first_name, second_name = EXCLUDED.second_name, web_name = EXCLUDED.web_name;

    INSERT INTO player_seasons (season_id, player_code, fpl_element_id, position_id, club_code_start)
    SELECT DISTINCT ON (2)
           v_season, (payload->>'code')::int, (payload->>'id')::smallint,
           (payload->>'element_type')::smallint, (payload->>'team_code')::int
    FROM stg_raw WHERE season_name = p_season AND kind = 'players'
      AND (payload->>'element_type')::int BETWEEN 1 AND 4
    ON CONFLICT (season_id, player_code) DO UPDATE
        SET fpl_element_id = EXCLUDED.fpl_element_id, position_id = EXCLUDED.position_id,
            club_code_start = EXCLUDED.club_code_start;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'players        %', n;

    -- gameweeks: api ships deadlines, csv does not (FPL rule: 90 min before first kickoff)
    -- gameweeks.finished is game state driven by advance_gameweek(), never overwritten here
    IF EXISTS (SELECT 1 FROM stg_raw WHERE season_name = p_season AND kind = 'events') THEN
        INSERT INTO gameweeks (season_id, gw_no, deadline_time)
        SELECT v_season, (payload->>'id')::smallint, (payload->>'deadline_time')::timestamptz
        FROM stg_raw WHERE season_name = p_season AND kind = 'events'
        ON CONFLICT (season_id, gw_no) DO UPDATE SET deadline_time = EXCLUDED.deadline_time;
    ELSE
        INSERT INTO gameweeks (season_id, gw_no, deadline_time)
        SELECT v_season, (payload->>'event')::smallint,
               min((payload->>'kickoff_time')::timestamptz) - interval '90 minutes'
        FROM stg_raw WHERE season_name = p_season AND kind = 'fixtures'
          AND NULLIF(payload->>'event', '') IS NOT NULL
        GROUP BY 2
        ON CONFLICT (season_id, gw_no) DO UPDATE SET deadline_time = EXCLUDED.deadline_time;
    END IF;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'gameweeks      %', n;

    -- fixtures (unscheduled ones have no event yet and are skipped)
    INSERT INTO fixtures (season_id, gw_no, fpl_fixture_id, kickoff_time,
                          home_club, away_club, home_score, away_score, finished)
    SELECT v_season, (p->>'event')::smallint, (p->>'id')::int, (p->>'kickoff_time')::timestamptz,
           h.club_code, a.club_code,
           NULLIF(p->>'team_h_score', '')::smallint, NULLIF(p->>'team_a_score', '')::smallint,
           (p->>'finished')::boolean
    FROM (SELECT payload AS p FROM stg_raw WHERE season_name = p_season AND kind = 'fixtures') s
    JOIN club_seasons h ON h.season_id = v_season AND h.fpl_team_id = (p->>'team_h')::smallint
    JOIN club_seasons a ON a.season_id = v_season AND a.fpl_team_id = (p->>'team_a')::smallint
    WHERE NULLIF(p->>'event', '') IS NOT NULL AND NULLIF(p->>'kickoff_time', '') IS NOT NULL
    ON CONFLICT (season_id, fpl_fixture_id) DO UPDATE
        SET gw_no = EXCLUDED.gw_no, kickoff_time = EXCLUDED.kickoff_time,
            home_score = EXCLUDED.home_score, away_score = EXCLUDED.away_score,
            finished = EXCLUDED.finished;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'fixtures       %', n;

    -- player x fixture stats; club derived from fixture side, so mid-season moves are correct
    INSERT INTO player_fixture_stats (
        player_code, fixture_id, club_code, minutes, starts, goals_scored, assists, clean_sheets,
        goals_conceded, own_goals, penalties_saved, penalties_missed, yellow_cards, red_cards,
        saves, bonus, bps, defensive_contribution, expected_goals, expected_assists,
        expected_goal_involvements, expected_goals_conceded, ict_index, official_points)
    SELECT DISTINCT ON (ps.player_code, f.fixture_id)
           ps.player_code, f.fixture_id,
           CASE WHEN (p->>'was_home')::boolean THEN f.home_club ELSE f.away_club END,
           stg_int(p, 'minutes'), stg_int(p, 'starts'), stg_int(p, 'goals_scored'), stg_int(p, 'assists'),
           stg_int(p, 'clean_sheets'), stg_int(p, 'goals_conceded'), stg_int(p, 'own_goals'),
           stg_int(p, 'penalties_saved'), stg_int(p, 'penalties_missed'), stg_int(p, 'yellow_cards'),
           stg_int(p, 'red_cards'), stg_int(p, 'saves'), stg_int(p, 'bonus'), stg_int(p, 'bps'),
           stg_int(p, 'defensive_contribution'), stg_num(p, 'expected_goals'), stg_num(p, 'expected_assists'),
           stg_num(p, 'expected_goal_involvements'), stg_num(p, 'expected_goals_conceded'),
           stg_num(p, 'ict_index'), stg_int(p, 'total_points')
    FROM (SELECT payload AS p FROM stg_raw WHERE season_name = p_season AND kind = 'gw_stats') s
    JOIN player_seasons ps ON ps.season_id = v_season AND ps.fpl_element_id = (p->>'element')::smallint
    JOIN fixtures f        ON f.season_id = v_season AND f.fpl_fixture_id = (p->>'fixture')::int
    ON CONFLICT (player_code, fixture_id) DO UPDATE
        SET club_code = EXCLUDED.club_code, minutes = EXCLUDED.minutes, starts = EXCLUDED.starts,
            goals_scored = EXCLUDED.goals_scored, assists = EXCLUDED.assists,
            clean_sheets = EXCLUDED.clean_sheets, goals_conceded = EXCLUDED.goals_conceded,
            own_goals = EXCLUDED.own_goals, penalties_saved = EXCLUDED.penalties_saved,
            penalties_missed = EXCLUDED.penalties_missed, yellow_cards = EXCLUDED.yellow_cards,
            red_cards = EXCLUDED.red_cards, saves = EXCLUDED.saves, bonus = EXCLUDED.bonus,
            bps = EXCLUDED.bps, defensive_contribution = EXCLUDED.defensive_contribution,
            expected_goals = EXCLUDED.expected_goals, expected_assists = EXCLUDED.expected_assists,
            expected_goal_involvements = EXCLUDED.expected_goal_involvements,
            expected_goals_conceded = EXCLUDED.expected_goals_conceded,
            ict_index = EXCLUDED.ict_index, official_points = EXCLUDED.official_points;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'fixture stats  %', n;

    -- one price per player per gameweek (double gameweeks repeat it)
    INSERT INTO player_gw_prices (season_id, gw_no, player_code, price, selected_by, transfers_in, transfers_out)
    SELECT DISTINCT ON (ps.player_code, (p->>'round')::smallint)
           v_season, (p->>'round')::smallint, ps.player_code,
           stg_int(p, 'value'), stg_int(p, 'selected'), stg_int(p, 'transfers_in'), stg_int(p, 'transfers_out')
    FROM (SELECT payload AS p FROM stg_raw WHERE season_name = p_season AND kind = 'gw_stats') s
    JOIN player_seasons ps ON ps.season_id = v_season AND ps.fpl_element_id = (p->>'element')::smallint
    ON CONFLICT (season_id, gw_no, player_code) DO UPDATE
        SET price = EXCLUDED.price, selected_by = EXCLUDED.selected_by,
            transfers_in = EXCLUDED.transfers_in, transfers_out = EXCLUDED.transfers_out;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'prices         %', n;

    -- api only: history has prices for played gameweeks; the upcoming one gets today's now_cost
    INSERT INTO player_gw_prices (season_id, gw_no, player_code, price)
    SELECT v_season, ev.gw_no, (pl.payload->>'code')::int, (pl.payload->>'now_cost')::smallint
    FROM stg_raw pl
    CROSS JOIN (SELECT (payload->>'id')::smallint AS gw_no FROM stg_raw
                WHERE season_name = p_season AND kind = 'events' AND (payload->>'is_next')::boolean LIMIT 1) ev
    WHERE pl.season_name = p_season AND pl.kind = 'players'
      AND (pl.payload->>'element_type')::int BETWEEN 1 AND 4
    ON CONFLICT (season_id, gw_no, player_code) DO UPDATE SET price = EXCLUDED.price;
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n > 0 THEN RAISE NOTICE 'current prices %', n; END IF;

    INSERT INTO app_settings (key, value) VALUES ('current_season', v_season::text)
    ON CONFLICT (key) DO NOTHING;

    ANALYZE players, player_seasons, fixtures, player_fixture_stats, player_gw_prices;
    REFRESH MATERIALIZED VIEW mv_player_gw_points;
END;
$$;
