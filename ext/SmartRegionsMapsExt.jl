module SmartRegionsMapsExt

# Rasters as the maps of a page of terrain_maps: each a PNG in grey beside the page, north up, the outlines of the
# features as GDAL traces them, and the imagery: tiles placed on the grid by their projected corners, or Google's map,
# which follows the grid through the longitude and latitude of points over it.

using SmartRegions, Rasters, ArchGDAL
import SmartRegions: terrain_maps

const SR = SmartRegions
const GDAL = ArchGDAL.GDAL
const L = Rasters.Lookups
const LONLAT = Rasters.GeoFormatTypes.EPSG(4326)

centres(r, D) = collect(L.shiftlocus(L.Center(), lookup(r, D)))

function grey_png(r, low, high)
	shade(v) = ismissing(v) || !isfinite(v) ? 0x00 : round(UInt8, 255 * clamp((v - low) / (high - low), 0, 1))
	g = UInt8[shade(v) for v in parent(r)]
	step(lookup(r, Rasters.X)) < 0 && (g = reverse(g; dims = 1))  # the first column is the west
	step(lookup(r, Rasters.Y)) > 0 && (g = reverse(g; dims = 2))  # the first row is the north
	png = tempname(SR.pages()) * ".png"
	ArchGDAL.create(ArchGDAL.getdriver("MEM"); width = size(g, 1), height = size(g, 2), nbands = 1, dtype = UInt8) do mem
		ArchGDAL.write!(mem, g, 1)
		ArchGDAL.destroy(ArchGDAL.unsafe_copy(mem; filename = png, driver = ArchGDAL.getdriver("PNG")))
	end
	return basename(png)
end

# The rings of the outlines of the features, as points in the coordinates of the rasters
function outline_rings(labels)
	return [[Tuple(parse.(Float64, split(point)[1:2])) for point in split(ring[:points], ',')]
		for (_, wkt) in SR.feature_outlines(labels) for ring in eachmatch(r"\((?<points>[^()]+)\)", wkt)]
end

# The outlines as one SVG path, from the north-west corner of the rasters
function outline_path(rings, west, north)
	path = IOBuffer()
	for ring in rings
		for (k, (x, y)) in enumerate(ring)
			print(path, k == 1 ? 'M' : 'L', x - west, ' ', north - y)
		end
		print(path, 'Z')
	end
	return String(take!(path))
end

# The imagery of a source of tiles over the box of the rasters, as tiles of SVG on their grid
function imagery_tiles(source, system, west, north, w, h)
	key = isempty(source.key) ? "" : strip(ENV[source.key])
	border = [(west + a * w, north - b * h) for a in 0:0.25:1 for b in 0:0.25:1]
	places = [(p[1], p[2]) for p in ArchGDAL.reproject(border, system, LONLAT; order = :trad)]
	z, tiles = SR.tiles_over(places; closest = source.closest)
	corners = [SR.tile_corner(i + a, j + b, z) for (i, j) in tiles for (a, b) in ((0, 0), (1, 0), (0, 1))]
	on_grid = [(p[1] - west, north - p[2]) for p in ArchGDAL.reproject(corners, LONLAT, system; order = :trad)]
	return join(SR.tile_image(source.address(z, i, j, key), on_grid[3k - 2], on_grid[3k - 1], on_grid[3k]) for (k, (i, j)) in enumerate(tiles))
end

# What Google's map needs to follow the grid: the longitude and latitude of n by n points over the rasters, row by row
# from the north-west, the metres on the ground in a unit of the grid at their middle, and the outlines as GeoJSON
function google_view(system, west, north, w, h, rings; n = 9)
	grid = [(west + i * w / (n - 1), north - j * h / (n - 1)) for j in 0:n - 1 for i in 0:n - 1]
	points = [(p[1], p[2]) for p in ArchGDAL.reproject(grid, system, LONLAT; order = :trad)]
	middle = div(n, 2) * n + div(n, 2) + 1
	(lon1, lat1), (lon2, lat2) = points[middle], points[middle + 1]
	ground = 2 * 6378137 * asin(sqrt(sind((lat2 - lat1) / 2)^2 + cosd(lat1) * cosd(lat2) * sind((lon2 - lon1) / 2)^2))
	outlines = "null"
	if !isempty(rings)
		ends = cumsum(length.(rings))
		projected = [(p[1], p[2]) for p in ArchGDAL.reproject(reduce(vcat, rings), system, LONLAT; order = :trad)]
		lines = ["[" * join(("[$(lon),$(lat)]" for (lon, lat) in projected[e - length(ring) + 1:e]), ',') * "]" for (ring, e) in zip(rings, ends)]
		outlines = """{"type":"Feature","properties":{},"geometry":{"type":"MultiLineString","coordinates":[$(join(lines, ','))]}}"""
	end
	site = "{n: $(n), points: [$(join(("[$(lon),$(lat)]" for (lon, lat) in points), ','))], metres: $(ground / (w / (n - 1))), outlines: $(outlines)}"
	return (; site, key = strip(ENV[SR.GOOGLE_KEY]))
end

function terrain_maps(title::AbstractString, layers::Pair...; labels = nothing, centre = nothing, width = nothing, imagery = :auto)
	isempty(layers) && throw(ArgumentError("terrain_maps needs at least one layer, as name => raster"))
	source = SR.imagery_source(imagery)
	drawn = [value isa Tuple ? (String(name), value...) : (String(name), value, 0, 1) for (name, value) in layers]
	r = drawn[1][2]
	all(d -> size(d[2]) == size(r), drawn) && (labels === nothing || size(labels) == size(r)) ||
		throw(DimensionMismatch("the layers and the labels must be on one grid"))
	cx, cy = centres(r, Rasters.X), centres(r, Rasters.Y)
	dx, dy = abs(Float64(step(lookup(r, Rasters.X)))), abs(Float64(step(lookup(r, Rasters.Y))))
	west, north = minimum(cx) - dx / 2, maximum(cy) + dy / 2
	w, h = length(cx) * dx, length(cy) * dy
	place = nothing
	if centre !== nothing || width !== nothing
		at = centre === nothing ? (w / 2, h / 2) : (centre[1] - west, north - centre[2])
		0 <= at[1] <= w && 0 <= at[2] <= h || throw(ArgumentError("the centre $(centre) is outside the rasters"))
		side = Float64(something(width, min(w, h) / 4))
		place = (Float64.(at), (side, side))
	end
	maps = [(; name, body = """<image class="cells" href="$(grey_png(v, low, high))" width="$(w)" height="$(h)" preserveAspectRatio="none"/>""",
		credit = "", google = false) for (name, v, low, high) in drawn]
	rings = labels === nothing ? Vector{Tuple{Float64, Float64}}[] : outline_rings(labels)
	system = Rasters.crs(r)
	known = !isnothing(system) && !isempty(convert(String, system))
	metres = nothing
	google = nothing
	if known
		reference = ArchGDAL.importCRS(system)
		GDAL.osrisprojected(reference) == 1 && (metres = GDAL.osrgetlinearunits(reference, C_NULL))
		if source === :google
			google = google_view(system, west, north, w, h, rings)
			push!(maps, (name = SR.GOOGLE_NAME, body = "", credit = "", google = true))
		elseif source !== :none
			tiles = getfield(SR.TILES, source)
			push!(maps, (name = tiles.name, body = imagery_tiles(tiles, system, west, north, w, h), credit = tiles.credit, google = false))
		end
	end
	return SR.maps_page(title, maps, outline_path(rings, west, north); size = (w, h), cell = dx, metres,
		centre = (w / 2, h / 2), span = (w, h), place, google)
end

end
