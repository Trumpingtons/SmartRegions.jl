# INSPIRE: the datasets of data.europa.eu and their download services, and the features of a Web Feature Service
# (WFS), an Atom feed or an OGC API Features

const DATA_EUROPA = "https://data.europa.eu/api/hub/search/search"

# The parameters of a request to a WFS, which its address should not carry
const WFS_PARAMETERS = r"(?i)(service|request|version|acceptversions|typenames?|outputformat|count|maxfeatures|startindex|srsname|content-disposition)=[^&]*&?"

# A name for the files of a service, from its host and a name of its data
stem_of(kind, url, name) = replace("inspire-$(kind)-$(match(r"//([^/:]+)", url)[1])-$(name)", r"[^A-Za-z0-9.-]+" => "-")

# The words of a theme, and inspire, for the search of data.europa.eu
words_of(theme) = join([split(theme); "inspire"], "+AND+")

"""
    inspire_search(con, theme, country; rows = 50)

Searches data.europa.eu, the European entry point for INSPIRE's datasets, for those of `country` (its code, as
`"pt"`) whose metadata hold every word of `theme` and the word inspire, the `rows` most relevant. Writes the tables
`datasets` (`n`, its rank, `title`, in English when the portal has it, `catalogue` and `r`, its record as JSON) and
`services` (`n`, `kind`: `"WFS"`, `"OGC API Features"`, `"Atom"` or `"File"`, `address`, a WFS without a request,
and `licence`) on the DuckDB connection `con`. Returns the number of datasets that match.
"""
function inspire_search(con, theme::AbstractString, country::AbstractString; rows::Integer = 50)
	search = fetched("$(DATA_EUROPA)?q=$(words_of(theme))&filter=dataset&limit=$(rows)&facets=" * encoded("{\"country\":[\"$(lowercase(country))\"]}"), tempname() * ".json"; source = "data.europa.eu")
	total = scalar(con, "SELECT CAST(json_extract(content, '/result/count') AS BIGINT) FROM read_text('$(quoted(search))')")
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE datasets AS
	SELECT row_number() OVER () AS n, coalesce(r->>'/title/en', r->'/title'->>(json_keys(r->'/title')[1])) AS title, r->>'/catalog/id' AS catalogue, r
	FROM (SELECT unnest(CAST(json_extract(content, '/result/results') AS JSON[])) AS r FROM read_text('$(quoted(search))'))
	""")
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE services AS
	SELECT DISTINCT n, kind, CASE WHEN kind = 'WFS' THEN rtrim(regexp_replace(url, '(?i)(service|request|version|acceptversions|typenames?|outputformat|count|maxfeatures|startindex|srsname|content-disposition)=[^&]*&?', '', 'g'), '?&') ELSE url END AS address, licence
	FROM (
		SELECT n, d->>'/format/id' AS format, coalesce(d->>'/download_url/0', d->>'/access_url/0') AS url, d->>'/license/id' AS licence,
			CASE WHEN format = 'WFS_SRVC' OR url ILIKE '%service=wfs%' OR url ILIKE '%/wfs%' THEN 'WFS'
				WHEN (format IN ('OGCFEAT', 'ogcapi-features') OR url ILIKE '%/ogc/%') AND url NOT ILIKE '%service=wms%' THEN 'OGC API Features'
				WHEN (format = 'ATOM' OR url ILIKE '%atom%') AND (url ILIKE '%atom%' OR url ILIKE '%.xml%') AND url NOT LIKE '%#%' THEN 'Atom'
				WHEN format IN ('GPKG', 'GEOJSON', 'SHP', 'GML', 'FGB', 'KML') THEN 'File' END AS kind
		FROM (SELECT n, unnest(CAST(coalesce(r->'/distributions', '[]') AS JSON[])) AS d FROM datasets)
	) WHERE kind IS NOT NULL
	""")
	rm(search)
	return total
end

