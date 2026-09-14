-- run: psql -d fpl -v ON_ERROR_STOP=1 -f tests/test_all.sql
-- everything happens inside one transaction and is rolled back; game data in the db is untouched

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

BEGIN;

CREATE TEMP TABLE t_results (line text);

-- record a boolean check
CREATE FUNCTION pg_temp.check(p_name text, p_ok boolean) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text := CASE WHEN p_ok THEN 'PASS ' ELSE 'FAIL ' END || p_name;
BEGIN
    INSERT INTO t_results VALUES (v);
    RETURN v;
END $$;

-- run sql that must fail with a message containing p_fragment; deferred triggers are forced immediately
CREATE FUNCTION pg_temp.expect_error(p_name text, p_sql text, p_fragment text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    SET CONSTRAINTS ALL IMMEDIATE;
    RETURN pg_temp.check(p_name || ' (no error raised)', false);
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%' || p_fragment || '%' THEN
        RETURN pg_temp.check(p_name, true);
    END IF;
    RETURN pg_temp.check(p_name || ' (got: ' || SQLERRM || ')', false);
END $$;

-- greedy legal squad: GK,DEF*4,MID*4,FWD*2 start; GK,DEF,MID,FWD bench; p_skip varies the pick
CREATE FUNCTION pg_temp.pick_squad(p_skip integer DEFAULT 0) RETURNS integer[]
LANGUAGE plpgsql AS $$
DECLARE
    r record; gk int[] := '{}'; df int[] := '{}'; md int[] := '{}'; fw int[] := '{}';
    clubs jsonb := '{}'; cnt int; c text;
BEGIN
    FOR r IN
        SELECT ps.player_code, ps.position_id, ps.club_code_start AS club
        FROM player_seasons ps
        JOIN player_gw_prices pr ON pr.season_id = ps.season_id AND pr.player_code = ps.player_code AND pr.gw_no = 1
        WHERE ps.season_id = fn_current_season()
        ORDER BY pr.price, ps.player_code
        OFFSET p_skip
    LOOP
        c := r.club::text; cnt := COALESCE((clubs ->> c)::int, 0);
        IF cnt >= 3 THEN CONTINUE; END IF;
        IF    r.position_id = 1 AND cardinality(gk) < 2 THEN gk := gk || r.player_code;
        ELSIF r.position_id = 2 AND cardinality(df) < 5 THEN df := df || r.player_code;
        ELSIF r.position_id = 3 AND cardinality(md) < 5 THEN md := md || r.player_code;
        ELSIF r.position_id = 4 AND cardinality(fw) < 3 THEN fw := fw || r.player_code;
        ELSE CONTINUE; END IF;
        clubs := clubs || jsonb_build_object(c, cnt + 1);
        EXIT WHEN cardinality(gk) + cardinality(df) + cardinality(md) + cardinality(fw) = 15;
    END LOOP;
    RETURN ARRAY[gk[1]] || df[1:4] || md[1:4] || fw[1:2] || ARRAY[gk[2], df[5], md[5], fw[3]];
END $$;

-- carol makes one transfer a week from gameweek 3 to the end; everyone else sits still
CREATE FUNCTION pg_temp.play_season(p_carol integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    FOR gw IN 3..38 LOOP
        PERFORM pg_temp.transfer(p_carol, gw, 3, 1);
        CALL advance_gameweek();
    END LOOP;
END $$;

-- n same-position transfers: sell the priciest, buy the cheapest legal replacement
CREATE FUNCTION pg_temp.transfer(p_entry integer, p_gw integer, p_position integer, p_n integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_out int; v_in int;
BEGIN
    FOR i IN 1..p_n LOOP
        SELECT sq.player_code INTO v_out
        FROM fn_squad_at(p_entry, p_gw) sq
        JOIN player_seasons ps ON ps.season_id = fn_current_season() AND ps.player_code = sq.player_code
        WHERE ps.position_id = p_position
        ORDER BY sq.purchase_price DESC, sq.player_code LIMIT 1;

        SELECT pr.player_code INTO v_in
        FROM player_gw_prices pr
        JOIN player_seasons ps USING (season_id, player_code)
        WHERE pr.season_id = fn_current_season() AND pr.gw_no = p_gw AND ps.position_id = p_position
          AND pr.player_code NOT IN (SELECT player_code FROM fn_squad_at(p_entry, p_gw))
          AND fn_club_at(pr.season_id, pr.player_code, p_gw) NOT IN
              (SELECT fn_club_at(fn_current_season(), player_code, p_gw) FROM fn_squad_at(p_entry, p_gw))
        ORDER BY pr.price, pr.player_code LIMIT 1;

        INSERT INTO transfers (entry_id, gw_no, player_out, player_in) VALUES (p_entry, p_gw, v_out, v_in);
    END LOOP;
END $$;


\echo
\echo '== 1. scoring against official FPL points'
SELECT pg_temp.check('every player-fixture row matches official points',
    (SELECT count(*) = 0 FROM v_player_fixture_points WHERE points <> official_points));
SELECT pg_temp.check('a full season is loaded (20000+ rows)',
    (SELECT count(*) > 20000 FROM v_player_fixture_points));
SELECT pg_temp.check('per-gameweek totals match too',
    (SELECT count(*) = 0 FROM mv_player_gw_points WHERE points <> official_points));


\echo
\echo '== 2. game setup'
CALL reset_game();
CALL start_replay();
SELECT pg_temp.check('replay clock starts one day before deadline 1',
    (SELECT fn_now() = deadline_time - interval '1 day' FROM gameweeks WHERE season_id = fn_current_season() AND gw_no = 1));
SELECT pg_temp.check('current gameweek is 1', fn_current_gw() = 1);

SELECT create_entry('alice', 'Alice FC',   sq, sq[10], sq[6]) FROM pg_temp.pick_squad(0)  sq \gset alice_
SELECT create_entry('bob',   'Bob United', sq, sq[10], sq[6]) FROM pg_temp.pick_squad(40) sq \gset bob_
SELECT create_entry('carol', 'Carol City', sq, sq[10], sq[6]) FROM pg_temp.pick_squad(80) sq \gset carol_

SELECT pg_temp.check('three entries created', (SELECT count(*) = 3 FROM entries));
SELECT pg_temp.check('every squad passes fn_squad_error',
    (SELECT bool_and(fn_squad_error(entry_id, 1) IS NULL) FROM entries));
SELECT pg_temp.check('every lineup passes fn_lineup_error',
    (SELECT bool_and(fn_lineup_error(entry_id, 1) IS NULL) FROM entries));
SELECT pg_temp.check('squads cost at most the budget',
    (SELECT bool_and((SELECT sum(purchase_price) FROM fn_squad_at(e.entry_id, 1)) <= e.budget) FROM entries e));


\echo
\echo '== 3. rules the database must reject'
SELECT pg_temp.expect_error('lineup for a locked gameweek',
    format('INSERT INTO lineups VALUES (%s, 5, (SELECT player_code FROM fn_squad_at(%s, 1) LIMIT 1), true, false, false, NULL)', :alice_create_entry, :alice_create_entry),
    'locked');

SELECT pg_temp.expect_error('deleting a lineup row leaves 14',
    format('DELETE FROM lineups WHERE entry_id = %s AND gw_no = 1 AND is_captain', :alice_create_entry),
    '14 players');

SELECT pg_temp.expect_error('no captain',
    format('UPDATE lineups SET is_captain = false WHERE entry_id = %s AND gw_no = 1 AND is_captain', :alice_create_entry),
    '0 captains');

SELECT pg_temp.expect_error('two captains',
    format('UPDATE lineups SET is_captain = true, is_vice = false WHERE entry_id = %s AND gw_no = 1 AND is_vice', :alice_create_entry),
    'uq_lineups_captain');

SELECT pg_temp.expect_error('two goalkeepers on the pitch',
    format($q$
        DO $d$ DECLARE v_gk int; v_slot int; v_def int; BEGIN
            SELECT l.player_code, l.bench_order INTO v_gk, v_slot
            FROM lineups l JOIN player_seasons ps ON ps.season_id = fn_current_season() AND ps.player_code = l.player_code
            WHERE l.entry_id = %1$s AND l.gw_no = 1 AND NOT l.is_starter AND ps.position_id = 1;
            SELECT min(l.player_code) INTO v_def
            FROM lineups l JOIN player_seasons ps ON ps.season_id = fn_current_season() AND ps.player_code = l.player_code
            WHERE l.entry_id = %1$s AND l.gw_no = 1 AND l.is_starter AND ps.position_id = 2 AND NOT l.is_captain AND NOT l.is_vice;
            UPDATE lineups SET is_starter = true,  bench_order = NULL   WHERE entry_id = %1$s AND gw_no = 1 AND player_code = v_gk;
            UPDATE lineups SET is_starter = false, bench_order = v_slot WHERE entry_id = %1$s AND gw_no = 1 AND player_code = v_def;
        END $d$
    $q$, :alice_create_entry),
    'GKP=2');

SELECT pg_temp.expect_error('lineup with a player outside the squad',
    format('INSERT INTO lineups VALUES (%s, 1, (SELECT min(player_code) FROM player_seasons WHERE player_code NOT IN (SELECT player_code FROM fn_squad_at(%s, 1))), true, false, false, NULL)', :alice_create_entry, :alice_create_entry),
    'not in the squad');

SELECT pg_temp.expect_error('transfer out a player you do not own',
    format('INSERT INTO transfers (entry_id, gw_no, player_out, player_in) VALUES (%s, 1, 999999, 1)', :alice_create_entry),
    'not in the squad');

SELECT pg_temp.expect_error('transfer that changes position',
    format($q$INSERT INTO transfers (entry_id, gw_no, player_out, player_in)
        SELECT %s, 1, sq.player_code,
               (SELECT min(player_code) FROM player_seasons WHERE season_id = fn_current_season() AND position_id = 4
                 AND player_code NOT IN (SELECT player_code FROM fn_squad_at(%s, 1)))
        FROM fn_squad_at(%s, 1) sq JOIN player_seasons ps ON ps.season_id = fn_current_season() AND ps.player_code = sq.player_code
        WHERE ps.position_id = 2 LIMIT 1$q$, :alice_create_entry, :alice_create_entry, :alice_create_entry),
    'keep the position');

SELECT pg_temp.expect_error('transfer that breaks the budget',
    format('UPDATE entries SET budget = 600 WHERE entry_id = %s; SELECT pg_temp.transfer(%s, 1, 2, 1)', :alice_create_entry, :alice_create_entry),
    'budget');

SELECT pg_temp.expect_error('fourth player from one club',
    format($q$
        DO $d$ DECLARE sq int[] := pg_temp.pick_squad(0); ars int[]; BEGIN
            SELECT array_agg(player_code) INTO ars FROM (
                SELECT ps.player_code FROM player_seasons ps
                JOIN player_gw_prices pr ON pr.season_id = ps.season_id AND pr.player_code = ps.player_code AND pr.gw_no = 1
                WHERE ps.season_id = fn_current_season() AND ps.position_id = 2 AND ps.club_code_start = 3 AND ps.player_code <> ALL (sq)
                ORDER BY pr.price LIMIT 4) x;
            sq[2:5] := ars;
            PERFORM create_entry('dave', 'Dave Rovers', sq, sq[10], sq[6]);
        END $d$$q$),
    'more than 3 players');

SELECT pg_temp.expect_error('create_entry with 16 players',
    format('SELECT create_entry(''erin'', ''Erin Town'', pg_temp.pick_squad(0) || ARRAY[1], 1, 2)'),
    'needs 15');

SELECT pg_temp.expect_error('removing a squad slot leaves 14',
    format('DELETE FROM squad_slots WHERE slot_id = (SELECT min(slot_id) FROM squad_slots WHERE entry_id = %s)', :alice_create_entry),
    '14 players');

SELECT pg_temp.expect_error('rewriting squad history',
    format('UPDATE squad_slots SET purchase_price = 1 WHERE entry_id = %s', :alice_create_entry),
    'only to_gw');

SELECT pg_temp.check('nothing leaked from the rejected statements',
    (SELECT count(*) = 3 FROM entries) AND (SELECT count(*) = 0 FROM transfers) AND (SELECT count(*) = 45 FROM squad_slots));


\echo
\echo '== 4. transfers, penalties and free transfer rollover'
SELECT pg_temp.transfer(:alice_create_entry, 1, 2, 1);       -- joining gameweek: unlimited free transfers
CALL advance_gameweek();
SELECT pg_temp.check('joining-week transfer carries no penalty',
    (SELECT penalty_points = 0 FROM entry_gw_state WHERE entry_id = :alice_create_entry AND gw_no = 1));
SELECT pg_temp.check('gameweek 2 is current after advance', fn_current_gw() = 2);
SELECT pg_temp.check('lineups copied to gameweek 2', (SELECT count(*) = 45 FROM lineups WHERE gw_no = 2));

SELECT pg_temp.transfer(:alice_create_entry, 2, 3, 3);       -- 3 transfers, 1 free
CALL advance_gameweek();
SELECT pg_temp.check('3 transfers with 1 free = 8 point hit',
    (SELECT penalty_points = 8 AND transfers_made = 3 FROM entry_gw_state WHERE entry_id = :alice_create_entry AND gw_no = 2));
SELECT pg_temp.check('hit shows in v_entry_gw_points',
    (SELECT points = raw_points - 8 FROM v_entry_gw_points WHERE entry_id = :alice_create_entry AND gw_no = 2));
SELECT pg_temp.check('free transfers reset to 1 after a hit',
    (SELECT free_transfers_start = 1 FROM entry_gw_state WHERE entry_id = :alice_create_entry AND gw_no = 3));
SELECT pg_temp.check('transfer history: 3 closed slots, 3 opened in gameweek 2',
    (SELECT count(*) FILTER (WHERE to_gw = 2) = 3 AND count(*) FILTER (WHERE from_gw = 2) = 3 FROM squad_slots WHERE entry_id = :alice_create_entry));
SELECT pg_temp.check('transfer prices were filled by the trigger',
    (SELECT bool_and(price_in > 0 AND price_out > 0 AND made_at < g.deadline_time) FROM transfers t JOIN gameweeks g ON g.season_id = fn_current_season() AND g.gw_no = t.gw_no WHERE t.gw_no = 2));
SELECT pg_temp.expect_error('transfers are immutable', 'DELETE FROM transfers', 'cannot be changed');

-- carol: one free transfer every week from gameweek 3; bob: never transfers
SELECT pg_temp.play_season(:carol_create_entry);

SELECT pg_temp.check('season is over: no current gameweek', fn_current_gw() IS NULL);
SELECT pg_temp.check('idle entry accumulates 5 free transfers and stops there',
    (SELECT max(free_transfers_start) = 5 AND (SELECT free_transfers_start FROM entry_gw_state WHERE entry_id = :bob_create_entry AND gw_no = 38) = 5
     FROM entry_gw_state WHERE entry_id = :bob_create_entry));
SELECT pg_temp.check('one transfer a week never costs points',
    (SELECT bool_and(penalty_points = 0) AND sum(transfers_made) = 36 FROM entry_gw_state WHERE entry_id = :carol_create_entry));
SELECT pg_temp.expect_error('no entries after the season', 'SELECT create_entry(''late'', ''Late FC'', pg_temp.pick_squad(0), 1, 2)', 'is over');
SELECT pg_temp.expect_error('no advance after the season', 'CALL advance_gameweek()', 'is over');


\echo
\echo '== 5. season totals'
SELECT pg_temp.check('38 state rows per entry', (SELECT count(*) = 3 * 38 FROM entry_gw_state));
SELECT pg_temp.check('15 lineup rows per entry per gameweek', (SELECT count(*) = 3 * 38 * 15 FROM lineups));
SELECT pg_temp.check('standings cover every entry and gameweek', (SELECT count(*) = 3 * 38 FROM mv_standings));
SELECT pg_temp.check('standings total equals the sum of weekly points',
    (SELECT bool_and(s.total_points = w.total) FROM mv_standings s
     JOIN (SELECT entry_id, sum(points) AS total FROM v_entry_gw_points GROUP BY entry_id) w USING (entry_id)
     WHERE s.gw_no = 38));
SELECT pg_temp.check('ranks in the final table are 1, 2, 3',
    (SELECT array_agg(rank ORDER BY rank) = ARRAY[1, 2, 3]::bigint[] FROM mv_standings WHERE gw_no = 38));
SELECT pg_temp.check('every squad is legal in every gameweek',
    (SELECT bool_and(fn_squad_error(e.entry_id, g.gw_no) IS NULL) FROM entries e CROSS JOIN generate_series(1, 38) g(gw_no)));
SELECT pg_temp.check('audit log covers all four game tables',
    (SELECT count(DISTINCT table_name) = 4 FROM audit_log));


\echo
\echo '== summary'
SELECT count(*) FILTER (WHERE line LIKE 'PASS%') || ' passed, ' || count(*) FILTER (WHERE line LIKE 'FAIL%') || ' failed' FROM t_results;
SELECT line FROM t_results WHERE line LIKE 'FAIL%';

DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM t_results WHERE line LIKE 'FAIL%') THEN
        RAISE EXCEPTION 'tests failed';
    END IF;
END $$;

ROLLBACK;
