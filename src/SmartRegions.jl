"""
    SmartRegions

Open data of places for smart cities and regions, read into DuckDB from Julia: the buildings, places and other
features of Overture Maps, the aircraft and flights of the OpenSky Network, and pages of Google's 2D and 3D maps with
features of one's own drawn on them. The functions that read data take a DuckDB connection with the extensions
`spatial` and, for files over HTTPS, `httpfs` loaded, and write tables in it, or return SQL that reads what they
downloaded; the map functions write an HTML page and return its path.
"""
module SmartRegions

using DBInterface, Dates, Downloads, Tables

# Places: boxes, projections and GeoJSON
export around, utmzone, geojson
# Google's 2D and 3D maps
export googlemap, googlemap3d
# Overture Maps
export overture_release, overture
# The OpenSky Network
export opensky, opensky_states, opensky_track, opensky_flights, opensky_credits, has_opensky_client

include("places.jl")
include("google.jl")
include("overture.jl")
include("opensky.jl")

end
