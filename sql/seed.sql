-- static data: positions and FPL scoring rules (2025/26)

INSERT INTO positions (position_id, code, name, squad_select, min_play, max_play) VALUES
    (1, 'GKP', 'Goalkeeper', 2, 1, 1),
    (2, 'DEF', 'Defender',   5, 3, 5),
    (3, 'MID', 'Midfielder', 5, 2, 5),
    (4, 'FWD', 'Forward',    3, 1, 3)
ON CONFLICT (position_id) DO UPDATE
    SET squad_select = EXCLUDED.squad_select, min_play = EXCLUDED.min_play, max_play = EXCLUDED.max_play;

-- points = points * LEAST(cap, value / per_units) when value >= min_value, else 0
-- position_id NULL = every position
TRUNCATE scoring_rules;
INSERT INTO scoring_rules (stat, position_id, points, per_units, min_value, cap, description) VALUES
    ('minutes',                NULL, 1, 1,  1,  1, 'played'),
    ('minutes',                NULL, 1, 1, 60,  1, 'played 60+'),
    ('goals_scored',           1,    6, 1,  1, NULL, NULL),
    ('goals_scored',           2,    6, 1,  1, NULL, NULL),
    ('goals_scored',           3,    5, 1,  1, NULL, NULL),
    ('goals_scored',           4,    4, 1,  1, NULL, NULL),
    ('assists',                NULL, 3, 1,  1, NULL, NULL),
    ('clean_sheets',           1,    4, 1,  1, NULL, 'stat already requires 60 min'),
    ('clean_sheets',           2,    4, 1,  1, NULL, NULL),
    ('clean_sheets',           3,    1, 1,  1, NULL, NULL),
    ('saves',                  1,    1, 3,  3, NULL, 'per 3 saves'),
    ('goals_conceded',         1,   -1, 2,  2, NULL, 'per 2 conceded'),
    ('goals_conceded',         2,   -1, 2,  2, NULL, NULL),
    ('penalties_saved',        NULL, 5, 1,  1, NULL, NULL),
    ('penalties_missed',       NULL,-2, 1,  1, NULL, NULL),
    ('yellow_cards',           NULL,-1, 1,  1, NULL, NULL),
    ('red_cards',              NULL,-3, 1,  1, NULL, NULL),
    ('own_goals',              NULL,-2, 1,  1, NULL, NULL),
    ('bonus',                  NULL, 1, 1,  1, NULL, 'as awarded'),
    ('defensive_contribution', 2,    2, 1, 10,  1, 'DEF: 10+ CBIT'),
    ('defensive_contribution', 3,    2, 1, 12,  1, 'MID/FWD: 12+ CBIRT'),
    ('defensive_contribution', 4,    2, 1, 12,  1, NULL);
