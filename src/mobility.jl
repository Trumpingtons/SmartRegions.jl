# Mobility: flows between zones (commuting, trips by bike, taxi and bus), counts of road traffic, and the flights of
# the OpenSky Network's flight list, from the open data of national statistics offices, cities and transport bodies

# The cities of each kind of data
const COMMUTING_CITIES = ("cambridge", "oxford", "london", "amsterdam", "paris", "frankfurt", "newyork", "tokyo", "hongkong")
const TRIP_CITIES = ("london", "newyork", "singapore")
const COUNT_CITIES = ("cambridge", "oxford", "london", "newyork", "paris")

# The files of the OpenSky Network's flight list, 2019 to 2022, on Zenodo
const FLIGHT_LISTS = "https://zenodo.org/api/records/7923702"

# One file of a zip archive, extracted once beside it
function unzipped(zip, entry)
	path = joinpath(dirname(zip), entry)
	isfile(path) || write(path, zip_readentry(ZipReader(read(zip)), entry))
	return path
end

# The functions that read a source, on the connection `con`, with the files downloaded once into `folder`
function readers(con, folder)
	execute(sql) = DBInterface.execute(con, sql)
	query(sql) = Tables.columntable(DBInterface.execute(con, sql))
	fetch(url, name; headers = Pair{String, String}[]) = cached(url, joinpath(folder, name); headers)
	enc(s) = encoded(s; safe = "-_.~,")
	return execute, query, fetch, enc
end

# A choice that must be one of a list
function checked(value, known, what)
	value in known || throw(ArgumentError("No $(what) for $(repr(value)): the choices are $(join(known, ", "))"))
	return value
end

# The middle layer super output areas (MSOAs) of 2021 of a city of England as the table zones
function msoa_zones(con, city, folder)
	execute, query, fetch, enc = readers(con, folder)
	authorities = Dict("cambridge" => ["Cambridge", "South Cambridgeshire"], "oxford" => ["Oxford", "Cherwell", "South Oxfordshire", "Vale of White Horse", "West Oxfordshire"],
		"london" => ["City of London", "Barking and Dagenham", "Barnet", "Bexley", "Brent", "Bromley", "Camden", "Croydon", "Ealing", "Enfield", "Greenwich", "Hackney", "Hammersmith and Fulham", "Haringey", "Harrow", "Havering", "Hillingdon",
		"Hounslow", "Islington", "Kensington and Chelsea", "Kingston upon Thames", "Lambeth", "Lewisham", "Merton", "Newham", "Redbridge", "Richmond upon Thames", "Southwark", "Sutton", "Tower Hamlets", "Waltham Forest", "Wandsworth", "Westminster"])[city]  # the local authorities whose areas are the zones
	boundaries = fetch("https://services1.arcgis.com/ESMARspQHYMw9BZ9/arcgis/rest/services/MSOA_2021_EW_BSC_V3_RUC/FeatureServer/0/query?where=" * enc(join(["MSOA21NM LIKE '$(a) 0%'" for a in authorities], " OR ")) * "&outFields=MSOA21CD,MSOA21NM&outSR=4326&f=geojson", "msoa-2021-$(city).geojson")
	execute("CREATE OR REPLACE TABLE zones AS SELECT MSOA21CD AS zone, MSOA21NM AS name, geom FROM ST_Read('$(boundaries)')")  # the middle layer super output areas (MSOAs) of 2021, Office for National Statistics
end

# The centroid of each zone, from which distances are measured
function centroids(con)
	DBInterface.execute(con, "CREATE OR REPLACE TABLE zones AS SELECT zone, name, geom, ST_X(ST_Centroid(geom)) AS lon, ST_Y(ST_Centroid(geom)) AS lat FROM zones")
end