"""
    inspire_countries(con, theme; table = "countries")

The number of datasets of data.europa.eu of each country that match `theme` and inspire, as [`inspire_search`](@ref)
searches them, and of those with a service of each kind, by the format data.europa.eu gives the service. Writes the
table `table` on the DuckDB connection `con`: `country`, `datasets`, `wfs`, `atom` and `ogc`, the most datasets first.
"""
function inspire_countries(con, theme::AbstractString; table::AbstractString = "countries")
	counts = Dict{String, String}()
	for (kind, formats) in (("datasets", String[]), ("wfs", ["WFS_SRVC"]), ("atom", ["ATOM"]), ("ogc", ["OGCFEAT", "ogcapi-features"]))
		facet = isempty(formats) ? "" : "&facets=" * encoded("{\"format\":[$(join(["\"$(f)\"" for f in formats], ","))]}")
		counts[kind] = fetched("$(DATA_EUROPA)?q=$(words_of(theme))&filter=dataset&limit=0$(facet)", tempname() * ".json"; source = "data.europa.eu")
	end
	facet(kind) = "(SELECT i->>'/id' AS country, CAST(i->>'/count' AS BIGINT) AS n FROM (SELECT unnest(CAST(f->'/items' AS JSON[])) AS i FROM (SELECT unnest(CAST(json_extract(content, '/result/facets') AS JSON[])) AS f FROM read_text('$(quoted(counts[kind]))')) WHERE f->>'/id' = 'country'))"
	DBInterface.execute(con, """
	CREATE OR REPLACE TABLE $(table) AS
	SELECT upper(a.country) AS country, a.n AS datasets, coalesce(w.n, 0) AS wfs, coalesce(t.n, 0) AS atom, coalesce(o.n, 0) AS ogc
	FROM $(facet("datasets")) a LEFT JOIN $(facet("wfs")) w USING (country) LEFT JOIN $(facet("atom")) t USING (country) LEFT JOIN $(facet("ogc")) o USING (country)
	ORDER BY datasets DESC
	""")
	foreach(rm, values(counts))
	return scalar(con, "SELECT count(*) FROM $(table)")
end

"""
    wfs_features(con, service, layer; folder, page = 1000, table = "features")

The features of the layer `layer` of the Web Feature Service (WFS, version 2.0.0) at `service`, read `page` at a time,
as GeoJSON when the service offers it, else as GML, and kept once downloaded in `folder` as a GeoParquet file, which a
later call reads. Writes them to the table `table` on the DuckDB connection `con`: their columns, `geom` in longitude
and latitude, and `km2`, their area in km² on the WGS 84 ellipsoid. Returns `(; n, format, file, stem)`: the number of
features, the format read, the GeoParquet file, and the name of the files of the layer.
"""
function wfs_features(con, service::AbstractString, layer::AbstractString; folder::AbstractString, page::Integer = 1000, table::AbstractString = "features")
	service = rstrip(replace(service, WFS_PARAMETERS => ""), ['?', '&'])
	ask(request) = string(service, occursin('?', service) ? "&" : "?", "service=WFS&version=2.0.0&request=", request)
	caps = root(parsexml(String(take!(Downloads.download(ask("GetCapabilities"), IOBuffer(); headers = [AGENT])))))
	find(xpath) = nodecontent.(findall(xpath, caps, Pair{String, String}[]))  # by local names, whatever the prefixes of the namespaces
	layers = find("//*[local-name()='FeatureType']/*[local-name()='Name']")
	layer in layers || throw(ArgumentError("The WFS has no layer $(layer): its layers are $(join(layers, ", "))"))
	formats = find("//*[local-name()='Operation'][@name='GetFeature']//*[local-name()='Parameter'][@name='outputFormat']//*[local-name()='Value']")
	k = findfirst(f -> occursin(r"json"i, f), formats)
	format = k === nothing ? "GML" : formats[k]  # GeoJSON when the service offers it: GML may hold curves DuckDB cannot read
	stem = stem_of("wfs", service, layer)
	file = joinpath(mkpath(folder), "$(stem).parquet")
	if !isfile(file)
		pages, parts = mktempdir(), String[]
		for start in 0:page:10^7  # a page at a time, until one has fewer features than asked for
			path = joinpath(pages, "page-$(length(parts) + 1).$(format == "GML" ? "gml" : "geojson")")
			Downloads.download(ask("GetFeature&typeNames=$(layer)&count=$(page)&startIndex=$(start)" * (format == "GML" ? "" : "&outputFormat=" * encoded(format))), path; headers = [AGENT])
			m = scalar(con, "SELECT count(*) FROM $(vector_units(con, path))")
			m == 0 && break
			push!(parts, path)
			m < page && break
		end
		isempty(parts) && error("The WFS sent no features of $(layer)")
		DBInterface.execute(con, "COPY (SELECT *, ST_Area_Spheroid(geom) / 1e6 AS km2 FROM ($(join(["SELECT * FROM $(vector_units(con, p))" for p in parts], " UNION ALL BY NAME ")))) TO '$(quoted(file))' (FORMAT parquet)")
		rm(pages; recursive = true)
	end
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT * FROM '$(quoted(file))'")
	return (; n = scalar(con, "SELECT count(*) FROM $(table)"), format, file, stem)
