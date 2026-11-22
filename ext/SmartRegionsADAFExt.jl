# ADAF's HRNet segmentation models in Julia: the backbone of timm's hrnet_w48 and the head of AiTLAS, with each batch
# normalisation folded into the convolution before it, the weights read from ADAF's PyTorch checkpoints with
# Pickle.jl (which reads the tensors without running Python code), the layers computed with NNlib.jl

module SmartRegionsADAFExt

using SmartRegions, NNlib, Pickle
import SmartRegions: adaf_model, adaf_probability

# A convolution with the batch normalisation after it folded in: weights (kw, kh, in, out) as NNlib takes them
struct Folded
	weight::Array{Float32, 4}
	bias::Vector{Float32}
	stride::Int
	pad::Int
end

has(sd, key) = haskey(sd, key * ".weight")

# 0, 1, 2... for as long as f holds
function upto(f)
	k = 0
	while f(k)
		k += 1
	end
	return 0:k - 1
end

function folded(sd, conv, bn; stride::Integer = 1)
	W = Array{Float32}(sd[conv * ".weight"])  # PyTorch's (out, in, kh, kw)
	K = permutedims(W, (4, 3, 2, 1))
	b = haskey(sd, conv * ".bias") ? Vector{Float32}(sd[conv * ".bias"]) : zeros(Float32, size(W, 1))
	if bn !== nothing
		s = Vector{Float32}(sd[bn * ".weight"]) ./ sqrt.(Vector{Float32}(sd[bn * ".running_var"]) .+ 1.0f-5)
		K = K .* reshape(s, 1, 1, 1, :)
		b = (b .- Vector{Float32}(sd[bn * ".running_mean"])) .* s .+ Vector{Float32}(sd[bn * ".bias"])
	end
	return Folded(K, b, stride, size(W, 3) ÷ 2)
end
(f::Folded)(x) = NNlib.conv(x, f.weight; stride = f.stride, pad = f.pad, flipped = true) .+ reshape(f.bias, 1, 1, :, 1)

# A residual block: the basic block of two 3 x 3 convolutions, or the bottleneck of 1 x 1, 3 x 3 and 1 x 1
struct Block
	convs::Vector{Folded}
	down::Union{Folded, Nothing}
end
function block(sd, p)
	convs = [folded(sd, "$(p).conv$(k)", "$(p).bn$(k)") for k in 1:3 if has(sd, "$(p).conv$(k)")]
	return Block(convs, has(sd, "$(p).downsample.0") ? folded(sd, "$(p).downsample.0", "$(p).downsample.1") : nothing)
end
function (b::Block)(x)
	y = x
	for (k, c) in enumerate(b.convs)
		y = c(y)
		k < length(b.convs) && (y = relu.(y))
	end
	return relu.(y .+ (b.down === nothing ? x : b.down(x)))
end
blocks(sd, p) = [block(sd, "$(p).$(k)") for k in upto(k -> has(sd, "$(p).$(k).conv1"))]

# The convolutions of stride 2 from a finer branch to a coarser one, with a ReLU after each but the last
struct Down
	convs::Vector{Folded}
end
function (d::Down)(x)
	for (k, c) in enumerate(d.convs)
		x = c(x)
		k < length(d.convs) && (x = relu.(x))
	end
	return x
end

# One module of a stage: its branches, and the fusion of every branch into every other
struct HRModule
	branches::Vector{Vector{Block}}
	fuse::Matrix{Any}  # fuse[i, j]: branch j onto branch i; nothing on the diagonal
end
function hrmodule(sd, p)
	n = count(b -> has(sd, "$(p).branches.$(b).0.conv1"), 0:7)
	branches = [blocks(sd, "$(p).branches.$(b)") for b in 0:n - 1]
	fuse = Matrix{Any}(nothing, n, n)
	for i in 0:n - 1, j in 0:n - 1
		q = "$(p).fuse_layers.$(i).$(j)"
		if j > i
			fuse[i + 1, j + 1] = (folded(sd, "$(q).0", "$(q).1"), 2^(j - i))
		elseif j < i
			fuse[i + 1, j + 1] = Down([folded(sd, "$(q).$(k).0", "$(q).$(k).1"; stride = 2) for k in 0:i - j - 1])
		end
	end
	return HRModule(branches, fuse)
end
function (m::HRModule)(xs)
	xs = [foldl((y, b) -> b(y), m.branches[k]; init = xs[k]) for k in eachindex(xs)]
	return map(axes(m.fuse, 1)) do i
		y = nothing
		for j in axes(m.fuse, 2)
			f = m.fuse[i, j]
			t = f === nothing ? xs[j] : f isa Down ? f(xs[j]) : NNlib.upsample_nearest(f[1](xs[j]), (f[2], f[2]))
			y = y === nothing ? t : y .+ t
		end
		relu.(y)
	end