"""
    commuting_flows(con, city; folder)

The commuters between the zones of `city`, from the census or the employment statistics of its country, downloaded
once into `folder`: `"cambridge"`, `"oxford"` and `"london"` (Census 2021 of England and Wales, by middle layer super
output area), `"amsterdam"` (Statistics Netherlands, by municipality), `"paris"` (INSEE, by arrondissement and commune),
`"frankfurt"` (the Federal Employment Agency, by district), `"newyork"` (LODES, by Neighborhood Tabulation Area),
`"tokyo"` (the 2020 Census, by municipality) or `"hongkong"` (the 2021 Population Census, from each district to the
three areas the census groups places of work in). Writes the tables `zones` (`zone`, `name`, `geom`, and `lon`, `lat`
of its centroid) and `flows` (`origin`, `destination`, `flow`) on the DuckDB connection `con`. Returns
`(; unit, source, away, home)`: what the flows count, the source, and how many start or end outside the zones and how
many work at or from home (`missing` where the source does not say).
"""
function commuting_flows(con, city::AbstractString; folder::AbstractString)
	checked(city, COMMUTING_CITIES, "commuting flows")
	execute, query, fetch, enc = readers(con, folder)
	if city in ("cambridge", "oxford", "london")
		msoa_zones(con, city, folder)
		census = unzipped(fetch("https://www.nomisweb.co.uk/output/census/2021/odwp01ew.zip", "odwp01ew.zip"), "ODWP01EW_MSOA.csv")  # Census 2021, residence and place of work by MSOA, ONS through Nomis (77 MB, once)
		execute("""CREATE OR REPLACE TEMP TABLE census AS SELECT "Middle layer Super Output Areas code" AS origin, "MSOA of workplace code" AS destination, "Place of work indicator (4 categories) code" AS kind, "Count" AS people FROM read_csv('$(census)') WHERE origin IN (SELECT zone FROM zones)""")
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, sum(people)::DOUBLE AS flow FROM census WHERE kind = 3 AND destination IN (SELECT zone FROM zones) GROUP BY ALL")  # those who travel to a place of work in the UK, between the zones
		left = query("SELECT sum(people) FILTER (WHERE kind = 3 AND destination NOT IN (SELECT zone FROM zones)) AS away, sum(people) FILTER (WHERE kind = 1) AS home FROM census")
		unit, source = "workers", "Census 2021 (March 2021), workers aged 16 and over"
	elseif city == "amsterdam"
		boundaries = fetch("https://api.pdok.nl/cbs/gebiedsindelingen/ogc/v1/collections/gemeente_gegeneraliseerd/items?f=json&limit=1000&jaarcode=2024&bbox=4.5,52.2,5.35,52.58", "gemeenten-2024-amsterdam.geojson")
		execute("CREATE OR REPLACE TABLE zones AS SELECT statcode AS zone, statnaam AS name, geom FROM ST_Read('$(boundaries)')")  # the municipalities around Amsterdam in 2024, Statistics Netherlands (CBS) through PDOK
		codes = query("SELECT zone FROM zones").zone
		selection = "Perioden eq '2024MM12' and (" * join(["WoonregioS eq '$(c)'" for c in codes], " or ") * ") and (WerkregioS eq 'NL00  ' or " * join(["WerkregioS eq '$(c)'" for c in codes], " or ") * ")"
		jobs = fetch("https://opendata.cbs.nl/ODataApi/odata/85481NED/TypedDataSet?\$format=json&\$filter=" * enc(selection), "cbs-85481NED-2024-amsterdam.json")  # jobs of employees by municipality of residence and of work, CBS table 85481NED
		execute("CREATE OR REPLACE TEMP TABLE cbs AS SELECT trim(r.WoonregioS) AS origin, trim(r.WerkregioS) AS destination, coalesce(r.BanenVanWerknemers_1, 0) * 1000 AS jobs FROM (SELECT unnest(value) AS r FROM read_json('$(jobs)'))")  # the table counts thousands of jobs
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, jobs AS flow FROM cbs WHERE destination <> 'NL00' AND jobs > 0")
		left = query("SELECT sum(jobs) FILTER (WHERE destination = 'NL00') - sum(jobs) FILTER (WHERE destination <> 'NL00') AS away, NULL::DOUBLE AS home FROM cbs")
		unit, source = "jobs", "Statistics Netherlands, jobs of employees in December 2024 (provisional)"
	elseif city == "paris"
		geo = "https://geo.api.gouv.fr/communes?format=geojson&geometry=contour&fields=code,nom&codeDepartement="
		parts = [fetch(geo * "75&type=arrondissement-municipal", "paris-arrondissements.geojson"); [fetch(geo * d, "communes-$(d).geojson") for d in ("92", "93", "94")]]  # Paris and the three departments around it, from geo.api.gouv.fr
		execute("CREATE OR REPLACE TABLE zones AS " * join(["SELECT code AS zone, nom AS name, geom FROM ST_Read('$(p)')" for p in parts], " UNION ALL "))  # the 20 arrondissements of Paris and the communes of Hauts-de-Seine, Seine-Saint-Denis and Val-de-Marne
		flux = unzipped(fetch("https://www.insee.fr/fr/statistiques/fichier/8582949/base-flux-mobilite-domicile-lieu-travail-2022_csv.zip", "insee-flux-domicile-travail-2022.zip"), "base-flux-mobilite-domicile-lieu-travail-2022.csv")  # INSEE, 2022 census
		execute("CREATE OR REPLACE TEMP TABLE insee AS SELECT CODGEO AS origin, DCLT AS destination, NBFLUX_C22_ACTOCC15P AS workers FROM read_csv('$(flux)', delim = ';', types = {'CODGEO': 'VARCHAR', 'DCLT': 'VARCHAR'}) WHERE CODGEO IN (SELECT zone FROM zones)")
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, sum(workers) AS flow FROM insee WHERE destination IN (SELECT zone FROM zones) GROUP BY ALL")
		left = query("SELECT sum(workers) FILTER (WHERE destination NOT IN (SELECT zone FROM zones)) AS away, NULL::DOUBLE AS home FROM insee")
		unit, source = "workers", "INSEE, 2022 census, employed people aged 15 and over by commune of residence and of work"
	elseif city == "frankfurt"
		boundaries = fetch("https://sgx.geodatenzentrum.de/wfs_vg250?service=WFS&version=2.0.0&request=GetFeature&typeNames=vg250:vg250_krs&outputFormat=application/json&srsName=EPSG:4326&bbox=49.75,8.15,50.45,9.3,urn:ogc:def:crs:EPSG::4326", "vg250-kreise-frankfurt.geojson")
		execute("CREATE OR REPLACE TABLE zones AS SELECT ags AS zone, gen AS name, ST_Union_Agg(geom) AS geom FROM ST_Read('$(boundaries)') WHERE gf = 4 GROUP BY ALL")  # the districts (Kreise) around Frankfurt, VG250 of the Federal Agency for Cartography and Geodesy (BKG)
		execute("INSTALL excel"); execute("LOAD excel")  # DuckDB's extension for Excel files
		pendler = fetch("https://statistik.arbeitsagentur.de/Statistikdaten/Detail/202306/iiia6/beschaeftigung-pendler-krpend/krpend-k-0-202306-xlsx.xlsx?__blob=publicationFile&v=1", "krpend-k-0-202306.xlsx")  # Federal Employment Agency, commuters between districts on 30 June 2023
		execute("""CREATE OR REPLACE TEMP TABLE ba AS WITH r AS (SELECT row_number() OVER () AS i, * FROM read_xlsx('$(pendler)', sheet = 'Auspendler Kreise', all_varchar = true, header = false, range = 'A1:E400000', stop_at_empty = false))
			SELECT origin, destination, people FROM (SELECT last_value(A IGNORE NULLS) OVER (ORDER BY i) AS origin, C AS destination, TRY_CAST(E AS DOUBLE) AS people FROM r)
			WHERE length(destination) = 5 AND origin IN (SELECT zone FROM zones)""")  # a residence row, then one row per district of work; codes of 5 digits are districts, the shorter ones totals
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, people AS flow FROM ba WHERE destination IN (SELECT zone FROM zones) AND people > 0")
		left = query("SELECT sum(people) FILTER (WHERE destination NOT IN (SELECT zone FROM zones)) AS away, NULL::DOUBLE AS home FROM ba")
		unit, source = "employees", "Federal Employment Agency, employees subject to social insurance who work outside their district, 30 June 2023"
	elseif city == "newyork"
		areas = fetch("https://data.cityofnewyork.us/resource/9nt8-h7nd.geojson?\$limit=1000", "nyc-nta-2020.geojson")
		execute("CREATE OR REPLACE TABLE zones AS SELECT nta2020 AS zone, ntaname AS name, geom FROM ST_Read('$(areas)')")  # the 262 Neighborhood Tabulation Areas of 2020, NYC Department of City Planning
		tracts = fetch("https://data.cityofnewyork.us/resource/63ge-mke6.csv?\$select=geoid,nta2020&\$limit=5000", "nyc-tracts-2020.csv")  # the area each census tract of 2020 is in
		lodes = fetch("https://lehd.ces.census.gov/data/lodes/LODES8/ny/od/ny_od_main_JT00_2023.csv.gz", "ny_od_main_JT00_2023.csv.gz")  # LODES 8, all jobs of 2023 with home and work in New York State, U.S. Census Bureau
		execute("CREATE OR REPLACE TEMP TABLE tracts AS SELECT CAST(geoid AS VARCHAR) AS tract, nta2020 AS zone FROM read_csv('$(tracts)', types = {'geoid': 'VARCHAR'})")
		execute("CREATE OR REPLACE TEMP TABLE lodes AS SELECT h.zone AS origin, w.zone AS destination, sum(S000)::DOUBLE AS jobs FROM read_csv('$(lodes)', types = {'w_geocode': 'VARCHAR', 'h_geocode': 'VARCHAR'}) l JOIN tracts h ON h.tract = left(l.h_geocode, 11) LEFT JOIN tracts w ON w.tract = left(l.w_geocode, 11) GROUP BY ALL")
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, jobs AS flow FROM lodes WHERE destination IS NOT NULL")
		left = query("SELECT sum(jobs) FILTER (WHERE destination IS NULL) AS away, NULL::DOUBLE AS home FROM lodes")
		unit, source = "jobs", "LEHD Origin-Destination Employment Statistics (LODES 8), primary and other jobs in 2023"
	elseif city == "tokyo"
		table = fetch("https://www.toukei.metro.tokyo.lg.jp/tyukanj/2020/tj20zv0702.csv", "tokyo-2020-table-7-2.csv")  # Table 7-2 of Tokyo's daytime population: commuters between municipalities, 2020 Census, Tokyo Metropolitan Government
		small_areas = fetch("https://www.e-stat.go.jp/gis/statmap-search/data?dlserveyId=A002005212020&code=13&coordSys=1&format=shape&downloadType=5&datum=2011", "estat-2020-small-areas-tokyo.zip")  # the small areas of the 2020 Census in Tokyo, e-Stat
		execute("CREATE OR REPLACE TEMP TABLE places AS SELECT \"地域コード\" AS code, replace(\"地域\", '従業地・通学地／', '') AS name FROM read_csv('$(table)', all_varchar = true) WHERE \"階層\" = '5'")  # the municipalities, by code and name
		execute("""CREATE OR REPLACE TEMP TABLE tokyo AS SELECT h.code AS origin, w.code AS destination, TRY_CAST(replace(people, ',', '') AS DOUBLE) AS people
			FROM (UNPIVOT (SELECT * FROM read_csv('$(table)', all_varchar = true) WHERE "階層" = '5') ON COLUMNS('^常住地／') INTO NAME home VALUE people) r
			JOIN places w ON w.code = r."地域コード" JOIN places h ON '常住地／' || h.name || '（人）' = r.home""")  # rows are places of work, columns places of residence
		execute("CREATE OR REPLACE TABLE zones AS SELECT a.zone, p.name, a.geom FROM (SELECT PREF || CITY AS zone, ST_Union_Agg(geom) AS geom FROM ST_Read('/vsizip/$(small_areas)/r2ka13.shp') WHERE (PREF || CITY) < '13360' GROUP BY ALL) a JOIN places p ON p.code = a.zone")  # the 23 wards and the cities, towns and villages of Tama, without the islands
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, people AS flow FROM tokyo WHERE origin IN (SELECT zone FROM zones) AND destination IN (SELECT zone FROM zones) AND people > 0")
		left = (away = [missing], home = [missing])  # the table counts only commuters who live and work in Tokyo, and none who work at home
		unit, source = "commuters", "2020 Census, commuters aged 15 and over who live and work in Tokyo"
	else
		districts = fetch("https://portal.csdi.gov.hk/csdi-webpage/file-api?dataset_id=censtatd_rcd_1635932856094_19982&format=geojson&layer_name=DC_21C", "hk-2021-census-districts.geojson")  # the 18 districts with the statistics of the 2021 Population Census, through the CSDI portal (25 MB, once)
		execute("CREATE OR REPLACE TEMP TABLE census AS SELECT dc_class AS zone, dc_eng AS name, CASE WHEN dc_class <= 'D' THEN 'HKI' WHEN dc_class <= 'J' THEN 'KLN' ELSE 'NT' END AS area, * EXCLUDE (dc_class, dc_eng) FROM ST_Read('$(districts)')")
		execute("CREATE OR REPLACE TABLE zones AS SELECT zone, name, geom FROM census UNION ALL SELECT area, CASE area WHEN 'HKI' THEN 'Hong Kong Island' WHEN 'KLN' THEN 'Kowloon' ELSE 'New Territories' END, ST_Union_Agg(geom) FROM census GROUP BY area")  # the districts, and the three areas the census groups places of work in
		work_in(a) = "CASE '$(a)' WHEN 'HKI' THEN plw_diff_hk WHEN 'KLN' THEN plw_diff_kln ELSE plw_diff_nt + plw_diff_oth END"  # those who work in another district of an area
		execute("CREATE OR REPLACE TABLE flows AS " * join(["SELECT zone AS origin, '$(a)' AS destination, ($(work_in(a)) + CASE WHEN area = '$(a)' THEN plw_same ELSE 0 END)::DOUBLE AS flow FROM census" for a in ("HKI", "KLN", "NT")], " UNION ALL "))
		left = query("SELECT sum(plw_out) AS away, sum(plw_hm) AS home FROM census")
		unit, source = "workers", "2021 Population Census, working population by district of residence and area of work"
	end
	centroids(con)
	return (; unit, source, away = only(left.away), home = only(left.home))
