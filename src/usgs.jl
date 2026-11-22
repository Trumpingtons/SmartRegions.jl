# USGS EarthExplorer: its Machine-to-Machine (M2M) API, with a USGS account and an application token, for the scenes
# of a dataset and the files of a scene

const M2M = "https://m2m.cr.usgs.gov/api/api/json/stable/"
const M2M_KEY = Ref("")

"""
    usgs(endpoint, body = "{}")

One request to the Machine-to-Machine API of USGS EarthExplorer, `endpoint` after
`https://m2m.cr.usgs.gov/api/api/json/stable/` (as `"scene-search"`), with the JSON `body`; its answer is written to
a JSON file, which is returned. The first request logs in with `ENV["USGS_USERNAME"]` and `ENV["USGS_TOKEN"]`, an
application token made on the profile page of a USGS account, and the session's API key is kept for the others until
[`usgs_logout`](@ref). An error of the API stops with its code and message.
"""
function usgs(endpoint::AbstractString, body::AbstractString = "{}")
	endpoint == "login-token" || !isempty(M2M_KEY[]) || usgs_login()
	out, headers = IOBuffer(), ["Content-Type" => "application/json"]
	isempty(M2M_KEY[]) || push!(headers, "X-Auth-Token" => M2M_KEY[])
	r = Downloads.request(M2M * endpoint; method = "POST", input = IOBuffer(body), output = out, headers = headers, throw = false)
	r isa Downloads.Response || error("The M2M API of USGS could not be reached: $(r.message)")
	answer = String(take!(out))
	startswith(lstrip(answer), "{") || error("The M2M API of USGS answered $(endpoint) with HTTP $(r.status): $(first(answer, 300))")
	code = match(r"\"errorCode\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", answer)
	if code !== nothing
		said = match(r"\"errorMessage\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", answer)
		error("The M2M API of USGS answered $(endpoint) with $(code[1]): $(said === nothing ? "" : said[1])")
	end
	file = tempname() * ".json"
	write(file, answer)
	return file
end

# A session's API key, from the username and the application token
function usgs_login()
	for v in ("USGS_USERNAME", "USGS_TOKEN")
		haskey(ENV, v) || error("The M2M API of USGS EarthExplorer needs an account: set ENV[\"USGS_USERNAME\"] and ENV[\"USGS_TOKEN\"], an application token of the account. In Pollis, set them with the key on the Powered by line")
	end
	answer = read(usgs("login-token", "{\"username\": $(jsonstring(ENV["USGS_USERNAME"])), \"token\": $(jsonstring(ENV["USGS_TOKEN"]))}"), String)
	M2M_KEY[] = match(r"\"data\"\s*:\s*\"([^\"]+)\"", answer)[1]
end

"""
    usgs_logout()

Ends the session of the M2M API of USGS EarthExplorer, if there is one; the next request logs in again.
"""
function usgs_logout()
	isempty(M2M_KEY[]) && return nothing
	try usgs("logout") catch end
	M2M_KEY[] = ""
	return nothing
end

