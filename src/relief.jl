# Relief visualisation of a terrain model, for archaeological prospection: the local relief model, the sky-view factor,
# openness, shaded relief, slope and the layered image (VAT), computed as RVT, the Relief Visualization Toolbox,
# computes them. A terrain model is a matrix of heights z[i, j], i along x and j along y; `cellsize` is the width of a
# cell, or (dx, dy) with the sign of each axis (dy < 0 when j runs from north to south). Radii are in the units of the
# cell size, metres for a projected terrain model. Cells too close to the edge for a window are NaN.

cellwidth(cellsize) = abs(Float64(first(cellsize)))
cellsteps(cellsize::Real) = (Float64(cellsize), Float64(cellsize))
cellsteps(cellsize) = (Float64(cellsize[1]), Float64(cellsize[2]))
cells(distance, cellsize) = round(Int, distance / cellwidth(cellsize))

# The sum of the finite values and their count in the (2r + 1) x (2r + 1) cells around each cell, from summed-area
# tables; 0 within r cells of the edge
function box_sums(v::AbstractMatrix, r::Integer)
	ok = isfinite.(v)
	S, C = zeros(size(v) .+ 1), zeros(size(v) .+ 1)
	S[2:end, 2:end] = cumsum(cumsum(ifelse.(ok, v, 0.0); dims = 1); dims = 2)
	C[2:end, 2:end] = cumsum(cumsum(Float64.(ok); dims = 1); dims = 2)
	box(T, i, j) = T[i + r + 1, j + r + 1] - T[i - r, j + r + 1] - T[i + r + 1, j - r] + T[i - r, j - r]
	s, c = zeros(size(v)), zeros(size(v))
	for j in r + 1:size(v, 2) - r, i in r + 1:size(v, 1) - r
		s[i, j], c[i, j] = box(S, i, j), box(C, i, j)
	end
	return s, c
end

"""
    local_relief(z, cellsize; radius = 20)

The simple local relief model of the terrain model `z` (Hesse 2010; as RVT's `slrm` computes it): the heights less
their mean over the square window of `radius` (in the units of `cellsize`, rounded to whole cells) around each cell,
the trend. Positive on banks and mounds, negative in ditches and pits, in the units of the heights. The mean counts
only finite heights; cells within the radius of the edge are NaN.
"""
function local_relief(z::AbstractMatrix{<:Real}, cellsize; radius::Real = 20)
	r = cells(radius, cellsize)
	v = Float64.(z)
	z0 = mean(filter(isfinite, v))  # heights less their mean, so the sums stay small and exact
	s, c = box_sums(v .- z0, r)
	out = fill(NaN, size(v))
	inner = (r + 1:size(v, 1) - r, r + 1:size(v, 2) - r)
	out[inner...] .= v[inner...] .- z0 .- s[inner...] ./ c[inner...]
	return out
end

# For each of n directions, the cells along it out to rmax cells, sampled every third of a cell and rounded to whole
# cells, nearest first, as RVT samples them
function horizon_offsets(n::Integer, rmax::Integer)
	return map(0:n - 1) do k
		a = 2pi * k / n
		offsets = unique([(round(Int, cos(a) * q), round(Int, sin(a) * q)) for q in 1:1 / 3:rmax])
		sort(offsets; by = o -> hypot(o...))
	end
end

# The elevation angle of the horizon, in radians, of each cell in each direction: the steepest rise to a cell within
# rmax cells; NaN within rmax cells of the edge
function horizon_angles(z::AbstractMatrix, rmax::Integer, n::Integer, h::Real)
	angles = fill(NaN, size(z)..., n)
	for (k, offsets) in enumerate(horizon_offsets(n, rmax)), j in rmax + 1:size(z, 2) - rmax, i in rmax + 1:size(z, 1) - rmax
		steepest = -Inf
		for (di, dj) in offsets
			steepest = max(steepest, (z[i - di, j - dj] - z[i, j]) / (h * hypot(di, dj)))
		end
		angles[i, j, k] = atan(steepest)
	end
	return angles
end

"""
    sky_view_factor(z, cellsize; radius = 10, directions = 16)

The sky-view factor of each cell of the terrain model `z` (Zakšek, Oštir and Kokalj 2011): one less the mean, over
`directions` directions, of the sine of the angle of the horizon within `radius`, a horizon below the cell counted as
level. 1 on open ground and crests, lower in ditches and hollows. Horizons are sampled as RVT's `sky_view_factor`
samples them.
"""
function sky_view_factor(z::AbstractMatrix{<:Real}, cellsize; radius::Real = 10, directions::Integer = 16)
	a = horizon_angles(Float64.(z), cells(radius, cellsize), directions, cellwidth(cellsize))
	return dropdims(mean(1 .- sin.(max.(a, 0)); dims = 3); dims = 3)
end

"""
    openness(z, cellsize; radius = 10, directions = 16, negative = false)

Positive openness of each cell of the terrain model `z` (Yokoyama, Shirasawa and Pike 2002), in degrees: the mean,
over `directions` directions, of the angle from the zenith to the horizon within `radius`. Above 90 on crests, banks
and mounds, below 90 in ditches and pits. With `negative = true`, negative openness: the same seen from below the
surface, high in ditches and pits.
"""
function openness(z::AbstractMatrix{<:Real}, cellsize; radius::Real = 10, directions::Integer = 16, negative::Bool = false)
	a = horizon_angles((negative ? -1.0 : 1.0) .* Float64.(z), cells(radius, cellsize), directions, cellwidth(cellsize))
	return 90 .- rad2deg.(dropdims(mean(a; dims = 3); dims = 3))
