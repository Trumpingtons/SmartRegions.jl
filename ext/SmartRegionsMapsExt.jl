module SmartRegionsMapsExt

# Rasters as the maps of a page of terrain_maps: each a PNG in grey beside the page, north up, the outlines of the
# features as GDAL traces them, and the tiles of the imagery, each placed on the grid by its projected corners.

using SmartRegions, Rasters, ArchGDAL
import SmartRegions: terrain_maps

const SR = SmartRegions
const GDAL = ArchGDAL.GDAL
const L = Rasters.Lookups

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

# The outlines as one SVG path, from the corner that feature_outlines counts the cells from
function outline_path(labels)
	X, Y = lookup(labels, Rasters.X), lookup(labels, Rasters.Y)
	dx, dy = Float64(step(X)), Float64(step(Y))
	(xa, xb), (ya, yb) = Rasters.bounds(labels, Rasters.X), Rasters.bounds(labels, Rasters.Y)
	west = dx > 0 ? xa : xb + length(X) * dx
	north = dy < 0 ? yb : ya + length(Y) * dy
	path = IOBuffer()
	for (_, wkt) in SR.feature_outlines(labels), ring in eachmatch(r"\((?<points>[^()]+)\)", wkt)
		for (k, point) in enumerate(split(ring[:points], ','))
			x, y = parse.(Float64, split(point)[1:2])
			print(path, k == 1 ? 'M' : 'L', x - west, ' ', north - y)
		end
		print(path, 'Z')
	end
	return String(take!(path))
end

# The imagery over the box of the rasters, as tiles of SVG on their grid
function imagery_tiles(system, west, north, w, h)
	lonlat = Rasters.GeoFormatTypes.EPSG(4326)
	border = [(west + a * w, north - b * h) for a in 0:0.25:1 for b in 0:0.25:1]
	places = [(p[1], p[2]) for p in ArchGDAL.reproject(border, system, lonlat; order = :trad)]
	z, tiles = SR.tiles_over(places)
	corners = [SR.tile_corner(i + a, j + b, z) for (i, j) in tiles for (a, b) in ((0, 0), (1, 0), (0, 1))]
	on_grid = [(p[1] - west, north - p[2]) for p in ArchGDAL.reproject(corners, lonlat, system; order = :trad)]
	return join(SR.tile_image(z, tile, on_grid[3k - 2], on_grid[3k - 1], on_grid[3k]) for (k, tile) in enumerate(tiles))
end

function terrain_maps(title::AbstractString, layers::Pair...; labels = nothing, centre = nothing, width = nothing, imagery::Bool = true)
	isempty(layers) && throw(ArgumentError("terrain_maps needs at least one layer, as name => raster"))
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
	maps = Tuple{String, String, String}[(name, """<image class="cells" href="$(grey_png(v, low, high))" width="$(w)" height="$(h)" preserveAspectRatio="none"/>""", "")
		for (name, v, low, high) in drawn]
	system = Rasters.crs(r)
	known = !isnothing(system) && !isempty(convert(String, system))
	metres = nothing
	if known
		reference = ArchGDAL.importCRS(system)
		GDAL.osrisprojected(reference) == 1 && (metres = GDAL.osrgetlinearunits(reference, C_NULL))
		imagery && push!(maps, ("Aerial and Satellite Imagery", imagery_tiles(system, west, north, w, h), SR.IMAGERY_CREDIT))
	end
	return SR.maps_page(title, maps, labels === nothing ? "" : outline_path(labels); size = (w, h), cell = dx, metres,
		centre = (w / 2, h / 2), span = (w, h), place)
end

end
