# The relief visualisations and candidate features of SmartRegions for a terrain model read with Rasters.jl: radii
# and areas in the units of its coordinates, results on its grid (missing where undefined), and candidates at x and y

module SmartRegionsRastersExt

using SmartRegions, Rasters
import SmartRegions: local_relief, sky_view_factor, openness, terrain_slope, shaded_relief, layered_image,
	find_mounds, find_pits, find_regions, find_templates, scheduled_monuments, save_candidates, candidates_table, crs_string,
	adaf_input, adaf_probability, adaf_features

const L = Rasters.Lookups

steps(r) = (Float64(step(lookup(r, X))), Float64(step(lookup(r, Y))))
heights(r) = Float64.(coalesce.(parent(r), NaN))
on_grid(r, v) = rebuild(r; data = [isfinite(x) ? x : missing for x in v], missingval = missing)
centres(r, D) = collect(L.shiftlocus(L.Center(), lookup(r, D)))

function located(r, candidates)  # the positions i, j of the candidates turned into x, y, the centres of their cells
	x, y = centres(r, X), centres(r, Y)
	at(c, t) = c[1] + (t - 1) * (c[end] - c[1]) / max(length(c) - 1, 1)
	return [merge((id = c.id, x = at(x, c.i), y = at(y, c.j)), Base.structdiff(c, NamedTuple{(:id, :i, :j)})) for c in candidates]
end

crs_string(r::Rasters.AbstractRaster) = string(Rasters.GeoFormatTypes.val(convert(Rasters.GeoFormatTypes.WellKnownText, Rasters.crs(r))))

local_relief(dem::Rasters.AbstractRaster; kw...) = on_grid(dem, local_relief(heights(dem), steps(dem); kw...))
sky_view_factor(dem::Rasters.AbstractRaster; kw...) = on_grid(dem, sky_view_factor(heights(dem), steps(dem); kw...))
openness(dem::Rasters.AbstractRaster; kw...) = on_grid(dem, openness(heights(dem), steps(dem); kw...))
terrain_slope(dem::Rasters.AbstractRaster) = on_grid(dem, terrain_slope(heights(dem), steps(dem)))
shaded_relief(dem::Rasters.AbstractRaster; kw...) = on_grid(dem, shaded_relief(heights(dem), steps(dem); kw...))
layered_image(dem::Rasters.AbstractRaster; kw...) = on_grid(dem, layered_image(heights(dem), steps(dem); kw...))

function with_grid(r, found)  # candidates at x, y, and the matrices of the result as rasters on the grid of r
	extra = Dict(k => rebuild(r; data = v, missingval = nothing) for (k, v) in pairs(found) if k != :candidates)
	return merge((candidates = located(r, found.candidates),), NamedTuple(extra))
end
find_mounds(surface::Rasters.AbstractRaster; kw...) = with_grid(surface, find_mounds(heights(surface), steps(surface); kw...))
find_pits(surface::Rasters.AbstractRaster; kw...) = with_grid(surface, find_pits(heights(surface), steps(surface); kw...))
find_regions(lrm::Rasters.AbstractRaster; kw...) = with_grid(lrm, find_regions(heights(lrm), steps(lrm); kw...))
find_templates(lrm::Rasters.AbstractRaster; kw...) = with_grid(lrm, find_templates(heights(lrm), steps(lrm); kw...))

# ADAF reads a terrain model from its north-west corner: the matrices are turned north first, and back
north_first(r) = first(lookup(r, Y)) > last(lookup(r, Y))
turned(r, v) = north_first(r) ? v : reverse(v; dims = 2)

adaf_input(dem::Rasters.AbstractRaster) = on_grid(dem, turned(dem, adaf_input(turned(dem, heights(dem)), steps(dem))))

"""
    adaf_probability(model, dem::Raster; tile = 1024)

The probability of an archaeological feature at each cell of the terrain model `dem`, from ADAF's model `model`, on
the grid of `dem`: its local relief image, tiled from the north-west corner as ADAF tiles it. Missing where `dem` is.
"""
function adaf_probability(model, dem::Rasters.AbstractRaster; kw...)
	p = turned(dem, adaf_probability(model, turned(dem, Float32.(parent(adaf_input(dem)) .|> x -> coalesce(x, 0.0f0))); kw...))
	return on_grid(dem, ifelse.(isfinite.(heights(dem)), Float64.(p), NaN))
end

"""
    adaf_features(probability::Raster; kw...)

The features of the probability map `probability` (see `adaf_features(probability, cellsize)`), with their tiles
counted from the north-west corner, at `x` and `y`, and their cells as a raster `labels`.
"""
function adaf_features(probability::Rasters.AbstractRaster; kw...)
	ny = size(probability, Y)
	found = adaf_features(turned(probability, heights(probability)), steps(probability); kw...)
	if !north_first(probability)
		found = (candidates = [merge(c, (j = ny + 1 - c.j,)) for c in found.candidates], labels = reverse(found.labels; dims = 2))
	end
	return with_grid(probability, found)
end

"""
    scheduled_monuments(con, dem::Raster; table = "monuments")

The scheduled monuments of the National Heritage List for England that meet the terrain model `dem`, in its
coordinate system: see `scheduled_monuments(con, box; crs)`.
"""
function scheduled_monuments(con, dem::Rasters.AbstractRaster; table::AbstractString = "monuments")
	(x1, x2), (y1, y2) = Rasters.bounds(dem, X), Rasters.bounds(dem, Y)
	return scheduled_monuments(con, (x1, y1, x2, y2); crs = crs_string(dem), table)
end

end
