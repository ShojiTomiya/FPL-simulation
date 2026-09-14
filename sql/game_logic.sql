-- game rules: clock, squad/lineup/transfer triggers, entry and gameweek procedures

-- virtual_now set = replay mode; absent = live
CREATE OR REPLACE FUNCTION fn_now() RETURNS timestamptz
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT value::timestamptz FROM app_settings WHERE key = 'virtual_now'), now())
$$;

CREATE OR REPLACE FUNCTION fn_current_season() RETURNS smallint
LANGUAGE sql STABLE AS $$
    SELECT value::smallint FROM app_settings WHERE key = 'current_season'
$$;

-- first gameweek whose deadline is still ahead; NULL once the season is over
CREATE OR REPLACE FUNCTION fn_current_gw(p_season integer DEFAULT fn_current_season()) RETURNS smallint
LANGUAGE sql STABLE AS $$
    SELECT min(gw_no) FROM gameweeks WHERE season_id = p_season AND deadline_time > fn_now()
$$;

CREATE OR REPLACE FUNCTION fn_assert_open(p_season integer, p_gw integer) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cur smallint := fn_current_gw(p_season);
BEGIN
    IF v_cur IS NULL THEN
        RAISE EXCEPTION 'season % is over', p_season USING ERRCODE = 'check_violation';
    END IF;
    IF p_gw <> v_cur THEN
        RAISE EXCEPTION 'gameweek % is locked, current gameweek is % (deadline %)',
            p_gw, v_cur, (SELECT deadline_time FROM gameweeks WHERE season_id = p_season AND gw_no = v_cur)
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$;


CREATE OR REPLACE FUNCTION fn_squad_at(p_entry integer, p_gw integer)
RETURNS TABLE (player_code integer, purchase_price smallint)
LANGUAGE sql STABLE AS $$
    SELECT player_code, purchase_price
    FROM squad_slots
    WHERE entry_id = p_entry AND from_gw <= p_gw AND (to_gw IS NULL OR to_gw > p_gw)
$$;

-- last known price on or before the gameweek (blank gameweeks have no price row)
CREATE OR REPLACE FUNCTION fn_price_at(p_season integer, p_player integer, p_gw integer) RETURNS smallint
LANGUAGE sql STABLE AS $$
    SELECT price FROM player_gw_prices
    WHERE season_id = p_season AND player_code = p_player AND gw_no <= p_gw
    ORDER BY gw_no DESC LIMIT 1
$$;

-- club the player represents from this gameweek on (next fixture, else last, else season start)
CREATE OR REPLACE FUNCTION fn_club_at(p_season integer, p_player integer, p_gw integer) RETURNS integer
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT s.club_code FROM player_fixture_stats s JOIN fixtures f USING (fixture_id)
         WHERE s.player_code = p_player AND f.season_id = p_season AND f.gw_no >= p_gw
         ORDER BY f.gw_no LIMIT 1),
        (SELECT s.club_code FROM player_fixture_stats s JOIN fixtures f USING (fixture_id)
         WHERE s.player_code = p_player AND f.season_id = p_season AND f.gw_no < p_gw
         ORDER BY f.gw_no DESC LIMIT 1),
        (SELECT club_code_start FROM player_seasons WHERE season_id = p_season AND player_code = p_player))
$$;


CREATE OR REPLACE FUNCTION fn_squad_error(p_entry integer, p_gw integer) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_season smallint;
    v_budget smallint;
    v_total  integer;
    v_spent  integer;
    v_bad    text;
