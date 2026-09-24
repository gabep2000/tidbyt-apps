"""
NFL Scores — Tidbyt app

Pulls the NFL scoreboard from ESPN's public (unofficial) scoreboard endpoint
and cycles through every game, showing each team's logo, score, and brand
color.

Monday–Wednesday (before Thursday Night Football), it shows last week's
final scores. From Thursday on, it switches to the new week: games already
underway or finished show live/final scores as usual, and games that
haven't kicked off yet show the matchup plus each team's current
season-leading player as a "player to watch" — NOT a real per-game fantasy
projection (no free API provides that), just their most productive player
so far this season.

Config options (set from the Tidbyt mobile app):
  - team:      3-letter team abbreviation (e.g. KC, DAL, SF) to highlight
  - fav_only:  if on, only show games involving that team
"""

load("render.star", "render")
load("http.star", "http")
load("encoding/json.star", "json")
load("encoding/base64.star", "base64")
load("cache.star", "cache")
load("schema.star", "schema")
load("time.star", "time")

ESPN_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
LOGO_URL_TEMPLATE = "https://a.espncdn.com/i/teamlogos/nfl/500/%s.png"
TEAM_INFO_URL_TEMPLATE = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/%s?enable=leaders"
TIMEZONE = "America/New_York"
DEFAULT_TEAM = ""
FRAME_DELAY_MS = 800
LOGO_SIZE = 10
LOGO_CACHE_TTL = 21600  # 6 hours — logos rarely change
LEADER_CACHE_TTL = 3600  # 1 hour — season leaders shift slowly
DEFAULT_COLOR = "#ffffff"
HIGHLIGHT_COLOR = "#ffcc00"
STATUS_COLOR = "#7fd4ff"
LEADER_COLOR = "#aaaaaa"
ERROR_COLOR = "#ff5555"
PRE_WEEK_DAYS = ("Mon", "Tue", "Wed")  # before Thursday night, show last week's finals

# Primary brand color per NFL team abbreviation (as used by ESPN's API).
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

def main(config):
    fav_team = config.get("team", DEFAULT_TEAM)
    if fav_team:
        fav_team = fav_team.upper()
    fav_only = config.bool("fav_only", False)

    now = time.now().in_location(TIMEZONE)
    weekday = now.format("Mon")

    data = fetch_scoreboard(ESPN_URL)
    if data == None:
        return error_root("NFL data unavailable")

    # If it's Mon/Tue/Wed and none of "this week"'s games have kicked off yet,
    # ESPN's own pointer has already flipped to the upcoming week — pull the
    # previous (fully completed) week instead. From Thursday on, use whatever
    # week ESPN is currently pointing to.
    if weekday in PRE_WEEK_DAYS and not any_game_started(data):
        week_num = data.get("week", {}).get("number")
        season = data.get("season", {})
        year = season.get("year")
        season_type = season.get("type")
        if week_num and year and season_type and week_num > 1:
            prev_url = "%s?week=%d&seasontype=%d&year=%d" % (ESPN_URL, week_num - 1, season_type, year)
            prev_data = fetch_scoreboard(prev_url)
            if prev_data != None:
                data = prev_data

    games = extract_games(data, fav_team, fav_only)

    if len(games) == 0:
        msg = "No games for " + fav_team if fav_only and fav_team else "No NFL games found"
        return error_root(msg)

    frames = []
    for g in games:
        if g["state"] == "pre":
            frames.append(upcoming_frame(g, fav_team))
        else:
            frames.append(game_frame(g, fav_team))

    return render.Root(
        delay = FRAME_DELAY_MS,
        child = render.Animation(children = frames),
    )

def fetch_scoreboard(url):
    res = http.get(url, ttl_seconds = 60)
    if res.status_code != 200:
        return None
    return json.decode(res.body())

def any_game_started(data):
    for event in data.get("events", []):
        state = event.get("status", {}).get("type", {}).get("state", "pre")
        if state != "pre":
            return True
    return False

def extract_games(data, fav_team, fav_only):
    games = []
    for event in data.get("events", []):
        competitions = event.get("competitions", [])
        if len(competitions) == 0:
            continue
        comp = competitions[0]
        competitors = comp.get("competitors", [])

        home = None
        away = None
        for c in competitors:
            if c.get("homeAway") == "home":
                home = c
            else:
                away = c

        if not home or not away:
            continue

        away_abbr = away["team"]["abbreviation"].upper()
        home_abbr = home["team"]["abbreviation"].upper()

        if fav_only and fav_team and fav_team != away_abbr and fav_team != home_abbr:
            continue

        status_type = event.get("status", {}).get("type", {})

        games.append(dict(
            away_abbr = away_abbr,
            home_abbr = home_abbr,
            away_score = away.get("score", "0"),
            home_score = home.get("score", "0"),
            status = status_type.get("shortDetail", ""),
            state = status_type.get("state", "post"),
        ))

    return games

