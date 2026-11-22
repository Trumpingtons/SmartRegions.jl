# Candidate features of a terrain model, for archaeological prospection: mounds and pits by depression filling,
# places that match a template, and regions above or below a threshold, each with its size and shape; the scheduled
# monuments of England to set them beside; and the candidates written to a GeoPackage. Positions are i and j, the
# indices of the matrix, fractional at the centre of a region; the Rasters.jl extension turns them into x and y.

"""
    fill_depressions(v)

The surface `v` with each depression filled to the height at which it would spill, by Priority-Flood (Barnes,
Lehman and Mulla 2014), from the edge of the grid and from the cells that are not finite, which drain the cells
around them.
"""
function fill_depressions(v::AbstractMatrix{<:Real})
	f = Float64.(v)
	nx, ny = size(f)
	done = falses(nx, ny)
	heap = BinaryMinHeap{Tuple{Float64, Int, Int}}()
	for j in 1:ny, i in 1:nx
		if i in (1, nx) || j in (1, ny) || !isfinite(f[i, j])
			push!(heap, (isfinite(f[i, j]) ? f[i, j] : -Inf, i, j))
			done[i, j] = true
		end
	end
	while !isempty(heap)
		w, i, j = pop!(heap)
		for b in max(1, j - 1):min(ny, j + 1), a in max(1, i - 1):min(nx, i + 1)
			done[a, b] && continue
			done[a, b] = true
			f[a, b] = max(f[a, b], w)
			push!(heap, (f[a, b], a, b))
		end
	end
	return f
end

# The regions of the mask joined through the eight neighbours (through the four that share a side, with `diagonal =
# false`), numbered from 1 in the order they are met, 0 outside
function label_regions(mask::AbstractMatrix{Bool}; diagonal::Bool = true)
	labels = zeros(Int, size(mask))
	n = 0
	stack = CartesianIndex{2}[]
	for c in CartesianIndices(mask)
		(mask[c] && labels[c] == 0) || continue
		n += 1
		labels[c] = n
		push!(stack, c)
		while !isempty(stack)
			d = pop!(stack)
			for b in max(1, d[2] - 1):min(size(mask, 2), d[2] + 1), a in max(1, d[1] - 1):min(size(mask, 1), d[1] + 1)
				(diagonal || a == d[1] || b == d[2]) || continue
				if mask[a, b] && labels[a, b] == 0
					labels[a, b] = n
					push!(stack, CartesianIndex(a, b))
				end
			end
		end
	end
	return labels
end

"""
    regions(mask, value, cellsize)

The regions of the cells where `mask` is true, joined through the eight neighbours: a matrix of labels (0 outside
every region) and a table with, for each region, its `id`, the position `i`, `j` of its centre, its `area`, the
`height` of its cell farthest from zero in `value`, its `length` (the long axis of the ellipse with the same second
moments, each cell a square) and `roundness` (the short axis over the long, 1 for a circle).
"""
function regions(mask::AbstractMatrix{Bool}, value::AbstractMatrix{<:Real}, cellsize)
	h = cellwidth(cellsize)
	labels = label_regions(mask)
	members = [CartesianIndex{2}[] for _ in 1:maximum(labels; init = 0)]
	for c in CartesianIndices(labels)
		labels[c] > 0 && push!(members[labels[c]], c)
	end
	table = map(enumerate(members)) do (k, cs)
		I, J = [c[1] for c in cs], [c[2] for c in cs]
		dI, dJ = I .- mean(I), J .- mean(J)
		M = [mean(dI .^ 2) mean(dI .* dJ); mean(dI .* dJ) mean(dJ .^ 2)] .+ 1 / 12  # each cell a unit square
		short, long = eigvals(Symmetric(M))
		top = cs[argmax(abs.(value[cs]))]
		(id = k, i = mean(I), j = mean(J), area = length(cs) * h^2, height = Float64(value[top]), length = 4 * sqrt(long) * h, roundness = sqrt(short / long))
	end
	return labels, table
end