end

"""
    trip_flows(con, city; month = "latest", folder, key = nothing)

The trips between the zones of `city` in `month` (as `"2025-06"`, or `"latest"`), downloaded once into `folder`:
`"london"` (the journeys of Santander Cycles, Transport for London, by middle layer super output area), `"newyork"`
(the yellow taxi trips of the NYC Taxi and Limousine Commission, by taxi zone) or `"singapore"` (the bus trips of LTA
DataMall, by planning area, which need an account key: `key`, or `ENV["LTA_ACCOUNT_KEY"]`). Writes the tables `zones`
(`zone`, `name`, `geom`, `lon`, `lat`), `flows` (`origin`, `destination`, `flow`), `hours` (`hour`, `day`, `flow`:
the trips by hour of start, on weekdays and other days) and, for London and New York, `trips` (`origin`,
`destination`, `start`) on the DuckDB connection `con`. Returns `(; unit, source, away, home)`, as
[`commuting_flows`](@ref).
"""
function trip_flows(con, city::AbstractString; month::AbstractString = "latest", folder::AbstractString, key = nothing)
	checked(city, TRIP_CITIES, "trips")
	execute, query, fetch, enc = readers(con, folder)
	if city == "london"
		msoa_zones(con, city, folder)
		listing = String(take!(Downloads.download("https://s3-eu-west-1.amazonaws.com/cycling.data.tfl.gov.uk?list-type=2&prefix=usage-stats/", IOBuffer())))  # the journey files of Santander Cycles, Transport for London
		files = [(key = m[1], month = Date(parse(Int, m[4]), findfirst(==(m[3]), Dates.LOCALES["english"].months_abbr), 1)) for m in eachmatch(r"<Key>usage-stats/(\d+JourneyDataExtract(\d{2})([A-Z][a-z]{2})(\d{4})-\d{2}[A-Z][a-z]{2}\d{4}\.csv)</Key>", listing)]  # each file covers half a month
		chosen = month == "latest" ? maximum(f.month for f in files) : Date("$(month)-01")
		journeys = [fetch("https://cycling.data.tfl.gov.uk/usage-stats/$(f.key)", f.key) for f in files if f.month == chosen]
		isempty(journeys) && error("No journey files of Santander Cycles for $(Dates.format(chosen, "yyyy-mm"))")
		stations = fetch("https://api.tfl.gov.uk/BikePoint", "tfl-bikepoints.json")  # the docking stations, with their terminal numbers and positions
		execute("CREATE OR REPLACE TEMP TABLE stations AS SELECT s.station, s.name, z.zone FROM (SELECT lpad([p.value FOR p IN additionalProperties IF p.key = 'TerminalName'][1], 6, '0') AS station, commonName AS name, ST_Point(lon, lat) AS point FROM read_json('$(stations)')) s JOIN zones z ON ST_Within(s.point, z.geom)")
		execute("CREATE OR REPLACE TEMP TABLE journeys AS SELECT lpad(\"Start station number\", 6, '0') AS a, lpad(\"End station number\", 6, '0') AS b, strptime(\"Start date\", '%Y-%m-%d %H:%M') AS start FROM read_csv([$(join(["'$(j)'" for j in journeys], ", "))], all_varchar = true)")
		execute("CREATE OR REPLACE TABLE trips AS SELECT o.zone AS origin, d.zone AS destination, start FROM journeys j LEFT JOIN stations o ON o.station = j.a LEFT JOIN stations d ON d.station = j.b")
		unit, source = "journeys", "Santander Cycles journeys of $(Dates.format(chosen, "U yyyy")), Transport for London"
	elseif city == "newyork"
		taxi_zones = fetch("https://d37ci6vzurychx.cloudfront.net/misc/taxi_zones.zip", "taxi_zones.zip")  # the taxi zones, NYC Taxi and Limousine Commission (TLC)
		execute("CREATE OR REPLACE TABLE zones AS SELECT CAST(LocationID AS VARCHAR) AS zone, zone AS name, ST_Transform(geom, 'EPSG:2263', 'EPSG:4326') AS geom FROM ST_Read('/vsizip/$(taxi_zones)/taxi_zones/taxi_zones.shp')")
		months = month == "latest" ? [firstdayofmonth(today()) - Month(k) for k in 1:8] : [Date("$(month)-01")]  # the TLC publishes each month about two months later
		chosen, records = nothing, ""
		for m in months
			name = "yellow_tripdata_$(Dates.format(m, "yyyy-mm")).parquet"
			try
				records = fetch("https://d37ci6vzurychx.cloudfront.net/trip-data/$(name)", name)  # the yellow taxi trips of the month (about 60 MB)
				chosen = m
				break
			catch e
				m == last(months) && rethrow()
			end
		end
		execute("CREATE OR REPLACE TABLE trips AS SELECT CAST(PULocationID AS VARCHAR) AS origin, CAST(DOLocationID AS VARCHAR) AS destination, tpep_pickup_datetime AS start FROM read_parquet('$(records)') WHERE tpep_pickup_datetime >= DATE '$(chosen)' AND tpep_pickup_datetime < DATE '$(chosen + Month(1))'")
		unit, source = "trips", "yellow taxi trips of $(Dates.format(chosen, "U yyyy")), NYC Taxi and Limousine Commission"
	else
		if key === nothing
			haskey(ENV, "LTA_ACCOUNT_KEY") || error("The bus trips of LTA DataMall need an account key: set ENV[\"LTA_ACCOUNT_KEY\"], or pass key. In Pollis, set it with the key on the Powered by line")
			key = ENV["LTA_ACCOUNT_KEY"]
		end
		lta = ["AccountKey" => key, "accept" => "application/json"]
		areas = joinpath(folder, "sg-planning-areas-2025.geojson")  # the 55 planning areas of the Master Plan 2025, Urban Redevelopment Authority, through data.gov.sg
		if !isfile(areas)
			poll = Downloads.download("https://api-open.data.gov.sg/v1/public/api/datasets/d_2cc750190544007400b2cfd5d7f53209/poll-download", tempname())  # a link to the file, valid for a short time
			Downloads.download(only(query("SELECT data.url AS u FROM read_json('$(poll)')").u), areas)
		end
		execute("CREATE OR REPLACE TABLE zones AS SELECT PLN_AREA_C AS zone, array_to_string(list_transform(string_split(lower(PLN_AREA_N), ' '), lambda w: upper(w[1]) || w[2:]), ' ') AS name, geom FROM ST_Read('$(areas)')")
		pages = [fetch("https://datamall2.mytransport.sg/ltaodataservice/BusStops?\$skip=$(500k)", "lta-bus-stops-$(k).json"; headers = lta) for k in 0:19]  # the bus stops, 500 a page
		execute("CREATE OR REPLACE TEMP TABLE stops AS SELECT s.BusStopCode AS stop, z.zone FROM (SELECT unnest(value, recursive := true) FROM read_json([$(join(["'$(p)'" for p in pages], ", "))], columns = {'value': 'STRUCT(BusStopCode VARCHAR, Latitude DOUBLE, Longitude DOUBLE)[]'})) s JOIN zones z ON ST_Within(ST_Point(s.Longitude, s.Latitude), z.geom)")
		month_wanted = month == "latest" ? "" : "?Date=" * replace(month, "-" => "")  # DataMall keeps the last three months
		answer = Downloads.download("https://datamall2.mytransport.sg/ltaodataservice/PV/ODBus" * month_wanted, tempname(); headers = lta)
		link = only(query("SELECT value[1].Link AS link FROM read_json('$(answer)')").link)  # a link to the month's file, valid for 15 minutes
		chosen = match(r"origin_destination_bus_(\d{6})", link)[1]
		archive = fetch(link, "origin_destination_bus_$(chosen).zip")
		records = unzipped(archive, only(filter(endswith(".csv"), zip_names(ZipReader(read(archive))))))
		execute("CREATE OR REPLACE TEMP TABLE od AS SELECT DAY_TYPE AS day, TIME_PER_HOUR AS hour, o.zone AS origin, d.zone AS destination, TOTAL_TRIPS AS trips FROM read_csv('$(records)', types = {'ORIGIN_PT_CODE': 'VARCHAR', 'DESTINATION_PT_CODE': 'VARCHAR'}) r LEFT JOIN stops o ON o.stop = r.ORIGIN_PT_CODE LEFT JOIN stops d ON d.stop = r.DESTINATION_PT_CODE")
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, sum(trips)::DOUBLE AS flow FROM od WHERE origin IS NOT NULL AND destination IS NOT NULL GROUP BY ALL")
		left = query("SELECT sum(trips) FILTER (WHERE origin IS NULL OR destination IS NULL) AS away, NULL::DOUBLE AS home FROM od")
		unit, source = "bus trips", "bus trips by stop of origin and of destination, $(chosen[1:4])-$(chosen[5:6]), LTA DataMall"
		execute("CREATE OR REPLACE TABLE hours AS SELECT hour, CASE day WHEN 'WEEKDAY' THEN 'Weekdays' ELSE 'Weekends and holidays' END AS day, sum(trips)::DOUBLE AS flow FROM od GROUP BY ALL")
	end
	if city != "singapore"
		execute("CREATE OR REPLACE TABLE flows AS SELECT origin, destination, count(*)::DOUBLE AS flow FROM trips WHERE origin IS NOT NULL AND destination IS NOT NULL GROUP BY ALL")
		left = query("SELECT count(*) FILTER (WHERE origin IS NULL OR destination IS NULL OR origin NOT IN (SELECT zone FROM zones) OR destination NOT IN (SELECT zone FROM zones)) AS away, NULL::DOUBLE AS home FROM trips")
		execute("DELETE FROM flows WHERE origin NOT IN (SELECT zone FROM zones) OR destination NOT IN (SELECT zone FROM zones)")
		execute("CREATE OR REPLACE TABLE hours AS SELECT hour(start) AS hour, CASE WHEN dayofweek(start) IN (0, 6) THEN 'Weekends' ELSE 'Weekdays' END AS day, count(*)::DOUBLE AS flow FROM trips GROUP BY ALL")
	end
	centroids(con)
	return (; unit, source, away = only(left.away), home = only(left.home))
