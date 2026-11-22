# SmartRegions.jl

Open data of places for smart cities and regions, read into DuckDB from Julia.

- **Overture Maps**: the buildings, places, roads, boundaries and addresses of an area, read over HTTPS from the GeoParquet files of the newest release, only the parts that overlap the area.
- **The OpenSky Network**: the aircraft over an area now, the track of an aircraft, and the arrivals and departures of an airport on a day, from its REST API, anonymous or with an API client.
- **Mapillary**: the street-level images of an area from its coverage tiles or its image search, its map features (traffic signs and other objects detected in the images), the images near a point, and thumbnails.
- **The Copernicus Data Space Ecosystem**: the scenes of a collection (Sentinel-1, -2, -3, -5P and others) over an area from its STAC catalogue, and the files of their bands.
- **USGS EarthExplorer**: the scenes of a dataset (Landsat and others) over an area, the bands of a Landsat scene, and the SRTM tiles of an area, from its Machine-to-Machine API.
- **OpenTopography**: the topographic datasets over an area from its catalogue, and the elevation of an area from a global model or from USGS 3DEP.
- **Google's maps**: pages with Google's 2D maps (roadmap, satellite, terrain) or its photorealistic 3D map, with features of one's own drawn on them, coloured by a column: polygons raised to a height, lines at their altitudes, points with labels.
- **Places**: the box around a point, the UTM zone of a point, a box in another coordinate system, and GeoJSON written from a query.

The functions that read data take a DuckDB connection with the extensions `spatial` and, for files over HTTPS, `httpfs` loaded. Overture Maps, Mapillary and the catalogues of satellite scenes and topographic datasets are read into tables; the OpenSky functions return the SQL that reads what they downloaded, to make a table of or join with others. The files of bands and elevation models are downloaded once into a folder and returned as paths, to read with Rasters.jl. The map functions write an HTML page and return its path; the page holds the key, so it is written to a temporary folder that Julia removes when it exits.

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

# The Sentinel-2 scenes over central Bologna in June 2025 with at most 10% of clouds, from the catalogue, which needs no account
box = (11.30, 44.47, 11.37, 44.52)
copernicus_scenes(con, "sentinel-2-l2a"; box, days = ("2025-06-01", "2025-06-30"), cloud = 10)
scene = only(Tables.columntable(DBInterface.execute(con, "SELECT id FROM scenes ORDER BY covered DESC, cloud LIMIT 1")).id)
red = copernicus_band(con, scene, "B04_10m"; folder = "copernicus")  # the red band, with an account
x0, y0, x1, y1 = projected_box(con, box, red.crs)  # the box in the band's UTM zone, to crop it with Rasters.jl

# The elevation of the same box from Copernicus GLO-30, by OpenTopography
dem = opentopography_dem(box, "COP30"; folder = "opentopography")

# The Mapillary images within 100 m of the Piazza Maggiore, with their distance from it
mapillary_near(con, 11.3426, 44.4938, 100)
```

## Keys and Accounts

Google's maps need a key of the Google Maps Platform, as `ENV["GOOGLE_MAPS_API_KEY"]` or the keyword `key`; a Maps Demo Key, without billing, covers the 2D and 3D maps. The OpenSky Network answers anonymous requests for the aircraft now and live tracks; the flights of an airport and past tracks need an API client, created on the Account page of an OpenSky Network account, as `ENV["OPENSKY_CLIENT_ID"]` and `ENV["OPENSKY_CLIENT_SECRET"]`. Mapillary needs a client access token of an application registered on mapillary.com, as `ENV["MAPILLARY_ACCESS_TOKEN"]` or the keyword `token`. The catalogue of the Copernicus Data Space Ecosystem needs no account; the files of its bands need one, as `ENV["CDSE_USERNAME"]` and `ENV["CDSE_PASSWORD"]`. USGS EarthExplorer needs a USGS account with access to its Machine-to-Machine API, as `ENV["USGS_USERNAME"]` and an application token, `ENV["USGS_TOKEN"]`. The catalogue of OpenTopography needs no key; its elevation models need an API key, as `ENV["OPENTOPOGRAPHY_API_KEY"]` or the keyword `key`. Overture Maps needs nothing.

The terms of each source apply to what is read from it: the Google Maps Platform Terms of Service to the maps, the licences of Overture Maps (ODbL, CDLA Permissive 2.0 and others, given for each feature in `license`) to its data, the terms of use of the OpenSky Network to its data, and the terms of Mapillary, the Copernicus Data Space Ecosystem, USGS and OpenTopography, and of each dataset's provider, to theirs.

## Licence

MIT.
