# OpenStreetMap: the features of a tag over an area from the Overpass API, and the files of Geofabrik's regions (their
# layers as GeoPackages, their full extracts as PBF files), read in DuckDB through GDAL's OSM driver

const OVERPASS = "https://overpass-api.de/api/interpreter"
const GEOFABRIK = "https://download.geofabrik.de/"
const OSMCONF = "https://raw.githubusercontent.com/OSGeo/gdal/v3.10.0/ogr/ogrsf_frmts/osm/data/osmconf.ini"

# A Downloader with no limit on a silent connection: Overpass sends nothing until its result is ready, and Geofabrik's
# server may take a minute before the first byte of an older file
function patient()
	d = Downloads.Downloader()
	d.easy_hook = (easy, info) -> Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_TIME, 0)
	return d
end

# The answer of an Overpass API instance to a query, retried while the server is busy, as it asks
function overpass(query, server)
	downloader = patient()
	for k in 0:5
		out = IOBuffer()
		r = Downloads.request(server; method = "POST", input = IOBuffer(query), output = out, headers = [AGENT], downloader, timeout = 300)
		r isa Downloads.Response || error("Overpass could not be reached: $(r.message)")
		r.status == 200 && return take!(out)
		r.status in (429, 502, 503, 504) || error("Overpass refused the query (HTTP $(r.status)): $(first(String(take!(out)), 500))")
		k < 5 && (@info "Overpass is busy (HTTP $(r.status)): trying again in $(5 * 2^k) s"; sleep(5 * 2^k))
	end
	error("Overpass stayed busy: try again later, or give another instance as server")
end

# A tag as key and value: "key=value", or a key alone for every value
function tagpair(tag)
	occursin("=", tag) || return (String(strip(tag)), "")
	key, value = split(tag, "="; limit = 2)
	return (String(strip(key)), String(strip(value)))
end

"""
    osm_overpass(box, tag; date = nothing, server = "https://overpass-api.de/api/interpreter", file = tempname() * ".osm")

The features of OpenStreetMap with `tag` (`"key=value"`, or a key alone for every value, as `"amenity=library"` or
`"building"`) over `box = (west, south, east, north)`, in degrees, from an instance of the Overpass API: now, or as
they were on `date` (a `Date` or `"2020-01-01"`). Writes them, with the ways and nodes they are made of, to the OSM XML
file `file`, which [`osm_read`](@ref) reads. Returns `(; query, file, base)`: the query sent, the file, and the time
of the OpenStreetMap data the server holds.
"""
function osm_overpass(box, tag::AbstractString; date = nothing, server::AbstractString = OVERPASS, file::AbstractString = tempname() * ".osm")
	west, south, east, north = box
	key, value = tagpair(tag)
	selector = isempty(value) ? "[\"$(key)\"]" : "[\"$(key)\"=\"$(value)\"]"
	when = date === nothing ? "" : "[date:\"$(date)T00:00:00Z\"]"
	query = "[out:xml][timeout:180]$(when);\nnwr$(selector)($(south),$(west),$(north),$(east));\n(._; >;);\nout;"  # the features, then the ways and nodes they are made of
	write(file, overpass(query, server))
	m = match(r"osm_base=\"(?<t>[^\"]+)\"", open(io -> String(read(io, 2000)), file))
	return (; query, file, base = m === nothing ? "unknown" : String(m[:t]))
end

"""
    osm_read(con, file, tag; folder, table = "features")

The features with `tag` (`"key=value"`, or a key alone) of the OpenStreetMap file `file` (OSM XML or PBF), from the
five layers of GDAL's OSM driver, written to the table `table` on the DuckDB connection `con`: `osm_type` (node, way
or relation), `osm_id`, `value` (of the key), `name`, `layer`, `tags` (all of them, as JSON) and `geom`. GDAL's
configuration of the driver, `osmconf.ini`, is downloaded once into `folder`. Returns the number of features. A large
file takes minutes: GDAL builds every geometry in it.
"""
function osm_read(con, file::AbstractString, tag::AbstractString; folder::AbstractString, table::AbstractString = "features")
	key, value = tagpair(tag)
	osmconf = cached(OSMCONF, joinpath(folder, "osmconf.ini"))
	options = "open_options = ['CONFIG_FILE=$(quoted(osmconf))', 'TAGS_FORMAT=JSON', 'INTERLEAVED_READING=YES']"  # per layer, GDAL may drop features of larger files
	parts = String[]
	for layer in ("points", "lines", "multilinestrings", "multipolygons", "other_relations")
		from = "ST_Read('$(quoted(file))', layer = '$(layer)', $(options))"
		named = setdiff(Tables.columntable(DBInterface.execute(con, "DESCRIBE SELECT * FROM $(from)")).column_name, ["OGC_FID", "osm_id", "osm_way_id", "other_tags", "z_order", "geom"])  # tags with a column of their own in osmconf.ini
		tags = "json_merge_patch(coalesce(other_tags, '{}'), json_object($(join(["'$(c)', \"$(c)\"" for c in named], ", "))))"  # every tag; one the element lacks, null, is left out
		type, id = layer == "points" ? ("'node'", "osm_id") : layer == "lines" ? ("'way'", "osm_id") : layer == "multipolygons" ? ("CASE WHEN osm_id IS NULL THEN 'way' ELSE 'relation' END", "coalesce(osm_id, osm_way_id)") : ("'relation'", "osm_id")
		push!(parts, "SELECT $(type) AS osm_type, CAST($(id) AS BIGINT) AS osm_id, '$(layer)' AS layer, CAST($(tags) AS JSON) AS tags, geom FROM $(from)")
	end
	k = quoted(key)
	wanted = isempty(value) ? "tags->>'$(k)' IS NOT NULL" : "tags->>'$(k)' = '$(quoted(value))'"  # the nodes of the ways come with their own tags: only the features with the tag are kept
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT osm_type, osm_id, tags->>'$(k)' AS value, tags->>'name' AS name, layer, tags, geom FROM ($(join(parts, " UNION ALL "))) WHERE $(wanted)")
	return scalar(con, "SELECT count(*) FROM $(table)")
