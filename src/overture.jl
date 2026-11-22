# Overture Maps: its releases, from the STAC catalogue, and the features of a type over an area, read over HTTPS from
# the GeoParquet files of the release, only the files and row groups that overlap the area

const STAC = "https://stac.overturemaps.org"

"""
    overture_release(con)

The newest release of Overture Maps, as `"2026-11-18.0"`, from Overture's STAC catalogue, which DuckDB reads over
HTTPS on the connection `con`, with the extension `httpfs` loaded.
"""
overture_release(con) = scalar(con, "SELECT latest FROM '$(STAC)/catalog.json'")

"""
    overture(con, type; box = nothing, within = nothing, columns = "id, names.primary AS name", filter = "true",
        release = "latest", table = "features")

Reads the features of an Overture Maps `type` (`"place"`, `"building"`, `"segment"`, `"division_area"`, `"address"`
and the others of the schema) over an area into the table `table` of the DuckDB connection `con`, which needs the
extensions `spatial` and `httpfs` loaded. The area is `box = (west, south, east, north)` in degrees, or
`within = (lon, lat, radius)`, the features whose centres lie within `radius` metres of a point. Only the files of the
release that overlap the area are read, and in them only the row groups whose bounding boxes overlap it.

The table holds `columns`, SQL over Overture's schema, of the features that meet `filter`, also SQL; then `dataset`
and `license`, the source of the feature itself, `sources`, the sources of the feature and of its properties, and
`geom`, its geometry in longitude and latitude. `release` is a release of the catalogue, or `"latest"` for the newest.

Returns `(; release, files, bytes, n, seconds)`: the release read, the addresses of the files read and their sizes in
bytes, the number of features in the table, and the seconds the reading took.

```julia
using DuckDB, SmartRegions
con = DBInterface.connect(DuckDB.DB)
foreach(sql -> DBInterface.execute(con, sql), ["LOAD spatial", "LOAD httpfs", "SET geometry_always_xy = true"])
r = overture(con, "building"; within = (151.2093, -33.8675, 300), columns = "id, names.primary AS name, height, num_floors", table = "buildings")
```
"""
function overture(con, type::AbstractString; box = nothing, within = nothing, columns::AbstractString = "id, names.primary AS name",
		filter::AbstractString = "true", release::AbstractString = "latest", table::AbstractString = "features")
	(box === nothing) == (within === nothing) && throw(ArgumentError("Give the area as box = (west, south, east, north) or within = (lon, lat, radius), one of the two"))
	west, south, east, north = box === nothing ? around(within...) : box
	release = release == "latest" ? overture_release(con) : String(release)
	in_box = "bbox.xmin <= $(east) AND bbox.xmax >= $(west) AND bbox.ymin <= $(north) AND bbox.ymax >= $(south)"
	found = Tables.columntable(DBInterface.execute(con, "SELECT assets.aws.href AS href, assets.aws.\"file:size\" AS bytes FROM '$(STAC)/$(release)/collections.parquet' WHERE collection = '$(quoted(type))' AND $(in_box)"))
	isempty(found.href) && error("No $(type) file of Overture release $(release) covers longitude $(west) to $(east), latitude $(south) to $(north)")
	main = "list_filter(sources, lambda s: coalesce(s.property, '') = '')[1]"  # the source of the feature itself, not of one of its properties
	near = within === nothing ? "ST_Intersects(geometry, ST_MakeEnvelope($(west), $(south), $(east), $(north)))" :
		"ST_Distance_Sphere(ST_Centroid(geometry)::GEOMETRY, ST_Point($(within[1]), $(within[2]))) <= $(within[3])"
	seconds = @elapsed DBInterface.execute(con, """
		CREATE OR REPLACE TABLE $(table) AS
		SELECT $(columns), $(main).dataset AS dataset, $(main).license AS license, sources, geometry AS geom
		FROM read_parquet([$(join(["'$(quoted(f))'" for f in found.href], ", "))])
		WHERE $(in_box) AND ($(filter)) AND $(near)""")
	n = scalar(con, "SELECT count(*) FROM $(table)")
	return (; release, files = collect(found.href), bytes = collect(found.bytes), n, seconds)
end
