# Pages of maps side by side that move together: rasters of a terrain model in grey, the outlines of features on them,
# and aerial or satellite imagery of the same ground. The rasters become such pages in the extension
# SmartRegionsMapsExt, with Rasters.jl and ArchGDAL.jl.

# The sources of imagery as map tiles: the address of a tile from its zoom, column, row and key, the name of the map,
# the credit its terms ask for, the closest zoom asked and the environment variable of the key
const TILES = (
	esri = (address = (z, i, j, key) -> "https://ibasemaps-api.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/$(z)/$(j)/$(i)?token=$(key)",
		name = "Esri World Imagery", credit = "Powered by Esri. Esri, Vantor, Earthstar Geographics, and the GIS User Community",
		closest = 17, key = "ARCGIS_API_KEY"),
	sentinel = (address = (z, i, j, key) -> "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/$(z)/$(j)/$(i).jpg",
		name = "Sentinel-2 Cloudless 2016, 10 m", credit = "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017)",
		closest = 15, key = ""),
)
const GOOGLE_KEY = "GOOGLE_MAPS_API_KEY"
const GOOGLE_NAME = "Google Satellite, North Up"

"""
    terrain_maps(title, layers...; labels = nothing, centre = nothing, width = nothing, imagery = :auto)

Writes a page with maps side by side of the same ground at the same scale, which drag and zoom together, and returns
its path. Each of `layers` is `name => raster`, drawn in grey from 0 to 1, or `name => (raster, low, high)`, drawn in
grey from `low` to `high`; the rasters are `Raster`s of Rasters.jl on one grid. `labels`, the cells of features as
the functions that find them return, are outlined on every map. The maps open on the whole raster; the hand moves them
all, + and − zoom them all. With `centre`, as `(x, y)` in the coordinates of the rasters, and `width`, a button Zoom
on the Place takes them to the square `width` across around `centre`, and Reset back to the whole raster. Each map
has a scale bar, in metres when the coordinate system is projected, and N, E, S and W, which follow the grid.

When the rasters have a coordinate system, a last map shows imagery of the same ground, from the source `imagery`
names. Its server then learns where the area is, and its terms are the user's to follow:

- `:google`: Google's satellite map, drawn by the Maps JavaScript API with the key in `ENV["GOOGLE_MAPS_API_KEY"]`,
  north up, following the other maps;
- `:esri`: Esri's World Imagery, with an ArcGIS Location Platform key in `ENV["ARCGIS_API_KEY"]`, on the grid;
- `:sentinel`: EOX's Sentinel-2 cloudless of 2016, with no key, open under CC BY 4.0, in cells of 10 m, on the grid;
- `:none`: no imagery;
- `:auto`: Google when its key is set, otherwise Esri when its key is set, otherwise Sentinel-2.

Needs Rasters.jl and ArchGDAL.jl loaded.

```julia
using SmartRegions, Rasters, ArchGDAL
lrm = local_relief(dem)
page = terrain_maps("Local Relief", "Local Relief" => (lrm, -0.5, 0.5); centre = (549716, 252899), width = 300)
Pollis.browse(page)  # in Pollis; elsewhere, open the file in a web browser
```
"""
function terrain_maps end

# Whether the environment variable `name` holds a key
haskey_set(name) = !isempty(strip(get(ENV, name, "")))

# The source of the imagery map: `imagery` as given, checked, or for :auto (and true) Google when its key is set,
# otherwise Esri when its key is set, otherwise Sentinel-2; false is :none
function imagery_source(imagery)
	imagery === false && return :none
	source = imagery === true ? :auto : Symbol(imagery)
	source in (:auto, :google, :esri, :sentinel, :none) ||
		throw(ArgumentError("imagery must be :auto, :google, :esri, :sentinel or :none, not :$(source)"))
	source === :auto && return haskey_set(GOOGLE_KEY) ? :google : haskey_set(TILES.esri.key) ? :esri : :sentinel
	source === :google && !haskey_set(GOOGLE_KEY) && throw(ArgumentError(
		"Google's imagery needs a Google Maps key in ENV[\"$(GOOGLE_KEY)\"]: in Pollis, set it with the keys on the Powered by line"))
	source === :esri && !haskey_set(TILES.esri.key) && throw(ArgumentError(
		"Esri's imagery needs an ArcGIS Location Platform key in ENV[\"$(TILES.esri.key)\"]: in Pollis, set it with the keys on the Powered by line"))
	return source