end

# The step from one stage to the next: each branch kept, changed by a 3 x 3 convolution, or made from the coarsest
struct Transition
	steps::Vector{Any}  # per branch: nothing (kept), a Folded of stride 1, or a Down from the coarsest branch
end
function transition(sd, p, n)
	steps = map(0:n - 1) do i
		has(sd, "$(p).$(i).0.0") ? Down([folded(sd, "$(p).$(i).$(k).0", "$(p).$(i).$(k).1"; stride = 2) for k in upto(k -> has(sd, "$(p).$(i).$(k).0"))]) :
		has(sd, "$(p).$(i).0") ? folded(sd, "$(p).$(i).0", "$(p).$(i).1") : nothing
	end
	return Transition(steps)
end
(t::Transition)(ys) = [s === nothing ? ys[i] : s isa Down ? relu.(s(ys[end])) : relu.(s(ys[i])) for (i, s) in enumerate(t.steps)]  # a ReLU after every convolution of a transition

struct ADAFModel
	stem::Vector{Folded}
	layer1::Vector{Block}
	transitions::Vector{Transition}
	stages::Vector{Vector{HRModule}}
	head::Vector{Folded}
end

function adaf_model(path::AbstractString)
	sd = Pickle.Torch.THload(path)["state_dict"]
	stem = [folded(sd, "backbone.conv1", "backbone.bn1"; stride = 2), folded(sd, "backbone.conv2", "backbone.bn2"; stride = 2)]
	modules(s) = [hrmodule(sd, "backbone.stage$(s).$(m)") for m in upto(m -> has(sd, "backbone.stage$(s).$(m).branches.0.0.conv1"))]
	return ADAFModel(stem, blocks(sd, "backbone.layer1"), [transition(sd, "backbone.transition$(s)", s + 1) for s in 1:3], [modules(s) for s in 2:4],
		[folded(sd, "head.projection.0", "head.projection.1"), folded(sd, "head.projection.3", nothing)])
end

# PyTorch's nearest interpolation from n to m cells along one axis: cell k takes cell floor(k * n / m), in single precision
nearest(n, m) = m == n ? (1:n) : [min(floor(Int, Float32(k) * (Float32(n) / Float32(m))), n - 1) + 1 for k in 0:m - 1]

# PyTorch's bilinear interpolation of a matrix to m x m cells, without aligning the corners
function bilinear(v::AbstractMatrix{Float32}, m::Integer)
	weights(n) = map(0:m - 1) do k
		s = max((Float32(k) + 0.5f0) * (Float32(n) / Float32(m)) - 0.5f0, 0.0f0)
		a = floor(Int, s)
		(a + 1, min(a + 1, n - 1) + 1, s - a)
	end
	wi, wj = weights(size(v, 1)), weights(size(v, 2))
	return [begin
		(i0, i1, li), (j0, j1, lj) = wi[i], wj[j]
		(1 - lj) * ((1 - li) * v[i0, j0] + li * v[i1, j0]) + lj * ((1 - li) * v[i0, j1] + li * v[i1, j1])
	end for i in 1:m, j in 1:m]
end

# The probability of the feature at each cell of one tile, as AiTLAS's HRNet computes it: the relief image repeated
# into three bands, the backbone, the head on all branches brought to 120 x 120 cells, and the sigmoid of its second
# output brought back to the size of the tile
function forward(model::ADAFModel, image::AbstractMatrix{Float32})
	n = size(image, 1)
	x = repeat(reshape(image, n, n, 1, 1), 1, 1, 3, 1)
	for c in model.stem
		x = relu.(c(x))
	end
	x = foldl((y, b) -> b(y), model.layer1; init = x)
	ys = [x]
	for (t, stage) in zip(model.transitions, model.stages)
		ys = foldl((y, m) -> m(y), stage; init = t(ys))
	end
	low = cat([f[nearest(size(f, 1), 120), nearest(size(f, 2), 120), :, :] for f in [[x]; ys]]...; dims = 3)
	out = model.head[2](relu.(model.head[1](low)))
	p = bilinear(out[:, :, 2, 1], n)
	return 1 ./ (1 .+ exp.(-p))
end

function adaf_probability(model::ADAFModel, image::StridedMatrix{<:Real}; tile::Integer = 1024)
	nx, ny = size(image)
	out = zeros(Float32, nx, ny)
	for j in 1:tile:ny, i in 1:tile:nx
		piece = zeros(Float32, tile, tile)
		ri, rj = i:min(i + tile - 1, nx), j:min(j + tile - 1, ny)
		piece[1:length(ri), 1:length(rj)] .= image[ri, rj]
		out[ri, rj] .= forward(model, piece)[1:length(ri), 1:length(rj)]
	end
	return out
end

end
