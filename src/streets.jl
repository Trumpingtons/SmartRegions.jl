# Street networks: the streets of OpenStreetMap over an area, the directed graph of those a mode of travel may use, and
# the fastest routes, travel times, service areas and matrices on it

"""
    osm_streets(con, box; pbf = nothing, folder, server = "https://overpass-api.de/api/interpreter")

The ways of OpenStreetMap with a highway tag over `box = (west, south, east, north)`, in degrees, from the Overpass
API (its answer kept in `folder`, one file for each box, which a later call reads) or, with `pbf`, from that PBF file
(as an extract of Geofabrik). Writes the tables `ways` (`id`, `tags`, `refs`), `points` (the nodes inside the box:
`id`, `lon`, `lat`) and `segments` on the DuckDB connection `con`: each way cut into segments between consecutive
nodes (`way`, `a`, `b`, `class`, `name`, `tags`, `metres` on the WGS 84 ellipsoid, `geom`), the network cut at the
edges of the box. Returns the number of segments.
"""
function osm_streets(con, box; pbf = nothing, folder::AbstractString, server::AbstractString = OVERPASS)
	west, south, east, north = box
	if pbf === nothing
		file = joinpath(mkpath(folder), "overpass_$(west)_$(south)_$(east)_$(north).json")
		isfile(file) || write(file, overpass("[out:json][timeout:180];\nway[\"highway\"]($(south),$(west),$(north),$(east));\n(._; >;);\nout;", server))  # the ways, then their nodes
		elements = "(SELECT unnest(CAST(json_extract(content, '/elements') AS JSON[])) AS e FROM read_text('$(quoted(file))'))"
		DBInterface.execute(con, "CREATE OR REPLACE TABLE ways AS SELECT CAST(e->>'id' AS BIGINT) AS id, CAST(e->'tags' AS MAP(VARCHAR, VARCHAR)) AS tags, CAST(e->'nodes' AS BIGINT[]) AS refs FROM $(elements) WHERE e->>'type' = 'way'")
		DBInterface.execute(con, "CREATE OR REPLACE TABLE points AS SELECT CAST(e->>'id' AS BIGINT) AS id, CAST(e->>'lon' AS DOUBLE) AS lon, CAST(e->>'lat' AS DOUBLE) AS lat FROM $(elements) WHERE e->>'type' = 'node'")
	else
		DBInterface.execute(con, "CREATE OR REPLACE TABLE ways AS SELECT id, tags, refs FROM ST_ReadOSM('$(quoted(pbf))') WHERE kind = 'way' AND tags['highway'] IS NOT NULL")
		DBInterface.execute(con, "CREATE OR REPLACE TABLE points AS SELECT id, lon, lat FROM ST_ReadOSM('$(quoted(pbf))') WHERE kind = 'node' AND id IN (SELECT unnest(refs) FROM ways)")
	end
	DBInterface.execute(con, "DELETE FROM points WHERE NOT (lon BETWEEN $(west) AND $(east) AND lat BETWEEN $(south) AND $(north))")  # the network is cut at the edges of the area
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE segments AS
	WITH p AS (SELECT id AS way, unnest(refs) AS node, generate_subscripts(refs, 1) AS i FROM ways)
	SELECT a.way, a.node AS a, b.node AS b, w.tags['highway'] AS class, w.tags['name'] AS name, w.tags AS tags,
		ST_Distance_Spheroid(ST_Point(pa.lon, pa.lat), ST_Point(pb.lon, pb.lat)) AS metres, ST_MakeLine(ST_Point(pa.lon, pa.lat), ST_Point(pb.lon, pb.lat)) AS geom
	FROM p a JOIN p b ON a.way = b.way AND b.i = a.i + 1 JOIN ways w ON w.id = a.way JOIN points pa ON pa.id = a.node JOIN points pb ON pb.id = b.node
	WHERE a.node <> b.node
	""")
	return scalar(con, "SELECT count(*) FROM segments")
end

# The segments a mode may use, the directions it may travel them in, and its speed in km/h, in SQL
function rules(mode)
	t(key) = "coalesce(tags['$(key)'], '')"
	closed(key) = "$(t(key)) IN ('no', 'private')"
	open_to(key) = "$(t(key)) IN ('yes', 'designated', 'permissive')"
	oneway = "CASE WHEN $(t("oneway")) = '-1' THEN 'backward' WHEN $(t("oneway")) IN ('yes', 'true', '1') OR $(t("junction")) = 'roundabout' OR class = 'motorway' THEN 'forward' ELSE 'both' END"
	roads = "'living_street', 'residential', 'service', 'unclassified', 'road', 'tertiary', 'tertiary_link', 'secondary', 'secondary_link', 'primary', 'primary_link'"
	mode == "walk" && return ("class IN ($(roads), 'footway', 'path', 'pedestrian', 'steps', 'track', 'cycleway', 'bridleway', 'trunk', 'trunk_link') AND NOT $(closed("foot")) AND (NOT $(closed("access")) OR $(open_to("foot")))", "'both'", "4.8")
	mode == "cycle" && return ("(class IN ($(roads), 'cycleway', 'path', 'track', 'bridleway') OR (class IN ('footway', 'pedestrian') AND $(open_to("bicycle")))) AND NOT ($(closed("bicycle")) OR $(t("bicycle")) = 'dismount') AND (NOT $(closed("access")) OR $(open_to("bicycle")))",
		"CASE WHEN $(t("oneway:bicycle")) = 'no' THEN 'both' ELSE $(oneway) END", "15.0")
	mode == "drive" || throw(ArgumentError("No mode $(repr(mode)): the modes are walk, cycle and drive"))
	speed = "coalesce(TRY_CAST(regexp_extract($(t("maxspeed")), '^([0-9]+)', 1) AS DOUBLE) * CASE WHEN $(t("maxspeed")) LIKE '%mph%' THEN 1.609344 ELSE 1 END,
		CASE class WHEN 'motorway' THEN 110 WHEN 'trunk' THEN 90 WHEN 'primary' THEN 60 WHEN 'secondary' THEN 50 WHEN 'tertiary' THEN 40 WHEN 'living_street' THEN 10 WHEN 'service' THEN 15
		WHEN 'motorway_link' THEN 60 WHEN 'trunk_link' THEN 50 WHEN 'primary_link' THEN 40 WHEN 'secondary_link' THEN 40 ELSE 30 END)"  # the speed limit, else a speed for the class
	return ("class IN ($(roads), 'motorway', 'motorway_link', 'trunk', 'trunk_link') AND NOT ($(closed("access")) OR $(closed("motor_vehicle")) OR $(closed("motorcar")))", oneway, speed)
end

"""
    street_network(con, mode; keep = true)