# The regions of the depressions of v deeper than min_height, kept by area and roundness, with the depth of each cell
function depression_candidates(v, cellsize, min_height, area, min_roundness)
	w = ifelse.(isfinite.(v), Float64.(v), -Inf)
	depth = fill_depressions(w) .- w
	depth[.!isfinite.(depth)] .= 0
	labels, table = regions(depth .> min_height, depth, cellsize)
	kept = filter(c -> area[1] <= c.area <= area[2] && c.roundness >= min_roundness, table)
	keep = Set(c.id for c in kept)
	return (candidates = kept, labels = ifelse.(in.(labels, Ref(keep)), labels, 0), depth = depth)
end

"""
    find_mounds(surface, cellsize; min_height = 0.2, area = (20, 5000), min_roundness = 0.5)

Mounds by inverse depression analysis (Freeland, Heung, Burley, Clark and Knudby 2016): the surface, a terrain model
or better its local relief model, turned upside down and its depressions filled; the fill is the height of each
mound above the level at which it would spill. Returns `candidates`, the regions higher than `min_height`, of an area
within `area` and of roundness at least `min_roundness` (see [`regions`](@ref)); `labels`, their cells; and `depth`,
the fill of every cell.
"""
find_mounds(surface::AbstractMatrix{<:Real}, cellsize; min_height::Real = 0.2, area = (20, 5000), min_roundness::Real = 0.5) =
	depression_candidates(-Float64.(surface), cellsize, min_height, area, min_roundness)

"""
    find_pits(surface, cellsize; min_depth = 0.2, area = (20, 5000), min_roundness = 0.5)

Pits and hollows by depression filling: each depression of the surface filled to the level at which it would spill;
the fill is the depth of each pit. Returns `candidates`, `labels` and `depth` as [`find_mounds`](@ref), the `height`
of each candidate negative, its depth below the rim.
"""
function find_pits(surface::AbstractMatrix{<:Real}, cellsize; min_depth::Real = 0.2, area = (20, 5000), min_roundness::Real = 0.5)
	found = depression_candidates(Float64.(surface), cellsize, min_depth, area, min_roundness)
	return merge(found, (candidates = [merge(c, (height = -c.height,)) for c in found.candidates],))
end

"""
    find_regions(lrm, cellsize; threshold = 0.25, side = :raised, shape = :round, area = (20, 5000))

The regions of the local relief model `lrm` more than `threshold` above the trend (`side = :raised`) or below it
(`:sunken`), kept by area and by shape: `:round`, roundness at least 0.5 (mounds, pits, enclosures); `:long`,
roundness at most 0.25 (banks, ditches, hollow ways); `:any`. Returns `candidates` (see [`regions`](@ref)) and
`labels`, their cells.
"""
function find_regions(lrm::AbstractMatrix{<:Real}, cellsize; threshold::Real = 0.25, side::Symbol = :raised, shape::Symbol = :round, area = (20, 5000))
	side in (:raised, :sunken) || throw(ArgumentError("side is :raised or :sunken"))
	shape in (:round, :long, :any) || throw(ArgumentError("shape is :round, :long or :any"))
	mask = side == :raised ? lrm .> threshold : lrm .< -threshold
	labels, table = regions(mask, lrm, cellsize)
	fits(c) = shape == :any || (shape == :round ? c.roundness >= 0.5 : c.roundness <= 0.25)
	kept = filter(c -> area[1] <= c.area <= area[2] && fits(c), table)
	keep = Set(c.id for c in kept)
	return (candidates = kept, labels = ifelse.(in.(labels, Ref(keep)), labels, 0))
end

"""
    feature_template(shape, radius)

A template of `radius` cells: for `:mound`, a half-dome within a flat ring out to 1.5 times the radius (Trier and
Pilø 2012); for `:pit`, its negative; for `:ring`, a ditch around a ring, a quarter of the radius wide and at least
one cell, with level ground inside and out.
"""
function feature_template(shape::Symbol, R::Real)
	shape in (:mound, :pit, :ring) || throw(ArgumentError("shape is :mound, :pit or :ring"))
	k = ceil(Int, 1.5R)
	return [begin
		d = hypot(p, q)
		shape == :mound ? (d <= R ? sqrt(R^2 - d^2) : 0.0) :
		shape == :pit ? (d <= R ? -sqrt(R^2 - d^2) : 0.0) :
		(w = max(1.0, R / 4); abs(d - R) <= w ? -(1 - ((d - R) / w)^2) : 0.0)
	end for p in -k:k, q in -k:k]
end

