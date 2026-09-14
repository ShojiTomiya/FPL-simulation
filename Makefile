# usage: make setup fetch load replay   (then: make advance / make test)

CONFIG := config/season.toml
DB     := $(shell python3 -c "import tomllib;print(tomllib.load(open('$(CONFIG)','rb'))['db'])")
SOURCE := $(shell python3 -c "import tomllib;print(tomllib.load(open('$(CONFIG)','rb'))['source'])")
PSQL   := psql -d $(DB) -v ON_ERROR_STOP=1 -q

# order matters: load.sql refers to views, views to tables, indexes to everything
SQL_FILES := sql/schema.sql sql/constraints.sql sql/seed.sql sql/load.sql \
             sql/views.sql sql/game_logic.sql sql/indexes.sql

.PHONY: setup schema logic fetch load all replay live advance status test reset-game reset psql

setup:            ## create the database and apply every sql file
	@psql -lqt | cut -d'|' -f1 | grep -qw $(DB) || createdb $(DB)
	@$(MAKE) --no-print-directory schema

schema:           ## apply every sql file to a fresh database
	@for f in $(SQL_FILES); do echo "apply $$f"; $(PSQL) -f $$f 2>&1 | grep -vE 'NOTICE:|DETAIL|SZCZEGÓŁY|drop cascades'; done; true

logic:            ## re-apply procedures, views, triggers, indexes after editing them (data kept)
	@for f in sql/load.sql sql/views.sql sql/game_logic.sql sql/indexes.sql; do echo "apply $$f"; $(PSQL) -f $$f 2>&1 | grep -vE 'NOTICE:|DETAIL|SZCZEGÓŁY|drop cascades'; done; true

fetch:            ## download season data (source from config: csv | api)
	python3 etl/fetch_$(SOURCE).py

load:             ## cache -> stg_raw -> tables, refresh player points
	python3 etl/load.py

all: setup fetch load

replay:           ## start the virtual clock one day before deadline 1
	@$(PSQL) -c "CALL start_replay()"
	@$(MAKE) --no-print-directory status

live:             ## drop the virtual clock, play against real time
	@$(PSQL) -c "CALL go_live()"
	@$(MAKE) --no-print-directory status

advance:          ## close the current gameweek and show the table
	@$(PSQL) -c "CALL advance_gameweek()"
	@$(MAKE) --no-print-directory status
	@psql -d $(DB) -c "SELECT rank, e.name, s.points AS gw_points, s.total_points, s.rank_change \
	                    FROM mv_standings s JOIN entries e USING (entry_id) \
	                    WHERE s.gw_no = (SELECT max(gw_no) FROM mv_standings) ORDER BY rank"

status:           ## clock, current gameweek, entries
	@psql -d $(DB) -c "SELECT fn_now() AS game_time, fn_current_gw() AS current_gw, \
	                    (SELECT name FROM seasons WHERE season_id = fn_current_season()) AS season, \
	                    (SELECT count(*) FROM entries) AS entries, \
	                    CASE WHEN EXISTS (SELECT 1 FROM app_settings WHERE key = 'virtual_now') THEN 'replay' ELSE 'live' END AS mode"

test:             ## run the suite; exit code != 0 on any FAIL
	@$(PSQL) -f tests/test_all.sql | grep -E '^(==|PASS|FAIL|[0-9]+ passed)'

reset-game:       ## wipe entries, squads, transfers; keep loaded data
	@$(PSQL) -c "CALL reset_game()"

reset:            ## drop and recreate the database (data must be loaded again)
	dropdb --if-exists $(DB)
	@$(MAKE) --no-print-directory setup

psql:             ## open a console
	psql -d $(DB)