end

"""
    given_flows(con, flows, zones)

The flows of the CSV file `flows` (with the columns `origin`, `destination` and `flow`) between the zones of the file
`zones` (any format GDAL reads, with the columns `zone`, a geometry and, optionally, `name`), as
[`commuting_flows`](@ref) writes them: the tables `zones` and `flows` on the DuckDB connection `con`, the flows that
start or end outside the zones left out. Returns `(; unit, source, away, home)`.
"""
function given_flows(con, flows::AbstractString, zones::AbstractString)
	execute(sql) = DBInterface.execute(con, sql)
	query(sql) = Tables.columntable(DBInterface.execute(con, sql))
	names = query("DESCRIBE SELECT * FROM ST_Read('$(quoted(zones))')").column_name
	execute("CREATE OR REPLACE TABLE zones AS SELECT CAST(zone AS VARCHAR) AS zone, CAST($("name" in names ? "name" : "zone") AS VARCHAR) AS name, geom FROM ST_Read('$(quoted(zones))')")
	execute("CREATE OR REPLACE TEMP TABLE given AS SELECT CAST(origin AS VARCHAR) AS origin, CAST(destination AS VARCHAR) AS destination, CAST(flow AS DOUBLE) AS flow FROM read_csv('$(quoted(flows))')")
	execute("CREATE OR REPLACE TABLE flows AS SELECT * FROM given WHERE origin IN (SELECT zone FROM zones) AND destination IN (SELECT zone FROM zones)")
	left = query("SELECT sum(flow) FILTER (WHERE origin NOT IN (SELECT zone FROM zones) OR destination NOT IN (SELECT zone FROM zones)) AS away FROM given")
	centroids(con)
	return (; unit = "flows", source = basename(flows), away = only(left.away), home = missing)