end

const MAPS_CSS = raw"""
html, body { height: 100%; margin: 0; background: #1e1e1e; color: #ddd; font: 13px sans-serif; }
body { display: flex; flex-direction: column; }
header { display: flex; align-items: center; gap: 8px; padding: 6px 10px; }
header h1 { margin: 0 auto 0 0; font-size: 14px; }
header button { min-width: 30px; padding: 3px 8px; font: inherit; color: inherit; background: #333; border: 1px solid #555; border-radius: 3px; cursor: pointer; }
main { flex: 1; min-height: 0; display: flex; gap: 4px; }
figure { position: relative; flex: 1; min-width: 0; min-height: 0; margin: 0; overflow: hidden; background: #000; }
figure svg { position: absolute; inset: 0; width: 100%; height: 100%; touch-action: none; user-select: none; cursor: grab; }
figure svg.grabbing { cursor: grabbing; }
figure image { pointer-events: none; }
figure .google { position: absolute; inset: 0; }
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
figure.google-map .scale { bottom: 46px; }
figure.google-map .s { bottom: 30px; }
@media (max-width: 700px) { main { flex-direction: column; } }
"""

# SITE is the size of the rasters, the side of a cell, the metres in a unit, what the maps open on and the place of
# Zoom on the Place (or null), in units of the coordinate system from the north-west corner, y to the south; and for
# Google's map (or null) the longitude and latitude of n by n points over the rasters, the metres on the ground in a
# unit and the outlines as GeoJSON
const MAPS_JS = raw"""
const maps = [...document.querySelectorAll("figure svg")];
const tiles = [...document.querySelectorAll("image.tile")].map(i => [i, Math.hypot(...i.getAttribute("transform").slice(7, -1).split(" ").slice(0, 2))]);
let x, y, unit, moved = false, gmap = null;
const limit = v => Math.min(SITE.span[0] * 10, Math.max(SITE.cell / 64, v));
function show(centre, span) {
	const w = maps[0].clientWidth || 1, h = maps[0].clientHeight || 1;
	[x, y] = centre;
	unit = Math.max(span[0] / w, span[1] / h);
}
const fit = () => show(SITE.centre, SITE.span);
// the longitude and latitude of a point of the grid: linear between the points of SITE.google, and beyond them
function lonlat(px, py) {
	const g = SITE.google, n = g.n;
	const fx = px / (SITE.size[0] / (n - 1)), fy = py / (SITE.size[1] / (n - 1));
	const i = Math.min(n - 2, Math.max(0, Math.floor(fx))), j = Math.min(n - 2, Math.max(0, Math.floor(fy)));
	const a = fx - i, b = fy - j, p = (di, dj) => g.points[(j + dj) * n + i + di];
	return [0, 1].map(k => (1 - a) * (1 - b) * p(0, 0)[k] + a * (1 - b) * p(1, 0)[k] + (1 - a) * b * p(0, 1)[k] + a * b * p(1, 1)[k]);
}
// Google's map on the same centre and scale as the others
function follow() {
	const [lon, lat] = lonlat(x, y);
	gmap.moveCamera({ center: { lat, lng: lon }, zoom: Math.log2(156543.03392 * Math.cos(lat * Math.PI / 180) / (unit * SITE.google.metres)) });
}
async function start() {
	const { Map } = await google.maps.importLibrary("maps");
	gmap = new Map(document.getElementById("google"), { mapTypeId: "satellite", tilt: 0, disableDefaultUI: true, gestureHandling: "none", keyboardShortcuts: false, clickableIcons: false, isFractionalZoomEnabled: true });
	if (SITE.google.outlines) {
		gmap.data.addGeoJson(SITE.google.outlines);
		gmap.data.setStyle({ strokeColor: "#e8a33d", strokeWeight: 2, clickable: false });
	}
	follow();
}
function gm_authFailure() {
	document.querySelector("figure.google-map .name").textContent = "Google refused the key: check it, and that the Maps JavaScript API is enabled for it.";
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
	if (gmap) { follow(); }
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
	svg.addEventListener("pointerdown", e => { from = [e.clientX, e.clientY]; svg.setPointerCapture(e.pointerId); svg.classList.add("grabbing"); });
	svg.addEventListener("pointermove", e => {
		if (!from) { return; }
		x -= (e.clientX - from[0]) * unit;
		y -= (e.clientY - from[1]) * unit;
		from = [e.clientX, e.clientY];
		moved = true;
		draw();
	});
	for (const end of ["pointerup", "pointercancel"]) { svg.addEventListener(end, () => { from = null; svg.classList.remove("grabbing"); }); }
	svg.addEventListener("wheel", e => {
		e.preventDefault();
		const box = svg.getBoundingClientRect();
		zoom(Math.exp(e.deltaY * (e.ctrlKey ? 0.01 : 0.0015)), e.clientX - box.left - box.width / 2, e.clientY - box.top - box.height / 2);
	}, { passive: false });
	svg.querySelectorAll("image.tile").forEach(i => i.addEventListener("error", () => {
		svg.parentNode.querySelector(".credit").textContent = "Some of the imagery could not be loaded: it needs an internet connection, and a key that the source accepts.";
	}));
}
document.getElementById("in").onclick = () => zoom(1 / 1.5);
document.getElementById("out").onclick = () => zoom(1.5);
if (SITE.place) { document.getElementById("place").onclick = () => { show(SITE.place.centre, SITE.place.span); moved = true; draw(); }; }
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
function tile_image(address, nw, ne, sw)
	m = ((ne .- nw) ./ 256..., (sw .- nw) ./ 256..., nw...)
	return """<image class="tile" href="$(html(address))" width="256.7" height="256.7" preserveAspectRatio="none" transform="matrix($(join(m, ' ')))"/>"""
end

# The page: `maps` are (name, the SVG of the map, its credit, whether it is Google's), `outline` an SVG path drawn on
# each of the others, `place` the centre and span of Zoom on the Place, or nothing, and `google` the points, metres
# and outlines of Google's map, as JavaScript, and the key, or nothing
function maps_page(title, maps, outline; size, cell, metres, centre, span, place = nothing, google = nothing)
	drawn = isempty(outline) ? "" : """<path d="$(outline)" fill="none" stroke="#000" stroke-opacity="0.45" stroke-width="4" vector-effect="non-scaling-stroke"/><path d="$(outline)" fill="none" stroke="#e8a33d" stroke-width="2" vector-effect="non-scaling-stroke"/>"""
	over(m) = """<div class="over name">$(html(m.name))</div><div class="over n">N</div><div class="over e">E</div><div class="over s">S</div><div class="over w">W</div>
