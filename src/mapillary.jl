# Mapillary: the coverage tiles, the image search and the map features of its API, and the images near a point,
# read into DuckDB tables

const MAPILLARY = "https://graph.mapillary.com/"
const IMAGE_FIELDS = "id,captured_at,compass_angle,computed_compass_angle,geometry,computed_geometry,camera_type,make,model,is_pano,on_foot,quality_score,sequence,creator,thumb_1024_url,thumb_2048_url,width,height"

# The access token: the keyword, or ENV["MAPILLARY_ACCESS_TOKEN"]
function mapillary_token(token)
	token === nothing || return String(token)
	haskey(ENV, "MAPILLARY_ACCESS_TOKEN") || error("Mapillary needs an access token: set ENV[\"MAPILLARY_ACCESS_TOKEN\"], or pass token. In Pollis, set it with the key on the Powered by line")
	return ENV["MAPILLARY_ACCESS_TOKEN"]
end

# The message of an error of the API
mapillary_said(s) = (m = match(r"\"message\"\s*:\s*\"(.*?)\""s, s); m === nothing ? first(s, 300) : String(m[1]))

"""
    mapillary(path, file = tempname() * ".json"; token = nothing)

One request to the Graph API of Mapillary, `path` after `https://graph.mapillary.com/`, as
`"images?fields=id,geometry&bbox=11.34,44.49,11.35,44.50"`; its answer is written to `file`, which is returned. The
access token is `token`, or `ENV["MAPILLARY_ACCESS_TOKEN"]`: a client token of an application registered on
mapillary.com. Any answer but HTTP 200 stops with the API's message.
"""
mapillary(path::AbstractString, file::AbstractString = tempname() * ".json"; token = nothing) =
	fetched(MAPILLARY * path, file; source = "Mapillary", headers = ["Authorization" => "OAuth " * mapillary_token(token)], said = mapillary_said)

# The images of answers of the API, a list in `data` or one image each, as the table `table`
function read_images(con, answers, table; list = true)
	rows = list ? jsonrows(answers, "/data") : "(SELECT CAST(content AS JSON) AS x FROM read_text($(sqllist(answers))))"
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(table) AS
	SELECT DISTINCT ON (id) x->>'id' AS id, x->>'sequence' AS sequence_id, epoch_ms(CAST(x->>'captured_at' AS BIGINT)) AS captured_at,
		TRY_CAST(coalesce(x->>'computed_compass_angle', x->>'compass_angle') AS DOUBLE) AS compass_angle, coalesce(TRY_CAST(x->>'is_pano' AS BOOLEAN), false) AS is_pano,
		TRY_CAST(x->>'on_foot' AS BOOLEAN) AS on_foot, TRY_CAST(x->>'quality_score' AS DOUBLE) AS quality_score, x->>'camera_type' AS camera_type,
		x->>'make' AS make, x->>'model' AS camera_model, TRY_CAST(x->>'width' AS INTEGER) AS width, TRY_CAST(x->>'height' AS INTEGER) AS height,
		x->'creator'->>'username' AS creator, x->>'thumb_1024_url' AS thumb_url, x->>'thumb_2048_url' AS large_url, CAST(NULL AS VARCHAR) AS thumbnail,
		ST_GeomFromGeoJSON(coalesce(x->'computed_geometry', x->'geometry')) AS geom, ST_GeomFromGeoJSON(x->'geometry') AS camera_geom
	FROM $(rows)
	""")
	foreach(rm, answers)
end

# Every answer of a search of the API over the box, in boxes of at most 0.09 degrees a side; a box with 2,000
# answers, the most the API gives, is split in four
function mapillary_search(con, endpoint, fields, filters, box; token)
	west, south, east, north = box
	(east - west) * (north - south) > 1 && throw(ArgumentError("The area is $(round((east - west) * (north - south); digits = 2)) square degrees, more than the 1 square degree Mapillary's search reads: make it smaller"))
	boxes = [(w, s, min(w + 0.09, east), min(s + 0.09, north)) for w in west:0.09:prevfloat(float(east)) for s in south:0.09:prevfloat(float(north))]
	answers = String[]
	while !isempty(boxes)
		w, s, e, n = pop!(boxes)
		answer = mapillary("$(endpoint)?" * join(["fields=$(fields)"; "bbox=$(w),$(s),$(e),$(n)"; "limit=2000"; filters], "&"); token)
		if scalar(con, "SELECT json_array_length(content, '/data') FROM read_text('$(quoted(answer))')") >= 2000 && e - w > 1e-4
			mw, ms = (w + e) / 2, (s + n) / 2
			append!(boxes, [(w, s, mw, ms), (mw, s, e, ms), (w, ms, mw, n), (mw, ms, e, n)])
		else
			push!(answers, answer)
		end
	end
	return answers
end

"""
    mapillary_coverage(con, box; folder, images = "images", sequences = "sequences", most = 400, token = nothing)