"""
    template_scores(v, T)

The normalised cross-correlation of the surface `v` with the template `T` (odd size, centred on each cell), from -1
to 1, as scikit-image's `match_template` computes it with `pad_input = True`: cells that are not finite, and cells
beyond the edge, count as 0. Only the cells where `T` differs from its most common value are multiplied, so templates
with a flat ring cost little.
"""
function template_scores(v::AbstractMatrix{<:Real}, T::AbstractMatrix{<:Real})
	k, n = size(T, 1) ÷ 2, length(T)
	a = ifelse.(isfinite.(v), Float64.(v), 0.0)
	T0 = T .- mean(T)
	base = T0[1, 1]  # the value of the flat ring, which the window sum carries
	active = [(p - k - 1, q - k - 1, T0[p, q] - base) for p in axes(T, 1), q in axes(T, 2) if T0[p, q] != base]
	nx, ny = size(a)
	padded = zeros(nx + 2k, ny + 2k)
	padded[k + 1:k + nx, k + 1:k + ny] .= a
	S1, S2 = zeros(nx + 2k + 1, ny + 2k + 1), zeros(nx + 2k + 1, ny + 2k + 1)
	S1[2:end, 2:end] = cumsum(cumsum(padded; dims = 1); dims = 2)
	S2[2:end, 2:end] = cumsum(cumsum(padded .^ 2; dims = 1); dims = 2)
	box(S, i, j) = S[i + 2k + 1, j + 2k + 1] - S[i, j + 2k + 1] - S[i + 2k + 1, j] + S[i, j]
	ssd = sum(T0 .^ 2)
	scores = zeros(nx, ny)
	Threads.@threads for j in 1:ny
		for i in 1:nx
			num = base * box(S1, i, j)
			for (p, q, t) in active
				num += t * padded[i + k + p, j + k + q]
			end
			s1, s2 = box(S1, i, j), box(S2, i, j)
			den = sqrt(max((s2 - s1^2 / n) * ssd, 0.0))
			scores[i, j] = den > 1e-9 ? num / den : 0.0
		end
	end
	return scores
end

"""
    find_templates(lrm, cellsize; shape = :mound, radii = [3, 5, 8, 12], min_score = 0.7)

Template matching (Trier and Pilø 2012): the local relief model `lrm` correlated with templates of `shape` (see
[`feature_template`](@ref)) of each of `radii`; each cell keeps its best score and radius. Candidates are the places
scoring at least `min_score`, best first, none within the radius of a better one, and farther from the edge than the
largest template reaches. Returns `candidates` (`id`, `i`, `j`, `radius`, `score`, `height`, the local relief at the
centre), `labels` (a disc of the radius around each) and `score`, the best score of every cell.
"""
function find_templates(lrm::AbstractMatrix{<:Real}, cellsize; shape::Symbol = :mound, radii = [3, 5, 8, 12], min_score::Real = 0.7)
	h = cellwidth(cellsize)
	best, radius = fill(-1.0, size(lrm)), zeros(size(lrm))
	for R in radii
		s = template_scores(lrm, feature_template(shape, R / h))
		better = s .> best
		best[better] .= s[better]
		radius[better] .= R
	end
	margin = ceil(Int, 1.5 * maximum(radii) / h)
	edge = .!isfinite.(lrm)
	near_edge = falses(size(lrm))
	for c in findall(edge)
		near_edge[max(1, c[1] - margin):min(end, c[1] + margin), max(1, c[2] - margin):min(end, c[2] + margin)] .= true
	end
	near_edge[[1:margin; end - margin + 1:end], :] .= true
	near_edge[:, [1:margin; end - margin + 1:end]] .= true
	best[near_edge] .= -1
	taken = falses(size(lrm))
	labels = zeros(Int, size(lrm))
	candidates = NamedTuple{(:id, :i, :j, :radius, :score, :height), Tuple{Int, Float64, Float64, Float64, Float64, Float64}}[]
	for c in sort(findall(>=(min_score), best); by = c -> -best[c])
		taken[c] && continue
		R = radius[c] / h
		push!(candidates, (id = length(candidates) + 1, i = Float64(c[1]), j = Float64(c[2]), radius = radius[c], score = best[c], height = Float64(lrm[c])))
		for q in -ceil(Int, R):ceil(Int, R), p in -ceil(Int, R):ceil(Int, R)
			(hypot(p, q) <= R && checkbounds(Bool, taken, c[1] + p, c[2] + q)) || continue
			taken[c[1] + p, c[2] + q] = true
			labels[c[1] + p, c[2] + q] = length(candidates)
		end
	end
	return (candidates = candidates, labels = labels, score = best)
