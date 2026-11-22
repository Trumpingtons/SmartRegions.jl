"""
    SmartRegions

Open data of places for smart cities and regions, read into DuckDB from Julia: the buildings, places and other
features of Overture Maps, the aircraft and flights of the OpenSky Network, the street-level images and map features
of Mapillary, the satellite scenes of the Copernicus Data Space Ecosystem and USGS EarthExplorer, the elevation models
of OpenTopography, and pages of Google's 2D and 3D maps with features of one's own drawn on them. The functions that read data take a DuckDB connection with the extensions
`spatial` and, for files over HTTPS, `httpfs` loaded, and write tables in it, or return SQL that reads what they
downloaded; the map functions write an HTML page and return its path.
"""
module SmartRegions

using DBInterface, Dates, Downloads, Tables

# Places: boxes, projections and GeoJSON
export around, utmzone, geojson, projected_box
# Google's 2D and 3D maps
export googlemap, googlemap3d
# Overture Maps
export overture_release, overture
# The OpenSky Network
export opensky, opensky_states, opensky_track, opensky_flights, opensky_credits, has_opensky_client
# Mapillary
export mapillary, mapillary_coverage, mapillary_images, mapillary_thumbnails, mapillary_features, mapillary_near, mapillary_image
# The Copernicus Data Space Ecosystem
export copernicus_scenes, copernicus_band
# USGS EarthExplorer
export usgs, usgs_logout, usgs_scenes, usgs_download, usgs_bands, usgs_dem
# OpenTopography
export opentopography_catalog, opentopography_dem

include("places.jl")
include("google.jl")
include("overture.jl")
include("opensky.jl")
include("mapillary.jl")
include("copernicus.jl")
include("usgs.jl")
include("opentopography.jl")

end
