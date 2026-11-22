# OpenTopography: its catalogue of topographic datasets, searched without a key, and the elevation models of its API,
# with a key

const OPENTOPOGRAPHY = "https://portal.opentopography.org/API/"

# The largest areas OpenTopography serves of each model, in square kilometres; 450,000 for the global models not here
const OT_LIMITS = Dict("SRTMGL3" => 4.05e6, "COP90" => 4.05e6, "SRTM15Plus" => 1.25e8, "GEBCOIceTopo" => 1.25e8, "USGS30m" => 2.25e5, "USGS10m" => 2.5e4, "USGS1m" => 250.0)

# The size of a box, in square kilometres, on a sphere of the Earth's mean radius
km2(box) = 6371.0088^2 * deg2rad(box[3] - box[1]) * (sind(box[4]) - sind(box[2]))

"""
    opentopography_catalog(con, box; product = "all", federated = true, table = "datasets")

Searches the catalogue of OpenTopography, which needs no key, for the topographic datasets over
`box = (west, south, east, north)`, in degrees: of the format `product` (`"PointCloud"`, `"Raster"` or `"all"`), with
those of the other catalogues it federates (USGS 3DEP, NOAA) when `federated = true`. Writes them to the table `table`
on the DuckDB connection `con`, one row per dataset: `name`, `id`, `source`, `format` (`"Point cloud"` or
`"Raster"`), `short_name`, `first_day`, `last_day`, `doi`, the outline `geom` and `covered`, the share of the box it
covers in per cent. Returns the number of datasets.
"""
function opentopography_catalog(con, box; product::AbstractString = "all", federated::Bool = true, table::AbstractString = "datasets")
	west, south, east, north = box
	params = ["minx" => west, "miny" => south, "maxx" => east, "maxy" => north, "detail" => true, "outputFormat" => "json", "include_federated" => federated]
	product == "all" || push!(params, "productFormat" => product)
	found = fetched(OPENTOPOGRAPHY * "otCatalog?" * join(["$(k)=$(v)" for (k, v) in params], "&"), tempname() * ".json"; source = "OpenTopography")
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(table) AS
	SELECT d->>'name' AS name, d->'identifier'->>'value' AS id,
		CASE d->'identifier'->>'propertyID' WHEN 'opentopoID' THEN 'OpenTopography' WHEN 'USGS_3DEP_ID' THEN 'USGS 3DEP' WHEN 'NOAAID' THEN 'NOAA' ELSE d->'identifier'->>'propertyID' END AS source,
		CASE WHEN d->>'fileFormat' ILIKE 'point%' THEN 'Point cloud' ELSE 'Raster' END AS format, d->>'alternateName' AS short_name,
		TRY_CAST(split_part(d->>'temporalCoverage', ' / ', 1) AS DATE) AS first_day, TRY_CAST(nullif(split_part(d->>'temporalCoverage', ' / ', 2), '') AS DATE) AS last_day,
		d->>'url' AS doi, ST_GeomFromGeoJSON(d->'spatialCoverage'->'geo'->'geojson'->'features'->0->'geometry') AS geom
	FROM (SELECT x->'Dataset' AS d FROM $(jsonrows([found], "/Datasets")))
	""")
	DBInterface.execute(con, "ALTER TABLE $(table) ADD COLUMN covered DOUBLE")
	DBInterface.execute(con, "UPDATE $(table) SET covered = round(100 * ST_Area(ST_Intersection(ST_MakeValid(geom), $(envelope(box)))) / ST_Area($(envelope(box))), 1)")
	rm(found)
	return scalar(con, "SELECT count(*) FROM $(table)")
end

"""
    opentopography_dem(box, model; folder, key = nothing)

The elevation model `model` of OpenTopography over `box = (west, south, east, north)`, in degrees, as a GeoTIFF
downloaded once into `folder/<model>`, one file for each model and box, and returned. `model` is a global model of
its `globaldem` API (as `"COP30"`, `"SRTMGL1"`, `"NASADEM"`, `"AW3D30"`) or a resolution of USGS 3DEP over the United
States (`"USGS30m"`, `"USGS10m"`, `"USGS1m"`), each up to the largest area OpenTopography serves of it. The API key is
`key`, or `ENV["OPENTOPOGRAPHY_API_KEY"]`, from the account page of an OpenTopography account.
"""
function opentopography_dem(box, model::AbstractString; folder::AbstractString, key = nothing)
	west, south, east, north = box
	limit = get(OT_LIMITS, model, 4.5e5)
	km2(box) > limit && throw(ArgumentError("The area is $(round(Int, km2(box))) km², more than the $(round(Int, limit)) km² OpenTopography serves of $(model): make it smaller"))
	path = joinpath(mkpath(joinpath(folder, model)), "$(model)_$(west)_$(south)_$(east)_$(north).tif")
	isfile(path) && return path
	if key === nothing
		haskey(ENV, "OPENTOPOGRAPHY_API_KEY") || error("OpenTopography needs an API key: set ENV[\"OPENTOPOGRAPHY_API_KEY\"], or pass key. In Pollis, set it with the key on the Powered by line")
		key = ENV["OPENTOPOGRAPHY_API_KEY"]
	end
	usgs3dep = startswith(model, "USGS")
	endpoint, kind = usgs3dep ? ("usgsdem", "datasetName") : ("globaldem", "demtype")
	said(s) = (m = match(r"<error>(.*?)</error>"s, s); m === nothing ? first(s, 300) : strip(m[1]))
	fetched(OPENTOPOGRAPHY * "$(endpoint)?$(kind)=$(model)&south=$(south)&north=$(north)&west=$(west)&east=$(east)&outputFormat=GTiff&API_Key=$(key)", path; source = "OpenTopography", empty = (204,), said)
	if filesize(path) == 0
		rm(path)
		error(usgs3dep ? "USGS 3DEP has no data over the area: it covers the United States" : "OpenTopography has no data of $(model) over the area")
	end
	return path
end