end

"""
    geofabrik_file(url, path)

A file of Geofabrik's server downloaded once to `path`, retried while the server is busy. Returns `true`, or `false`
when the server has no such file.
"""
function geofabrik_file(url::AbstractString, path::AbstractString)
	isfile(path) && return true
	part = path * ".part"  # complete files only: an interrupted download is not taken for one
	downloader = patient()
	for k in 0:4
		r = open(io -> Downloads.request(url; output = io, headers = [AGENT], downloader, timeout = 3600), part, "w")
		r isa Downloads.Response || (rm(part; force = true); error("Geofabrik's server could not be reached: $(r.message)"))
		r.status == 200 && (mv(part, path; force = true); return true)
		rm(part; force = true)
		r.status == 404 && return false
		r.status in (429, 500, 502, 503, 504) || error("Geofabrik's server refused $(url) (HTTP $(r.status))")
		k < 4 && (@info "Geofabrik's server is busy (HTTP $(r.status)): trying again in $(10 * 2^k) s"; sleep(10 * 2^k))
	end
	error("Geofabrik's server stayed busy: try again later")
end

# A region of Geofabrik by its id, as monaco, portugal or hong-kong: its name and the addresses of its files
function geofabrik_region(con, region)
	index = tempname() * ".json"
	geofabrik_file(GEOFABRIK * "index-v1-nogeom.json", index)
	regions = "(SELECT unnest(features).properties AS p FROM read_json('$(index)', maximum_object_size = 100000000))"
	r = Tables.columntable(DBInterface.execute(con, "SELECT p.name AS name, p.urls.pbf AS pbf, p.urls.shp AS shp FROM $(regions) WHERE p.id = '$(quoted(region))'"))
	isempty(r.name) && (rm(index); throw(ArgumentError("Geofabrik has no region $(region): its ids are on download.geofabrik.de, as monaco, portugal, hong-kong or cataluna")))
	parts = Tables.columntable(DBInterface.execute(con, "SELECT p.id AS id FROM $(regions) WHERE p.parent = '$(quoted(region))' ORDER BY id")).id
	rm(index)
	return (; name = only(r.name), pbf = only(r.pbf), shp = only(r.shp), parts)
end

# The names of the files in a zip archive, from the directory at its end, without reading the whole archive
function zip_entries(path)
	open(path) do io
		seek(io, max(0, filesize(path) - 65557))
		tail = read(io)
		k = findlast(i -> view(tail, i:i + 3) == [0x50, 0x4b, 0x05, 0x06], 1:length(tail) - 3)  # the end of the central directory
		u16(b, i) = Int(b[i]) | Int(b[i + 1]) << 8
		u32(b, i) = u16(b, i) | u16(b, i + 2) << 16
		seek(io, u32(tail, k + 16))
		directory = read(io, u32(tail, k + 12))
		names, i = String[], 1
		while i + 45 <= length(directory) && view(directory, i:i + 3) == [0x50, 0x4b, 0x01, 0x02]
			l = u16(directory, i + 28)
			push!(names, String(directory[i + 46:i + 45 + l]))
			i += 46 + l + u16(directory, i + 30) + u16(directory, i + 32)
		end
		return names
	end
end

