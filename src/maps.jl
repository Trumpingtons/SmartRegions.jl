# Pages of maps side by side that move together: rasters of a terrain model in grey, the outlines of features on them,
# and aerial and satellite imagery of the same ground, on the grid of the rasters. The rasters become such pages in
# the extension SmartRegionsMapsExt, with Rasters.jl and ArchGDAL.jl.

const IMAGERY = "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile"
const IMAGERY_CREDIT = "Esri, Maxar, Earthstar Geographics, and the GIS User Community"

"""
    terrain_maps(title, layers...; labels = nothing, centre = nothing, width = nothing, imagery = true)

Writes a page with maps side by side of the same ground at the same scale, which drag and zoom together, and returns
its path. Each of `layers` is `name => raster`, drawn in grey from 0 to 1, or `name => (raster, low, high)`, drawn in
grey from `low` to `high`; the rasters are `Raster`s of Rasters.jl on one grid. With `imagery`, a last map shows
Esri's World Imagery of that ground, put on the grid of the rasters, when they have a coordinate system: the page
then asks Esri's server for the tiles of that area, which tells it where the area is. `labels`, the cells of features
as the functions that find them return, are outlined on every map. The maps open on the whole raster, or on the
square `width` across around `centre`, as `(x, y)` in the coordinates of the rasters. Each has a scale bar, in metres
when the coordinate system is projected, and N, E, S and W, which follow the grid. Needs Rasters.jl and ArchGDAL.jl
loaded.

```julia
using SmartRegions, Rasters, ArchGDAL
lrm = local_relief(dem)
page = terrain_maps("Local Relief", "Local Relief" => (lrm, -0.5, 0.5); centre = (549716, 252899), width = 300)
Pollis.browse(page)  # in Pollis; elsewhere, open the file in a web browser
```
"""
function terrain_maps end

const MAPS_CSS = raw"""
html, body { height: 100%; margin: 0; background: #1e1e1e; color: #ddd; font: 13px sans-serif; }
body { display: flex; flex-direction: column; }
header { display: flex; align-items: center; gap: 8px; padding: 6px 10px; }
header h1 { margin: 0 auto 0 0; font-size: 14px; }
header button { min-width: 30px; padding: 3px 8px; font: inherit; color: inherit; background: #333; border: 1px solid #555; border-radius: 3px; cursor: pointer; }
main { flex: 1; min-height: 0; display: flex; gap: 4px; }
figure { position: relative; flex: 1; min-width: 0; min-height: 0; margin: 0; overflow: hidden; background: #000; }
figure svg { position: absolute; inset: 0; width: 100%; height: 100%; touch-action: none; user-select: none; cursor: grab; }
figure image { pointer-events: none; }
.over { position: absolute; padding: 2px 6px; background: rgba(0, 0, 0, 0.65); color: #fff; border-radius: 3px; pointer-events: none; }
.name { top: 6px; left: 6px; max-width: 40%; }
.n, .e, .s, .w { font-weight: 700; }
.n { top: 6px; left: 50%; transform: translateX(-50%); }
.s { bottom: 6px; left: 50%; transform: translateX(-50%); }
.e { right: 6px; top: 50%; transform: translateY(-50%); }
.w { left: 6px; top: 50%; transform: translateY(-50%); }
.scale { left: 6px; bottom: 26px; padding: 3px 6px; }
.bar { height: 5px; margin-top: 2px; border: 2px solid #fff; border-top: 0; box-sizing: border-box; }
.credit { right: 6px; bottom: 6px; max-width: 42%; font-size: 10px; }
@media (max-width: 700px) { main { flex-direction: column; } }
"""

