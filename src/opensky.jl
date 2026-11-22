# The OpenSky Network: requests to its REST API, anonymous or with an API client, whose answers are saved to JSON
# files, and the SQL that reads those files in DuckDB as tables

const OPENSKY = "https://opensky-network.org/api/"
const OPENSKY_TOKEN = "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"
const AGENT = "User-Agent" => "SmartRegions.jl (https://pollis.org)"
const CREDITS = Dict{String, String}()
const TOKEN = Ref(("", 0.0))

"""
    has_opensky_client()

Whether an OpenSky API client is set, as `ENV["OPENSKY_CLIENT_ID"]` and `ENV["OPENSKY_CLIENT_SECRET"]`: the client id
and secret created on the Account page of an OpenSky Network account. Without one, requests are anonymous.
"""
has_opensky_client() = haskey(ENV, "OPENSKY_CLIENT_ID") && haskey(ENV, "OPENSKY_CLIENT_SECRET")

"""
    opensky_credits()

The credits left today in each bucket of the OpenSky API (`"states"`, `"flights"`, `"tracks"`), as its last answer to
a request of that bucket reported them, in a `Dict`; empty before the first request.
"""
opensky_credits() = copy(CREDITS)

# Percent-encoding of a value in a form
encoded(s) = join(isletter(c) && isascii(c) || isdigit(c) || c in "-_.~" ? string(c) : join("%" * uppercase(string(b; base = 16, pad = 2)) for b in codeunits(string(c))) for c in s)

# An access token for the API client, kept for 25 of its 30 minutes
function token()
	time() < TOKEN[][2] && return TOKEN[][1]
	out = IOBuffer()
	r = Downloads.request(OPENSKY_TOKEN; method = "POST", output = out, throw = false,
		input = IOBuffer("grant_type=client_credentials&client_id=$(encoded(ENV["OPENSKY_CLIENT_ID"]))&client_secret=$(encoded(ENV["OPENSKY_CLIENT_SECRET"]))"),
		headers = ["Content-Type" => "application/x-www-form-urlencoded", AGENT])
	answer = String(take!(out))
	r isa Downloads.Response && r.status == 200 || error("The OpenSky Network refused the API client (HTTP $(r isa Downloads.Response ? r.status : r.message)): check ENV[\"OPENSKY_CLIENT_ID\"] and ENV[\"OPENSKY_CLIENT_SECRET\"]")
	TOKEN[] = (match(r"\"access_token\"\s*:\s*\"([^\"]+)\"", answer)[1], time() + 25 * 60)
	return TOKEN[][1]
end

"""
    opensky(path, file = tempname() * ".json"; account = has_opensky_client(), empty = "[]")

One request to the REST API of the OpenSky Network, `path` after `https://opensky-network.org/api/`, as
`"states/all?lamin=51.2&lomin=-0.7&lamax=51.8&lomax=0.4"`; its answer is written to `file`, which is returned. With
`account = true` the request carries the access token of the API client of [`has_opensky_client`](@ref); otherwise it
is anonymous. When the network has nothing (HTTP 404), `file` holds `empty`. The credits left that the answer reports
are kept for [`opensky_credits`](@ref). Spent credits (HTTP 429), a refused request and any other answer stop with a
message.
"""
function opensky(path::AbstractString, file::AbstractString = tempname() * ".json"; account::Bool = has_opensky_client(), empty::AbstractString = "[]")
	account && !has_opensky_client() && error("This request to the OpenSky Network needs an API client: set ENV[\"OPENSKY_CLIENT_ID\"] and ENV[\"OPENSKY_CLIENT_SECRET\"]. In Pollis, set them with the key on the Powered by line of Air Traffic")
	headers = [AGENT]
	account && push!(headers, "Authorization" => "Bearer $(token())")
	part = file * ".part"
	r = open(io -> Downloads.request(OPENSKY * path; output = io, headers = headers, throw = false), part, "w")
	r isa Downloads.Response || error("The OpenSky Network could not be reached: $(r.message)")
	answer = Dict(lowercase(k) => v for (k, v) in r.headers)
	bucket = String(first(split(path, '/')))
	haskey(answer, "x-rate-limit-remaining") && (CREDITS[bucket] = answer["x-rate-limit-remaining"])
	if r.status in (200, 404)
		r.status == 404 && write(part, empty)  # nothing found: no flights in the interval, or no track
		return mv(part, file; force = true)
	end
	said = first(read(part, String), 300)
	rm(part; force = true)
	r.status == 429 && error("The OpenSky credits for $(bucket) are spent: they refill in about $(round(parse(Int, get(answer, "x-rate-limit-retry-after-seconds", "86400")) / 3600; digits = 1)) hours")
	r.status in (401, 403) && error("The OpenSky Network refused the request (HTTP $(r.status)): $(said)" * (account ? "" : ". It needs an API client: see has_opensky_client"))
	error("The OpenSky Network answered HTTP $(r.status) to $(path): $(said)")