end

# The gradient of each cell from the four neighbours that share a side (Zevenbergen and Thorne 1987), along x and
# along y; NaN on the edge
function gradient_zt(z::AbstractMatrix, cellsize)
	dx, dy = cellsteps(cellsize)
	gx, gy = fill(NaN, size(z)), fill(NaN, size(z))
	for j in 2:size(z, 2) - 1, i in 2:size(z, 1) - 1
		gx[i, j] = (z[i + 1, j] - z[i - 1, j]) / (2dx)
		gy[i, j] = (z[i, j + 1] - z[i, j - 1]) / (2dy)
	end
	return gx, gy
end

"""
    terrain_slope(z, cellsize)

The slope of each cell of the terrain model `z`, in degrees, from the four neighbours that share a side (Zevenbergen
and Thorne 1987), as RVT's `slope_aspect` computes it.
"""
function terrain_slope(z::AbstractMatrix{<:Real}, cellsize)
	gx, gy = gradient_zt(Float64.(z), cellsize)
	return atand.(hypot.(gx, gy))
end

"""
    shaded_relief(z, cellsize; azimuth = 315, elevation = 35)

The hillshade of the terrain model `z` lit from `azimuth` (degrees clockwise from north) at `elevation` (degrees
above the horizon): the cosine of the angle between the light and the perpendicular to the ground (Horn 1981), from 0
in shadow to 1, with the slope and aspect of Zevenbergen and Thorne (1987), as RVT's `hillshade` computes it. With a
vector of azimuths, the multidirectional hillshade of Mark (1992): each light weighted by how much the ground faces
it, from Horn's gradient, as Geomorphometry.jl's `multihillshade` computes it (without rounding to whole numbers).
"""
function shaded_relief(z::AbstractMatrix{<:Real}, cellsize; azimuth = 315, elevation::Real = 35)
	v = Float64.(z)
	zen = 90 - elevation
	if azimuth isa Real
		gx, gy = gradient_zt(v, cellsize)
		s = atand.(hypot.(gx, gy))
		a = ifelse.((gx .== 0) .& (gy .== 0), 0.0, mod.(atand.(-gx, -gy), 360))  # the way the ground faces; flat ground faces no way
		return max.(cosd(zen) .* cosd.(s) .+ sind(zen) .* sind.(s) .* cosd.(azimuth .- a), 0)
	end
	dx, dy = cellsteps(cellsize)
	out = fill(NaN, size(v))
	for j in 2:size(v, 2) - 1, i in 2:size(v, 1) - 1
		w(di, dj) = v[i + di, j + dj]
		gx = (w(1, -1) + 2w(1, 0) + w(1, 1) - w(-1, -1) - 2w(-1, 0) - w(-1, 1)) / (8dx)  # Horn's gradient
		gy = (w(-1, 1) + 2w(0, 1) + w(1, 1) - w(-1, -1) - 2w(0, -1) - w(1, -1)) / (8dy)
		a = gx != 0 ? mod(atan(gx, gy), 2pi) : (gy < 0 ? pi / 2 + 2pi : pi / 2)
		s = atan(hypot(gx, gy))
		total, weights = 0.0, 0.0
		for az in azimuth
			weight = sin(a - deg2rad(az - 90))^2
			weights += weight
			total += weight * (cosd(zen) * cos(s) + sind(zen) * sin(s) * cos(deg2rad(az) - a))
		end
		out[i, j] = max(total / weights, 0)
	end
	return out
end

"""
    layered_image(z, cellsize; radius = 10, directions = 16, overlay_opacity = 0.5)

The Visualization for Archaeological Topography (VAT) of Kokalj and Somrak (2019), from 0 dark to 1 light, built from
the bottom up as RVT's VAT - Archaeological combination: hillshade from 315 degrees at 35 (normal, 100%); slope from 0
to 50 degrees, reversed (luminosity, 50%); positive openness from 68 to 93 degrees (overlay, `overlay_opacity`); the
sky-view factor from 0.7 to 1 (multiply, 25%). RVT 2.2.3 applies the overlay at full strength whatever its opacity:
`overlay_opacity = 1` reproduces its image.
"""
function layered_image(z::AbstractMatrix{<:Real}, cellsize; radius::Real = 10, directions::Integer = 16, overlay_opacity::Real = 0.5)
	stretch(x, lo, hi) = clamp.((x .- lo) ./ (hi - lo), 0, 1)
	overlay(top, base) = ifelse.(base .> 0.5, 1 .- 2 .* (1 .- base) .* (1 .- top), 2 .* base .* top)
	a = horizon_angles(Float64.(z), cells(radius, cellsize), directions, cellwidth(cellsize))
	svf = dropdims(mean(1 .- sin.(max.(a, 0)); dims = 3); dims = 3)
	positive = 90 .- rad2deg.(dropdims(mean(a; dims = 3); dims = 3))
	image = shaded_relief(z, cellsize)
	image = 0.5 .* (1 .- stretch(terrain_slope(z, cellsize), 0, 50)) .+ 0.5 .* image
	image = overlay_opacity .* overlay(stretch(positive, 68, 93), image) .+ (1 - overlay_opacity) .* image
	image = 0.25 .* stretch(svf, 0.7, 1) .* image .+ 0.75 .* image
	return ifelse.(isfinite.(svf), image, NaN)
end
