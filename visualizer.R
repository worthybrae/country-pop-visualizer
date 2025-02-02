### 1. DOWNLOAD & UNZIP DATA
### ------------------------
# Assuming data.csv file looks like this:
# DERIVED_COUNTRY,GEO,LOCATES
# usa,djgr,15806663
# usa,dp7z,3651373
# idn,w0jq,316099
# arg,6ehv,23045

your_data <- read.csv("data.csv")

iso3_code = 'ukr'
iso3_code_upper <- toupper(iso3_code)
your_data <- read.csv("data.csv") %>%
  filter(DERIVED_COUNTRY == iso3_code)

country_name <- countrycode(iso3_code, 'iso3c', 'country.name')
graph_name = paste0(country_name, " Data Density")

# Function to get geohash and its boundaries
get_geohash_polygon <- function(geohash) {
  ne <- gh_decode(geohash, coord_loc = 'ne')
  se <- gh_decode(geohash, coord_loc = 'se')
  sw <- gh_decode(geohash, coord_loc = 'sw')
  nw <- gh_decode(geohash, coord_loc = 'nw')
  
  st_polygon(list(rbind(
    c(ne$longitude, ne$latitude),
    c(se$longitude, se$latitude),
    c(sw$longitude, sw$latitude),
    c(nw$longitude, nw$latitude),
    c(ne$longitude, ne$latitude)  # close polygon
  )))
}

geometry_list <- lapply(your_data$GEO, get_geohash_polygon)
geometry_sf <- st_sfc(geometry_list, crs = 4326)

# Combine with your_data
your_data_sf <- cbind(your_data, geometry_sf)

# Convert to sf object
your_sf <- st_as_sf(your_data_sf)

your_data_sf <- st_set_crs(your_sf, 4326)

# Transform the CRS to WGS 84 / Pseudo-Mercator
your_data_sf_transformed <- st_transform(your_data_sf, 3857)

crsLAEA <- "+proj=laea +lat_0=52 +lon_0=10 +x_0=4321000 +y_0=3210000 +datum=WGS84 +units=m +no_defs"
pop_sf <- st_transform(your_data_sf_transformed, crsLAEA)

geo_data <- st_read("map.geo.json")

# Filter for the specified country's boundary using the iso3_code
country_boundary <- geo_data[geo_data$A3 == iso3_code_upper, ]

country_boundary <- st_set_crs(country_boundary, 4326)

# Transform the CRS to WGS 84 / Pseudo-Mercator
country_boundary_transformed <- st_transform(country_boundary, 3857)

crsLAEA <- "+proj=laea +lat_0=52 +lon_0=10 +x_0=4321000 +y_0=3210000 +datum=WGS84 +units=m +no_defs"
boundary_sf <- st_transform(country_boundary_transformed, crsLAEA)

ggplot() +
  geom_sf(
    data = pop_sf,
    color = "grey10", fill = "grey10"
  ) + 
  geom_sf(
    data = boundary_sf, 
    fill = "NA", 
    color = "red"
  )

### 3. SHP TO RASTER

bb <- sf::st_bbox(boundary_sf)

get_raster_size <- function() {
  height <- sf::st_distance(
    sf::st_point(c(bb[["xmin"]], bb[["ymin"]])),
    sf::st_point(c(bb[["xmin"]], bb[["ymax"]]))
  )
  width <- sf::st_distance(
    sf::st_point(c(bb[["xmin"]], bb[["ymin"]])),
    sf::st_point(c(bb[["xmax"]], bb[["ymin"]]))
  )
  
  if (height > width) {
    height_ratio <- 1
    width_ratio <- width / height
  } else {
    width_ratio <- 1
    height_ratio <- height / width
  }
  
  return(list(width_ratio, height_ratio))
}
width_ratio <- get_raster_size()[[1]]
height_ratio <- get_raster_size()[[2]]

size <- 3000
width <- round((size * width_ratio), 0)
height <- round((size * height_ratio), 0)

get_population_raster <- function() {
  pop_rast <- stars::st_rasterize(
    pop_sf |>
      dplyr::select(LOCATES, geometry),
    nx = width, ny = height
  )
  
  return(pop_rast)
}

get_boundary_raster <- function() {
  
  boundary_rast <- stars::st_rasterize(
    boundary_sf,
    nx = width, ny = height
  )
  
  return(boundary_rast)
}

boundary_rast <- get_boundary_raster()
plot(boundary_rast)
boundary_mat <- boundary_rast |> 
  as("Raster") |> 
  raster_to_matrix()

pop_rast <- get_population_raster()
plot(pop_rast)
pop_mat <- pop_rast |>
  as("Raster") |>
  rayshader::raster_to_matrix()

boundary_mat[is.na(boundary_mat)] <- 0
pop_mat[is.na(pop_mat)] <- 0

score_transform <- function(x, power=3) {
  # Replace 0 with NA to keep them out of the ranking
  x[x == 0] <- NA
  
  # Rank the non-zero values (NA values get the rank NA)
  ranks <- rank(-x, ties.method = "min", na.last = "keep")
  
  # Calculate scores using a power scale to emphasize the top ranks
  scores <- (max(ranks, na.rm = TRUE) - ranks + 1)^power
  
  # Replace NA back with 0 for zero values
  scores[is.na(scores)] <- 0
  
  # Scale scores to a range of 1-100, where the highest rank gets 100
  max_score <- max(scores, na.rm = TRUE)
  scaled_scores <- scores / max_score * 100
  
  return(scaled_scores)
}

# Apply the scoring transformation to pop_mat
scored_pop_mat <- matrix(score_transform(as.vector(pop_mat)), nrow = nrow(pop_mat))

normalized_boundary_mat <- boundary_mat * 10
combined_mat <- (scored_pop_mat + normalized_boundary_mat) * 20

# Create the initial 3D object
combined_mat %>%
  rayshader::height_shade(
    texture = (grDevices::colorRampPalette(c("transparent", "#d6ce93", "#ffba08", "#faa307", "#f48c06", "#e85d04", "#dc2f02", "#d00000", "#9d0208", "#6a040f", "#370617", "#03071e")))(256)
  ) %>%
  rayshader::plot_3d(
    heightmap = combined_mat,
    solid = F,
    zscale = 20,
    shadowdepth = 0
  )

# Use this to adjust the view after building the window object
rayshader::render_camera(theta = 0, phi = 45, zoom = .8)
output_image_name <- paste0(iso3_code, ".png")
final_image_name <- paste0(iso3_code, "_final.png")

rayshader::render_highquality(
  filename = output_image_name,
  interactive = FALSE,
  lightdirection = 280,
  lightaltitude = c(20, 80),
  lightcolor = c("#ffba08"),
  lightintensity = c(600, 100),
  samples = 450,
  width = width, height = height
)

rayshader_img <- image_read(output_image_name)

final_img <- rayshader_img %>%
  image_crop(gravity = "center", geometry = "6000x3500+0-150") %>%
  image_annotate(graph_name, gravity = "northwest", location = "+200+100",
                 color = c("#9d0208"), size = 200, weight = 700,
                 font = "DIN Condensed") %>%
image_write(final_img, final_image_name)