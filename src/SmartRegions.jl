"""
    SmartRegions

Open data of places for smart cities and regions, read into DuckDB from Julia: the buildings, places and other
features of Overture Maps, the aircraft and flights of the OpenSky Network, the street-level images and map features
of Mapillary, the satellite scenes of the Copernicus Data Space Ecosystem and USGS EarthExplorer, the elevation models
of OpenTopography, the features of OpenStreetMap (from the Overpass API and Geofabrik) and its street networks, with
their fastest routes and travel times, the geographic files of Eurostat's GISCO and Eurostat's tables, INSPIRE's
datasets and the features of their download services, flows of commuters and trips between zones, counts of road
traffic and the flights of the OpenSky Network's flight list, pages of Google's 2D and 3D maps with features of
one's own drawn on them, and, for archaeological prospection, relief visualisations of lidar terrain models and the
candidate features found in them, with the scheduled monuments of England to set them beside, and pages of these
rasters beside imagery of the same ground. The functions that read
data take a DuckDB connection with the extensions
`spatial` and, for files over HTTPS, `httpfs` loaded, and write tables in it, or return SQL that reads what they
downloaded; the map functions write an HTML page and return its path.
"""
module SmartRegions

using DBInterface, Dates, Downloads, Tables, EzXML, Graphs, SparseArrays, ZipArchives, LinearAlgebra, Statistics
using DataStructures: BinaryMinHeap

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
# OpenStreetMap and Geofabrik
export osm_overpass, osm_read, geofabrik_file, geofabrik_layer, geofabrik_extract, geofabrik_earlier
# Street networks
export osm_streets, street_network, nearest_node, fastest_route, travel_times, service_areas, travel_matrix
# Eurostat and GISCO
export gisco_files, gisco_file, eurostat, vector_units
# INSPIRE
export inspire_search, inspire_countries, wfs_features, atom_files, atom_features, ogc_features
# Mobility
export commuting_flows, trip_flows, given_flows, traffic_counts, given_counts, flight_list, air_flights
# Relief visualisation
export local_relief, sky_view_factor, openness, terrain_slope, shaded_relief, layered_image
# Candidate features and known sites
export fill_depressions, regions, find_mounds, find_pits, find_regions, feature_template, template_scores, find_templates
export scheduled_monuments, candidates_table, save_candidates, feature_outlines
# Maps of terrain models
export terrain_maps

include("places.jl")
include("google.jl")
include("overture.jl")
include("opensky.jl")
include("mapillary.jl")
include("copernicus.jl")
include("usgs.jl")
include("opentopography.jl")
include("osm.jl")
include("streets.jl")
include("gisco.jl")
include("inspire.jl")
include("mobility.jl")
include("relief.jl")
include("features.jl")
include("maps.jl")

end