BEGIN
    SELECT season_id, budget INTO v_season, v_budget FROM entries WHERE entry_id = p_entry;

    SELECT count(*), COALESCE(sum(purchase_price), 0)
    INTO v_total, v_spent
    FROM fn_squad_at(p_entry, p_gw);

    IF v_total = 0 THEN RETURN NULL; END IF;   -- no squad yet
    IF v_total <> 15 THEN
        RETURN format('squad has %s players, needs 15', v_total);
    END IF;
    IF v_spent > v_budget THEN
        RETURN format('squad costs %s, budget is %s', v_spent, v_budget);
    END IF;

    IF EXISTS (SELECT 1 FROM fn_squad_at(p_entry, p_gw) sq
               WHERE NOT EXISTS (SELECT 1 FROM player_seasons ps
                                 WHERE ps.season_id = v_season AND ps.player_code = sq.player_code)) THEN
        RETURN 'squad contains a player not registered in this season';
    END IF;

    SELECT string_agg(format('%s=%s', p.code, COALESCE(c.n, 0)), ', ' ORDER BY p.position_id)
    INTO v_bad
    FROM positions p
    LEFT JOIN (SELECT ps.position_id, count(*) AS n
               FROM fn_squad_at(p_entry, p_gw) sq
               JOIN player_seasons ps ON ps.season_id = v_season AND ps.player_code = sq.player_code
               GROUP BY 1) c USING (position_id)
    WHERE COALESCE(c.n, 0) <> p.squad_select;
    IF v_bad IS NOT NULL THEN
        RETURN 'wrong position counts: ' || v_bad;
    END IF;

    SELECT string_agg(cl.short_name || ' x' || c.n, ', ')
    INTO v_bad
    FROM (SELECT fn_club_at(v_season, sq.player_code, p_gw) AS club_code, count(*) AS n
          FROM fn_squad_at(p_entry, p_gw) sq
          GROUP BY 1 HAVING count(*) > 3) c
    JOIN clubs cl USING (club_code);
    IF v_bad IS NOT NULL THEN
        RETURN 'more than 3 players from one club: ' || v_bad;
    END IF;

    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_lineup_error(p_entry integer, p_gw integer) RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_rows     integer;
    v_starters integer;
    v_captains integer;
    v_vices    integer;
    v_bad      text;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE is_starter),
           count(*) FILTER (WHERE is_captain), count(*) FILTER (WHERE is_vice)
    INTO v_rows, v_starters, v_captains, v_vices
    FROM lineups WHERE entry_id = p_entry AND gw_no = p_gw;

    IF v_rows = 0 THEN RETURN NULL; END IF;    -- no lineup = 0 points, allowed
    IF v_rows <> 15     THEN RETURN format('lineup has %s players, needs 15', v_rows); END IF;
    IF v_starters <> 11 THEN RETURN format('lineup has %s starters, needs 11', v_starters); END IF;
    IF v_captains <> 1  THEN RETURN format('lineup has %s captains, needs 1', v_captains); END IF;
    IF v_vices <> 1     THEN RETURN format('lineup has %s vice-captains, needs 1', v_vices); END IF;

    IF EXISTS (SELECT 1 FROM fn_squad_at(p_entry, p_gw) sq
               WHERE NOT EXISTS (SELECT 1 FROM lineups l
                                 WHERE l.entry_id = p_entry AND l.gw_no = p_gw AND l.player_code = sq.player_code)) THEN
        RETURN 'lineup does not match squad';
    END IF;

    SELECT string_agg(format('%s=%s', p.code, COALESCE(c.n, 0)), ', ' ORDER BY p.position_id)
    INTO v_bad
    FROM positions p
    LEFT JOIN (SELECT ps.position_id, count(*) AS n
               FROM lineups l
               JOIN entries e USING (entry_id)
               JOIN player_seasons ps ON ps.season_id = e.season_id AND ps.player_code = l.player_code
               WHERE l.entry_id = p_entry AND l.gw_no = p_gw AND l.is_starter
               GROUP BY 1) c USING (position_id)
    WHERE COALESCE(c.n, 0) NOT BETWEEN p.min_play AND p.max_play;
    IF v_bad IS NOT NULL THEN
        RETURN 'illegal formation: ' || v_bad;
    END IF;

    RETURN NULL;
END;
$$;


