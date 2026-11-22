using SmartRegions, Test

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
end