end

"""
    traffic_counts(con, city; folder)

The counts of road traffic of `city`, downloaded once into `folder`: `"cambridge"`, `"oxford"` and `"london"` (the
annual average daily flows of the Department for Transport), `"newyork"` (the automated traffic volume counts of the
NYC Department of Transportation) or `"paris"` (the permanent road counters of the Ville de Paris). Writes the table
`counts` (`site`, `name`, `kind`, `lon`, `lat`, `year`, `flow`: vehicles a day, `method`) on the DuckDB connection
`con`, and with it `classes` (`site`, `year`, `class`, `flow`: the flows by type of vehicle) for the cities of
England, and `hours` (`hour`, `day`, `flow`: the mean vehicles an hour) for New York and Paris. Returns
`(; unit, source)`.
"""
function traffic_counts(con, city::AbstractString; folder::AbstractString)
	checked(city, COUNT_CITIES, "traffic counts")
	execute, query, fetch, enc = readers(con, folder)
	if city in ("cambridge", "oxford", "london")
		dft = "https://storage.googleapis.com/dft-statistics/road-traffic/downloads/aadf/"
		file = fetch(dft * Dict("cambridge" => "local_authority_id/dft_aadf_local_authority_id_97.csv", "oxford" => "local_authority_id/dft_aadf_local_authority_id_142.csv", "london" => "region_id/dft_aadf_region_id_6.csv")[city], "dft-aadf-$(city).csv")  # annual average daily flows at the count points, Department for Transport
		box = Dict("cambridge" => (-0.05, 52.13, 0.25, 52.28), "oxford" => (-1.40, 51.68, -1.13, 51.82), "london" => (-0.52, 51.28, 0.34, 51.70))[city]  # the area around the city, in degrees of longitude and latitude
		execute("CREATE OR REPLACE TEMP TABLE dft AS SELECT * FROM read_csv('$(file)') WHERE longitude BETWEEN $(box[1]) AND $(box[3]) AND latitude BETWEEN $(box[2]) AND $(box[4])")
		execute("CREATE OR REPLACE TABLE counts AS SELECT CAST(count_point_id AS VARCHAR) AS site, road_name || coalesce(' (' || start_junction_road_name || ' to ' || end_junction_road_name || ')', '') AS name, road_type AS kind, longitude AS lon, latitude AS lat, year, all_motor_vehicles::DOUBLE AS flow, estimation_method AS method FROM dft")
		execute("""CREATE OR REPLACE TABLE classes AS UNPIVOT (SELECT CAST(count_point_id AS VARCHAR) AS site, year, pedal_cycles AS "Pedal cycles", two_wheeled_motor_vehicles AS "Motorcycles", cars_and_taxis AS "Cars and taxis", buses_and_coaches AS "Buses and coaches", lgvs AS "Light goods vehicles", all_hgvs AS "Heavy goods vehicles" FROM dft) ON COLUMNS(* EXCLUDE (site, year)) INTO NAME class VALUE flow""")
		unit, source = "motor vehicles a day", "Department for Transport, annual average daily flows"
	elseif city == "newyork"
		socrata = "https://data.cityofnewyork.us/resource/7ym2-wayt.csv?"  # automated traffic volume counts, NYC Department of Transportation
		file = fetch(socrata * "\$select=" * enc("segmentid, boro, street, fromst, tost, direction, wktgeom, yr, avg(vol) * 96 AS daily") * "&\$group=" * enc("segmentid, boro, street, fromst, tost, direction, wktgeom, yr") * "&\$limit=500000", "nyc-dot-counts-$(today()).csv")  # the mean count of a quarter hour, times 96
		execute("CREATE OR REPLACE TABLE counts AS SELECT segmentid || ' ' || direction AS site, street || ' (' || fromst || ' to ' || tost || ', ' || direction || ')' AS name, boro AS kind, ST_X(p) AS lon, ST_Y(p) AS lat, CAST(yr AS INTEGER) AS year, daily AS flow, 'Automated count' AS method FROM (SELECT *, ST_Transform(ST_GeomFromText(wktgeom), 'EPSG:2263', 'EPSG:4326') AS p FROM read_csv('$(file)', types = {'segmentid': 'VARCHAR', 'yr': 'VARCHAR'}))")
		latest_year = only(query("SELECT max(year) AS y FROM counts").y)
		hourly = fetch(socrata * "\$select=" * enc("hh, avg(vol) * 4 AS flow") * "&\$where=" * enc("yr = '$(latest_year)'") * "&\$group=hh", "nyc-dot-hours-$(latest_year).csv")
		execute("CREATE OR REPLACE TABLE hours AS SELECT CAST(hh AS INTEGER) AS hour, 'All days' AS day, flow FROM read_csv('$(hourly)')")
		unit, source = "vehicles a day", "NYC Department of Transportation, automated traffic volume counts"
	else
		paris = "https://opendata.paris.fr/api/explore/v2.1/catalog/datasets/"
		sections = fetch(paris * "referentiel-comptages-routiers/exports/geojson", "paris-counted-sections.geojson")  # the road sections with a permanent counter, Ville de Paris
		yearly = fetch(paris * "comptages-routiers-permanents/exports/csv?select=" * enc("iu_ac, avg(q) * 24 AS flow") * "&group_by=" * enc("iu_ac, year(t_1h) AS year") * "&where=" * enc("q is not null") * "&timezone=Europe%2FParis&delimiter=%3B", "paris-counts-$(today()).csv")  # the mean hourly flow of each counter in each year, times 24
		hourly = fetch(paris * "comptages-routiers-permanents/exports/csv?select=" * enc("avg(q) AS flow") * "&group_by=" * enc("hour(t_1h) AS hour") * "&where=" * enc("q is not null") * "&timezone=Europe%2FParis&delimiter=%3B", "paris-hours-$(today()).csv")
		execute("CREATE OR REPLACE TABLE counts AS SELECT CAST(c.iu_ac AS VARCHAR) AS site, replace(s.libelle, '_', ' ') AS name, 'Road section' AS kind, ST_X(ST_Centroid(s.geom)) AS lon, ST_Y(ST_Centroid(s.geom)) AS lat, c.year, c.flow, 'Permanent counter' AS method FROM read_csv('$(yearly)', delim = ';') c JOIN (SELECT * FROM ST_Read('$(sections)') QUALIFY row_number() OVER (PARTITION BY iu_ac ORDER BY coalesce(date_fin, TIMESTAMP '9999-12-31') DESC) = 1) s ON CAST(s.iu_ac AS VARCHAR) = CAST(c.iu_ac AS VARCHAR)")
		execute("CREATE OR REPLACE TABLE hours AS SELECT hour, 'All days' AS day, flow FROM read_csv('$(hourly)', delim = ';')")
		unit, source = "vehicles a day", "Ville de Paris, permanent road counters"
	end
	return (; unit, source)