"""
    usgs_scenes(con, dataset; box, days = nothing, cloud = nothing, unknown = true, most = 100, table = "scenes")

Searches the scenes of the EarthExplorer dataset `dataset` (as `"landsat_ot_c2_l2"`, Landsat 8-9 Collection 2
Level-2) over `box = (west, south, east, north)`, in degrees, acquired between the two days of `days = (first, last)`,
with at most `cloud` per cent of clouds, those of unknown cloud cover with `unknown = true`; at most `most` of them,
read a hundred at a time. Writes them to the table `table` on the DuckDB connection `con`, one row per scene:
`entity` (the id for downloads), `id` (the display id), `acquired`, `cloud`, the outline `geom`, `browse` (JSON) and
`covered`, the share of the box it covers in per cent. Returns the number of scenes.
"""
function usgs_scenes(con, dataset::AbstractString; box, days = nothing, cloud = nothing, unknown::Bool = true, most::Integer = 100, table::AbstractString = "scenes")
	west, south, east, north = box
	filter = ["\"spatialFilter\": {\"filterType\": \"mbr\", \"lowerLeft\": {\"latitude\": $(south), \"longitude\": $(west)}, \"upperRight\": {\"latitude\": $(north), \"longitude\": $(east)}}"]
	days === nothing || push!(filter, "\"acquisitionFilter\": {\"start\": \"$(days[1])\", \"end\": \"$(days[2])\"}")
	cloud === nothing || push!(filter, "\"cloudCoverFilter\": {\"min\": 0, \"max\": $(cloud), \"includeUnknown\": $(unknown)}")
	files, start = String[], 1
	while 100 * length(files) < most
		push!(files, usgs("scene-search", "{\"datasetName\": $(jsonstring(dataset)), \"maxResults\": 100, \"startingNumber\": $(start), \"sceneFilter\": {$(join(filter, ", "))}}"))
		t = only(Tables.rowtable(DBInterface.execute(con, "SELECT CAST(json_extract(content, '/data/totalHits') AS BIGINT) AS total, CAST(json_extract(content, '/data/nextRecord') AS BIGINT) AS next, CAST(json_extract(content, '/data/recordsReturned') AS BIGINT) AS n FROM read_text('$(quoted(files[end]))')")))
		(coalesce(t.n, 0) == 0 || coalesce(t.next, 0) <= start || t.next > coalesce(t.total, 0)) && break
		start = t.next
	end
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(table) AS
	SELECT x->>'entityId' AS entity, x->>'displayId' AS id, TRY_CAST(coalesce(x->>'/temporalCoverage/startDate', x->>'/temporalCoverage/StartDate') AS TIMESTAMP) AS acquired,
		nullif(TRY_CAST(x->>'cloudCover' AS DOUBLE), -1) AS cloud, ST_GeomFromGeoJSON(x->'spatialCoverage') AS geom, x->'browse' AS browse
	FROM $(jsonrows(files, "/data/results"))
	QUALIFY row_number() OVER (PARTITION BY entity) = 1
	""")
	DBInterface.execute(con, "ALTER TABLE $(table) ADD COLUMN covered DOUBLE")
	DBInterface.execute(con, "UPDATE $(table) SET covered = round(100 * ST_Area(ST_Intersection(geom, $(envelope(box)))) / ST_Area($(envelope(box))), 1)")
	return scalar(con, "SELECT count(*) FROM $(table)")
end

# One file of a download, named as the server names it
function save_url(url, folder)
	part = joinpath(folder, "download.part")
	r = open(io -> Downloads.request(url; output = io), part, "w")
	h = Dict(lowercase(k) => v for (k, v) in r.headers)
	m = match(r"filename=\"?([^\";]+)", get(h, "content-disposition", ""))
	return mv(part, joinpath(folder, m === nothing ? basename(first(split(url, '?'))) : m[1]); force = true)
end

"""
    usgs_download(con, downloads, folder; wait = 600)

Asks the M2M API of USGS EarthExplorer for the files `downloads`, pairs `(entity, product)` of a scene's entity id
and a product id of `download-options`, waits up to `wait` seconds for those it prepares, and downloads them to
`folder`, named as the server names them; `con` is a DuckDB connection that reads the answers. Returns the files downloaded, with a warning when some were not ready.
"""
function usgs_download(con, downloads, folder::AbstractString; wait::Real = 600)
	label = "smartregions-$(round(Int, time()))"
	asked = usgs("download-request", "{\"downloads\": [$(join(["{\"entityId\": $(jsonstring(e)), \"productId\": $(jsonstring(p))}" for (e, p) in downloads], ", "))], \"label\": \"$(label)\"}")
	urls_of(file, list) = collect(skipmissing(Tables.columntable(DBInterface.execute(con, "SELECT x->>'url' AS url FROM $(jsonrows([file], "/data/$(list)"))")).url))
	urls = urls_of(asked, "availableDownloads")
	deadline = time() + wait
	while length(urls) < length(downloads) && time() < deadline
		sleep(15)
		urls = unique([urls; urls_of(usgs("download-retrieve", "{\"label\": \"$(label)\"}"), "available")])
	end
	length(urls) < length(downloads) && @warn "Only $(length(urls)) of $(length(downloads)) files were ready after $(round(Int, wait)) seconds: ask again later for the others"
	return [save_url(u, mkpath(folder)) for u in urls]
end

"""
    usgs_bands(con, dataset, entity, scene, bands; folder)

