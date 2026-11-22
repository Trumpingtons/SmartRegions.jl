# SmartRegions.jl

Open data of places for smart cities and regions, read into DuckDB from Julia.

- **Overture Maps**: the buildings, places, roads, boundaries and addresses of an area, read over HTTPS from the GeoParquet files of the newest release, only the parts that overlap the area.
- **The OpenSky Network**: the aircraft over an area now, the track of an aircraft, and the arrivals and departures of an airport on a day, from its REST API, anonymous or with an API client.
- **Google's maps**: pages with Google's 2D maps (roadmap, satellite, terrain) or its photorealistic 3D map, with features of one's own drawn on them, coloured by a column: polygons raised to a height, lines at their altitudes, points with labels.
- **Places**: the box around a point, the UTM zone of a point, and GeoJSON written from a query.

The functions that read data take a DuckDB connection with the extensions `spatial` and, for files over HTTPS, `httpfs` loaded. Overture Maps is read into a table; the OpenSky functions return the SQL that reads what they downloaded, to make a table of or join with others. The map functions write an HTML page and return its path; the page holds the key, so it is written to a temporary folder that Julia removes when it exits.

## Usage

```julia
using SmartRegions, DuckDB, Tables

con = DBInterface.connect(DuckDB.DB)
foreach(sql -> DBInterface.execute(con, sql), ["LOAD spatial", "LOAD httpfs", "SET geometry_always_xy = true"])

# The buildings of Overture Maps within 300 m of Martin Place, Sydney, with their heights
r = overture(con, "building"; within = (151.2093, -33.8675, 300), columns = "id, names.primary AS name, height, num_floors", table = "buildings")
println(r.n, " buildings from Overture release ", r.release)

# Drawn on Google's 3D map, raised to their heights and coloured by them (a key of the Google Maps Platform)
ENV["GOOGLE_MAPS_API_KEY"] = "your key"
buildings = geojson(con, "SELECT name, height, geom FROM buildings WHERE height > 0")
page = googlemap3d("Sydney CBD, Buildings by Height", 151.2093, -33.8675; features = buildings, height = "height", column = "height")
# open page in a web browser; in Pollis, Pollis.browse(page)

# Google's satellite map of the harbour
googlemap("Sydney Harbour, Satellite", 151.2125, -33.858; types = "satellite", zoom = 16)

# The aircraft over a box of 60 km around the harbour now, from the OpenSky Network, and the track of the first one
DBInterface.execute(con, "CREATE OR REPLACE TABLE aircraft AS " * opensky_states(around(151.2125, -33.858, 30_000)))
first_aircraft = only(Tables.columntable(DBInterface.execute(con, "SELECT icao24 FROM aircraft WHERE NOT on_ground LIMIT 1")).icao24)
track = opensky_track(first_aircraft)
track === nothing || DBInterface.execute(con, "CREATE OR REPLACE TABLE track AS " * track)
opensky_credits()  # the credits left today
```

## Keys and Accounts

Google's maps need a key of the Google Maps Platform, as `ENV["GOOGLE_MAPS_API_KEY"]` or the keyword `key`; a Maps Demo Key, without billing, covers the 2D and 3D maps. The OpenSky Network answers anonymous requests for the aircraft now and live tracks; the flights of an airport and past tracks need an API client, created on the Account page of an OpenSky Network account, as `ENV["OPENSKY_CLIENT_ID"]` and `ENV["OPENSKY_CLIENT_SECRET"]`. Overture Maps needs neither.

The terms of each source apply to what is read from it: the Google Maps Platform Terms of Service to the maps, the licences of Overture Maps (ODbL, CDLA Permissive 2.0 and others, given for each feature in `license`) to its data, and the terms of use of the OpenSky Network to its data.

## Licence

MIT.