The directed graph of the segments of the table `segments` (from [`osm_streets`](@ref)) on the DuckDB connection
`con` that `mode` may use: `"walk"` (both ways, at 4.8 km/h), `"cycle"` (one-way streets one way unless open to
bicycles both ways, at 15 km/h) or `"drive"` (one-way streets one way, at the speed limit, else a speed for the class
of road), by the tags of access of OpenStreetMap. With `keep`, the segments are written to the table `network`, with
their `direction` and `seconds`. Returns `(; mode, g, ids, main, lon, lat, seconds, metres)`: the graph (a
`SimpleDiGraph` of Graphs.jl), the OpenStreetMap id and position of each of its nodes, the nodes of its largest
strongly connected part (in which every node reaches every other), and the seconds and metres of each edge, as sparse
matrices.
"""
function street_network(con, mode::AbstractString; keep::Bool = true)
	allowed, direction, kmh = rules(mode)
	pick = "SELECT *, $(direction) AS direction, metres / ($(kmh) / 3.6) AS seconds FROM segments WHERE $(allowed)"
	keep && DBInterface.execute(con, "CREATE OR REPLACE TABLE network AS $(pick)")
	e = Tables.columntable(DBInterface.execute(con, "SELECT a AS u, b AS v, seconds, metres FROM ($(pick)) WHERE direction <> 'backward' UNION ALL SELECT b, a, seconds, metres FROM ($(pick)) WHERE direction <> 'forward'"))
	isempty(e.u) && error("The area has no streets open to $(mode)")
	ids = unique([e.u; e.v])
	index = Dict(id => k for (k, id) in enumerate(ids))
	us, vs = [index[x] for x in e.u], [index[x] for x in e.v]
	g = SimpleDiGraph(length(ids))
	foreach((x, y) -> add_edge!(g, x, y), us, vs)
	xy = Tables.columntable(DBInterface.execute(con, "SELECT id, lon, lat FROM points"))
	at = Dict(zip(xy.id, zip(xy.lon, xy.lat)))
	main = argmax(length, strongly_connected_components(g))
	n = length(ids)
	return (; mode, g, ids, main, lon = [at[i][1] for i in ids], lat = [at[i][2] for i in ids],
		seconds = sparse(us, vs, Float64.(e.seconds), n, n, min), metres = sparse(us, vs, Float64.(e.metres), n, n, min))
end

"""
    nearest_node(con, net, lon, lat)

