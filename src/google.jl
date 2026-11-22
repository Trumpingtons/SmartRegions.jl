# Google's 2D and 3D maps: pages with a map of Google's and nothing else, which the Maps JavaScript API draws with
# the user's key, and the features of a GeoJSON file of the user's own on them

# The folder of the pages: they hold the key in the address of the API, so they stay in a temporary folder that Julia
# removes when it exits
const PAGES = Ref("")
pages() = isempty(PAGES[]) || !isdir(PAGES[]) ? (PAGES[] = mktempdir()) : PAGES[]

# The names of Google's map types
const MAPTYPES = Dict("roadmap" => "Roadmap", "satellite" => "Satellite", "hybrid" => "Satellite with Labels", "terrain" => "Terrain")

slug(s) = lowercase(join((m.match for m in eachmatch(r"[A-Za-z0-9]+", s)), "-"))
html(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

# A GeoJSON file as a value of JavaScript inside a script element: `</` and `<!--` would end or derail the element
function embedded(features)
	isempty(features) && return "null"
	return replace(read(features, String), "</" => "<\\/", "<!--" => "<\\!--")
end

function mapskey(key)
	key === nothing || return String(key)
	haskey(ENV, "GOOGLE_MAPS_API_KEY") && return ENV["GOOGLE_MAPS_API_KEY"]
	error("No key of the Google Maps Platform: pass key = \"...\", or set ENV[\"GOOGLE_MAPS_API_KEY\"]. In Pollis, set it with the key on the Powered by line of Google Maps")
end

# A page with a map of Google's and nothing else; its hidden text says what the map shows, for screen readers
function page(title, about, css, body)
	file = joinpath(pages(), slug(title) * ".html")
	write(file, """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$(html(title))</title>
<style>
html, body { height: 100%; margin: 0; font: 13px sans-serif; }
.about { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
.box { position: absolute; z-index: 1; top: 10px; left: 10px; max-width: 60%; padding: 6px 10px; background: #fff; border-radius: 4px; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.3); font-weight: 600; }
.legend { margin: 0 0 10px 10px; padding: 6px 10px; background: #fff; border-radius: 4px; box-shadow: 0 1px 4px rgba(0, 0, 0, 0.3); }
.swatch { display: inline-block; width: 10px; height: 10px; margin-right: 6px; border-radius: 2px; }
$(css)
</style>
<script>function gm_authFailure() { document.getElementById("title").textContent = "Google refused the key: check it, and that the Maps JavaScript API is enabled for it." }</script>
</head><body>
<section class="about" aria-label="What the map shows"><h1>$(html(title))</h1><ul>$(join("<li>" .* html.(about) .* "</li>"))</ul></section>
<div class="box" id="title">$(html(title))</div>
$(body)
</body></html>""")
	return file
end

# The colours of the features by the values of a column: five steps for numbers, a colour for each value of text,
# grey where there is none; and the legend, the column's name over a line for each step or value
const SCALE_JS = """
function scale(all, column) {
	const RAMP = ["#440154", "#3b528b", "#21918c", "#5ec962", "#fde725"], PALETTE = ["#4e79a7", "#f28e2b", "#e15759", "#76b7b2", "#59a14f", "#edc948", "#b07aa1", "#ff9da7"];
	const values = all.filter(v => v !== null && v !== undefined);
	const numeric = values.length > 0 && values.every(v => typeof v === "number");
	const lo = numeric ? values.reduce((a, b) => Math.min(a, b)) : 0, hi = numeric ? values.reduce((a, b) => Math.max(a, b)) : 0;
	const kinds = [...new Set(values.map(String))];
	const step = v => hi > lo ? Math.min(4, Math.floor((v - lo) / (hi - lo) * 5)) : 2;
	const colour = v => !column ? PALETTE[0] : v === null || v === undefined ? "#999999" : numeric ? RAMP[step(v)] : PALETTE[kinds.indexOf(String(v)) % PALETTE.length];
	const legend = () => {
		const box = document.createElement("div");
		box.className = "legend";
		const row = (c, text) => { const line = document.createElement("div"); const swatch = document.createElement("span"); swatch.className = "swatch"; swatch.style.background = c; line.append(swatch, text); box.append(line); };
		const title = document.createElement("div");
		title.textContent = column;
		title.style.fontWeight = "600";
		box.append(title);
		const format = v => Number(v.toPrecision(4)).toLocaleString();
		if (numeric) {
			RAMP.forEach((c, i) => row(c, format(lo + (hi - lo) * i / 5) + " to " + format(lo + (hi - lo) * (i + 1) / 5)));
		} else {
			kinds.slice(0, PALETTE.length).forEach((k, i) => row(PALETTE[i], k));
		}
		return box;
	};
	return { colour, legend, shown: Boolean(column && values.length) };
}"""

"""
    googlemap(title, lon, lat; types = "roadmap", zoom = 15, features = "", column = "", note = "", place = title, key = nothing)

Writes a page with Google's 2D map centred on `lon`, `lat` at `zoom` (0 the whole world, each level up half the
width), and returns its path. `types` is a map type, `"roadmap"`, `"satellite"`, `"hybrid"` (satellite with labels)
or `"terrain"`, or a vector of them, drawn side by side and moving together. `features` is a GeoJSON file whose
features are drawn on Google's Data layer, coloured by `column` (five steps of a number, or a colour for each value of
a text), with a legend; a click on a feature shows its columns. `note` adds a line to the page's hidden description
for screen readers, which names `place`. The key is `key`, or `ENV["GOOGLE_MAPS_API_KEY"]`; as the page holds it, the
page is written to a temporary folder that Julia removes when it exits.

```julia
using SmartRegions
page = googlemap("Sydney Harbour, Satellite", 151.2125, -33.858; types = "satellite", zoom = 16)
Pollis.browse(page)  # in Pollis; elsewhere, open the file in a web browser
```
"""
function googlemap(title::AbstractString, lon::Real, lat::Real; types = "roadmap", zoom::Integer = 15, features::AbstractString = "",
		column::AbstractString = "", note::AbstractString = "", place::AbstractString = title, key = nothing)
	key = mapskey(key)
	types = types isa AbstractString ? [String(types)] : String.(collect(types))
	about = ["Google Maps, $(join([get(MAPTYPES, t, t) for t in types], " and ")), centred on $(place): longitude $(lon), latitude $(lat), zoom $(zoom)."]
	isempty(note) || push!(about, note)
	css = ".maps { display: flex; height: 100%; } .maps > div { flex: 1; height: 100%; }"
	return page(title, about, css, """<div class="maps">$(join(["<div id=\"map$(i - 1)\"></div>" for i in eachindex(types)]))</div>
<script>
const TYPES = [$(join(repr.(types), ", "))], GEOJSON = $(embedded(features)), COLUMN = $(repr(String(column)));
$(SCALE_JS)
async function start() {
	const { Map, InfoWindow } = await google.maps.importLibrary("maps");
	const maps = TYPES.map((type, i) => new Map(document.getElementById("map" + i), { center: { lat: $(lat), lng: $(lon) }, zoom: $(zoom), mapTypeId: type, mapTypeControl: false, streetViewControl: false }));
	if (maps.length > 1) {
		let moving = false;
		const follow = (a, b) => a.addListener("bounds_changed", () => { if (!moving) { moving = true; b.setCenter(a.getCenter()); b.setZoom(a.getZoom()); moving = false; } });
		maps.forEach((a, i) => maps.forEach((b, j) => { if (i !== j) { follow(a, b); } }));
	}
	if (!GEOJSON) {
		return;
	}
	const { colour, legend, shown } = scale(GEOJSON.features.map(f => f.properties ? f.properties[COLUMN] : undefined), COLUMN);
	const info = new InfoWindow();
	const bounds = new google.maps.LatLngBounds();
	maps.forEach(map => {
		map.data.addGeoJson(GEOJSON);
		map.data.setStyle(f => {
			const c = colour(f.getProperty(COLUMN));
			return { icon: { path: google.maps.SymbolPath.CIRCLE, scale: 7, fillColor: c, fillOpacity: 1, strokeColor: "#ffffff", strokeWeight: 2 }, fillColor: c, fillOpacity: 0.5, strokeColor: c, strokeWeight: 1 };
		});
		map.data.addListener("click", e => {
			const lines = document.createElement("div");
			e.feature.forEachProperty((v, k) => { const line = document.createElement("div"); line.textContent = k + ": " + v; lines.append(line); });
			info.setContent(lines);
			info.setPosition(e.latLng);
			info.open({ map });
		});
		map.data.forEach(f => f.getGeometry().forEachLatLng(p => bounds.extend(p)));
	});
	if (!bounds.getNorthEast().equals(bounds.getSouthWest())) {
		maps[0].fitBounds(bounds, 40);
	}
	if (shown) {
		maps[maps.length - 1].controls[google.maps.ControlPosition.LEFT_BOTTOM].push(legend());
	}
}
</script>
<script async src="https://maps.googleapis.com/maps/api/js?key=$(key)&v=weekly&loading=async&callback=start"></script>""")
end

"""
    googlemap3d(title, lon, lat; range = 1500, tilt = 60, heading = 0, mode = "satellite", orbit = false, features = "",
        height = "", column = "", curtain = false, note = "", place = title, key = nothing)

Writes a page with Google's photorealistic 3D map centred on `lon`, `lat`, and returns its path. The camera looks at
the centre from `range` metres away, `tilt` degrees from straight down and `heading` degrees from north; `mode` is
`"satellite"`, or `"hybrid"` with Google's labels; with `orbit = true` the camera turns once around the centre.
`features` is a GeoJSON file whose features are drawn in 3D, coloured by `column`, with a legend, and a click on one
shows its columns: polygons raised the metres of their column `height` above the ground, lines at the altitude of each
point above sea level (with `curtain = true`, hanging down to the ground), and points at their altitude, labelled by
their column `label`. `note`, `place` and `key` are as in [`googlemap`](@ref).

```julia
using SmartRegions
page = googlemap3d("Sydney Harbour, 3D View", 151.2125, -33.858; range = 1500, tilt = 60, heading = 30)
Pollis.browse(page)
```
"""
function googlemap3d(title::AbstractString, lon::Real, lat::Real; range::Real = 1500, tilt::Real = 60, heading::Real = 0,
		mode::AbstractString = "satellite", orbit::Bool = false, features::AbstractString = "", height::AbstractString = "",
		column::AbstractString = "", curtain::Bool = false, note::AbstractString = "", place::AbstractString = title, key = nothing)
	key = mapskey(key)
	camera = "range $(range) m, tilt $(tilt) degrees, heading $(heading) degrees"
	about = ["Google's 3D map, mode $(mode), centred on $(place): longitude $(lon), latitude $(lat); camera at $(camera)." * (orbit ? " The camera turns once around the centre." : "")]
	isempty(note) || push!(about, note)
	turn = orbit ? """<script>customElements.whenDefined("gmp-map-3d").then(() => document.getElementById("map").flyCameraAround({ camera: { center: { lat: $(lat), lng: $(lon), altitude: 0 }, range: $(range), tilt: $(tilt), heading: $(heading) }, durationMillis: 60000, repeatCount: 1 }));</script>""" : ""
	css = "gmp-map-3d { display: block; height: 100%; } .corner { position: absolute; z-index: 1; left: 0; bottom: 24px; }"
	return page(title, about, css, """<gmp-map-3d id="map" center="$(lat),$(lon),0" range="$(range)" tilt="$(tilt)" heading="$(heading)" mode="$(html(mode))"></gmp-map-3d>
<script>
document.getElementById("map").addEventListener("gmp-error", () => { document.getElementById("title").textContent = "Google could not open the 3D map: check the key, and that the Maps JavaScript API is enabled for it." });
const GEOJSON = $(embedded(features)), HEIGHT = $(repr(String(height))), COLUMN = $(repr(String(column))), CURTAIN = $(curtain);
$(SCALE_JS)
async function start() {
	if (!GEOJSON) {
		return;
	}
	const { Polygon3DInteractiveElement, Polyline3DInteractiveElement, Marker3DInteractiveElement, PopoverElement, AltitudeMode } = await google.maps.importLibrary("maps3d");
	const map = document.getElementById("map");
	const popover = new PopoverElement();
	map.append(popover);
	const show = (properties, position) => {
		popover.replaceChildren(...Object.entries(properties).map(([k, v]) => { const line = document.createElement("div"); line.textContent = k + ": " + v; return line; }));
		popover.positionAnchor = position;
		popover.open = true;
	};
	const { colour, legend, shown } = scale(GEOJSON.features.map(f => f.properties ? f.properties[COLUMN] : undefined), COLUMN);
	const at = (q, altitude) => ({ lat: q[1], lng: q[0], altitude: altitude ?? q[2] ?? 0 });
	for (const f of GEOJSON.features) {
		const g = f.geometry, p = f.properties || {}, c = colour(p[COLUMN]);
		if (!g) {
			continue;
		}
		const parts = g.type.startsWith("Multi") ? g.coordinates : [g.coordinates];
		let shapes = [];
		if (g.type.endsWith("Polygon")) {
			const h = Number(p[HEIGHT]) || 0;
			shapes = parts.map(rings => new Polygon3DInteractiveElement({ altitudeMode: AltitudeMode.RELATIVE_TO_GROUND, extruded: true, fillColor: c + "b3", strokeColor: c, strokeWidth: 1, path: rings[0].map(q => at(q, h)), innerPaths: rings.slice(1).map(r => r.map(q => at(q, h))) }));
		} else if (g.type.endsWith("LineString")) {
			shapes = parts.map(line => new Polyline3DInteractiveElement({ altitudeMode: AltitudeMode.ABSOLUTE, extruded: CURTAIN, drawsOccludedSegments: true, strokeColor: c, strokeWidth: 4, path: line.map(q => at(q)) }));
		} else if (g.type.endsWith("Point")) {
			shapes = parts.map(q => new Marker3DInteractiveElement({ altitudeMode: q.length > 2 ? AltitudeMode.ABSOLUTE : AltitudeMode.CLAMP_TO_GROUND, extruded: q.length > 2, drawsWhenOccluded: true, position: at(q), label: String(p.label ?? "") }));
		}
		shapes.forEach(shape => { shape.addEventListener("gmp-click", e => show(p, e.position)); map.append(shape); });
	}
	if (shown) {
		const box = legend();
		box.classList.add("corner");
		document.body.append(box);
	}
}
</script>
<script async src="https://maps.googleapis.com/maps/api/js?key=$(key)&v=weekly&loading=async&libraries=maps3d&callback=start"></script>
$(turn)""")
end
