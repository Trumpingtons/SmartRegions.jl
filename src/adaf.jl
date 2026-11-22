# The trained models of ADAF, the Automatic Detection of Archaeological Features tool (Čož, Corns, Curran, Kocev and
# Kokalj 2026), applied as ADAF applies them: HRNet segmentation models trained on lidar of Ireland, whose input is
# the simple local relief model and whose output is the probability of an archaeological feature at each cell. The
# network itself runs in the NNlib extension; here are the weights, the input and the features.

const ADAF_RECORD = "https://zenodo.org/records/15848662/files/"
const ADAF_FILES = Dict(
	:all => "AO_HRNet_SLRM_512px_pretrained_train_12_val_124_with_Transformation.tar",
	:barrow => "barrow_HRNet_SLRM_512px_pretrained_train_12_val_124_with_Transformation.tar",
	:enclosure => "enclosure_HRNet_SLRM_512px_pretrained_train_12_val_124_with_Transformation.tar",
	:ringfort => "ringfort_HRNet_SLRM_512px_pretrained_train_12_val_124_with_Transformation.tar",
)

"""
    adaf_weights(folder; feature = :all)

The file of ADAF's trained segmentation model for `feature`, downloaded once from its Zenodo record (about 860 MB) to
`folder/adaf` and returned from there later: `:all` (all archaeology), `:barrow`, `:enclosure` or `:ringfort`.
"""
function adaf_weights(folder::AbstractString; feature::Symbol = :all)
	haskey(ADAF_FILES, feature) || throw(ArgumentError("feature is one of $(join(sort(collect(keys(ADAF_FILES))), ", "))"))
	return cached(ADAF_RECORD * ADAF_FILES[feature] * "?download=1", joinpath(folder, "adaf", ADAF_FILES[feature]))
end

"""
    adaf_input(z, cellsize)

The image ADAF's models read, from the terrain model `z`: the simple local relief model with a radius of 10 cells
(10 m or more of cells finer than 1 m), stretched from -0.5 to 0.5 m onto 0 to 1, and 0 where it is undefined.
"""
function adaf_input(z::AbstractMatrix{<:Real}, cellsize)
	h = cellwidth(cellsize)
	r = h < 1 ? ceil(Int, 10 / h) : 10
	lrm = local_relief(z, cellsize; radius = r * h)
	return Float32.(ifelse.(isfinite.(lrm), clamp.(lrm .+ 0.5, 0, 1), 0))
end

"""
    adaf_model(path)

ADAF's trained segmentation model read from `path` (see [`adaf_weights`](@ref)), ready for
[`adaf_probability`](@ref). Needs NNlib.jl and Pickle.jl loaded.
"""
function adaf_model end

"""
    adaf_probability(model, image; tile = 1024)

The probability of an archaeological feature at each cell of `image` (see [`adaf_input`](@ref)), from ADAF's model
`model`, run as ADAF runs it: on tiles of `tile` cells from the first cell of the matrix, the image beyond the last
tile filled with 0. Needs NNlib.jl and Pickle.jl loaded.
"""
function adaf_probability end

# The perimeter of the convex hull of the points p (Andrew's monotone chain)
function hull_perimeter(p::Vector{Tuple{Float64, Float64}})
	p = sort(unique(p))
	length(p) < 3 && return 2 * sum(hypot((p[k + 1] .- p[k])...) for k in 1:length(p) - 1; init = 0.0)
	cross(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
	chain(q) = foldl(q; init = Tuple{Float64, Float64}[]) do h, x
		while length(h) >= 2 && cross(h[end - 1], h[end], x) <= 0
			pop!(h)
		end
		push!(h, x)
	end
	ring = [chain(p)[1:end - 1]; chain(reverse(p))[1:end - 1]]
	return sum(hypot((ring[mod1(k + 1, end)] .- ring[k])...) for k in eachindex(ring))
end

"""
    adaf_features(probability, cellsize; threshold = 0.5, min_area = 0, min_roundness = 0, tile = 1024, margin = 8)

The features ADAF draws from a probability map: the cells of probability at least `threshold`, leaving out the
`margin` cells along the edges of each tile of `tile` cells, joined into regions through the sides of the cells. Each
feature has its `id`, the position `i`, `j` of its centre, its `area`, its `roundness` as ADAF measures it (4 pi times
the area over the squared perimeter of its convex hull: 1 for a circle, 0.785 for a square) and its highest
`probability`. Features of area up to `min_area` or roundness up to `min_roundness` are left out. Returns
`candidates` and `labels`, their cells.
"""
function adaf_features(probability::AbstractMatrix{<:Real}, cellsize; threshold::Real = 0.5, min_area::Real = 0, min_roundness::Real = 0, tile::Integer = 1024, margin::Integer = 8)
	h = cellwidth(cellsize)
	inside(k) = margin <= mod(k - 1, tile) < tile - margin
	mask = [isfinite(probability[i, j]) && probability[i, j] >= threshold && inside(i) && inside(j) for i in axes(probability, 1), j in axes(probability, 2)]
	labels = label_regions(mask; diagonal = false)
	members = [CartesianIndex{2}[] for _ in 1:maximum(labels; init = 0)]
	for c in CartesianIndices(labels)
		labels[c] > 0 && push!(members[labels[c]], c)
	end
	table = map(enumerate(members)) do (k, cs)
		corners = [(Float64(c[1] + a), Float64(c[2] + b)) for c in cs for a in (-0.5, 0.5), b in (-0.5, 0.5)]
		area = length(cs) * h^2
		perimeter = hull_perimeter(corners) * h
		(id = k, i = mean(c[1] for c in cs), j = mean(c[2] for c in cs), area = area, roundness = 4pi * area / perimeter^2, probability = Float64(maximum(probability[cs])))
	end
	kept = filter(c -> c.area > min_area && c.roundness > min_roundness, table)
	keep = Set(c.id for c in kept)
	return (candidates = kept, labels = ifelse.(in.(labels, Ref(keep)), labels, 0))
end
