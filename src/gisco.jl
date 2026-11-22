# Eurostat: the geographic files of GISCO (NUTS regions, local administrative units, countries, the cities and
# functional urban areas of the Urban Audit) and the tables of Eurostat's API

const GISCO = "https://gisco-services.ec.europa.eu/distribution/v2"
const EUROSTAT = "https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/data/"

"""
    gisco_files(theme, year)

The names of the GeoPackages GISCO has of `theme` (`"nuts"`, `"lau"`, `"countries"` or `"urau"`) for `year`, as
`"NUTS_RG_01M_2024_4326_LEVL_2"`: by kind of unit (`RG` regions, `BN` boundaries, `LB` points), scale (`01M` for 1:1
million to `60M`), year, coordinate system (`4326` for longitude and latitude) and, for NUTS, level.
"""
function gisco_files(theme::AbstractString, year)
	listing = try
		String(take!(Downloads.download("$(GISCO)/$(theme)/$(theme)-$(year)-files.json", IOBuffer(); headers = [AGENT])))
	catch
		throw(ArgumentError("GISCO has no $(theme) for the year $(year)"))
	end
	return sort(unique([m[1] for m in eachmatch(r"\"([A-Za-z0-9_]+)\.gpkg\"", listing)]))
end

"""
    gisco_file(theme, name; folder)

The GeoPackage `name` of GISCO's `theme` (`"nuts"`, `"lau"`, `"countries"` or `"urau"`), as
`"NUTS_RG_01M_2024_4326_LEVL_2"` (one of [`gisco_files`](@ref)), downloaded once into `folder` and returned.
"""
function gisco_file(theme::AbstractString, name::AbstractString; folder::AbstractString)
	path = joinpath(folder, "$(name).gpkg")
	isfile(path) && return path
	m = match(r"_(\d{4})_", name)
	m === nothing && throw(ArgumentError("$(name) names no year"))
	name in gisco_files(theme, m[1]) || throw(ArgumentError("GISCO has no $(name).gpkg: $(GISCO)/$(theme)/$(theme)-$(m[1])-files.json lists the files it has for $(m[1])"))
	return cached("$(GISCO)/$(theme)/gpkg/$(name).gpkg", path)
end

"""
    eurostat(con, dataset, key; table = "eurostat")

The series of the table `dataset` of Eurostat (as `"demo_r_d3dens"`) selected by `key` (the values of its
dimensions, separated by dots, an empty value for all, as `"A.PER_KM2."`), every period, from Eurostat's API as
SDMX-CSV, written with every column as text to the table `table` on the DuckDB connection `con`, which should have the
extension `httpfs` loaded. Returns the name of its column of the codes of places (`"geo"` or `"cities"`).
"""
function eurostat(con, dataset::AbstractString, key::AbstractString; table::AbstractString = "eurostat")
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT * FROM read_csv('$(EUROSTAT)$(quoted(dataset))/$(quoted(key))?format=SDMX-CSV', all_varchar = true)")
	found = intersect(["geo", "cities"], Tables.columntable(DBInterface.execute(con, "DESCRIBE $(table)")).column_name)
	isempty(found) && error("The table $(dataset) has no column of places")
	return first(found)
end

"""
    vector_units(con, path; layer = "")

SQL that reads the features of the vector file `path` (any format GDAL reads, of the layer `layer` when given) on the
DuckDB connection `con`: their columns, and their geometry as `geom` in longitude and latitude, transformed from the
coordinate system the file gives. A GML file with a property named as its geometry, which DuckDB cannot read twice,
has that property renamed in the description of its layers GDAL writes beside it.
"""
function vector_units(con, path::AbstractString; layer::AbstractString = "")
	from = isempty(layer) ? "ST_Read('$(quoted(path))')" : "ST_Read('$(quoted(path))', layer = '$(quoted(layer))')"
	describe() = Tables.columntable(DBInterface.execute(con, "DESCRIBE SELECT * FROM $(from)"))
	d = try
		describe()
	catch e
		gfs = splitext(path)[1] * ".gfs"  # GDAL's description of the layers of a GML file, written beside it
		(occursin("duplicate column name", sprint(showerror, e)) && isfile(gfs)) || rethrow()
		s = read(gfs, String)
		for g in unique(m[1] for m in eachmatch(r"<GeometryName>([^<]+)</GeometryName>", s))
			s = join([i > 1 ? replace(c, "<Name>$(g)</Name>" => "<Name>$(g)_property</Name>"; count = 1) : c for (i, c) in enumerate(split(s, "<PropertyDefn>"))], "<PropertyDefn>")
		end
		write(gfs, s)
		describe()
	end
	k = findfirst(t -> startswith(t, "GEOMETRY"), d.column_type)
	k === nothing && error("$(path) has no geometry")
	g, m = d.column_name[k], match(r"'([^']+)'", d.column_type[k])
	crs = m === nothing ? "EPSG:4326" : m[1]
	geom = crs in ("EPSG:4326", "OGC:CRS84") ? "\"$(g)\"" : "ST_Transform(\"$(g)\", '$(crs)', 'EPSG:4326')"
	return "(SELECT COLUMNS(lambda c: lower(c) NOT IN ('ogc_fid', 'fid', '$(lowercase(g))')), $(geom) AS geom FROM $(from))"
end