The node of the largest strongly connected part of the network `net` (from [`street_network`](@ref)) nearest to the
point `lon`, `lat`, and its distance in metres on the WGS 84 ellipsoid, from DuckDB's `ST_Distance_Spheroid` on the
connection `con`, as `(node, metres)`.
"""
function nearest_node(con, net, lon::Real, lat::Real)
	k = argmin(k -> hypot((net.lon[k] - lon) * cosd(lat), net.lat[k] - lat), net.main)
	return k, scalar(con, "SELECT ST_Distance_Spheroid(ST_Point($(lon), $(lat)), ST_Point($(net.lon[k]), $(net.lat[k])))")
end

"""
    fastest_route(net, from, to)

The fastest path from the node `from` to the node `to` of the network `net` (from [`street_network`](@ref)), by
Dijkstra's algorithm on the seconds of its edges: `(path, minutes, km)`, the nodes of the path, empty when there is
none, and its minutes and kilometres.
"""
function fastest_route(net, from::Integer, to::Integer)
	found = dijkstra_shortest_paths(net.g, from, net.seconds)
	path = enumerate_paths(found, to)
	return path, found.dists[to] / 60, sum(net.metres[path[i], path[i + 1]] for i in 1:length(path) - 1; init = 0.0) / 1000
end

"""
    travel_times(con, net, from, minutes; table = "reached")

The seconds from the node `from` of the network `net` (from [`street_network`](@ref)) to every node it reaches within
`minutes`, by its fastest path, written to the table `table` on the DuckDB connection `con` (`id`, the OpenStreetMap
id of the node, and `seconds`), which [`service_areas`](@ref) reads. Returns the number of nodes reached.
"""
function travel_times(con, net, from::Integer, minutes::Real; table::AbstractString = "reached")
	found = dijkstra_shortest_paths(net.g, from, net.seconds)
	near = findall(<=(60 * minutes), found.dists)
	csv = tempname() * ".csv"
	write(csv, "id,seconds\n" * join(["$(net.ids[k]),$(found.dists[k])" for k in near], "\n"))
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT * FROM read_csv('$(quoted(csv))', columns = {'id': 'BIGINT', 'seconds': 'DOUBLE'}, header = true)")
	rm(csv)
	return length(near)
end

"""
    service_areas(table, mode, bands)

SQL that gives, for each travel time of `bands` (in minutes), the area reached within it in the table `table` of
[`travel_times`](@ref): the concave hull of the nodes reached (`geom`), their number (`nodes`), and the kilometres of
the streets of the table `network` both of whose ends are reached (`street_km`), with `mode` and `band`. The tables
`points` and `network` of [`osm_streets`](@ref) and [`street_network`](@ref) should be on the same connection.
"""
function service_areas(table::AbstractString, mode::AbstractString, bands)
	return """SELECT '$(quoted(mode))' AS mode, b.band, ST_ConcaveHull(ST_Collect(list(ST_Point(p.lon, p.lat))), 0.3, false) AS geom, count(*) AS nodes,
		(SELECT round(sum(n.metres) / 1000, 2) FROM network n JOIN $(table) ra ON ra.id = n.a JOIN $(table) rb ON rb.id = n.b WHERE greatest(ra.seconds, rb.seconds) <= 60 * b.band) AS street_km
	FROM (SELECT unnest([$(join(bands, ", "))]) AS band) b JOIN $(table) r ON r.seconds <= 60 * b.band JOIN points p ON p.id = r.id GROUP BY b.band"""
end

"""
    travel_matrix(net, nodes)

The minutes and kilometres of the fastest path between every pair of the nodes `nodes` of the network `net` (from
[`street_network`](@ref)), as two matrices, a row for each node of departure; `Inf` where there is no path.
"""
function travel_matrix(net, nodes)
	minutes, km = fill(Inf, length(nodes), length(nodes)), fill(Inf, length(nodes), length(nodes))
	for (i, from) in enumerate(nodes)
		found = dijkstra_shortest_paths(net.g, from, net.seconds)
		for (j, to) in enumerate(nodes)
			isfinite(found.dists[to]) || continue
			path = enumerate_paths(found, to)
			minutes[i, j], km[i, j] = found.dists[to] / 60, sum(net.metres[path[k], path[k + 1]] for k in 1:length(path) - 1; init = 0.0) / 1000
		end
	end
	return minutes, km
end