def game_frame(g, fav_team):
    # Fixed heights that sum to exactly 32px (the display height) so both
    # teams are always fully visible instead of the second row getting cut off.
    return render.Column(
        children = [
            render.Box(
                height = 6,
                child = render.Text(
                    content = g["status"],
                    font = "tom-thumb",
                    color = STATUS_COLOR,
                ),
            ),
            render.Box(height = 13, child = team_row(g["away_abbr"], g["away_score"], fav_team)),
            render.Box(height = 13, child = team_row(g["home_abbr"], g["home_score"], fav_team)),
        ],
    )

def team_row(abbr, score, fav_team):
    color = HIGHLIGHT_COLOR if fav_team and abbr == fav_team else TEAM_COLORS.get(abbr, DEFAULT_COLOR)
    logo = get_logo(abbr)

    left_children = []
    if logo:
        left_children.append(render.Image(src = logo, width = LOGO_SIZE, height = LOGO_SIZE))
        left_children.append(render.Box(width = 3))
    left_children.append(render.Text(content = abbr, font = "6x13", color = color))

    return render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Row(cross_align = "center", children = left_children),
            render.Text(content = str(score), font = "6x13", color = color),
        ],
    )

def upcoming_frame(g, fav_team):
    # Same fixed-height layout as a finished/live game, but the score column
    # is swapped for each team's current season statistical leader — the
    # closest honest stand-in for a "predicted fantasy leader" available
    # without a paid projections service.
    return render.Column(
        children = [
            render.Box(
                height = 6,
                child = render.Text(
                    content = g["status"],
                    font = "tom-thumb",
                    color = STATUS_COLOR,
                ),
            ),
            render.Box(height = 13, child = leader_row(g["away_abbr"], fav_team)),
            render.Box(height = 13, child = leader_row(g["home_abbr"], fav_team)),
        ],
    )

def leader_row(abbr, fav_team):
    color = HIGHLIGHT_COLOR if fav_team and abbr == fav_team else TEAM_COLORS.get(abbr, DEFAULT_COLOR)
    logo = get_logo(abbr)
    leader = get_season_leader(abbr)

    left_children = []
    if logo:
        left_children.append(render.Image(src = logo, width = LOGO_SIZE, height = LOGO_SIZE))
        left_children.append(render.Box(width = 3))
    left_children.append(render.Text(content = abbr, font = "6x13", color = color))

    return render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Row(cross_align = "center", children = left_children),
            render.Text(content = leader or "--", font = "tom-thumb", color = LEADER_COLOR),
        ],
    )

def get_season_leader(abbr):
    cache_key = "nfl_leader_%s" % abbr
    cached = cache.get(cache_key)
    if cached != None:
        return cached if cached != "" else None

    url = TEAM_INFO_URL_TEMPLATE % abbr.lower()
    res = http.get(url, ttl_seconds = LEADER_CACHE_TTL)
    if res.status_code != 200:
        return None

    data = json.decode(res.body())
    categories = data.get("team", {}).get("leaders", [])

    # Prefer the passing leader (usually the starting QB — the single most
    # fantasy-relevant player on most teams); fall back to whatever's first.
    chosen = None
    for cat in categories:
        if cat.get("name") == "passingYards":
            chosen = cat
            break
    if chosen == None and len(categories) > 0:
        chosen = categories[0]

    name = ""
    if chosen != None:
        leaders = chosen.get("leaders", [])
        if len(leaders) > 0:
            athlete = leaders[0].get("athlete", {})
            name = athlete.get("shortName", "") or athlete.get("lastName", "")

    cache.set(cache_key, name, ttl_seconds = LEADER_CACHE_TTL)
    return name if name != "" else None

def get_logo(abbr):
    cache_key = "nfl_logo_%s" % abbr
    cached = cache.get(cache_key)
    if cached != None:
        return base64.decode(cached)

    url = LOGO_URL_TEMPLATE % abbr.lower()
    res = http.get(url)
    if res.status_code != 200:
        return None

    img = res.body()
    cache.set(cache_key, base64.encode(img), ttl_seconds = LOGO_CACHE_TTL)
    return img

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
                id = "team",
                name = "Favorite team",
                desc = "3-letter team abbreviation, e.g. KC, DAL, SF (optional)",
                icon = "football",
                default = DEFAULT_TEAM,
            ),
            schema.Toggle(
                id = "fav_only",
                name = "Only show favorite team",
                desc = "If on, only your team's game(s) will be shown instead of cycling through all games.",
                icon = "star",
                default = False,
            ),
        ],
    )