end

"""
    given_counts(con, file)

The counts of road traffic of the CSV file `file`, with the columns `site`, `lon`, `lat`, `year`, `flow` and,
optionally, `name`, as [`traffic_counts`](@ref) writes them: the table `counts` on the DuckDB connection `con`.
Returns `(; unit, source)`.
"""
function given_counts(con, file::AbstractString)
	names = Tables.columntable(DBInterface.execute(con, "DESCRIBE SELECT * FROM read_csv('$(quoted(file))')")).column_name
	DBInterface.execute(con, "CREATE OR REPLACE TABLE counts AS SELECT CAST(site AS VARCHAR) AS site, CAST($("name" in names ? "name" : "site") AS VARCHAR) AS name, 'Count point' AS kind, lon, lat, year, CAST(flow AS DOUBLE) AS flow, 'Given' AS method FROM read_csv('$(quoted(file))')")
	return (; unit = "vehicles a day", source = basename(file))
end

"""
    flight_list(month; folder)

The flight list of the OpenSky Network for `month` (as `"2022-12"`, from 2019-01 to 2022-12): every flight its
receivers saw, with its callsign, aircraft type, airports of departure and arrival where known, and day, a gzipped CSV
of 150 to 200 MB from Zenodo, downloaded once into `folder` and returned.
"""
function flight_list(month::AbstractString; folder::AbstractString)
	record = read(cached(FLIGHT_LISTS, joinpath(folder, "opensky-flightlist-record.json")), String)
	m = match(Regex("\"key\"\\s*:\\s*\"(flightlist_$(replace(month, "-" => ""))01_\\d+\\.csv\\.gz)\""), record)
	m === nothing && throw(ArgumentError("The flight list has no month $(month): it covers 2019-01 to 2022-12"))
	return cached("$(FLIGHT_LISTS)/files/$(m[1])/content", joinpath(folder, m[1]))