Reads the coverage tiles of Mapillary over `box = (west, south, east, north)`, in degrees: the vector tiles of zoom 14
of its computed public layer, kept in `folder/tiles/<today>` (a later day downloads them again), at most `most` of
them (Mapillary serves 50,000 tiles a day). Writes two tables on the DuckDB connection `con`: `images`, one row per
image over the box (`id`, `sequence_id`, `captured_at`, `compass_angle`, `is_pano`, `quality_score`, `creator`,
`organization_id`, `geom`), and `sequences`, one row per sequence (`id`, `image_id` of its first image,
`captured_at`, `is_pano`, mean `quality_score`, and its line `geom` cut to the box). Returns
`(; tiles, folder)`: the tiles that hold images, and the folder of today's tiles. Needs `spatial` and
`SET geometry_always_xy = true` on `con`.
"""
function mapillary_coverage(con, box; folder::AbstractString, images::AbstractString = "images", sequences::AbstractString = "sequences", most::Integer = 400, token = nothing)
	west, south, east, north = box
	key = mapillary_token(token)
	z = 14
	tile_x(lon) = floor(Int, (lon + 180) / 360 * 2^z)
	tile_y(lat) = floor(Int, (1 - asinh(tand(lat)) / pi) / 2 * 2^z)
	tiles = [(x, y) for x in tile_x(west):tile_x(east) for y in tile_y(north):tile_y(south)]
	length(tiles) > most && throw(ArgumentError("The area needs $(length(tiles)) tiles at zoom 14, more than the $(most) read in one call (Mapillary serves 50,000 tiles a day): make it smaller"))
	day = joinpath(folder, "tiles", string(today()))
	files = String[]
	for (x, y) in tiles
		path = joinpath(mkpath(joinpath(day, "$(z)", "$(x)")), "$(y).pbf")
		isfile(path) || fetched("https://tiles.mapillary.com/maps/vtp/mly1_computed_public/2/$(z)/$(x)/$(y)?access_token=$(key)", path; source = "Mapillary", empty = (204, 404), said = mapillary_said)  # 204 and 404: a tile with no images
		filesize(path) > 0 && push!(files, path)
	end
	isempty(files) && error("Mapillary has no images over the area")
	layers = Tables.columntable(DBInterface.execute(con, "SELECT file_name, l.name AS layer FROM ST_Read_Meta($(sqllist(files))) m, unnest(m.layers) AS u(l)"))
	# One layer of the tiles, read with GDAL's MVT driver, with the columns any tile may lack
	function layer_of(name, columns)
		reads = ["SELECT * FROM ST_Read('$(quoted(f))', layer = '$(name)')" for (f, l) in zip(layers.file_name, layers.layer) if l == name]
		return join(["SELECT $(columns), NULL::GEOMETRY AS geom WHERE false"; reads], " UNION ALL BY NAME ")
	end
	area = envelope(box)
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(images) AS
	SELECT DISTINCT ON (id) CAST(id AS VARCHAR) AS id, CAST(sequence_id AS VARCHAR) AS sequence_id, epoch_ms(CAST(captured_at AS BIGINT)) AS captured_at,
		CAST(compass_angle AS DOUBLE) AS compass_angle, CAST(is_pano AS BOOLEAN) AS is_pano, CAST(quality_score AS DOUBLE) AS quality_score,
		CAST(creator_id AS VARCHAR) AS creator, CAST(organization_id AS VARCHAR) AS organization_id, ST_Transform(geom, 'EPSG:3857', 'EPSG:4326') AS geom
	FROM ($(layer_of("image", "NULL::VARCHAR AS id, NULL::VARCHAR AS sequence_id, NULL::BIGINT AS captured_at, NULL::DOUBLE AS compass_angle, NULL::BOOLEAN AS is_pano, NULL::DOUBLE AS quality_score, NULL::VARCHAR AS creator_id, NULL::VARCHAR AS organization_id")))
	WHERE ST_Intersects(ST_Transform(geom, 'EPSG:3857', 'EPSG:4326'), $(area))
	""")
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(sequences) AS
	SELECT id, image_id, captured_at, is_pano, quality_score, ST_Intersection(geom, $(area)) AS geom FROM (
		SELECT CAST(id AS VARCHAR) AS id, CAST(any_value(image_id) AS VARCHAR) AS image_id, epoch_ms(CAST(min(captured_at) AS BIGINT)) AS captured_at,
			CAST(any_value(is_pano) AS BOOLEAN) AS is_pano, avg(CAST(quality_score AS DOUBLE)) AS quality_score,
			ST_LineMerge(ST_Collect(list(ST_Transform(geom, 'EPSG:3857', 'EPSG:4326')))) AS geom
		FROM ($(layer_of("sequence", "NULL::VARCHAR AS id, NULL::VARCHAR AS image_id, NULL::BIGINT AS captured_at, NULL::BOOLEAN AS is_pano, NULL::DOUBLE AS quality_score")))
		GROUP BY id)
	WHERE ST_Intersects(geom, $(area))
	""")  # pieces of a sequence from several tiles joined
	return (; tiles = length(files), folder = day)
end

"""
    mapillary_images(con, box; from = nothing, to = nothing, pano = nothing, table = "images", token = nothing)

