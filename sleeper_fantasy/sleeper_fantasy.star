"""
Sleeper Fantasy Football — Tidbyt app

Pulls your live fantasy lineup from Sleeper's public API (no login/API key
required) and cycles through each of your starters: NFL team logo, name,
roster slot (including FLEX/SUPERFLEX), and live fantasy points, all
colored by that player's NFL team.

Note: Sleeper's free API only exposes ACTUAL points once players start/finish
playing (correctly 0 before kickoff) — it does not expose pre-game projected
points for individual players. That data isn't available through any free
API, so this shows real live/final scoring only, never a fabricated guess.

Config options (set from the Tidbyt mobile app):
  - league_id: your Sleeper league ID (League -> gear icon -> League ID)
  - username:  your Sleeper account username (not display name)
"""

load("render.star", "render")
load("http.star", "http")
load("encoding/json.star", "json")
load("encoding/base64.star", "base64")
load("cache.star", "cache")
load("schema.star", "schema")
load("math.star", "math")

USER_URL_TEMPLATE = "https://api.sleeper.app/v1/user/%s"
ROSTERS_URL_TEMPLATE = "https://api.sleeper.app/v1/league/%s/rosters"
MATCHUPS_URL_TEMPLATE = "https://api.sleeper.app/v1/league/%s/matchups/%d"
LEAGUE_URL_TEMPLATE = "https://api.sleeper.app/v1/league/%s"
STATE_URL = "https://api.sleeper.app/v1/state/nfl"
PLAYERS_URL = "https://api.sleeper.app/v1/players/nfl"
ESPN_SCOREBOARD_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
LOGO_URL_TEMPLATE = "https://a.espncdn.com/i/teamlogos/nfl/500/%s.png"

DEFAULT_LEAGUE_ID = "1312058667234762752"
DEFAULT_USERNAME = "GabeP09"

FRAME_DELAY_MS = 1200
MY_COLOR = "#ffcc00"
POS_COLOR = "#aaaaaa"
ERROR_COLOR = "#ff5555"

USER_ID_CACHE_TTL = 21600  # 6 hours — username -> id never changes
ROSTER_CACHE_TTL = 15
MATCHUP_CACHE_TTL = 15
LEAGUE_CACHE_TTL = 21600  # 6 hours — roster slot structure is fixed for the season
NFL_SCORE_CACHE_TTL = 15
LOGO_CACHE_TTL = 21600  # 6 hours — logos rarely change
PLAYER_NAMES_CACHE_KEY = "sleeper_player_names_v4"
PLAYER_NAMES_CACHE_TTL = 2592000  # 30 days

DEFAULT_TEAM_COLOR = "#ffffff"

# Sleeper and ESPN don't always use the same team abbreviation — normalize
# Sleeper's version to ESPN's so logo/color/score lookups all line up.
SLEEPER_TO_ESPN_ABBR = {
    "WAS": "WSH",
}

# Primary brand color per NFL team abbreviation.
TEAM_COLORS = {
    "ARI": "#97233F",
    "ATL": "#A71930",
    "BAL": "#241773",
    "BUF": "#00338D",
    "CAR": "#0085CA",
    "CHI": "#0B162A",
    "CIN": "#FB4F14",
    "CLE": "#311D00",
    "DAL": "#003594",
    "DEN": "#FB4F14",
    "DET": "#0076B6",
    "GB": "#203731",
    "HOU": "#03202F",
    "IND": "#002C5F",
    "JAX": "#101820",
    "KC": "#E31837",
    "LV": "#A5ACAF",
    "LAC": "#0080C6",
    "LAR": "#003594",
    "MIA": "#008E97",
    "MIN": "#4F2683",
    "NE": "#002244",
    "NO": "#D3BC8D",
    "NYG": "#0B2265",
    "NYJ": "#125740",
    "PHI": "#004C54",
    "PIT": "#FFB612",
    "SF": "#AA0000",
    "SEA": "#69BE28",
    "TB": "#D50A0A",
    "TEN": "#4B92DB",
    "WSH": "#FFB612",
}

BENCH_SLOT_TYPES = ("BN", "TAXI", "IR")
SLOT_ABBR = {
    "QB": "QB",
    "RB": "RB",
    "WR": "WR",
    "TE": "TE",
    "FLEX": "FLEX",
    "SUPER_FLEX": "SFLX",
    "DEF": "DEF",
    "K": "K",
    "DL": "DL",
    "LB": "LB",
    "DB": "DB",
    "IDP_FLEX": "IDPF",
}