end

"""
    atom_files(url)

The files of the Atom feed of a download service at `url`: of the feeds of its datasets, or, when it links to none,
of itself. Returns a vector of `(; href, megabytes)`, `megabytes` `missing` where the feed does not say.
"""
function atom_files(url::AbstractString)
	atom = ["a" => "http://www.w3.org/2005/Atom"]
	feed(u) = root(parsexml(String(take!(Downloads.download(u, IOBuffer(); headers = [AGENT])))))
	top = feed(url)
	links = [l["href"] for l in findall("a:entry/a:link[@rel='alternate' and contains(@type, 'atom')]", top, atom)]
	files = NamedTuple{(:href, :megabytes), Tuple{String, Union{Missing, Float64}}}[]
	for f in (isempty(links) ? [top] : feed.(links))
		for l in findall("a:entry/a:link[@rel='alternate' or @rel='section']", f, atom)  # the files of each dataset, in one part or several
			occursin("atom", haskey(l, "type") ? l["type"] : "") && continue
			push!(files, (href = l["href"], megabytes = haskey(l, "length") ? round(parse(Int, l["length"]) / 2^20, digits = 1) : missing))
		end
	end
	return files
end

"""
    atom_features(con, url, pattern; layer = "", folder, table = "features")

The features of the first file of the Atom feed at `url` (from [`atom_files`](@ref)) whose address holds `pattern` and
that DuckDB reads (GeoPackage, GML, GeoJSON, shape file, FlatGeobuf, KML, or a .zip of them, unpacked), downloaded once
into `folder`, of its layer `layer` when given. Writes them to the table `table` on the DuckDB connection `con`: their
columns, `geom` in longitude and latitude, and `km2`. Returns `(; n, path, href, stem, files)`: the number of
features, the file read, its address, the name of its files, and the files of the feed.
"""
function atom_features(con, url::AbstractString, pattern::AbstractString; layer::AbstractString = "", folder::AbstractString, table::AbstractString = "features")
	files = atom_files(url)
	isempty(files) && error("The feed lists no files")
	readable = r"\.(gpkg|gml|geojson|json|shp|fgb|kml)$"i  # what DuckDB's spatial extension reads
	k = findfirst(f -> occursin(pattern, f.href) && occursin(readable, replace(first(split(f.href, '?')), r"\.zip$"i => ".gml")), files)
	k === nothing && throw(ArgumentError("No file of the feed matches \"$(pattern)\" and is one DuckDB reads, or a .zip"))
	href = String(first(split(files[k].href, '?')))
	stem = stem_of("atom", href, splitext(basename(href))[1])
	download = cached(files[k].href, joinpath(mkpath(folder), stem * lowercase(splitext(href)[2])))
	path = download
	if endswith(download, ".zip")  # unpacked once, into a folder beside the .zip
		unpacked = mkpath(joinpath(folder, stem))
		archive = ZipReader(read(download))
		for entry in filter(e -> !endswith(e, "/"), zip_names(archive))
			target = normpath(joinpath(unpacked, entry))
			startswith(target, normpath(unpacked)) || continue  # never outside the folder
			isfile(target) || (mkpath(dirname(target)); write(target, zip_readentry(archive, entry)))
		end
		inside = filter(e -> occursin(readable, e), zip_names(archive))
		isempty(inside) && error("The .zip holds no file DuckDB reads: $(join(zip_names(archive), ", "))")
		path = normpath(joinpath(unpacked, first(inside)))
	end
	layers = Tables.columntable(DBInterface.execute(con, "SELECT unnest(layers).name AS name FROM ST_Read_Meta('$(quoted(path))')")).name
	isempty(layer) || layer in layers || throw(ArgumentError("$(basename(path)) has no layer $(layer): its layers are $(join(layers, ", "))"))
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT *, ST_Area_Spheroid(geom) / 1e6 AS km2 FROM $(vector_units(con, path; layer))")
	return (; n = scalar(con, "SELECT count(*) FROM $(table)"), path, href = files[k].href, stem, files)
