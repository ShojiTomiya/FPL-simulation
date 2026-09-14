
CREATE TYPE source_kind AS ENUM ('csv', 'api');

CREATE TYPE stg_kind AS ENUM ('players', 'teams', 'fixtures', 'gw_stats', 'events');

CREATE TYPE audit_op AS ENUM ('INSERT', 'UPDATE', 'DELETE');

-- seasons
CREATE TABLE seasons (
    season_id   smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text        NOT NULL UNIQUE,
    source      source_kind NOT NULL,
    loaded_at   timestamptz NOT NULL DEFAULT now()
);

-- club
CREATE TABLE clubs (
    club_code   integer     PRIMARY KEY,
    name        text        NOT NULL,
    short_name  text        NOT NULL
);

-- club in season
CREATE TABLE club_seasons (
    season_id   smallint    NOT NULL REFERENCES seasons,
    club_code   integer     NOT NULL REFERENCES clubs,
    fpl_team_id smallint    NOT NULL,
    PRIMARY KEY (season_id, club_code),
    UNIQUE (season_id, fpl_team_id)
);

-- posiotions and limits
CREATE TABLE positions (
    position_id  smallint   PRIMARY KEY,
    code         text       NOT NULL UNIQUE,          -- 'GKP','DEF','MID','FWD'
    name         text       NOT NULL,
    squad_select smallint   NOT NULL,                 -- (2/5/5/3)
    min_play     smallint   NOT NULL,                 -- min (1/3/2/1)
    max_play     smallint   NOT NULL                  -- max (1/5/5/3)
);

-- player
CREATE TABLE players (
    player_code  integer    PRIMARY KEY,
    first_name   text       NOT NULL,
    second_name  text       NOT NULL,
    web_name     text       NOT NULL 
);

--player in season
CREATE TABLE player_seasons (
    season_id       smallint    NOT NULL REFERENCES seasons,
    player_code     integer     NOT NULL REFERENCES players,
    fpl_element_id  smallint    NOT NULL,
    position_id     smallint    NOT NULL REFERENCES positions,
    club_code_start integer     NOT NULL REFERENCES clubs,
    PRIMARY KEY (season_id, player_code),
    UNIQUE (season_id, fpl_element_id)
);

-- gameweek
CREATE TABLE gameweeks (
    season_id      smallint    NOT NULL REFERENCES seasons,
    gw_no          smallint    NOT NULL,
    deadline_time  timestamptz NOT NULL,
    finished       boolean     NOT NULL DEFAULT false,
    PRIMARY KEY (season_id, gw_no)
);

-- game
CREATE TABLE fixtures (
    fixture_id      integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    season_id       smallint    NOT NULL,
    gw_no           smallint    NOT NULL,
    fpl_fixture_id  integer     NOT NULL,             -- season id FPL
    kickoff_time    timestamptz NOT NULL,
    home_club       integer     NOT NULL REFERENCES clubs,
    away_club       integer     NOT NULL REFERENCES clubs,
    home_score      smallint,                         -- NULL
    away_score      smallint,
    finished        boolean     NOT NULL DEFAULT false,
    FOREIGN KEY (season_id, gw_no) REFERENCES gameweeks (season_id, gw_no),
    UNIQUE (season_id, fpl_fixture_id)
);

-- Stats
CREATE TABLE player_fixture_stats (
    player_code             integer     NOT NULL REFERENCES players,
    fixture_id              integer     NOT NULL REFERENCES fixtures,
    club_code               integer     NOT NULL REFERENCES clubs,
    minutes                 smallint    NOT NULL DEFAULT 0,
    starts                  smallint    NOT NULL DEFAULT 0,
    goals_scored            smallint    NOT NULL DEFAULT 0,
    assists                 smallint    NOT NULL DEFAULT 0,
    clean_sheets            smallint    NOT NULL DEFAULT 0,   -- 60 min
    goals_conceded          smallint    NOT NULL DEFAULT 0,
    own_goals               smallint    NOT NULL DEFAULT 0,
    penalties_saved         smallint    NOT NULL DEFAULT 0,
    penalties_missed        smallint    NOT NULL DEFAULT 0,
    yellow_cards            smallint    NOT NULL DEFAULT 0,
    red_cards               smallint    NOT NULL DEFAULT 0,
    saves                   smallint    NOT NULL DEFAULT 0,
    bonus                   smallint    NOT NULL DEFAULT 0,   -- no BPS
    bps                     smallint    NOT NULL DEFAULT 0,
    defensive_contribution  smallint    NOT NULL DEFAULT 0,
    expected_goals          numeric(5,2) NOT NULL DEFAULT 0,
    expected_assists        numeric(5,2) NOT NULL DEFAULT 0,
    expected_goal_involvements numeric(5,2) NOT NULL DEFAULT 0,
    expected_goals_conceded numeric(5,2) NOT NULL DEFAULT 0,
    ict_index               numeric(6,1) NOT NULL DEFAULT 0,
    official_points         smallint    NOT NULL,
    PRIMARY KEY (player_code, fixture_id)
);