end

# A coordinate system as a string GDAL reads: "EPSG:27700", a WKT string, or (with Rasters.jl) a terrain model
crs_string(crs::AbstractString) = String(crs)

const NHLE = "https://services-eu1.arcgis.com/ZOdPfBS3aqqDYPUQ/arcgis/rest/services/National_Heritage_List_for_England_NHLE_v02_VIEW/FeatureServer/6/query"

"""
    scheduled_monuments(con, box; crs, table = "monuments")

The scheduled monuments of Historic England's National Heritage List for England that meet `box = (xmin, ymin, xmax,
ymax)` in the coordinate system `crs` (as `"EPSG:27700"`, a WKT string, or a terrain model read with Rasters.jl), read from its open web service. Writes them
to the table `table` on the DuckDB connection `con`, which has `spatial` loaded: `list_entry`, `name` and `geom`, the
boundary in `crs`. Returns the number of monuments. England only.
"""
function scheduled_monuments(con, box; crs, table::AbstractString = "monuments")
	crs = crs_string(crs)
	DBInterface.execute(con, "SET geometry_always_xy = true")
	b = only(Tables.rowtable(DBInterface.execute(con, "SELECT ST_XMin(b) AS w, ST_YMin(b) AS s, ST_XMax(b) AS e, ST_YMax(b) AS n FROM (SELECT ST_Extent(ST_Transform(ST_MakeEnvelope($(box[1]), $(box[2]), $(box[3]), $(box[4])), '$(crs)', 'EPSG:4326')) AS b)")))
	query = "$(NHLE)?where=1%3D1&geometry=$(b.w),$(b.s),$(b.e),$(b.n)&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=ListEntry,Name&outSR=4326&f=geojson"
	file = fetched(query, tempname() * ".geojson"; source = "Historic England")
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT ListEntry AS list_entry, Name AS name, ST_Transform(geom, 'EPSG:4326', '$(crs)') AS geom FROM ST_Read('$(file)')")
	rm(file)
	return scalar(con, "SELECT count(*) FROM $(table)")
end

"""
    candidates_table(con, candidates; crs, table = "candidates")

Writes `candidates`, with positions `x` and `y` in the coordinate system `crs`, to the table `table` on the DuckDB
connection `con`, which has `spatial` loaded (`crs` as in [`scheduled_monuments`](@ref)): their fields and `geom`, a point at each. Returns the number of rows.
"""
function candidates_table(con, candidates; crs, table::AbstractString = "candidates")
	crs = crs_string(crs)
	isempty(candidates) && throw(ArgumentError("No candidates to write"))
	fields = collect(keys(first(candidates)))
	csv = tempname() * ".csv"
	write(csv, join(fields, ",") * "\n" * join([join([getfield(c, f) for f in fields], ",") for c in candidates], "\n"))
	DBInterface.execute(con, "CREATE OR REPLACE TABLE $(table) AS SELECT *, ST_Point(x, y) AS geom FROM read_csv('$(csv)')")
	rm(csv)
	return scalar(con, "SELECT count(*) FROM $(table)")
end

"""
    save_candidates(con, candidates, path; crs)

Writes `candidates`, with positions `x` and `y` in the coordinate system `crs`, as points with their fields to the
GeoPackage `path`, through the DuckDB connection `con`, which has `spatial` loaded (`crs` as in
[`scheduled_monuments`](@ref)). Returns `path`.
"""
function save_candidates(con, candidates, path::AbstractString; crs)
	crs = crs_string(crs)
	isfile(path) && throw(ArgumentError("$(path) is there already: rename or move it first"))
	DBInterface.execute(con, "SET geometry_always_xy = true")
	candidates_table(con, candidates; crs, table = "candidates_to_save")
	DBInterface.execute(con, "COPY candidates_to_save TO '$(path)' WITH (FORMAT GDAL, DRIVER 'GPKG', SRS '$(crs)')")
	DBInterface.execute(con, "DROP TABLE candidates_to_save")
	return path
end