end

"""
    ogc_features(con, url, collection; folder, page = 1000, table = "features")

The features of the collection `collection` of the OGC API Features whose landing page is `url`, read `page` at a
time, following the link of each page to the next, and kept once downloaded in `folder` as a GeoParquet file, which a
later call reads. Writes them to the table `table` on the DuckDB connection `con`: their columns, `geom` in longitude
and latitude, and `km2`. Returns `(; n, file, stem)`.
"""
function ogc_features(con, url::AbstractString, collection::AbstractString; folder::AbstractString, page::Integer = 1000, table::AbstractString = "features")
	landing = rstrip(first(split(url, '?')), '/')
	geojson = [AGENT, "Accept" => "application/geo+json, application/json"]
	listing = Downloads.download("$(landing)/collections?f=json", tempname() * ".json"; headers = geojson)
	collections = Tables.columntable(DBInterface.execute(con, "SELECT c->>'/id' AS id FROM (SELECT unnest(CAST(json_extract(content, '/collections') AS JSON[])) AS c FROM read_text('$(quoted(listing))'))")).id
	rm(listing)
	collection in collections || throw(ArgumentError("The API has no collection $(collection): its collections are $(join(collections, ", "))"))
	stem = stem_of("ogc", landing, collection)
	file = joinpath(mkpath(folder), "$(stem).parquet")
	if !isfile(file)
		pages, parts = mktempdir(), String[]
		next = "$(landing)/collections/$(collection)/items?f=json&limit=$(page)"
		while next !== nothing
			path = Downloads.download(next, joinpath(pages, "page-$(length(parts) + 1).geojson"); headers = geojson)
			scalar(con, "SELECT coalesce(json_array_length(json_extract(content, '/features')), 0) FROM read_text('$(quoted(path))')") == 0 && break
			push!(parts, path)
			l = Tables.columntable(DBInterface.execute(con, "SELECT x->>'/href' AS href FROM $(jsonrows([path], "/links")) WHERE x->>'/rel' = 'next' ORDER BY coalesce(x->>'/type', '') ILIKE '%json%' DESC LIMIT 1")).href
			next = isempty(l) ? nothing : only(l)
		end
		isempty(parts) && error("The API sent no features of $(collection)")
		DBInterface.execute(con, "COPY (SELECT *, ST_Area_Spheroid(geom) / 1e6 AS km2 FROM ($(join(["SELECT * FROM $(vector_units(con, p))" for p in parts], " UNION ALL BY NAME ")))) TO '$(quoted(file))' (FORMAT parquet)")
		rm(pages; recursive = true)
	end
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT * FROM '$(quoted(file))'")
	return (; n = scalar(con, "SELECT count(*) FROM $(table)"), file, stem)
end
