using SmartRegions, Test, Graphs, SparseArrays

@testset "SmartRegions" begin
	@testset "UTM zones" begin
		# Sydney lies in zone 56 south, New York in 18 north and London in 30 north
		@test [utmzone(151.2093, -33.8675), utmzone(-74.006, 40.7128), utmzone(-0.1276, 51.5072)] == ["EPSG:32756", "EPSG:32618", "EPSG:32630"]
	end

	@testset "A page whose features hold the end tag of a script" begin
		features = tempname() * ".geojson"
		write(features, """{"type": "FeatureCollection", "features": [{"type": "Feature", "properties": {"name": "</script><b>"}, "geometry": {"type": "Point", "coordinates": [151.2, -33.9]}}]}""")
		page = googlemap("A <Test> Page", 151.2, -33.9; features, column = "name", key = "KEY")
		text = read(page, String)
		@test (count("<script", text), count("</script>", text), occursin("key=KEY&", text), occursin("<title>A &lt;Test&gt; Page</title>", text)) == (3, 3, true, true)
	end

	@testset "The area of Overture Maps" begin
		@test_throws ArgumentError overture(nothing, "building")
		@test_throws ArgumentError overture(nothing, "building"; box = (0, 0, 1, 1), within = (0, 0, 100))
	end

	@testset "Requests refused before they are sent" begin
		@test_throws ArgumentError mapillary_near(nothing, 4.8932, 52.3731, 600; token = "T")  # more than 500 m
		@test_throws ArgumentError mapillary_images(nothing, (4.0, 52.0, 6.0, 53.0); token = "T")  # 2 square degrees
		@test_throws ArgumentError mapillary_image(nothing, "Dam Square", 4.8932, 52.3731; token = "T")
		@test_throws ArgumentError opentopography_dem((-123.0, 37.0, -122.0, 38.0), "USGS1m"; folder = mktempdir(), key = "K")  # about 9,800 km², more than 250
		@test_throws ArgumentError commuting_flows(nothing, "rome"; folder = mktempdir())  # no source of commuters for Rome
		@test_throws ArgumentError trip_flows(nothing, "paris"; folder = mktempdir())
		@test_throws ArgumentError traffic_counts(nothing, "tokyo"; folder = mktempdir())
	end

	@testset "Fastest routes on a network of four nodes" begin
		# 1 → 2 takes 60 s over 100 m, 2 → 3 120 s over 200 m, and 1 → 3 directly 300 s over 250 m; nothing leaves 3 or reaches 4
		g = SimpleDiGraph(4)
		add_edge!(g, 1, 2); add_edge!(g, 2, 3); add_edge!(g, 1, 3)
		net = (; g, seconds = sparse([1, 2, 1], [2, 3, 3], [60.0, 120.0, 300.0], 4, 4), metres = sparse([1, 2, 1], [2, 3, 3], [100.0, 200.0, 250.0], 4, 4))
		@test fastest_route(net, 1, 3) == ([1, 2, 3], 3.0, 0.3)  # through 2: 180 s, 300 m, against 300 s by the direct edge
		minutes, km = travel_matrix(net, [1, 3, 4])
		@test (minutes, km) == ([0.0 3.0 Inf; Inf 0.0 Inf; Inf Inf 0.0], [0.0 0.3 Inf; Inf 0.0 Inf; Inf Inf 0.0])
	end
end
