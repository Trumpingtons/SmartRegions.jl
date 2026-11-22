# Places: the box around a point, the UTM zone of a point, and GeoJSON written from a query

"""
    around(lon, lat, radius)

The box `(west, south, east, north)`, in degrees of longitude and latitude, that holds the circle of `radius` metres
around the point `lon`, `lat`: a degree of latitude taken as 111,320 m, and a degree of longitude as that times the
cosine of the latitude.

```julia
west, south, east, north = around(151.2093, -33.8675, 300)  # 300 m around Martin Place, Sydney
```
"""
function around(lon::Real, lat::Real, radius::Real)
	dlat = radius / 111_320
	dlon = dlat / cosd(lat)
	return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)
end

"""
    utmzone(lon, lat)

The code of the UTM zone of WGS 84 that holds the point, as `"EPSG:32756"`: EPSG 32601 to 32660 north of the equator,
32701 to 32760 south of it, the zones 6 degrees of longitude wide from 180 degrees west. Its coordinates are metres,
for distances, areas and grids of square cells with DuckDB's `ST_Transform`.

```julia
utmzone(151.2093, -33.8675)  # "EPSG:32756", Sydney
```
"""
utmzone(lon::Real, lat::Real) = "EPSG:$((lat >= 0 ? 32600 : 32700) + clamp(floor(Int, (lon + 180) / 6) + 1, 1, 60))"

"""
    geojson(con, sql; file = tempname() * ".geojson")

Writes the rows of the query `sql` on the DuckDB connection `con`, one of whose columns is a geometry, to a GeoJSON
file with the GDAL driver of DuckDB's spatial extension, and returns the file. The coordinates should be longitude and
latitude on WGS 84, which GeoJSON expects; the other columns become the properties of each feature.

```julia
file = geojson(con, "SELECT name, height, geom FROM buildings")
```
"""
function geojson(con, sql::AbstractString; file::AbstractString = tempname() * ".geojson")
	DBInterface.execute(con, "COPY ($(sql)) TO '$(quoted(file))' (FORMAT GDAL, DRIVER 'GeoJSON')")
	return file
end

# A text inside single quotes of SQL
quoted(s) = replace(String(s), "'" => "''")

# The first column of the first row of a query
scalar(con, sql) = only(only(Tables.columntable(DBInterface.execute(con, sql))))