<div class="over scale"><span class="length"></span><div class="bar"></div></div>$(isempty(m.credit) ? "" : "<div class=\"over credit\">$(html(m.credit))</div>")"""
	figure(m) = m.google ? """<figure class="google-map"><div class="google" id="google"></div><svg role="img" aria-label="$(html(m.name))"></svg>
$(over(m))</figure>""" : """<figure><svg role="img" aria-label="$(html(m.name))">$(m.body)$(drawn)</svg>
$(over(m))</figure>"""
	there = place === nothing ? "null" : "{centre: [$(join(place[1], ','))], span: [$(join(place[2], ','))]}"
	site = "{size: [$(join(size, ','))], cell: $(cell), metres: $(something(metres, "null")), centre: [$(join(centre, ','))], span: [$(join(span, ','))], place: $(there), google: $(google === nothing ? "null" : google.site)}"
	file = joinpath(pages(), slug(title) * ".html")
	write(file, """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$(html(title))</title>
<style>$(MAPS_CSS)</style>
</head><body>
<header><h1>$(html(title))</h1><span>Drag to move, scroll to zoom. N, E, S and W follow the grid$(google === nothing ? "" : ", and true north on Google's map").</span>
<button id="in" aria-label="Zoom in">+</button><button id="out" aria-label="Zoom out">−</button>$(place === nothing ? "" : "<button id=\"place\">Zoom on the Place</button>")<button id="reset">Reset</button></header>
<main>
$(join(figure.(maps), "\n"))
</main>
<script>
const SITE = $(site);
$(MAPS_JS)
</script>
$(google === nothing ? "" : "<script async src=\"https://maps.googleapis.com/maps/api/js?key=$(html(google.key))&v=weekly&loading=async&callback=start\"></script>")
</body></html>""")
	return file
end