Searches the images of Mapillary over `box = (west, south, east, north)`, in degrees, at most 1 square degree,
captured from the day `from` to the day `to` (each a `Date` or `"2024-05-01"`, or `nothing` for no limit), panoramas
only (`pano = true`), others only (`false`) or both (`nothing`), and writes them to the table `table` on the DuckDB
connection `con`, one row per image: `id`, `sequence_id`, `captured_at`, `compass_angle` (computed, or the camera's),
`is_pano`, `on_foot`, `quality_score`, `camera_type`, `make`, `camera_model`, `width`, `height`, `creator`,
`thumb_url` (1,024 pixels wide), `large_url` (2,048), `thumbnail` (empty until [`mapillary_thumbnails`](@ref)), `geom`
(the computed position) and `camera_geom` (the camera's). Returns the number of images.
"""
function mapillary_images(con, box; from = nothing, to = nothing, pano::Union{Nothing, Bool} = nothing, table::AbstractString = "images", token = nothing)
	filters = String[]
	from === nothing || push!(filters, "start_captured_at=$(from)T00:00:00Z")
	to === nothing || push!(filters, "end_captured_at=$(to)T23:59:59Z")
	pano === nothing || push!(filters, "is_pano=$(pano)")
	read_images(con, mapillary_search(con, "images", IMAGE_FIELDS, filters, box; token), table)
	return scalar(con, "SELECT count(*) FROM $(table)")
end

"""
    mapillary_thumbnails(con, most; folder, table = "images")

Downloads the thumbnails, 1,024 pixels wide, of `most` images of the table `table` that [`mapillary_images`](@ref)
wrote, one image of each sequence first and the newest first, to `folder` (those already there are kept), and sets
the column `thumbnail` of each to its file. Returns `folder`.
"""
function mapillary_thumbnails(con, most::Integer; folder::AbstractString, table::AbstractString = "images")
	pick = Tables.columntable(DBInterface.execute(con, "SELECT id, thumb_url FROM (SELECT id, thumb_url, captured_at, row_number() OVER (PARTITION BY sequence_id ORDER BY captured_at DESC) AS k FROM $(table) WHERE thumb_url IS NOT NULL) ORDER BY k, captured_at DESC LIMIT $(most)"))
	mkpath(folder)
	for i in eachindex(pick.id)
		thumb = joinpath(folder, pick.id[i] * ".jpg")
		isfile(thumb) || mv(Downloads.download(pick.thumb_url[i], thumb * ".part"), thumb)
		DBInterface.execute(con, "UPDATE $(table) SET thumbnail = ? WHERE id = ?", [thumb, pick.id[i]])
	end
	return folder
end

"""
    mapillary_features(con, box; values = nothing, kind = nothing, table = "features", token = nothing)

Searches the map features of Mapillary, the traffic signs and other objects it detects in the images, over
`box = (west, south, east, north)`, in degrees, at most 1 square degree, only those of the object values `values`
(as `"regulatory--stop--g1,object--fire-hydrant"`, or `nothing` for all) and of the kind `kind` (`"traffic_sign"`,
`"point"`, or `nothing` for both), and writes them to the table `table` on the DuckDB connection `con`, one row per
feature: `id`, `value`, `kind`, `family` (the value's first part), `first_seen`, `last_seen`, `aligned_direction` and
the point `geom`. Returns the number of features.
"""
function mapillary_features(con, box; values = nothing, kind = nothing, table::AbstractString = "features", token = nothing)
	filters = values === nothing ? String[] : ["object_values=" * replace(values isa AbstractString ? values : join(values, ","), " " => "")]
	answers = mapillary_search(con, "map_features", "id,object_value,object_type,first_seen_at,last_seen_at,aligned_direction,geometry", filters, box; token)
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(table) AS
	SELECT DISTINCT ON (id) x->>'id' AS id, x->>'object_value' AS value, x->>'object_type' AS kind, split_part(x->>'object_value', '--', 1) AS family,
		TRY_CAST(left(x->>'first_seen_at', 19) AS TIMESTAMP) AS first_seen, TRY_CAST(left(x->>'last_seen_at', 19) AS TIMESTAMP) AS last_seen,
		TRY_CAST(x->>'aligned_direction' AS DOUBLE) AS aligned_direction, ST_GeomFromGeoJSON(x->'geometry') AS geom
	FROM $(jsonrows(answers, "/data"))
	""")
	foreach(rm, answers)
	kind === nothing || DBInterface.execute(con, "DELETE FROM $(table) WHERE kind <> '$(quoted(kind))'")
	return scalar(con, "SELECT count(*) FROM $(table)")
end

# The distance of each image from the point, in metres, as the column metres
function add_metres(con, table, lon, lat)
	DBInterface.execute(con, "ALTER TABLE $(table) ADD COLUMN metres DOUBLE")
	DBInterface.execute(con, "UPDATE $(table) SET metres = ST_Distance_Sphere(geom, ST_Point($(lon), $(lat)))")
end

"""
    mapillary_near(con, lon, lat, radius; pano = false, table = "images", token = nothing)

Writes the images of Mapillary within `radius` metres (at most 500) of the point `lon`, `lat` to the table `table` on
the DuckDB connection `con`, panoramas only with `pano = true`, with the columns of [`mapillary_images`](@ref) and
`metres`, the distance from the point. Returns the number of images. One request gives at most 2,000 images, with a
warning when it does: some within the radius may then be missing.
"""
function mapillary_near(con, lon::Real, lat::Real, radius::Real; pano::Bool = false, table::AbstractString = "images", token = nothing)
	0 < radius <= 500 || throw(ArgumentError("The radius is $(radius) m: give one above 0 and at most 500"))
	dlon, dlat = radius / (111320 * cosd(lat)), radius / 110574  # the radius in degrees of longitude and latitude
	answer = mapillary("images?fields=$(IMAGE_FIELDS)&bbox=$(lon - dlon),$(lat - dlat),$(lon + dlon),$(lat + dlat)&limit=2000" * (pano ? "&is_pano=true" : ""); token)
	read_images(con, [answer], table)
	add_metres(con, table, lon, lat)
	scalar(con, "SELECT count(*) FROM $(table)") >= 2000 && @warn "Mapillary gave 2,000 images, as many as it gives to one request: some within the radius may be missing, so make the radius smaller"
	DBInterface.execute(con, "DELETE FROM $(table) WHERE metres > $(radius)")  # the corners of the box are farther than the radius
	return scalar(con, "SELECT count(*) FROM $(table)")
end

"""
    mapillary_image(con, image, lon, lat; table = "images", token = nothing)

Writes one image of Mapillary, given by its id or by a link of mapillary.com with `pKey=`, to the table `table` on the
DuckDB connection `con`, with the columns of [`mapillary_images`](@ref) and `metres`, its distance from the point
`lon`, `lat`. Returns the id of the image.
"""
function mapillary_image(con, image::AbstractString, lon::Real, lat::Real; table::AbstractString = "images", token = nothing)
	given = strip(image)
	link = match(r"pKey=(\d+)", given)
	id = link !== nothing ? String(link[1]) : occursin(r"^\d+$", given) ? String(given) : throw(ArgumentError("$(given) is neither the id of an image of Mapillary nor a link of mapillary.com with pKey="))
	read_images(con, [mapillary("$(id)?fields=$(IMAGE_FIELDS)"; token)], table; list = false)
	add_metres(con, table, lon, lat)
	return id
end