end

"""
    air_flights(con, month; folder)

The flights of `month` (as `"2022-12"`) of the OpenSky Network's [`flight_list`](@ref), and the airports of the world
of OurAirports, downloaded once into `folder`. Writes the tables `flights` (`callsign`, `origin`, `destination`,
`typecode`, `day`, the airports by their ICAO codes) and `airports` (`icao`, `name`, `country`, `municipality`, `lon`,
`lat`, `scheduled`: whether it has scheduled service) on the DuckDB connection `con`. Returns the file of the flight
list.
"""
function air_flights(con, month::AbstractString; folder::AbstractString)
	flights_file = flight_list(month; folder)
	airports_file = cached("https://davidmegginson.github.io/ourairports-data/airports.csv", joinpath(folder, "ourairports-airports.csv"))
	DBInterface.execute(con, "CREATE OR REPLACE TABLE airports AS SELECT ident AS icao, name, iso_country AS country, municipality, longitude_deg AS lon, latitude_deg AS lat, scheduled_service = 'yes' AS scheduled FROM read_csv('$(quoted(airports_file))')")
	DBInterface.execute(con, "CREATE OR REPLACE TABLE flights AS SELECT callsign, origin, destination, typecode, CAST(day AS DATE) AS day FROM read_csv('$(quoted(flights_file))', types = {'callsign': 'VARCHAR', 'origin': 'VARCHAR', 'destination': 'VARCHAR', 'typecode': 'VARCHAR', 'day': 'VARCHAR'})")
	return flights_file
end
