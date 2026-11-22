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

"""
    projected_box(con, box, crs)

The box `(west, south, east, north)`, in degrees of longitude and latitude, in the coordinate system `crs` (as
`"EPSG:32632"`), as `(x0, y0, x1, y1)`: the smallest box there that holds it, from DuckDB's `ST_Transform` on the
connection `con`, which should have `SET geometry_always_xy = true`. It is the extent to cut a raster of that system
to the box, as `Extent(X = (x0, x1), Y = (y0, y1))` of Rasters.jl.

```julia
x0, y0, x1, y1 = projected_box(con, (11.30, 44.47, 11.37, 44.52), "EPSG:32632")  # central Bologna in UTM zone 32 north
```
"""
function projected_box(con, box, crs::AbstractString)
	west, south, east, north = box
	b = Tables.columntable(DBInterface.execute(con, "SELECT ST_XMin(g) AS x0, ST_YMin(g) AS y0, ST_XMax(g) AS x1, ST_YMax(g) AS y1 FROM (SELECT ST_Transform(ST_MakeEnvelope($(west), $(south), $(east), $(north)), 'EPSG:4326', '$(quoted(crs))') AS g)"))
	return (only(b.x0), only(b.y0), only(b.x1), only(b.y1))
end

# The envelope of a box, in SQL
envelope(box) = "ST_MakeEnvelope($(box[1]), $(box[2]), $(box[3]), $(box[4]))"

# A list of texts, in SQL
sqllist(files) = "[" * join(("'$(quoted(f))'" for f in files), ", ") * "]"

# The elements of the JSON array at `pointer` in each file, one row each as `x`, in SQL
jsonrows(files, pointer) = "(SELECT unnest(CAST(coalesce(json_extract(content, '$(pointer)'), '[]') AS JSON[])) AS x FROM read_text($(sqllist(files))))"

# A text in JSON
jsonstring(s) = "\"" * replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t") * "\""

# One GET request written to path. The statuses in `empty` give an empty file; any other answer but 200 stops with
# the message `said` finds in it.
function fetched(url, path; source, headers = Pair{String, String}[], empty = (), said = s -> first(s, 300))
	part = path * ".part"
	r = open(io -> Downloads.request(url; output = io, headers = headers, throw = false), part, "w")
	r isa Downloads.Response || (rm(part; force = true); error("$(source) could not be reached: $(r.message)"))
	if r.status in empty
		write(part, "")
	elseif r.status != 200
		answer = read(part, String)
		rm(part; force = true)
		error("$(source) answered HTTP $(r.status): $(said(answer))")
	end
	return mv(part, path; force = true)
end

# The User-Agent of the requests to services that ask for one
const AGENT = "User-Agent" => "SmartRegions.jl (https://pollis.org)"

# Percent-encoding of a value in an address or a form, the characters of `safe` kept as they are
encoded(s; safe = "-_.~") = join(isletter(c) && isascii(c) || isdigit(c) || c in safe ? string(c) : join("%" * uppercase(string(b; base = 16, pad = 2)) for b in codeunits(string(c))) for c in s)

# A file downloaded once to `path`, a later call returning it from there; tried five times, waiting longer each time,
# unless the server refuses the request (an HTTP status of 400 to 499 other than 429). A file the server compresses
# for the transfer (Content-Encoding: gzip), even unasked, is saved as it is meant to be read
function cached(url, path; headers = Pair{String, String}[])
	isfile(path) && return path
	mkpath(dirname(path))
	decoding = Downloads.Downloader()
	decoding.easy_hook = (easy, info) -> Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_ACCEPT_ENCODING, "")
	for k in 0:4
		try
			Downloads.download(url, path * ".part"; headers = [AGENT; headers], downloader = decoding)
			return mv(path * ".part", path; force = true)
		catch e
			status = e isa Downloads.RequestError ? e.response.status : 0
			(k == 4 || 400 <= status < 500 && status != 429) && rethrow()
			@info "The download of $(basename(path)) failed (HTTP $(status)): trying again in $(5 * 2^k) s"
			sleep(5 * 2^k)
		end
	end
end