end

"""
    opensky_states(box; extended = true, account = has_opensky_client())

Asks the OpenSky Network for the state vectors of the aircraft over `box = (west, south, east, north)`, in degrees,
now, and returns the SQL that reads them in DuckDB, one row per aircraft: `seen`, `icao24`, `callsign`, `country`,
`positioned`, `last_contact`, `lon`, `lat`, `altitude` (barometric, m), `on_ground`, `velocity` (m/s), `heading`,
`vertical_rate`, `geo_altitude`, `squawk`, `source` (0 ADS-B, 1 ASTERIX, 2 MLAT, 3 FLARM) and `category`, times in
UTC. A box with no aircraft gives no rows. `extended` asks for the category of each aircraft.

```julia
DBInterface.execute(con, "CREATE OR REPLACE TABLE aircraft AS " * opensky_states((-0.7, 51.2, 0.4, 51.8)))  # London
```
"""
function opensky_states(box; extended::Bool = true, account::Bool = has_opensky_client())
	west, south, east, north = box
	file = opensky("states/all?lamin=$(south)&lomin=$(west)&lamax=$(north)&lomax=$(east)" * (extended ? "&extended=1" : ""); account, empty = "{\"time\": 0, \"states\": null}")
	return """SELECT make_timestamp(time * 1000000) AS seen, s->>0 AS icao24, nullif(trim(s->>1), '') AS callsign, s->>2 AS country,
		make_timestamp((s->>3)::BIGINT * 1000000) AS positioned, make_timestamp((s->>4)::BIGINT * 1000000) AS last_contact, (s->>5)::DOUBLE AS lon, (s->>6)::DOUBLE AS lat,
		(s->>7)::DOUBLE AS altitude, (s->>8)::BOOLEAN AS on_ground, (s->>9)::DOUBLE AS velocity, (s->>10)::DOUBLE AS heading, (s->>11)::DOUBLE AS vertical_rate,
		(s->>13)::DOUBLE AS geo_altitude, s->>14 AS squawk, (s->>16)::INTEGER AS source, (s->>17)::INTEGER AS category
		FROM (SELECT time, unnest(states) AS s FROM read_json('$(quoted(file))', columns = {time: 'BIGINT', states: 'JSON[]'}))"""
end