# SITE is the size of the rasters, the side of a cell, the metres in a unit and what the maps open on, in units of
# the coordinate system from the north-west corner, y to the south
const MAPS_JS = raw"""
const maps = [...document.querySelectorAll("figure svg")];
const tiles = [...document.querySelectorAll("image.tile")].map(i => [i, Math.hypot(...i.getAttribute("transform").slice(7, -1).split(" ").slice(0, 2))]);
let x, y, unit, moved = false;
const limit = v => Math.min(SITE.span[0] * 10, Math.max(SITE.cell / 64, v));
function fit() {
	const w = maps[0].clientWidth || 1, h = maps[0].clientHeight || 1;
	[x, y] = SITE.centre;
	unit = Math.max(SITE.span[0] / w, SITE.span[1] / h);
}
function draw() {
	// each tile reaches a pixel of the screen into the next, so that no line shows where they meet
	for (const [tile, scale] of tiles) {
		tile.setAttribute("width", 256 + unit / scale);
		tile.setAttribute("height", 256 + unit / scale);
	}
	for (const svg of maps) {
		const w = svg.clientWidth || 1, h = svg.clientHeight || 1;
		svg.setAttribute("viewBox", [x - w * unit / 2, y - h * unit / 2, w * unit, h * unit].join(" "));
		svg.querySelectorAll("image.cells").forEach(i => i.style.imageRendering = unit < SITE.cell / 2 ? "pixelated" : "auto");
		const most = w * unit * (SITE.metres || 1) / 4, power = 10 ** Math.floor(Math.log10(most));
		const round = [5, 2, 1].find(k => k * power <= most) * power, box = svg.parentNode;
		box.querySelector(".length").textContent = !SITE.metres ? Number(round.toPrecision(2)) + " units" : round >= 1000 ? round / 1000 + " km" : Number(round.toPrecision(2)) + " m";
		box.querySelector(".bar").style.width = round / (SITE.metres || 1) / unit + "px";
	}
}
function zoom(by, dx = 0, dy = 0) {
	const next = limit(unit * by);
	x += dx * (unit - next);
	y += dy * (unit - next);
	unit = next;
	moved = true;
	draw();
}
for (const svg of maps) {
	let from = null;
	svg.addEventListener("pointerdown", e => { from = [e.clientX, e.clientY]; svg.setPointerCapture(e.pointerId); });
	svg.addEventListener("pointermove", e => {
		if (!from) { return; }
		x -= (e.clientX - from[0]) * unit;
		y -= (e.clientY - from[1]) * unit;
		from = [e.clientX, e.clientY];
		moved = true;
		draw();
	});
	for (const end of ["pointerup", "pointercancel"]) { svg.addEventListener(end, () => { from = null; }); }
	svg.addEventListener("wheel", e => {
		e.preventDefault();
		const box = svg.getBoundingClientRect();
		zoom(Math.exp(e.deltaY * (e.ctrlKey ? 0.01 : 0.0015)), e.clientX - box.left - box.width / 2, e.clientY - box.top - box.height / 2);
	}, { passive: false });
	svg.querySelectorAll("image.tile").forEach(i => i.addEventListener("error", () => {
		svg.parentNode.querySelector(".credit").textContent = "Some of the imagery could not be loaded: it needs an internet connection.";
	}));
}
document.getElementById("in").onclick = () => zoom(1 / 1.5);
document.getElementById("out").onclick = () => zoom(1.5);
document.getElementById("reset").onclick = () => { moved = false; fit(); draw(); };
new ResizeObserver(() => { if (!moved) { fit(); } draw(); }).observe(document.querySelector("main"));
fit();
draw();
"""

# The tiles of web maps: the position of a place among those of zoom z, and the longitude and latitude of a corner
tile_at(lon, lat, z) = ((lon + 180) / 360 * 2^z, (1 - asinh(tand(lat)) / pi) / 2 * 2^z)
tile_corner(i, j, z) = (i / 2^z * 360 - 180, atand(sinh(pi * (1 - 2j / 2^z))))

# The tiles that cover places given as longitude and latitude, at the closest zoom with at most `most` of them
function tiles_over(places; most::Integer = 200, closest::Integer = 17)
	for z in closest:-1:0
		at = [tile_at(lon, lat, z) for (lon, lat) in places]
		is, js = [floor(Int, extrema(first.(at))[k]) for k in 1:2], [floor(Int, extrema(last.(at))[k]) for k in 1:2]
		i1, i2 = clamp.(is, 0, 2^z - 1)
		j1, j2 = clamp.(js, 0, 2^z - 1)
		(i2 - i1 + 1) * (j2 - j1 + 1) <= most && return z, [(i, j) for i in i1:i2 for j in j1:j2]
	end
	return 0, [(0, 0)]
end

# One tile as an image of SVG: an affine map takes its north-west, north-east and south-west corners to theirs on the grid
function tile_image(z, (i, j), nw, ne, sw)
	m = ((ne .- nw) ./ 256..., (sw .- nw) ./ 256..., nw...)
	return """<image class="tile" href="$(IMAGERY)/$(z)/$(j)/$(i)" width="256.7" height="256.7" preserveAspectRatio="none" transform="matrix($(join(m, ' ')))"/>"""
end

# The page: `maps` are (name, the SVG of the map, its credit), `outline` an SVG path drawn on each
function maps_page(title, maps, outline; size, cell, metres, centre, span)
	drawn = isempty(outline) ? "" : """<path d="$(outline)" fill="none" stroke="#000" stroke-opacity="0.45" stroke-width="4" vector-effect="non-scaling-stroke"/><path d="$(outline)" fill="none" stroke="#e8a33d" stroke-width="2" vector-effect="non-scaling-stroke"/>"""
	figures = join(("""<figure><svg role="img" aria-label="$(html(name))">$(body)$(drawn)</svg>
<div class="over name">$(html(name))</div><div class="over n">N</div><div class="over e">E</div><div class="over s">S</div><div class="over w">W</div>
<div class="over scale"><span class="length"></span><div class="bar"></div></div>$(isempty(credit) ? "" : "<div class=\"over credit\">$(html(credit))</div>")</figure>""" for (name, body, credit) in maps), "\n")
	site = "{size: [$(join(size, ','))], cell: $(cell), metres: $(something(metres, "null")), centre: [$(join(centre, ','))], span: [$(join(span, ','))]}"
	file = joinpath(pages(), slug(title) * ".html")
	write(file, """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$(html(title))</title>
<style>$(MAPS_CSS)</style>
</head><body>
<header><h1>$(html(title))</h1><span>Drag to move, scroll to zoom. N, E, S and W follow the grid.</span>
<button id="in" aria-label="Zoom in">+</button><button id="out" aria-label="Zoom out">−</button><button id="reset">Reset</button></header>
<main>
$(figures)
</main>
<script>
const SITE = $(site);
$(MAPS_JS)
</script>
</body></html>""")
	return file
end