-- prices
CREATE TABLE player_gw_prices (
    season_id      smallint    NOT NULL,
    gw_no          smallint    NOT NULL,
    player_code    integer     NOT NULL REFERENCES players,
    price          smallint    NOT NULL,              -- 55 = 5.5m
    selected_by    integer,                           -- how common
    transfers_in   integer,
    transfers_out  integer,
    PRIMARY KEY (season_id, gw_no, player_code),
    FOREIGN KEY (season_id, gw_no) REFERENCES gameweeks (season_id, gw_no)
);

-- points
CREATE TABLE scoring_rules (
    rule_id      smallint   GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stat         text       NOT NULL,                 
    position_id  smallint   REFERENCES positions,     
    points       smallint   NOT NULL,
    per_units    smallint   NOT NULL DEFAULT 1,
    min_value    smallint   NOT NULL DEFAULT 1,
    cap          smallint,
    description  text
);

CREATE TABLE users (
    user_id     integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username    text        NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- user's team
CREATE TABLE entries (
    entry_id    integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     integer     NOT NULL REFERENCES users,
    season_id   smallint    NOT NULL REFERENCES seasons,
    name        text        NOT NULL,
    budget      smallint    NOT NULL DEFAULT 1000,    -- 100.0m
    created_gw  smallint    NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, season_id)
);

-- team
CREATE TABLE squad_slots (
    slot_id         integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_id        integer     NOT NULL REFERENCES entries,
    player_code     integer     NOT NULL REFERENCES players,
    from_gw         smallint    NOT NULL,
    to_gw           smallint,              
    purchase_price  smallint    NOT NULL              -- price at the moment of purchase
);

-- lineup per gameweek
CREATE TABLE lineups (
    entry_id     integer    NOT NULL REFERENCES entries,
    gw_no        smallint   NOT NULL,
    player_code  integer    NOT NULL REFERENCES players,
    is_starter   boolean    NOT NULL,
    is_captain   boolean    NOT NULL DEFAULT false,
    is_vice      boolean    NOT NULL DEFAULT false,
    bench_order  smallint,                          
    PRIMARY KEY (entry_id, gw_no, player_code)
);

-- transfers
CREATE TABLE transfers (
    transfer_id  integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    entry_id     integer     NOT NULL REFERENCES entries,
    gw_no        smallint    NOT NULL,          
    player_out   integer     NOT NULL REFERENCES players,
    player_in    integer     NOT NULL REFERENCES players,
    price_out    smallint    NOT NULL,
    price_in     smallint    NOT NULL,
    made_at      timestamptz NOT NULL             
);

-- state
CREATE TABLE entry_gw_state (
    entry_id              integer   NOT NULL REFERENCES entries,
    gw_no                 smallint  NOT NULL,
    free_transfers_start  smallint  NOT NULL DEFAULT 1,
    transfers_made        smallint  NOT NULL DEFAULT 0,
    penalty_points        smallint  NOT NULL DEFAULT 0,
    PRIMARY KEY (entry_id, gw_no)
);

-- mini league
CREATE TABLE mini_leagues (
    league_id      integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    season_id      smallint    NOT NULL REFERENCES seasons,
    name           text        NOT NULL,
    owner_user_id  integer     NOT NULL REFERENCES users,
    join_code      text        NOT NULL UNIQUE,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE mini_members (
    league_id   integer     NOT NULL REFERENCES mini_leagues,
    entry_id    integer     NOT NULL REFERENCES entries,
    joined_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (league_id, entry_id)
);

-- changes
CREATE TABLE audit_log (
    log_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name  text        NOT NULL,
    op          audit_op    NOT NULL,
    row_pk      text        NOT NULL,              
    old_row     jsonb,
    new_row     jsonb,
    changed_at  timestamptz NOT NULL DEFAULT now(),   
    game_time   timestamptz,                         
    changed_by  text        NOT NULL DEFAULT current_user
);

-- settings
CREATE TABLE app_settings (
    key    text  PRIMARY KEY,
    value  text  NOT NULL
);

-- staging
CREATE TABLE stg_raw (
    id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    season_name  text        NOT NULL,                -- '2025/26'
    source       source_kind NOT NULL,
    kind         stg_kind    NOT NULL,
    payload      jsonb       NOT NULL,
    loaded_at    timestamptz NOT NULL DEFAULT now()
);
