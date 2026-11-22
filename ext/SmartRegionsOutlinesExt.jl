module SmartRegionsOutlinesExt

# The outlines of features as polygons, from the raster of their cells, by GDAL's polygonize (GDALPolygonize), which
# ADAF reaches through rasterio's shapes: each region of cells with the same id becomes a polygon along the edges of
# its cells, with its holes, in the coordinates of the raster.

using SmartRegions, Rasters, ArchGDAL
import SmartRegions: feature_outlines

const GDAL = ArchGDAL.GDAL

function feature_outlines(labels::Rasters.AbstractRaster)
	L = Int32.(coalesce.(parent(labels), 0))
	X, Y = lookup(labels, Rasters.X), lookup(labels, Rasters.Y)
	dx, dy = Float64(step(X)), Float64(step(Y))
	(xa, xb), (ya, yb) = Rasters.bounds(labels, Rasters.X), Rasters.bounds(labels, Rasters.Y)
	transform = [dx > 0 ? xa : xb, dx, 0.0, dy > 0 ? ya : yb, 0.0, dy]  # the corner of the first cell, then the steps
	outlines = Tuple{Int, String}[]
	ArchGDAL.create(ArchGDAL.getdriver("MEM"); width = size(L, 1), height = size(L, 2), nbands = 1, dtype = Int32) do grid
		ArchGDAL.setgeotransform!(grid, transform)
		ArchGDAL.write!(grid, L, 1)
		band = ArchGDAL.getband(grid, 1)
		ArchGDAL.create(ArchGDAL.getdriver("Memory")) do shapes
			layer = ArchGDAL.createlayer(; name = "outlines", dataset = shapes, geom = ArchGDAL.wkbPolygon)
			ArchGDAL.addfielddefn!(layer, "id", ArchGDAL.OFTInteger)
			# the band is its own mask: cells of 0 belong to no feature and give no polygon
			GDAL.gdalpolygonize(band.ptr, band.ptr, layer.ptr, 0, C_NULL, C_NULL, C_NULL) == GDAL.CE_None || error("GDAL could not trace the outlines")
			for feature in layer
				push!(outlines, (Int(ArchGDAL.getfield(feature, 0)), ArchGDAL.toWKT(ArchGDAL.getgeom(feature))))
			end
		end
	end
	return outlines
end

end