def main(config):
    league_id = config.get("league_id", DEFAULT_LEAGUE_ID)
    username = config.get("username", DEFAULT_USERNAME)

    if not league_id or not username:
        return error_root("Set league ID + username")

    user_id = get_user_id(username)
    if user_id == None:
        return error_root("Sleeper user not found")

    rosters = fetch_json(ROSTERS_URL_TEMPLATE % league_id, ROSTER_CACHE_TTL)
    if rosters == None:
        return error_root("Sleeper data unavailable")

    my_roster = None
    for r in rosters:
        if r.get("owner_id") == user_id:
            my_roster = r
            break
    if my_roster == None:
        return error_root("No roster for that user")

    my_roster_id = my_roster.get("roster_id")

    state = fetch_json(STATE_URL, ROSTER_CACHE_TTL)
    week = state.get("week", 1) if state != None else 1

    matchups = fetch_json(MATCHUPS_URL_TEMPLATE % (league_id, week), MATCHUP_CACHE_TTL)
    if matchups == None:
        return error_root("Sleeper data unavailable")

    my_matchup = None
    for m in matchups:
        if m.get("roster_id") == my_roster_id:
            my_matchup = m
            break

    if my_matchup == None:
        return error_root("No matchup this week")

    starters = my_matchup.get("starters", [])
    players_points = my_matchup.get("players_points", {})

    slot_labels = get_slot_labels(league_id, len(starters))
    nfl_scores = get_nfl_scores()

    trimmed = load_player_cache()
    trimmed = ensure_players_loaded(starters, trimmed)

    frames = []
    for i, pid in enumerate(starters):
        info = trimmed.get(pid, dict(name = "?", short_name = "?", pos = "", team = ""))
        pts = players_points.get(pid, 0)
        label = slot_labels[i] if i < len(slot_labels) else info["pos"]
        team = info.get("team", "")
        game_info = nfl_scores.get(team)
        frames.append(player_frame(info.get("short_name", info["name"]), label, team, pts, game_info))

    return render.Root(
        delay = FRAME_DELAY_MS,
        child = render.Animation(children = frames),
    )

def get_slot_labels(league_id, expected_count):
    league_info = fetch_json(LEAGUE_URL_TEMPLATE % league_id, LEAGUE_CACHE_TTL)
    if league_info == None:
        return []

    roster_positions = league_info.get("roster_positions", [])
    starting_slots = [p for p in roster_positions if p not in BENCH_SLOT_TYPES]

    # Sleeper's "starters" array is ordered to match these starting slots
    # exactly (FLEX/SUPER_FLEX included) — if the counts don't line up for
    # some reason, bail out and let the caller fall back to each player's
    # own natural position instead of mislabeling anyone.
    if len(starting_slots) != expected_count:
        return []

    return [SLOT_ABBR.get(s, s[:5]) for s in starting_slots]

def get_nfl_scores():
    data = fetch_json(ESPN_SCOREBOARD_URL, NFL_SCORE_CACHE_TTL)
    scores = {}
    if data == None:
        return scores

    for event in data.get("events", []):
        comps = event.get("competitions", [])
        if len(comps) == 0:
            continue
        competitors = comps[0].get("competitors", [])
        if len(competitors) != 2:
            continue
        a, b = competitors[0], competitors[1]
        a_abbr = a.get("team", {}).get("abbreviation", "").upper()
        b_abbr = b.get("team", {}).get("abbreviation", "").upper()
        a_score = a.get("score", "0")
        b_score = b.get("score", "0")
        scores[a_abbr] = dict(own = a_abbr, own_score = a_score, opp = b_abbr, opp_score = b_score)
        scores[b_abbr] = dict(own = b_abbr, own_score = b_score, opp = a_abbr, opp_score = a_score)

    return scores

def get_logo(team):
    if not team:
        return None
    cache_key = "sleeper_logo_%s" % team
    cached = cache.get(cache_key)
    if cached != None:
        return base64.decode(cached) if cached != "" else None

    res = http.get(LOGO_URL_TEMPLATE % team.lower())
    if res.status_code != 200:
        cache.set(cache_key, "", ttl_seconds = LOGO_CACHE_TTL)
        return None

    img = res.body()
    cache.set(cache_key, base64.encode(img), ttl_seconds = LOGO_CACHE_TTL)
    return img

