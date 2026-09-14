-- performance indexes; uniqueness/exclusion indexes live in constraints.sql

-- staging: ad-hoc jsonb queries
CREATE INDEX IF NOT EXISTS idx_stg_season_kind ON stg_raw (season_name, kind);
CREATE INDEX IF NOT EXISTS idx_stg_payload     ON stg_raw USING gin (payload jsonb_path_ops);

-- reference
CREATE INDEX IF NOT EXISTS idx_gameweeks_deadline ON gameweeks (season_id, deadline_time);          -- fn_current_gw
CREATE INDEX IF NOT EXISTS idx_fixtures_gw        ON fixtures (season_id, gw_no);
CREATE INDEX IF NOT EXISTS idx_fixtures_home      ON fixtures (home_club);
CREATE INDEX IF NOT EXISTS idx_fixtures_away      ON fixtures (away_club);
CREATE INDEX IF NOT EXISTS idx_pfs_fixture        ON player_fixture_stats (fixture_id);
CREATE INDEX IF NOT EXISTS idx_pfs_club           ON player_fixture_stats (club_code);
CREATE INDEX IF NOT EXISTS idx_prices_player      ON player_gw_prices (season_id, player_code, gw_no DESC);  -- fn_price_at
CREATE INDEX IF NOT EXISTS idx_pseasons_position  ON player_seasons (season_id, position_id);
CREATE INDEX IF NOT EXISTS idx_pseasons_club      ON player_seasons (season_id, club_code_start);

-- game
CREATE INDEX IF NOT EXISTS idx_entries_season     ON entries (season_id);
CREATE INDEX IF NOT EXISTS idx_slots_range        ON squad_slots (entry_id, from_gw, to_gw);           -- fn_squad_at
CREATE INDEX IF NOT EXISTS idx_slots_current      ON squad_slots (entry_id, player_code) WHERE to_gw IS NULL;
CREATE INDEX IF NOT EXISTS idx_slots_player       ON squad_slots (player_code);                        -- ownership
CREATE INDEX IF NOT EXISTS idx_lineups_player     ON lineups (player_code, gw_no);
CREATE INDEX IF NOT EXISTS idx_transfers_entry    ON transfers (entry_id, gw_no);
CREATE INDEX IF NOT EXISTS idx_transfers_in       ON transfers (player_in);
CREATE INDEX IF NOT EXISTS idx_transfers_out      ON transfers (player_out);
CREATE INDEX IF NOT EXISTS idx_members_entry      ON mini_members (entry_id);

-- audit: append-only, so BRIN on time is tiny and good enough
CREATE INDEX IF NOT EXISTS idx_audit_row  ON audit_log (table_name, row_pk);
CREATE INDEX IF NOT EXISTS idx_audit_time ON audit_log USING brin (changed_at);
