# The values of the vignette, from the sources that need no key, read live: run from this folder with
#     julia --project=.. values.jl [folder]
# with DuckDB.jl installed; folder keeps the files downloaded (a temporary folder when none is given), so that a second
# run reads them from there. The values depend on the day: the vignette gives those of the day it names.
using SmartRegions, DuckDB, Tables, Dates

folder = isempty(ARGS) ? mktempdir() : mkpath(ARGS[1])
con = DBInterface.connect(DuckDB.DB)
foreach(sql -> DBInterface.execute(con, sql), ["LOAD spatial", "LOAD httpfs", "SET geometry_always_xy = true"])
scalar(sql) = only(only(Tables.columntable(DBInterface.execute(con, sql))))
shown(label, value) = println(rpad(label, 68), value)
println("Read on ", Dates.format(now(UTC), "yyyy-mm-dd HH:MM"), " UTC")

# Overture Maps and the OpenSky Network
r = overture(con, "building"; within = (151.2093, -33.8675, 300), columns = "id, height", table = "buildings")
shown("Overture: buildings within 300 m of Martin Place, release", "$(r.n), $(r.release)")
DBInterface.execute(con, "CREATE OR REPLACE TABLE aircraft AS " * opensky_states(around(151.2125, -33.858, 30_000)))
shown("OpenSky: aircraft within a box of 60 km around Sydney Harbour", scalar("SELECT count(*) FROM aircraft"))

# The catalogues of satellite scenes and topographic datasets, central Bologna
box = (11.30, 44.47, 11.37, 44.52)
shown("Copernicus: Sentinel-2 L2A scenes, June 2025, at most 10% cloud", copernicus_scenes(con, "sentinel-2-l2a"; box, days = ("2025-06-01", "2025-06-30"), cloud = 10))
shown("OpenTopography: datasets over the box", opentopography_catalog(con, box))

# OpenStreetMap
schools = osm_overpass((11.32, 44.48, 11.37, 44.51), "amenity=school")
shown("Overpass: features with amenity=school, central Bologna", osm_read(con, schools.file, "amenity=school"; folder, table = "schools"))
g = geofabrik_layer(con, "monaco", "pois"; folder, table = "pois")
shown("Geofabrik: points of interest of Monaco", g.n)

# The streets of central Cambridge, walking from the station to King's College Chapel
osm_streets(con, (0.105, 52.188, 0.145, 52.216); folder)
net = street_network(con, "walk")
from, off_from = nearest_node(con, net, 0.13772, 52.19411)
to, off_to = nearest_node(con, net, 0.11654, 52.20478)
path, minutes, km = fastest_route(net, from, to)
shown("Streets: nodes and directed edges open to walking", "$(length(net.ids)), $(sum(length, net.g.fadjlist))")
shown("Streets: fastest walk, minutes and km", "$(round(minutes; digits = 1)), $(round(km; digits = 2))")
shown("Streets: nodes reached within 15 minutes of the station", travel_times(con, net, from, 15))

# Eurostat and INSPIRE
nuts = gisco_file("nuts", "NUTS_RG_20M_2024_4326_LEVL_3"; folder)
DBInterface.execute(con, "CREATE OR REPLACE TABLE regions AS SELECT * FROM $(vector_units(con, nuts)) WHERE CNTR_CODE = 'PT'")
place = eurostat(con, "demo_r_d3dens", "A.PER_KM2.")
shown("GISCO: NUTS 3 regions of Portugal, those with a density of 2024", "$(scalar("SELECT count(*) FROM regions")), $(scalar("SELECT count(*) FROM regions r JOIN eurostat e ON e.\"$(place)\" = r.NUTS_ID AND e.TIME_PERIOD = '2024' AND e.OBS_VALUE IS NOT NULL"))")
shown("INSPIRE: datasets of administrative units, the Netherlands", inspire_search(con, "administrative units", "NL"; rows = 25))
w = wfs_features(con, "https://service.pdok.nl/kadaster/brk-administratieve-eenheden/wfs/v2_0", "au:administrativeunit"; folder, table = "wfs")
o = ogc_features(con, "https://api.pdok.nl/kadaster/brk-administratieve-eenheden/ogc/v1", "administrativeunit"; folder, table = "ogc")
a = atom_features(con, "https://service.pdok.nl/kadaster/brk-administratieve-eenheden/atom/index.xml", ""; layer = "AdministrativeUnit", folder, table = "atom")
shown("INSPIRE: administrative units by WFS, OGC API and Atom", "$(w.n), $(o.n), $(a.n)")

# Mobility
c = commuting_flows(con, "cambridge"; folder)
shown("Commuting, Cambridge: zones, workers between them, away, at home", "$(scalar("SELECT count(*) FROM zones")), $(round(Int, scalar("SELECT sum(flow) FROM flows"))), $(round(Int, c.away)), $(round(Int, c.home))")
t = trip_flows(con, "london"; month = "2026-05", folder)
shown("Trips, London, May 2026: zones, journeys between them, away", "$(scalar("SELECT count(*) FROM zones")), $(round(Int, scalar("SELECT sum(flow) FROM flows"))), $(round(Int, t.away))")
traffic_counts(con, "cambridge"; folder)
shown("Road counts, Cambridge: count points, first and last year", "$(scalar("SELECT count(DISTINCT site) FROM counts")), $(scalar("SELECT min(year) FROM counts")), $(scalar("SELECT max(year) FROM counts"))")
air_flights(con, "2022-12"; folder)
shown("Flights, December 2022: seen, with both airports", "$(scalar("SELECT count(*) FROM flights")), $(scalar("SELECT count(*) FROM flights WHERE origin IS NOT NULL AND destination IS NOT NULL"))")