def fetch_json(url, ttl):
    if ttl and ttl > 0:
        res = http.get(url, ttl_seconds = ttl)
    else:
        res = http.get(url)  # no ttl_seconds passed => not cached, always live
    if res.status_code != 200:
        return None
    return json.decode(res.body())

def get_user_id(username):
    cache_key = "sleeper_userid_%s" % username
    cached = cache.get(cache_key)
    if cached != None:
        return cached if cached != "" else None

    data = fetch_json(USER_URL_TEMPLATE % username, USER_ID_CACHE_TTL)
    user_id = ""
    if data != None and type(data) == "dict":
        user_id = data.get("user_id", "") or ""

    cache.set(cache_key, user_id, ttl_seconds = USER_ID_CACHE_TTL)
    return user_id if user_id != "" else None

def load_player_cache():
    cached = cache.get(PLAYER_NAMES_CACHE_KEY)
    if cached == None:
        return {}
    return json.decode(cached)

def ensure_players_loaded(player_ids, trimmed):
    missing = [pid for pid in player_ids if pid not in trimmed]
    if len(missing) == 0:
        return trimmed

    res = http.get(PLAYERS_URL)
    if res.status_code != 200:
        return trimmed  # give up gracefully; missing ones just show "?"

    all_players = json.decode(res.body())
    for pid in missing:
        p = all_players.get(pid)
        if p == None:
            # Sleeper uses the team abbreviation itself as the ID for
            # team defenses (e.g. "PIT"), which won't be in the player dict.
            team = SLEEPER_TO_ESPN_ABBR.get(pid, pid)
            trimmed[pid] = dict(name = pid, short_name = pid, pos = "DEF", team = team)
        else:
            first = p.get("first_name", "") or ""
            last = p.get("last_name", "") or ""
            full = (first + " " + last).strip()
            # First-initial + last name is guaranteed to fit the display
            # width; the full name is kept too in case there's room for it.
            short = ("%s. %s" % (first[0], last)) if first and last else (full or "?")
            raw_team = p.get("team", "") or ""
            trimmed[pid] = dict(
                name = full if full else "?",
                short_name = short,
                pos = p.get("position", "") or "",
                team = SLEEPER_TO_ESPN_ABBR.get(raw_team, raw_team),
            )

    cache.set(PLAYER_NAMES_CACHE_KEY, json.encode(trimmed), ttl_seconds = PLAYER_NAMES_CACHE_TTL)
    return trimmed

def player_frame(short_name, pos, team, points, game_info):
    color = TEAM_COLORS.get(team, DEFAULT_TEAM_COLOR)
    logo = get_logo(team)
    label = "%s  %s" % (pos, team) if team else pos
    name_width = 64 - 12 if logo else 64  # leave room for the 10px logo + gap
    fpts_text = "FPTS: %s" % format_points(points)

    name_children = []
    if logo:
        name_children.append(render.Image(src = logo, width = 10, height = 10))
        name_children.append(render.Box(width = 2))
    # WrappedText, not a single Text line: if the name is too long for one
    # line it wraps to a second line instead of ever getting clipped.
    name_children.append(
        render.WrappedText(
            content = short_name,
            font = "tom-thumb",
            color = color,
            width = name_width,
            align = "left",
        ),
    )

    return render.Column(
        children = [
            render.Box(
                height = 6,
                child = render.Text(content = label, font = "tom-thumb", color = POS_COLOR),
            ),
            render.Box(
                height = 13,
                child = render.Row(cross_align = "center", children = name_children),
            ),
            render.Box(
                height = 13,
                child = render.Text(content = fpts_text, font = "6x13", color = color),
            ),
        ],
    )

def format_points(points):
    # Sleeper gives floats like 84.34 — round to one decimal for the tiny display.
    rounded = math.round(points * 10) / 10
    return str(rounded)

def error_root(message):
    return render.Root(
        child = render.Box(
            child = render.WrappedText(
                content = message,
                font = "tom-thumb",
                color = ERROR_COLOR,
                align = "center",
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "league_id",
                name = "Sleeper League ID",
                desc = "Found under League settings -> League ID, or in the app's URL",
                icon = "hashtag",
                default = DEFAULT_LEAGUE_ID,
            ),
            schema.Text(
                id = "username",
                name = "Sleeper username",
                desc = "Your Sleeper login username (not your display name)",
                icon = "user",
                default = DEFAULT_USERNAME,
            ),
        ],
    )