-- rows may only be added, closed or removed for the current gameweek
CREATE OR REPLACE FUNCTION trg_squad_window() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_season smallint;
BEGIN
    SELECT season_id INTO v_season FROM entries WHERE entry_id = COALESCE(NEW.entry_id, OLD.entry_id);
    IF v_season IS NULL THEN
        RAISE EXCEPTION 'entry % does not exist', COALESCE(NEW.entry_id, OLD.entry_id) USING ERRCODE = 'check_violation';
    END IF;
    CASE TG_OP
        WHEN 'INSERT' THEN
            PERFORM fn_assert_open(v_season, NEW.from_gw);
        WHEN 'UPDATE' THEN
            IF NEW.entry_id <> OLD.entry_id OR NEW.player_code <> OLD.player_code
               OR NEW.from_gw <> OLD.from_gw OR NEW.purchase_price <> OLD.purchase_price THEN
                RAISE EXCEPTION 'squad_slots: only to_gw may change' USING ERRCODE = 'check_violation';
            END IF;
            PERFORM fn_assert_open(v_season, NEW.to_gw);
        WHEN 'DELETE' THEN
            PERFORM fn_assert_open(v_season, OLD.from_gw);
    END CASE;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE TRIGGER squad_window
    BEFORE INSERT OR UPDATE OR DELETE ON squad_slots
    FOR EACH ROW EXECUTE FUNCTION trg_squad_window();

-- whole-squad rules, checked once the transaction is complete
CREATE OR REPLACE FUNCTION trg_squad_valid() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_gw  smallint := COALESCE(NEW.to_gw, NEW.from_gw, OLD.from_gw);
    v_err text     := fn_squad_error(COALESCE(NEW.entry_id, OLD.entry_id), v_gw);
BEGIN
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'invalid squad for gameweek %: %', v_gw, v_err USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS squad_valid ON squad_slots;
CREATE CONSTRAINT TRIGGER squad_valid
    AFTER INSERT OR UPDATE OR DELETE ON squad_slots
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_squad_valid();


CREATE OR REPLACE FUNCTION trg_lineup_window() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r        record   := COALESCE(NEW, OLD);
    v_season smallint;
BEGIN
    SELECT season_id INTO v_season FROM entries WHERE entry_id = r.entry_id;
    IF v_season IS NULL THEN
        RAISE EXCEPTION 'entry % does not exist', r.entry_id USING ERRCODE = 'check_violation';
    END IF;
    IF current_setting('fpl.system', true) IS DISTINCT FROM 'on' THEN   -- set by advance_gameweek only
        PERFORM fn_assert_open(v_season, r.gw_no);
    END IF;
    IF TG_OP <> 'DELETE' AND NOT EXISTS (
        SELECT 1 FROM fn_squad_at(NEW.entry_id, NEW.gw_no) WHERE player_code = NEW.player_code) THEN
        RAISE EXCEPTION 'player % is not in the squad for gameweek %', NEW.player_code, NEW.gw_no
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE TRIGGER lineup_window
    BEFORE INSERT OR UPDATE OR DELETE ON lineups
    FOR EACH ROW EXECUTE FUNCTION trg_lineup_window();

CREATE OR REPLACE FUNCTION trg_lineup_valid() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r     record := COALESCE(NEW, OLD);
    v_err text   := fn_lineup_error(r.entry_id, r.gw_no);
BEGIN
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'invalid lineup for gameweek %: %', r.gw_no, v_err USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS lineup_valid ON lineups;
CREATE CONSTRAINT TRIGGER lineup_valid
    AFTER INSERT OR UPDATE OR DELETE ON lineups
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_lineup_valid();


-- players are sold at purchase price (no sell-on profit); squad is 2/5/5/3 so in/out share a position
CREATE OR REPLACE FUNCTION trg_transfer_apply() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_season  smallint;
    v_slot    integer;
    v_from    smallint;
    v_pos_out smallint;
    v_pos_in  smallint;