"""
    opensky_track(icao24; time = 0, account = has_opensky_client() || time != 0)

Asks the OpenSky Network for the track of the aircraft whose transponder has the ICAO 24-bit address `icao24`, as
`"7c6b2d"`: the flight it is on now with `time = 0`, or the flight it was on at `time`, a `DateTime` in UTC or seconds
since 1970, within the last 30 days, which needs an API client. Returns the SQL that reads the waypoints in DuckDB, one
row each: `icao24`, `callsign`, `time` (UTC), `lat`, `lon`, `altitude` (barometric, m), `heading` and `on_ground`;
or `nothing` when the network has no such track.

```julia
sql = opensky_track("7c6b2d")
sql === nothing || DBInterface.execute(con, "CREATE OR REPLACE TABLE track AS " * sql)
```
"""
function opensky_track(icao24::AbstractString; time = 0, account::Bool = has_opensky_client() || time != 0)
	at = time isa DateTime ? round(Int, datetime2unix(time)) : Int(time)
	file = opensky("tracks/all?icao24=$(lowercase(icao24))&time=$(at)"; account, empty = "{}")
	read(file, String) == "{}" && return nothing
	return """SELECT icao24, nullif(trim(callsign), '') AS callsign, make_timestamp((p->>0)::BIGINT * 1000000) AS time, (p->>1)::DOUBLE AS lat, (p->>2)::DOUBLE AS lon,
		(p->>3)::DOUBLE AS altitude, (p->>4)::DOUBLE AS heading, (p->>5)::BOOLEAN AS on_ground
		FROM (SELECT icao24, callsign, unnest(path) AS p FROM read_json('$(quoted(file))', columns = {icao24: 'VARCHAR', callsign: 'VARCHAR', startTime: 'DOUBLE', endTime: 'DOUBLE', path: 'JSON[]'}))"""
end

"""
    opensky_flights(airport, day; folder = nothing)

Asks the OpenSky Network for the arrivals and departures of the airport with the ICAO code `airport`, as `"EGLL"`, on
`day`, a `Date` in UTC, which needs an API client; the network adds the flights of a day overnight. Returns the SQL
that reads them in DuckDB, one row per flight: `direction` (`'arrival'` or `'departure'`), `icao24`, `callsign`,
`origin` and `destination` (the estimated airports), `other` (the airport at the other end), `first_seen` and
`last_seen` (UTC), the distances of the estimated airports from the first and last positions in metres
(`origin_distance`, `destination_distance`), and how many airports were candidates (`origin_candidates`,
`destination_candidates`). With `folder`, the answers are kept there and read again on a later call instead of asked
for.

```julia
DBInterface.execute(con, "CREATE OR REPLACE TABLE flights AS " * opensky_flights("EGLL", Date(2026, 11, 20)))
```
"""
function opensky_flights(airport::AbstractString, day::Date; folder = nothing)
	code = uppercase(strip(airport))
	first_second = round(Int, datetime2unix(DateTime(day)))
	columns = "columns = {icao24: 'VARCHAR', callsign: 'VARCHAR', firstSeen: 'BIGINT', lastSeen: 'BIGINT', estDepartureAirport: 'VARCHAR', estArrivalAirport: 'VARCHAR', estDepartureAirportHorizDistance: 'DOUBLE', estArrivalAirportHorizDistance: 'DOUBLE', departureAirportCandidatesCount: 'INTEGER', arrivalAirportCandidatesCount: 'INTEGER'}"
	parts = map(("arrival", "departure")) do direction
		file = joinpath(folder === nothing ? mktempdir() : folder, "flights-$(code)-$(day)-$(direction).json")
		isfile(file) || opensky("flights/$(direction)?airport=$(code)&begin=$(first_second)&end=$(first_second + 86399)", file; account = true)
		"""SELECT '$(direction)' AS direction, icao24, nullif(trim(callsign), '') AS callsign, estDepartureAirport AS origin, estArrivalAirport AS destination,
			$(direction == "arrival" ? "estDepartureAirport" : "estArrivalAirport") AS other, make_timestamp(firstSeen * 1000000) AS first_seen, make_timestamp(lastSeen * 1000000) AS last_seen,
			estDepartureAirportHorizDistance AS origin_distance, estArrivalAirportHorizDistance AS destination_distance, departureAirportCandidatesCount AS origin_candidates, arrivalAirportCandidatesCount AS destination_candidates
			FROM read_json('$(quoted(file))', $(columns))"""
	end
	return join(parts, " UNION ALL ")
end
