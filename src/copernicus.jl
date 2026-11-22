# The Copernicus Data Space Ecosystem: its STAC catalogue, searched without an account, and the files of its download
# service, with an account

const CDSE_STAC = "https://stac.dataspace.copernicus.eu/v1/search"
const CDSE_TOKEN = "https://identity.dataspace.copernicus.eu/auth/realms/CDSE/protocol/openid-connect/token"

"""
    copernicus_scenes(con, collection; box = nothing, days = nothing, cloud = nothing, ids = nothing, most = 100, table = "scenes")

Searches the STAC catalogue of the Copernicus Data Space Ecosystem, which needs no account, for the scenes of
`collection` (as `"sentinel-2-l2a"`, `"sentinel-1-global-mosaics"`) over `box = (west, south, east, north)`, in
degrees, acquired between the two days of `days = (first, last)` (each a `Date` or `"2025-06-01"`), with at most
`cloud` per cent of clouds (for the collections that give it), or the scenes of the ids `ids` (the box then only
gives `covered`); at most `most` of them,
read a hundred to a page. Writes them to the table `table` on the DuckDB connection `con`, one row per scene: `id`,
`acquired`, `cloud`, `platform`, `tile`, `orbit`, the outline `geom`, the `assets` (JSON) and, with a box, `covered`,
the share of the box it covers in per cent. Returns the number of scenes.
"""
function copernicus_scenes(con, collection::AbstractString; box = nothing, days = nothing, cloud = nothing, ids = nothing, most::Integer = 100, table::AbstractString = "scenes")
	parts = ["collections=$(collection)", "limit=100"]
	ids === nothing || push!(parts, "ids=" * (ids isa AbstractString ? ids : join(ids, ",")))
	box === nothing || ids !== nothing || push!(parts, "bbox=$(join(box, ","))")
	days === nothing || push!(parts, "datetime=" * encoded("$(days[1])T00:00:00Z/$(days[2])T23:59:59Z"))
	cloud === nothing || push!(parts, "filter=" * encoded("eo:cloud_cover <= $(cloud)"), "filter-lang=cql2-text")
	url, pages, files = CDSE_STAC * "?" * join(parts, "&"), mktempdir(), String[]
	while url !== nothing && 100 * length(files) < most
		push!(files, fetched(url, joinpath(pages, "page-$(length(files) + 1).json"); source = "The STAC catalogue of the Copernicus Data Space"))
		next = Tables.columntable(DBInterface.execute(con, "SELECT x->>'href' AS href FROM $(jsonrows([files[end]], "/links")) WHERE x->>'rel' = 'next'")).href
		url = isempty(next) ? nothing : first(next)
	end
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(table) AS
	SELECT x->>'id' AS id, CAST(coalesce(x->>'/properties/datetime', x->>'/properties/start_datetime') AS TIMESTAMP) AS acquired, TRY_CAST(x->>'/properties/eo:cloud_cover' AS DOUBLE) AS cloud,
		x->>'/properties/platform' AS platform, x->>'/properties/grid:code' AS tile, x->>'/properties/sat:orbit_state' AS orbit,
		ST_GeomFromGeoJSON(x->'geometry') AS geom, x->'assets' AS assets
	FROM $(jsonrows(files, "/features"))
	QUALIFY row_number() OVER (PARTITION BY id) = 1
	""")
	if box !== nothing
		DBInterface.execute(con, "ALTER TABLE $(table) ADD COLUMN covered DOUBLE")
		DBInterface.execute(con, "UPDATE $(table) SET covered = round(100 * ST_Area(ST_Intersection(geom, $(envelope(box)))) / ST_Area($(envelope(box))), 1)")
	end
	rm(pages; recursive = true)
	return scalar(con, "SELECT count(*) FROM $(table)")
end

# An access token of the download service, for the account of ENV["CDSE_USERNAME"] and ENV["CDSE_PASSWORD"]
function copernicus_token()
	for v in ("CDSE_USERNAME", "CDSE_PASSWORD")
		haskey(ENV, v) || error("The download service of the Copernicus Data Space needs an account: set ENV[\"CDSE_USERNAME\"] and ENV[\"CDSE_PASSWORD\"]. In Pollis, set them with the key on the Powered by line")
	end
	out = IOBuffer()
	r = Downloads.request(CDSE_TOKEN; method = "POST", output = out, throw = false,
		input = IOBuffer("grant_type=password&client_id=cdse-public&username=$(encoded(ENV["CDSE_USERNAME"]))&password=$(encoded(ENV["CDSE_PASSWORD"]))"),
		headers = ["Content-Type" => "application/x-www-form-urlencoded"])
	answer = String(take!(out))
	r isa Downloads.Response && r.status == 200 || error("The Copernicus Data Space refused the account (HTTP $(r isa Downloads.Response ? r.status : r.message)): $(first(answer, 300))")
	return match(r"\"access_token\"\s*:\s*\"([^\"]+)\"", answer)[1]
end

"""
    copernicus_band(con, scene, band; folder, table = "scenes")

The file of the asset `band` (as `"B04_10m"`, `"SCL_20m"`, `"VV"`) of `scene`, a row of the table `table` that
[`copernicus_scenes`](@ref) wrote, downloaded once from the download service of the Copernicus Data Space Ecosystem
into `folder/<scene>`, with the account of `ENV["CDSE_USERNAME"]` and `ENV["CDSE_PASSWORD"]` (a new token for each
file, as a token lasts minutes). Returns `(; path, crs, scale, offset, nodata)`: the file, its coordinate system (as
`"EPSG:32632"`), and the scale, offset and no-data value the catalogue gives (`missing` where it gives none), by which
the stored integers become reflectance.
"""
function copernicus_band(con, scene::AbstractString, band::AbstractString; folder::AbstractString, table::AbstractString = "scenes")
	known = Tables.columntable(DBInterface.execute(con, "SELECT unnest(json_keys(assets)) AS k FROM $(table) WHERE id = '$(quoted(scene))'")).k
	isempty(known) && throw(ArgumentError("The table $(table) has no scene $(scene)"))
	band in known || throw(ArgumentError("The scene has no band $(band): its assets are $(join(sort(known), ", "))"))
	b = quoted(band)
	a = only(Tables.rowtable(DBInterface.execute(con, "SELECT assets->'$(b)'->>'href' AS file, assets->'$(b)'->'alternate'->'https'->>'href' AS href, assets->'$(b)'->>'proj:code' AS crs, TRY_CAST(assets->'$(b)'->>'raster:scale' AS DOUBLE) AS scale, TRY_CAST(assets->'$(b)'->>'raster:offset' AS DOUBLE) AS offset, TRY_CAST(assets->'$(b)'->>'nodata' AS DOUBLE) AS nodata FROM $(table) WHERE id = '$(quoted(scene))'")))
	ismissing(a.href) && error("The scene $(scene) has no file of $(band) on the download service")
	path = joinpath(mkpath(joinpath(folder, scene)), band * lowercase(splitext(coalesce(a.file, ".tif"))[2]))  # .jp2 or .tif, as the catalogue names it
	if !isfile(path)
		Downloads.download(a.href, path * ".part"; headers = ["Authorization" => "Bearer $(copernicus_token())"])
		mv(path * ".part", path)
	end
	return (; path, crs = a.crs, scale = a.scale, offset = a.offset, nodata = a.nodata)
end
