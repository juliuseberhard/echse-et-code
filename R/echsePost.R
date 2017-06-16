################################################################################
# Author: Julius Eberhard
# Last Edit: 2017-06-12
# Project: ECHSE Evapotranspiration
# Function: echsePost
# Aim: Model Run and Data Postprocessing
# TODO(2017-05-26): x axis labels for comparison plots: don't want weekdays
################################################################################

echsePost <- function(engine,  # name of ECHSE engine
                      et.choice,  # etp or eta
                      ma.width,  # width of moving average filter in time units
                      fs,  # field station name
                      comp = NA,  # variable for comparison btw. model & obs
                      wc_res,  # residual soil water content
                      wc_sat  # saturated soil water content
                      ) {

  #:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  # This function runs the models in ECHSE and does post-processing
  # of the results (mainly plots).
  #:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  # requires the TTR package!
  #:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  
  AddAxis <- function(data
                      ) {
    pr <- pretty(range(data, na.rm=TRUE))
    atlab <- c(pr[2], tail(pr, 2)[1])
    axis(2, at=atlab, labels=atlab)
  }

  MovAve <- function(station,
                     column,
                     period,
                     na.val,
                     ma.width
                     ) {
    # computes moving average of given data

    var <- as.numeric(get(station)[[column]][period])
    var[is.na(var)] <- na.val
    return(runMean(var, n=ma.width))
  }


  # RUN ECHSE ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

  system(paste0("cd ~/uni/projects/", engine, "/run; ./run cnf_default"))


  # READ RESULTS :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

  result <- read.delim(paste0("~/uni/projects/", engine, "/run/out/test1.txt"),
                       sep="\t")


  # POSTPROCESSING :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

  dstart <- strsplit(tstart, " ")[[1]][1]
  dend <- strsplit(tend, " ")[[1]][1]
  res <- xts(result[, 2], order.by=as.POSIXct(result$end_of_interval, tz="UTC"))
  res.mean <- mean(result[, 2])


  # PLOT :::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

  if (comp == "evap") {
  # evapotranspiration

    # NORMAL PLOT

    if (engine == "evap_portugal") {
    # Portugal

      period <- seq(as.POSIXct(tstart, tz="UTC"), as.POSIXct(tend, tz="UTC"),
                    by="1 hour")
      xl <- c(as.POSIXct(tstart), as.POSIXct(tend))
      # total incoming radiation
      rad.ma <- MovAve("tower", 3, period, 0, ma.width)
      # relative air humidity
      hum.ma <- MovAve("tower", 6, period, 0, ma.width)
      # net radiation
      radn.ma <- MovAve(fs, 1, period, 0, ma.width)
      # air temperature
      temp.ma <- MovAve(fs, 2, period, mean(as.numeric(get(fs)[[2]])), ma.width)
      # soil heat flux
      sohe.ma <- MovAve(fs, 3, period, 0, ma.width)
      # soil moisture content
      somo.ma <- MovAve(fs, 4, period, wc_res, ma.width)
      # wind speed
      wind.ma <- MovAve(fs, 11, period, 0, ma.width)

      # plot
      pdf(paste0("plot_evap_compare_portugal_", fs, "_", dstart, "_", dend,
                 ".pdf"))
      layout(matrix(1:7, 7, 1), heights=c(.2, rep(.1, 5), .3))
      par(mar=c(0, 5, 5, 2))
      plot(period, rad.ma, xlim=xl, type="l", ylab=(Rad~(W~m^{-2})),
           axes=FALSE, main=c(paste0("Engine: ", engine, ", ", fs), et.choice))
      AddAxis(rad.ma)
      par(mar=c(0, 5, 0, 2))
      plot(period, temp.ma, xlim=xl, type="l", ylab=(Temp~({}^o*C)), axes=FALSE)
      AddAxis(temp.ma)
      plot(period, sohe.ma, xlim=xl, type="l", ylab=(SHF~(W~m^{-2})),
           axes=FALSE)
      AddAxis(sohe.ma)
      plot(period, somo.ma, xlim=xl, type="l", ylab=expression(S.moist~({}-{})),
           axes=F)
      AddAxis(somo.ma)
      plot(period, hum.ma, xlim=xl, type="l", ylab=(Rel.hum.~("%")),
           axes=FALSE)
      AddAxis(hum.ma)
      plot(period, wind.ma, xlim=xl, type="l", ylab=(Wind~(m~s^{-1})),
           axes=FALSE)
      AddAxis(wind.ma)
      par(mar=c(4, 5, 0, 2))
      plot(period, as.numeric(get(fs)[[8]][period]), xlim=xl, ylim=c(-.1, 2),
           xlab="", ylab=(ET~(mm)), type="l")
      par(new=T)
      plot(period[-1], as.numeric(res), xlim=xl, ylim=c(-.1, 2), col=2,
           xlab="Date", ylab="", type="l")
      legend("topright", c("simulation", "observation"), lty=1,
             col=c(2, 1), bty="n")
      dev.off()

    } else {
    # Morocco

      period <- seq(as.POSIXct(tstart, tz="UTC"), as.POSIXct(tend, tz="UTC"),
                    by="1 hour")
      xl <- c(as.POSIXct(tstart, tz="UTC"), as.POSIXct(tend, tz="UTC"))
      # total incoming radiation
      rad.ma <- MovAve("meteo", 2, period, 0, ma.width)
      # relative air humidity
      hum.ma <- MovAve("meteo", 1, period, 0, ma.width)
      # net radiation
      radn.ma <- 0.8 * rad.ma
      # air temperature
      temp.ma <- MovAve("meteo", 3, period, mean(meteo[[3]], na.rm=TRUE),
                        ma.width)
      # soil heat flux
      sohe.ma <- NA
      # soil moisture content
      somo.ma <- 0.9 * wc_sat
      # wind speed
      wind.ma <- MovAve("meteo", 4, period, 0, ma.width)
      # calculate daily ET sums for comparison with observations
      etsum <- apply.daily(res, sum)

      # plot
      pdf("plot_evap_compare_morocco.pdf")
      layout(matrix(1:7, 7, 1), heights=c(.2, rep(.1, 5), .3))
      par(mar=c(0, 5, 5, 2))
      plot(period, rad.ma, xlim=xl, type="l", ylab=(Rad~(W~m^{-2})),
           axes=FALSE, main=c(paste0("Engine: ", engine, ", ", fs), et.choice))
      AddAxis(rad.ma)
      par(mar=c(0, 5, 0, 2))
      plot(period, temp.ma, xlim=xl, type="l", ylab=(Temp~({}^o*C)), axes=FALSE)
      AddAxis(temp.ma)
      plot(period, sohe.ma, xlim=xl, type="l", ylab=(SHF~(W~m^{-2})),
           axes=FALSE)
      AddAxis(sohe.ma)
      plot(period, somo.ma, xlim=xl, type="l", ylab=expression(S.moist~({}-{})),
           axes=F)
      AddAxis(somo.ma)
      plot(period, hum.ma, xlim=xl, type="l", ylab=(Rel.hum.~("%")),
           axes=FALSE)
      AddAxis(hum.ma)
      plot(period, wind.ma, xlim=xl, type="l", ylab=(Wind~(m~s^{-1})),
           axes=FALSE)
      AddAxis(wind.ma)
      par(mar=c(4, 5, 0, 2))
      plot(index(eta.day), as.numeric(eta.day), xlim=xl,
           ylim=c(-.1, max(c(as.numeric(eta.day), etsum))), xlab="Date",
           ylab=(ET~(mm)), type="l")
      lines(seq(as.POSIXct("2013-01-01"), as.POSIXct("2013-12-31"), by="day"),
            etsum, col=2)
      legend("topright", c("simulation", "observation"), lty=1,
             col=c(2, 1), bty="n")
      dev.off()

    }

    # CUMULATIVE PLOT

    if (engine == "evap_portugal") {
    # Portugal
      pdf(paste0("plot_evap_cum_portugal_", fs, "_", dstart, "_", dend, ".pdf"))
      plot(cumsum(res), ylim=c(0, 50), main=paste(engine, "cumulative"),
           ylab="cumulative ET (mm)")
      lines(cumsum(na.exclude(get(fs)[[8]][index(get(fs)[[8]]) >=
                                           index(res)[1]])),
            col=2)
      if (fs == "HS") {
      # Hauptstation
        lines(cumsum(na.exclude(HS.list[[8]][index(HS.list[[8]]) >=
                                             index(res)[1]])),
              col=2)
      } else {
      # Nebenstation A
        lines(cumsum(na.exclude(NSA.list[[8]][index(NSA.list[[8]]) >=
                                              index(res)[1]])),
              col=2)
        legend("topright", c("simulation", "observation"), lty=1, col=c(1, 2))
      }
      dev.off()
    } else {
    # Morocco
      pdf("plot_et_cum_morocco.pdf")
      plot(cumsum(res), ylim=c(0, 50), main=paste(engine, "cumulative"),
           ylab="cumulative ET (mm)")
      lines(cumsum(na.exclude(eta.day.xts[index(eta.day.xts) >=
                                          index(res)[1]])), col=2)
      legend("topright", c("simulation", "observation"), lty=1, col=c(1, 2))
      dev.off()
    }

  } else if (comp == "glorad") {
  # global radiation

    # NORMAL PLOT
    if (tail(strsplit(engine, "_")[[1]], 1) == "portugal") {
    # Portugal
      rad.plot <- apply.daily(tower["rsd"], mean)
      index(rad.plot) <- as.POSIXlt(index(rad.plot))
      index(rad.plot)$hour <- "00"
    } else {
    # Morocco
      rad.plot <- apply.daily(meteo[[2]], mean)
      index(rad.plot) <- as.POSIXlt(index(rad.plot))
      index(rad.plot)$hour <- "00"
    }

    if (tail(strsplit(engine, "_")[[1]], 1) == "portugal") {
      pdf(paste0("plot_glorad_compare_portugal_", fs, "_", dstart,
                 "_", dend, ".pdf"))
    } else {
      pdf("plot_glorad_compare_morocco.pdf")
    }

    plot(res, ylim=c(0, 500), main=engine, ylab=comp)
    lines(rad.plot, col=2)
    legend("topright", legend=c("simulation", "observation"), col=c(1, 2),
           lty=c(1, 1))
    dev.off()

    # CUMULATIVE PLOT
    if (tail(strsplit(engine, "_")[[1]], 1) == "portugal") {
      pdf(paste0("plot_glorad_cum_portugal_", fs, "_", dstart, "_",
                 dend, ".pdf"))
    } else {
      pdf("plot_glorad_cum_morocco.pdf")
    }

    plot(cumsum(res), ylim=c(0, 50000), main=paste(engine, "cumulative"),
         ylab="cumulative radiation (W m2)")
    lines(cumsum(rad.plot[index(rad.plot) >= index(res)[1]]), col=2)
    legend("topright", legend=c("simulation", "observation"), col=c(1, 2),
           lty=c(1, 1))
    dev.off()

  } else if (comp == "rad_net") {
  # net radiation

    # NORMAL PLOT
    if (tail(strsplit(engine, "_")[[1]], 1) == "portugal") {
      rnet.plot <- get(paste0(fs, ".list"))[[1]]
      pdf(paste0("plot_rad_net_compare_portugal_", fs, "_", dstart,
                 "_", dend, ".pdf"))
#      plot(res, ylim=c(0, 800), main=engine, ylab=comp)
      plot(res[round(length(res) / 3):round(length(res) / 1.5)],
           ylim=c(0, 800), main=engine, ylab=comp)
      lines(rnet.plot, col=2)
      legend("topright", legend=c("simulation", "observation"), col=c(1, 2),
             lty=c(1, 1))
      dev.off()
    }

    # CUMULATIVE PLOT
    if (tail(strsplit(engine, "_")[[1]], 1) == "portugal") {
      pdf(paste0("plot_rad_net_cum_portugal_", fs, "_", dstart, "_",
                 dend, ".pdf"))
      plot(cumsum(res), ylim=c(1, 30000), main=paste(engine, "cumulative"),
           ylab="cumulative net radiation (Wm2)")
      lines(cumsum(rnet.plot[index(rnet.plot) >= index(res)[1]]), col=2)
      legend("topright", legend=c("simulation", "observation"), col=c(1, 2),
             lty=c(1, 1))
      dev.off()
    }

  } else if (comp == "soilheat") {
  # soil heat flux

    # NORMAL PLOT
    if (tail(strsplit(engine, "_")[[1]], 1) == "portugal") {
      sheat.plot <- get(paste0(fs, ".list"))[[3]]
      pdf(paste0("plot_soilheat_compare_portugal_", fs, "_", dstart,
                 "_", dend, ".pdf"))

      plot(res, ylim=c(-20, 150), main=engine, ylab=comp)
      lines(sheat.plot, col=2)
      legend("topright", legend=c("simulation", "observation"), col=c(1, 2),
             lty=c(1, 1))
      dev.off()
    }

    # CUMULATIVE PLOT
    if (tail(strsplit(engine, "_")[[1]], 1) == "portugal") {
      pdf(paste0("plot_soilheat_cum_portugal_", fs, "_", dstart, "_",
                 dend, ".pdf"))

      plot(cumsum(res), ylim=c(-100, 1800),
           main=paste(engine, "cumulative"),
           ylab="cumulative soil heat flux (Wm2)")
      lines(cumsum(sheat.plot[index(sheat.plot) >= index(res)[1]]), col=2)
      legend("topright", legend=c("simulation", "observation"), col=c(1, 2),
             lty=c(1, 1))
      dev.off()
    }

  }

  # return mean evapotranspiration for sensitivity analysis
  #return(res.mean)

}