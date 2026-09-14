-- declarative rules only; anything needing a query lives in game_logic.sql

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- scalar = in EXCLUDE

-- clubs
ALTER TABLE clubs
    ADD CONSTRAINT chk_clubs_short_name CHECK (length(short_name) = 3);

-- positions
ALTER TABLE positions
    ADD CONSTRAINT chk_positions_play_range CHECK (1 <= min_play AND min_play <= max_play),
    ADD CONSTRAINT chk_positions_squad     CHECK (max_play <= squad_select);

-- gameweeks
ALTER TABLE gameweeks
    ADD CONSTRAINT chk_gameweeks_no CHECK (gw_no BETWEEN 1 AND 38);

-- fixtures
ALTER TABLE fixtures
    ADD CONSTRAINT chk_fixtures_clubs       CHECK (home_club <> away_club),
    ADD CONSTRAINT chk_fixtures_score_pair  CHECK ((home_score IS NULL) = (away_score IS NULL)),
    ADD CONSTRAINT chk_fixtures_score_range CHECK (home_score >= 0 AND away_score >= 0),
    ADD CONSTRAINT chk_fixtures_finished    CHECK (NOT finished OR home_score IS NOT NULL);

-- player_fixture_stats
ALTER TABLE player_fixture_stats
    ADD CONSTRAINT chk_pfs_minutes  CHECK (minutes BETWEEN 0 AND 120),
    ADD CONSTRAINT chk_pfs_flags    CHECK (starts IN (0, 1) AND clean_sheets IN (0, 1) AND red_cards IN (0, 1)),
    ADD CONSTRAINT chk_pfs_counts   CHECK (
        goals_scored >= 0 AND assists >= 0 AND goals_conceded >= 0 AND own_goals >= 0
        AND penalties_saved >= 0 AND penalties_missed >= 0 AND yellow_cards >= 0
        AND saves >= 0 AND bonus BETWEEN 0 AND 3 AND defensive_contribution >= 0
    ),
    ADD CONSTRAINT chk_pfs_expected CHECK (
        expected_goals >= 0 AND expected_assists >= 0
        AND expected_goal_involvements >= 0 AND expected_goals_conceded >= 0
    ),
    ADD CONSTRAINT chk_pfs_no_play  CHECK (minutes > 0 OR (goals_scored = 0 AND assists = 0 AND clean_sheets = 0));

-- player_gw_prices
ALTER TABLE player_gw_prices
    ADD CONSTRAINT chk_prices_gw     CHECK (gw_no BETWEEN 1 AND 38),
    ADD CONSTRAINT chk_prices_price  CHECK (price > 0),
    ADD CONSTRAINT chk_prices_market CHECK (selected_by >= 0 AND transfers_in >= 0 AND transfers_out >= 0);

-- scoring_rules
ALTER TABLE scoring_rules
    ADD CONSTRAINT chk_rules_units CHECK (per_units >= 1 AND min_value >= 0),
    ADD CONSTRAINT chk_rules_cap   CHECK (cap IS NULL OR cap >= 1),
    ADD CONSTRAINT uq_rules UNIQUE NULLS NOT DISTINCT (stat, position_id, min_value);

-- users
ALTER TABLE users
    ADD CONSTRAINT chk_users_name CHECK (length(username) BETWEEN 3 AND 30);

-- entries
ALTER TABLE entries
    ADD CONSTRAINT chk_entries_name   CHECK (length(name) BETWEEN 1 AND 40),
    ADD CONSTRAINT chk_entries_budget CHECK (budget > 0),
    ADD CONSTRAINT chk_entries_gw     CHECK (created_gw BETWEEN 1 AND 38);

-- squad_slots
ALTER TABLE squad_slots
    ADD CONSTRAINT chk_slots_gw    CHECK (from_gw BETWEEN 1 AND 38),
    ADD CONSTRAINT chk_slots_range CHECK (to_gw IS NULL OR to_gw > from_gw),
    ADD CONSTRAINT chk_slots_price CHECK (purchase_price > 0),
    -- same player cannot be in the squad twice over overlapping gameweeks
    ADD CONSTRAINT excl_slots_overlap EXCLUDE USING gist (
        entry_id    WITH =,
        player_code WITH =,
        int4range(from_gw::int, to_gw::int) WITH &&
    );

-- lineups
ALTER TABLE lineups
    ADD CONSTRAINT chk_lineups_gw      CHECK (gw_no BETWEEN 1 AND 38),
    ADD CONSTRAINT chk_lineups_captain CHECK (NOT is_captain OR is_starter),
    ADD CONSTRAINT chk_lineups_vice    CHECK (NOT is_vice OR is_starter),
    ADD CONSTRAINT chk_lineups_armband CHECK (NOT (is_captain AND is_vice)),
    ADD CONSTRAINT chk_lineups_bench   CHECK (
        (is_starter AND bench_order IS NULL)
        OR (NOT is_starter AND bench_order BETWEEN 1 AND 4)
    );

CREATE UNIQUE INDEX uq_lineups_captain ON lineups (entry_id, gw_no) WHERE is_captain;
CREATE UNIQUE INDEX uq_lineups_vice    ON lineups (entry_id, gw_no) WHERE is_vice;
CREATE UNIQUE INDEX uq_lineups_bench   ON lineups (entry_id, gw_no, bench_order) WHERE bench_order IS NOT NULL;

-- transfers
ALTER TABLE transfers
    ADD CONSTRAINT chk_transfers_gw      CHECK (gw_no BETWEEN 1 AND 38),
    ADD CONSTRAINT chk_transfers_players CHECK (player_out <> player_in),
    ADD CONSTRAINT chk_transfers_prices  CHECK (price_out > 0 AND price_in > 0);

-- entry_gw_state
ALTER TABLE entry_gw_state
    ADD CONSTRAINT chk_state_gw      CHECK (gw_no BETWEEN 1 AND 38),
    ADD CONSTRAINT chk_state_free    CHECK (free_transfers_start BETWEEN 0 AND 5),
    ADD CONSTRAINT chk_state_made    CHECK (transfers_made >= 0),
    ADD CONSTRAINT chk_state_penalty CHECK (penalty_points >= 0 AND penalty_points % 4 = 0);

-- mini_leagues
ALTER TABLE mini_leagues
    ADD CONSTRAINT chk_leagues_name CHECK (length(name) BETWEEN 1 AND 40),
    ADD CONSTRAINT chk_leagues_code CHECK (join_code ~ '^[A-Z0-9]{6}$');

-- app_settings
ALTER TABLE app_settings
    ADD CONSTRAINT chk_settings_key CHECK (key IN ('virtual_now', 'current_season'));

-- stg_raw
ALTER TABLE stg_raw
    ADD CONSTRAINT chk_stg_payload CHECK (jsonb_typeof(payload) = 'object');