"""
    geofabrik_layer(con, region, theme; folder, table = "features")

The layer `theme` (as `"buildings"`, `"roads"`, `"pois"`, `"landuse"`) of Geofabrik's region `region` (its id, as
`"monaco"`, `"portugal"`, `"hong-kong"`), its points or lines and its areas, from the GeoPackage of the region's
layers, downloaded once into `folder` and read inside its zip. Writes them to the table `table` on the DuckDB
connection `con`: `osm_id`, `value` (the class of the feature), `name`, `layer`, the other columns of the layer and
`geom`. Geofabrik has the layers of the smaller regions only. Returns `(; name, url, path, layers, n)`: the name of
the region, the address and path of the file, the layers read and the number of features.
"""
function geofabrik_layer(con, region::AbstractString, theme::AbstractString; folder::AbstractString, table::AbstractString = "features")
	r = geofabrik_region(con, region)
	r.shp === missing && throw(ArgumentError("Geofabrik has no layers for $(r.name), only for its parts: $(join(r.parts, ", "))"))
	url = replace(r.shp, "-free.shp.zip" => "-free.gpkg.zip")  # the same layers as a GeoPackage
	path = joinpath(folder, basename(url))
	geofabrik_file(url, path) || error("Geofabrik's server has no $(url)")
	source = "/vsizip/$(path)/$(only(filter(endswith(".gpkg"), zip_entries(path))))"  # read inside the zip, without unpacking it
	available = Tables.columntable(DBInterface.execute(con, "SELECT unnest(layers).name AS name FROM ST_Read_Meta('$(quoted(source))')")).name
	layers = filter(in(available), ["gis_osm_$(theme)_free", "gis_osm_$(theme)_a_free"])  # its points or lines, and its areas
	isempty(layers) && throw(ArgumentError("The GeoPackage of $(r.name) has no $(theme) layer: it has $(join(available, ", "))"))
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS " * join(["SELECT osm_id, fclass AS value, name, '$(l)' AS layer, COLUMNS(lambda c: c NOT IN ('osm_id', 'fclass', 'name', 'fid', 'geom')), geom FROM ST_Read('$(quoted(source))', layer = '$(l)')" for l in layers], " UNION ALL BY NAME "))
	return (; name = r.name, url, path, layers, n = scalar(con, "SELECT count(*) FROM $(table)"))
end

"""
    geofabrik_extract(con, region, tag; folder, table = "features")

The features with `tag` (`"key=value"`, or a key alone) of the full extract of Geofabrik's region `region` (its id),
a PBF file downloaded once into `folder`, read with [`osm_read`](@ref) into the table `table` on the DuckDB connection
`con`. Returns `(; name, url, path, n)`: the name of the region, the address and path of the file, and the number of
features.
"""
function geofabrik_extract(con, region::AbstractString, tag::AbstractString; folder::AbstractString, table::AbstractString = "features")
	r = geofabrik_region(con, region)
	path = joinpath(folder, basename(r.pbf))
	geofabrik_file(r.pbf, path) || error("Geofabrik's server has no $(r.pbf)")
	return (; name = r.name, url = r.pbf, path, n = osm_read(con, path, tag; folder, table))
end

"""
    geofabrik_earlier(con, url, year, what; folder, table = "earlier")

The same features as a file of Geofabrik read by [`geofabrik_layer`](@ref) or [`geofabrik_extract`](@ref), whose
address is `url`, as they were on 1 January of `year`, from Geofabrik's file of that day, downloaded once into
`folder`: the layer `what` of a region's layers (from its shape files, as Geofabrik keeps its older layers), or the
features with the tag `what` of an extract. Writes them to the table `table` on the DuckDB connection `con` (for a
layer: `osm_id`, as text, `value` and `layer`). Returns the number of features. Names the years Geofabrik has when it
has no file of that day.
"""
function geofabrik_earlier(con, url::AbstractString, year::Integer, what::AbstractString; folder::AbstractString, table::AbstractString = "earlier")
	yy = lpad(year % 100, 2, '0')
	layers = endswith(url, "-free.gpkg.zip")
	earlier = layers ? replace(url, "-latest-free.gpkg.zip" => "-$(yy)0101-free.shp.zip") : replace(url, "-latest.osm.pbf" => "-$(yy)0101.osm.pbf")
	path = joinpath(folder, basename(earlier))
	if !geofabrik_file(earlier, path)
		listing = String(take!(Downloads.download(replace(url, r"-latest[^/]*$" => ".html"), IOBuffer(); headers = [AGENT], downloader = patient())))  # the region's page, which lists its older files
		years = sort(unique(["20" * m[:y] for m in eachmatch(Regex(replace(basename(earlier), "$(yy)0101" => "(?<y>\\d\\d)0101", "." => "\\.")), listing)]))
		error("Geofabrik has no file of 1 January $(year) for this region; it has those of $(isempty(years) ? "no year" : join(years, ", "))")
	end
	layers || return osm_read(con, path, what; folder, table)
	files = filter(in(zip_entries(path)), ["gis_osm_$(what)_free_1.shp", "gis_osm_$(what)_a_free_1.shp"])
	isempty(files) && throw(ArgumentError("The file of $(year) has no $(what) layer"))
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS " * join(["SELECT CAST(osm_id AS VARCHAR) AS osm_id, fclass AS value, '$(replace(f, "_1.shp" => ""))' AS layer FROM ST_Read('/vsizip/$(quoted(path))/$(f)')" for f in files], " UNION ALL "))
	return scalar(con, "SELECT count(*) FROM $(table)")
end