BEGIN
    SELECT season_id INTO v_season FROM entries WHERE entry_id = NEW.entry_id;
    IF v_season IS NULL THEN
        RAISE EXCEPTION 'entry % does not exist', NEW.entry_id USING ERRCODE = 'check_violation';
    END IF;
    PERFORM fn_assert_open(v_season, NEW.gw_no);

    SELECT slot_id, from_gw, purchase_price INTO v_slot, v_from, NEW.price_out
    FROM squad_slots
    WHERE entry_id = NEW.entry_id AND player_code = NEW.player_out AND to_gw IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % is not in the squad', NEW.player_out USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM squad_slots
               WHERE entry_id = NEW.entry_id AND player_code = NEW.player_in AND to_gw IS NULL) THEN
        RAISE EXCEPTION 'player % is already in the squad', NEW.player_in USING ERRCODE = 'check_violation';
    END IF;

    SELECT position_id INTO v_pos_out FROM player_seasons WHERE season_id = v_season AND player_code = NEW.player_out;
    SELECT position_id INTO v_pos_in  FROM player_seasons WHERE season_id = v_season AND player_code = NEW.player_in;
    IF v_pos_in IS NULL THEN
        RAISE EXCEPTION 'player % is not registered in this season', NEW.player_in USING ERRCODE = 'check_violation';
    END IF;
    IF v_pos_in <> v_pos_out THEN
        RAISE EXCEPTION 'transfer must keep the position (out: %, in: %)', v_pos_out, v_pos_in
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.price_in := fn_price_at(v_season, NEW.player_in, NEW.gw_no);
    IF NEW.price_in IS NULL THEN
        RAISE EXCEPTION 'no price for player % in gameweek %', NEW.player_in, NEW.gw_no USING ERRCODE = 'check_violation';
    END IF;
    NEW.made_at := fn_now();

    -- bought and sold within the same window leaves no trace in squad history
    IF v_from = NEW.gw_no THEN
        DELETE FROM squad_slots WHERE slot_id = v_slot;
    ELSE
        UPDATE squad_slots SET to_gw = NEW.gw_no WHERE slot_id = v_slot;
    END IF;
    INSERT INTO squad_slots (entry_id, player_code, from_gw, purchase_price)
    VALUES (NEW.entry_id, NEW.player_in, NEW.gw_no, NEW.price_in);

    UPDATE lineups SET player_code = NEW.player_in
    WHERE entry_id = NEW.entry_id AND gw_no = NEW.gw_no AND player_code = NEW.player_out;

    INSERT INTO entry_gw_state (entry_id, gw_no, transfers_made)
    VALUES (NEW.entry_id, NEW.gw_no, 1)
    ON CONFLICT (entry_id, gw_no) DO UPDATE SET transfers_made = entry_gw_state.transfers_made + 1;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER transfer_apply
    BEFORE INSERT ON transfers
    FOR EACH ROW EXECUTE FUNCTION trg_transfer_apply();

CREATE OR REPLACE FUNCTION trg_transfer_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'transfers cannot be changed or deleted' USING ERRCODE = 'check_violation';
END;
$$;

CREATE OR REPLACE TRIGGER transfer_immutable
    BEFORE UPDATE OR DELETE ON transfers
    FOR EACH ROW EXECUTE FUNCTION trg_transfer_immutable();


CREATE OR REPLACE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_row jsonb := to_jsonb(COALESCE(NEW, OLD));
    v_pk  text;
BEGIN
    SELECT string_agg(v_row ->> a.attname, '/' ORDER BY a.attnum)
    INTO v_pk
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
    WHERE i.indrelid = TG_RELID AND i.indisprimary;

    INSERT INTO audit_log (table_name, op, row_pk, old_row, new_row, game_time)
    VALUES (TG_TABLE_NAME, TG_OP::audit_op, v_pk, to_jsonb(OLD), to_jsonb(NEW), fn_now());
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON entries     FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE OR REPLACE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON squad_slots FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE OR REPLACE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON lineups     FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE OR REPLACE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON transfers   FOR EACH ROW EXECUTE FUNCTION trg_audit();