The files of the bands `bands` (as `["SR_B4", "SR_B5", "QA_PIXEL"]`) of a Landsat scene of the EarthExplorer dataset
`dataset`, given by its `entity` id and display id `scene`, downloaded once into `folder` as USGS names them
(`<scene>_<band>.TIF`); only the bands not there yet are asked for, as the secondary files of `download-options`.
Returns a `Dict` of each band's file.
"""
function usgs_bands(con, dataset::AbstractString, entity::AbstractString, scene::AbstractString, bands; folder::AbstractString)
	path_of(b) = joinpath(folder, "$(scene)_$(b).TIF")
	wanted = [b for b in bands if !isfile(path_of(b))]
	if !isempty(wanted)
		options = usgs("download-options", "{\"datasetName\": $(jsonstring(dataset)), \"entityIds\": [$(jsonstring(entity))], \"includeSecondaryFileGroups\": true}")
		files = Tables.columntable(DBInterface.execute(con, "SELECT s->>'displayId' AS name, s->>'entityId' AS entity, s->>'id' AS id, CAST(s->>'available' AS VARCHAR) IN ('true', 'Y') AS available FROM (SELECT unnest(CAST(coalesce(x->'secondaryDownloads', '[]') AS JSON[])) AS s FROM $(jsonrows([options], "/data")))"))
		downloads = map(wanted) do b
			k = findfirst(n -> !ismissing(n) && endswith(uppercase(n), "_$(b).TIF"), files.name)
			k === nothing && throw(ArgumentError("The scene has no band $(b): its files end in $(join(unique(replace.(skipmissing(files.name), r"^.*?_(?=[A-Z]+_?[A-Z0-9]*\.TIF$)"i => "")), ", "))"))
			files.available[k] || error("The band $(b) of the scene is not available for download")
			(files.entity[k], files.id[k])
		end
		usgs_download(con, downloads, folder)
	end
	missed = [b for b in bands if !isfile(path_of(b))]
	isempty(missed) || error("The bands $(join(missed, ", ")) were not downloaded: ask again later")
	return Dict(b => path_of(b) for b in bands)
end

"""
    usgs_dem(con, product; box, folder)

The tiles of 1 by 1 degree of the elevation model `product` of EarthExplorer, an SRTM dataset by its name (as
`"SRTM 1 Arc-Second Global"`), over `box = (west, south, east, north)`, in degrees, each downloaded once as a GeoTIFF,
the finest offered, into `folder/<dataset>/<entity>`. Returns `(; dataset, files)`: the dataset's alias and the
GeoTIFF of each tile.
"""
function usgs_dem(con, product::AbstractString; box, folder::AbstractString)
	west, south, east, north = box
	known = Tables.columntable(DBInterface.execute(con, "SELECT x->>'datasetAlias' AS alias, x->>'collectionName' AS name FROM $(jsonrows([usgs("dataset-search", "{\"datasetName\": \"SRTM\"}")], "/data"))"))
	k = findfirst(isequal(product), known.name)
	k === nothing && throw(ArgumentError("EarthExplorer has no dataset $(product): its SRTM datasets are $(join(skipmissing(known.name), ", "))"))
	dataset = known.alias[k]
	found = usgs("scene-search", "{\"datasetName\": $(jsonstring(dataset)), \"maxResults\": 100, \"startingNumber\": 1, \"sceneFilter\": {\"spatialFilter\": {\"filterType\": \"mbr\", \"lowerLeft\": {\"latitude\": $(south), \"longitude\": $(west)}, \"upperRight\": {\"latitude\": $(north), \"longitude\": $(east)}}}}")
	tiles = Tables.columntable(DBInterface.execute(con, "SELECT x->>'entityId' AS entity FROM $(jsonrows([found], "/data/results"))")).entity
	isempty(tiles) && error("$(product) has no tile over the area: it covers the land between 60 degrees north and 56 degrees south")
	tile_dir(e) = mkpath(joinpath(folder, dataset, e))
	tifs(e) = [joinpath(tile_dir(e), f) for f in readdir(tile_dir(e)) if endswith(lowercase(f), ".tif")]
	missed = [e for e in tiles if isempty(tifs(e))]
	if !isempty(missed)
		options = usgs("download-options", "{\"datasetName\": $(jsonstring(dataset)), \"entityIds\": [$(join(jsonstring.(missed), ", "))]}")
		o = Tables.columntable(DBInterface.execute(con, "SELECT x->>'entityId' AS entity, x->>'id' AS id, x->>'productName' AS name, CAST(x->>'available' AS VARCHAR) IN ('true', 'Y') AS available FROM $(jsonrows([options], "/data")) WHERE name ILIKE '%geotiff%'"))
		for e in missed
			ks = [j for j in eachindex(o.entity) if o.entity[j] == e && o.available[j]]
			isempty(ks) && error("The tile $(e) has no GeoTIFF available for download")
			j = ks[something(findfirst(j -> occursin(r"1 arc"i, o.name[j]), ks), 1)]  # the finest of the GeoTIFFs offered
			usgs_download(con, [(e, o.id[j])], tile_dir(e))
		end
	end
	files = reduce(vcat, [tifs(e) for e in tiles])
	length(files) < length(tiles) && error("Only $(length(files)) of the $(length(tiles)) tiles of $(product) over the area were downloaded: ask again later")
	return (; dataset, files)
end
