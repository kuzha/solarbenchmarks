# Author: Kate Doubleday
# Last updated: 2/20/2020
# -----------------------------------------------------------------
# This script pre-processes SURFRAD files to make intra-hourly 
# averages for intra-hour forecasting and hourly averages that match
# the hourly average ECMWF forecasts. 
# -----------------------------------------------------------------
# Load dependencies

library(here)
library(ncdf4)

# -----------------------------------------------------------------
# Define constants

input_directory <- here("SURFRAD_files")
cs_directory <- here("CAMS_McClear_files")
output_directory <- here("GHI_files")
dir.create(output_directory, showWarnings = FALSE)

resolution <- c("Hourly", "Intrahour")
duration <- list(Hourly=60, Intrahour=5) # How many minutes to average for each forecast

for (r in resolution) {dir.create(file.path(output_directory, r), showWarnings = FALSE)}

site_names <- c("Bondville_IL",
                "Boulder_CO",
                "Desert_Rock_NV",
                "Fort_Peck_MT",
                "Goodwin_Creek_MS",
                "Penn_State_PA",
                "Sioux_Falls_SD")

# -----------------------------------------------------------------
#' A helper function to import each daily SURFRAD file and average hourly, if needed
#' @param fname Input file name
#' @param site Site name
#' @param res "Hourly" or "Intrahour" for averaging
#' @return an array of forecasts
get_time_series_data <- function(fname, site, res) {
  all_data <- read.table(file.path(input_directory, site, year, fname), skip=2, col.names=c(
    "year","jday","month","day","hour","min",'dt', "zen","dw_solar","qc_dwsolar","uw_solar","qc_uwsolar","direct_n",
    "qc_direct_n","diffuse","qc_diffuse","dw_ir", "qc_dwir","dw_casetemp","qc_dwcasetemp","dw_dometemp",
    "qc_dwdometemp","uw_ir","qc_uwir","uw_casetemp", "qc_uwcasetemp","uw_dometemp","qc_uwdometemp","uvb",
    "qc_uvb","par","qc_par","netsolar","qc_netsolar","netir", "qc_netir","totalnet","qc_totalnet",
    "temp","qc_temp","rh", "qc_rh","windspd","qc_windspd","winddir","qc_winddir","pressure","qc_pressure"))
  
  # Gather data, pre-processing for missing data
  GHI <- as.vector(sapply(0:23, FUN=function(hr) {sapply(0:59, FUN = function(min, hr) {
    matches <- all_data[, "min"]==min & all_data[, "hour"]==hr
    ifelse(any(matches), all_data[which(matches), "dw_solar"], NA)
  }, hr=hr)}))
  
  # Clean: truncate small negative values to 0
  GHI[GHI<0] <- 0
  
  zen_min <- as.vector(sapply(0:23, FUN=function(hr) {sapply(0:59, FUN = function(min, hr) {
    matches <- all_data[, "min"]==min & all_data[, "hour"]==hr
    ifelse(any(matches), all_data[which(matches), "zen"], NA)
  }, hr=hr)}))
  sun_up <- zen_min <= 85
  
  # Average to hourly to match ECMWF forecasts
  nsteps <- length(GHI)/duration[[res]]
  GHI <- sapply(1:nsteps, FUN=function(i) {mean(GHI[(duration[[res]]*(i-1)+1):(duration[[res]]*i)])})
  sun_up <- sapply(1:nsteps, FUN=function(i) {any(sun_up[(duration[[res]]*(i-1)+1):(duration[[res]]*i)])})
  
  return(matrix(c(GHI, sun_up), ncol=2))  
}

# -----------------------------------------------------------------
#' A helper function to gather the daily files into a single irradiance array for a given site and export to a new NetCDF
#' @param site Site name
#' @param year Data year
export_site_netcdf <- function(site, year) {
  daily_files <- list.files(file.path(input_directory, site, year), pattern=".dat")
 
  for (res in resolution) {
    # Get hourly irradiance and indicator if sun is up, based on solar zenith angle
    time_series_data <- sapply(daily_files, FUN=get_time_series_data, site=site, res=res, simplify="array")
    irr <- t(time_series_data[,1,])
    sun_up <- t(time_series_data[,2,])
    
    if (year==2017) {d_vals <- 1:20} else {d_vals <- 1:365}
    ndays <- length(d_vals)
    
    # Load in CAMS McClear clear-sky information
    CS <- read.table(file.path(cs_directory, paste(site, "_", year, ".csv", sep="")), sep=";", skip=38, 
                     col.names = c("Observation_period", "TOA", "Clear_sky_GHI", "Clear_sky_BHI", 
                                   "Clear_sky_DHI", "Clear_sky_BNI"))
    CS_GHI <- CS[, "Clear_sky_GHI"]*60 # Convert from Wh/m^2 with 1 min integration period to W/m^2
    # Average over window for this forecast's resolution
    CS_GHI <- matrix(sapply(1:(1440/duration[[res]]*ndays), 
                            FUN=function(i) {mean(CS_GHI[(duration[[res]]*(i-1)+1):(duration[[res]]*i)])}), 
                     byrow = T, nrow = ndays)
      
    # Parameters for new NetCDF file
    t_vals <- 1:(1440/duration[[res]])
    dims <- mapply(ncdim_def, name=c('Day', 'Hour'), units=c('', ''), vals=list(d_vals, t_vals), 
                   longname=c("Day number", "Hour of day"), SIMPLIFY = FALSE)
    ivar <- ncvar_def("irradiance", "W/m^2", dims, missval=NA, compression = 9)
    svar <- ncvar_def("sun_up", "", dims, compression = 9, prec="integer")
    csvar <- ncvar_def("clearsky_irradiance", "W/m^2", dims, missval=NA, compression = 9)
    vars <- list(ivar, svar, csvar)
    
    # Export new NetCDF file
    nc_new <- nc_create(file.path(output_directory, res, paste(site, "_", year, ".nc", sep='')), vars)
    ncvar_put(nc_new, ivar, irr, count=ivar[['varsize']])
    ncvar_put(nc_new, svar, sun_up, count=svar[['varsize']])
    ncvar_put(nc_new, csvar, CS_GHI, count=svar[['varsize']])
    nc_close(nc_new)  
  }
}

# -----------------------------------------------------------------
# Cycle through the sites, exporting their site-specific irradiance NetCDF's
for (year in c(2017, 2018)) {
  
  for (site in site_names) export_site_netcdf(site, year)  
}