-- replay: clock one day before the first deadline
CREATE OR REPLACE PROCEDURE start_replay(p_season integer DEFAULT fn_current_season())
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO app_settings (key, value)
    VALUES ('current_season', p_season::text),
           ('virtual_now', (SELECT (deadline_time - interval '1 day')::text FROM gameweeks
                            WHERE season_id = p_season AND gw_no = 1))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
    UPDATE gameweeks SET finished = false WHERE season_id = p_season;
END;
$$;

-- live: drop the virtual clock; gameweeks fully played before now count as closed
CREATE OR REPLACE PROCEDURE go_live()
LANGUAGE sql AS $$
    DELETE FROM app_settings WHERE key = 'virtual_now';
    UPDATE gameweeks g SET finished = true
    WHERE g.season_id = fn_current_season() AND g.deadline_time <= now()
      AND NOT EXISTS (SELECT 1 FROM fixtures f WHERE f.season_id = g.season_id AND f.gw_no = g.gw_no AND NOT f.finished);
$$;

-- wipe every game table, keep reference data
CREATE OR REPLACE PROCEDURE reset_game()
LANGUAGE sql AS $$
    TRUNCATE users, entries, squad_slots, lineups, transfers, entry_gw_state,
             mini_leagues, mini_members, audit_log RESTART IDENTITY CASCADE;
$$;

-- p_players: 15 player codes, first 11 are starters, last 4 bench in order
CREATE OR REPLACE FUNCTION create_entry(
    p_username text,
    p_name     text,
    p_players  integer[],
    p_captain  integer,
    p_vice     integer,
    p_season   integer DEFAULT fn_current_season()
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_user  integer;
    v_entry integer;
    v_gw    smallint := fn_current_gw(p_season);
BEGIN
    IF v_gw IS NULL THEN
        RAISE EXCEPTION 'season % is over', p_season USING ERRCODE = 'check_violation';
    END IF;
    IF array_length(p_players, 1) <> 15 THEN
        RAISE EXCEPTION 'create_entry needs 15 players, got %', array_length(p_players, 1)
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO users (username) VALUES (p_username)
    ON CONFLICT (username) DO UPDATE SET username = EXCLUDED.username
    RETURNING user_id INTO v_user;

    INSERT INTO entries (user_id, season_id, name, created_gw)
    VALUES (v_user, p_season, p_name, v_gw)
    RETURNING entry_id INTO v_entry;

    IF EXISTS (SELECT 1 FROM unnest(p_players) AS p(code) WHERE fn_price_at(p_season, p.code, v_gw) IS NULL) THEN
        RAISE EXCEPTION 'no price in gameweek % for player(s) %: not registered in season %?', v_gw,
            (SELECT string_agg(p.code::text, ', ') FROM unnest(p_players) AS p(code) WHERE fn_price_at(p_season, p.code, v_gw) IS NULL),
            p_season USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO squad_slots (entry_id, player_code, from_gw, purchase_price)
    SELECT v_entry, p.code, v_gw, fn_price_at(p_season, p.code, v_gw)
    FROM unnest(p_players) AS p(code);

    INSERT INTO lineups (entry_id, gw_no, player_code, is_starter, is_captain, is_vice, bench_order)
    SELECT v_entry, v_gw, p.code, p.ord <= 11, p.code = p_captain, p.code = p_vice,
           CASE WHEN p.ord > 11 THEN p.ord - 11 END
    FROM unnest(p_players) WITH ORDINALITY AS p(code, ord);

    INSERT INTO entry_gw_state (entry_id, gw_no, free_transfers_start) VALUES (v_entry, v_gw, 1);
    RETURN v_entry;
END;
$$;

-- close the current gameweek: penalties, free transfers, clock, lineups carried forward, standings
CREATE OR REPLACE PROCEDURE advance_gameweek(p_season integer DEFAULT fn_current_season())
LANGUAGE plpgsql AS $$
DECLARE
    v_gw     smallint;
    v_next   timestamptz;
    v_replay boolean := EXISTS (SELECT 1 FROM app_settings WHERE key = 'virtual_now');
BEGIN
    IF v_replay THEN
        -- replay: the clock sits just before the current deadline, closing means jumping over it
        v_gw := fn_current_gw(p_season);
        IF v_gw IS NULL THEN
            RAISE EXCEPTION 'season % is over', p_season USING ERRCODE = 'check_violation';
        END IF;
    ELSE
        -- live: oldest gameweek whose deadline has passed and whose matches are all played
        SELECT min(gw_no) INTO v_gw FROM gameweeks
        WHERE season_id = p_season AND NOT finished AND deadline_time <= now();
        IF v_gw IS NULL THEN
            RAISE EXCEPTION 'nothing to close: deadline of gameweek % has not passed yet', fn_current_gw(p_season)
                USING ERRCODE = 'check_violation';
        END IF;
        IF EXISTS (SELECT 1 FROM fixtures WHERE season_id = p_season AND gw_no = v_gw AND NOT finished) THEN
            RAISE EXCEPTION 'gameweek % still in progress: load fresh data after its last match', v_gw
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- every active entry gets a state row; first gameweek after joining has free transfers
    INSERT INTO entry_gw_state (entry_id, gw_no)
    SELECT entry_id, v_gw FROM entries WHERE season_id = p_season AND created_gw <= v_gw
    ON CONFLICT DO NOTHING;

    UPDATE entry_gw_state s
    SET penalty_points = CASE WHEN e.created_gw = v_gw THEN 0
                              ELSE 4 * GREATEST(0, s.transfers_made - s.free_transfers_start) END
    FROM entries e
    WHERE e.entry_id = s.entry_id AND e.season_id = p_season AND s.gw_no = v_gw;

    UPDATE gameweeks SET finished = true WHERE season_id = p_season AND gw_no = v_gw;

    IF v_gw < 38 THEN
        -- unused free transfers roll over, capped at 5; a hit resets to 1
        INSERT INTO entry_gw_state (entry_id, gw_no, free_transfers_start)
        SELECT s.entry_id, v_gw + 1,
               CASE WHEN e.created_gw = v_gw THEN 1
                    ELSE LEAST(5, GREATEST(0, s.free_transfers_start - s.transfers_made) + 1) END
        FROM entry_gw_state s
        JOIN entries e USING (entry_id)
        WHERE s.gw_no = v_gw AND e.season_id = p_season
        ON CONFLICT DO NOTHING;
    END IF;

    -- replay only: jump to one day before the next deadline
    IF v_replay THEN
        SELECT deadline_time - interval '1 day' INTO v_next
        FROM gameweeks WHERE season_id = p_season AND gw_no = v_gw + 1;
        IF v_next IS NULL THEN
            SELECT deadline_time + interval '1 day' INTO v_next
            FROM gameweeks WHERE season_id = p_season AND gw_no = v_gw;
        END IF;
        UPDATE app_settings SET value = v_next::text WHERE key = 'virtual_now';
    END IF;

    -- same lineup next week unless the manager changes it (system flag lets it bypass the deadline check)
    IF v_gw < 38 THEN
        PERFORM set_config('fpl.system', 'on', true);
        INSERT INTO lineups (entry_id, gw_no, player_code, is_starter, is_captain, is_vice, bench_order)
        SELECT l.entry_id, v_gw + 1, l.player_code, l.is_starter, l.is_captain, l.is_vice, l.bench_order
        FROM lineups l
        JOIN entries e USING (entry_id)
        WHERE l.gw_no = v_gw AND e.season_id = p_season
          AND NOT EXISTS (SELECT 1 FROM lineups x WHERE x.entry_id = l.entry_id AND x.gw_no = v_gw + 1);
        PERFORM set_config('fpl.system', 'off', true);
    END IF;

    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_standings;
END;
$$;
