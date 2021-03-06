################################################################################
# Author: Julius Eberhard
# Last Edit: 2017-07-05
# Project: ECHSE evapotranspiration
# Function: echseParEst
# Aim: Estimation of Model Parameters from Observations,
#      Works for alb, emis_*, f_*, fcorr_*, radex_*
################################################################################

echseParEst <- function(parname,  # name of parameter group to estimate
                                  # [radex_[a/b], fcorr_[a/b], emis_[a/b],
                                  # f_[day/night], alb]
                        rsdfile = NA,  # file with global radiation data*
                        hrfile = NA,  # file with relative humidity data*
                        rnetfile = NA,  # file with net radiation data*
                        rldfile = NA,  # file with downward lw rad. data*
                        rlufile = NA,  # file with upward lw rad. data*
                        rsufile = NA,  # file with upward sw rad. data*
                        rxfile = NA,  # file with extraterrestrial rad. data*
                        sheatfile = NA,  # file with soil heat flux data*
                        tafile = NA,  # file with mean air temperature data*
                                      # *Supply complete file path!
                        fs = NA,  # field station [HS, NSA]
                        emis_a = NA,  # net emissivity coefficient
                        emis_b = NA,  # ditto
                        lat = 0,  # latitude for calculating sunrise/-set
                        lon = 0,  # longitude for... ditto
                        radex_a = NA,  # parameter for estimating fcorr_*
                        radex_b = NA,  # ditto
                        r.quantile = 0.05,  # lower quantile for min rad.ratio
                        emismeth = NA,  # emissivity method [Brunt, Idso, both]
                        plots = TRUE  # plots for visual diagnosis?
                        ) {

  #:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
  # This function contains methods for estimating parameters involved
  # in the evapotranspiration engines of ECHSE.
  # Methods are discussed in the documentation.
  # Abbreviations: rlu = Upward Long-wave Radiation,
  #                rsd = Downward Short-wave Radiation, ...
  #:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::


  # FUNCTIONS ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

  EmisBrunt <- function(emis_a,  # emissivity parameter a (intersect)
                        emis_b,  # emissivity parameter b (slope)
                        vap  # water vapor pressure, in kPa (!)
                        ) {
    # calculates net emissivity between ground and atmosphere
    # after Brunt (1932)

    return(emis_a + emis_b * sqrt(vap))
  }

  EmisIdso <- function(ta  # mean air temperature, in degC
                       ) {
    # calculates net emissivity between ground and atmosphere
    # after Idso & Jackson (1969), modified by Maidment (1993)

    return(-0.02 + 0.261 * exp(-7.77E-4 * ta ^ 2))
  }

  VapMagnus <- function(ta,  # mean air temperature, in degC
                        hr  # relative humidity, in %
                        ) {
    # calculates vapor pressure in hPa
    # using the Magnus equation, see Dyck & Peschke

    return(6.11 * 10 ^ (7.5 * ta / (237.3 + ta)) * hr / 100)
  }

  ReadToXts <- function(file  # path to file, 1st column POSIX-like dates,
                              #               2nd column data
                        ) {
    # reads delimiter separated file and converts it to xts object

    return(xts(read.delim(file)[, 2],
               order.by=as.POSIXct(read.delim(file)[, 1])))
  }

  ReadToHlyMean <- function(file  # path to xts object
                            ) {
    # reads xts object (with sub-hourly data) and returns hourly means as xts

    f <- readRDS(file)
    ep <- endpoints(f, on="hours") + 1
    return(xts(period.apply(f, ep[-length(ep)], mean),
               order.by=index(f)[ep[-c(1, length(ep))]]))
  }

  GenerateEstDat <- function(vars  # vector of variable names
                             ) {
    # generates common xts object of data required for parameter estimation

    vars.ls <- list()
    for (i in 1:length(vars)) {
      if (length(grep("\\.dat|\\.txt", get(paste0(vars[i], "file")))) == 0) {
        # These variables have sub-hourly data.
        vars.ls[[i]] <- ReadToHlyMean(get(paste0(vars[i], "file")))
      } else {
        # These variables have hourly data.
        vars.ls[[i]] <- ReadToXts(get(paste0(vars[i], "file")))
      }
    }

    # collect all data needed for estimation in one xts object
    est.dat <- vars.ls[[1]]
    if (length(vars.ls) > 1) {
      for (i in 2:length(vars))
        est.dat <- merge(est.dat, vars.ls[[i]], join="inner")
      names(est.dat) <- vars
      return(est.dat)
    }
  }


  # PARAMETER ESTIMATION :::::::::::::::::::::::::::::::::::::::::::::::::::::::

  if (length(grep("alb", parname)) != 0) {
  # estimation of albedo
  # requires: rsd, rsu

    # collect estimation data
    est.dat <- GenerateEstDat(c("rsd", "rsu"))

    # restrict to times between 8:00 and 16:00 to avoid odd night effects
    # and to times when gr & rsu != 0
    ix <- as.numeric(format(index(est.dat), "%H")) < 17 &
          as.numeric(format(index(est.dat), "%H")) > 7 &
          est.dat$rsd != 0 & est.dat$rsu != 0
    alb.series <- with(est.dat, rsu[ix] / rsd[ix])
    alb <- mean(alb.series[alb.series < 1])
 
    # diagnostic plot
    if (plots) {
      pdf("../doku/fig/plot_alb.pdf", width=6, height=4)
      plot(apply.daily(alb.series[alb.series < 1], mean),
           ylab=expression(mu), main="", type="p", pch=20)
      dev.off()
    }

    return(alb)

  } else if (length(grep("radex", parname)) != 0) {
  # estimation of radex parameters
  # requires: rsd, rx

    # collect estimation data
    est.dat <- GenerateEstDat(c("rx", "rsd"))

    # restrict to times between 8:00 and 16:00 to avoid odd night effects
    # and to times when rx != 0 and where rsd > 50 W.m-2
    ix <- as.numeric(format(index(est.dat), "%H")) < 17 &
          as.numeric(format(index(est.dat), "%H")) > 7 &
          est.dat$rx != 0 & est.dat$rsd > 50

    # calculate ratio of rx and rsd
    rad.ratio <- with(est.dat[ix], as.numeric(rsd) / as.numeric(rx))

    # maximum ratio per hour
    MaxRadRatio <- function(i  # hour [0...23]
                            ) {
      # determines the maximum value of rad.ratio within hour i

      hour.is.i <- as.numeric(format(index(est.dat[ix]), "%H")) == i
      out <- NA
      if (any(hour.is.i))
        rad.ratio2 <- rad.ratio[hour.is.i]
      if (exists("rad.ratio2")) {
        out <- max(rad.ratio2[rad.ratio2 < 1], na.rm=T)
        return(out)
      }
    }
    r.max <- max(sapply(8:16, MaxRadRatio), na.rm=T)

    # diagnostic plots
    if (plots) {
      # plot histogram of calculated ratios
      pdf("../doku/fig/plot_radex.pdf", width=8, height=4)
      par(mfrow=c(1, 2))
      hist(rad.ratio, xlab="glorad/radex", breaks="Sturges", main="",
           xlim=c(0, 1))

      # plot rad.ratio over hours of day to detect subdaily trends
      plot(as.numeric(format(index(est.dat$rx[ix]), "%H")), rad.ratio,
           ylim=c(0, 1), xlab="hour of day", ylab="glorad/radex")
      abline(h=quantile(rad.ratio, r.quantile, na.rm=T), lty="dashed")
      dev.off()

      # plot extraterr. and global radiation to detect time shifts
      #plot(est.dat$rx, type="l", ylim=c(0, max(as.numeric(est.dat$rx))),
      #     xlab="Date", ylab="Rad (black: radex, red: glorad)", main="")
      #lines(est.dat$rsd, col=2)
    }

    # return parameters
    out <- c(# radex_a
             as.numeric(quantile(rad.ratio, r.quantile, na.rm=T)),
             # radex_b
             r.max - as.numeric(quantile(rad.ratio, r.quantile, na.rm=T)))
    return(out)

  } else if (length(grep("fcorr", parname)) != 0) {
  # estimation of fcorr parameters
  # requires: hr, rld, rlu, rsd, rx, ta, radex_a, radex_b

    # collect estimation data
    est.dat <- GenerateEstDat(c("ta", "hr", "rld", "rlu", "rsd", "rx"))

    # calculate net emissivity between ground and atmosphere
    if (emismeth == "Idso") {
      est.dat$emis <- EmisIdso(est.dat$ta)
    } else if (emismeth == "Brunt") {
      est.dat$vap <- VapMagnus(est.dat$ta, est.dat$hr)
      # vap in kPa!
      est.dat$emis <- EmisBrunt(0.34, -0.14, est.dat$vap / 10)
    } else if (emismeth == "both") {
    # both methods for comparison
      est.dat$vap <- VapMagnus(est.dat$ta, est.dat$hr)
      est.dat$emis.idso <- EmisIdso(est.dat$ta)
      # vap in kPa!
      est.dat$emis.brunt <- EmisBrunt(0.34, -0.14, est.dat$vap / 10)
    } else {
      stop("Unknown emismeth! Choose either 'Idso' or 'Brunt' or 'both'.")
    }

    # calculate fcorr (adapted Stefan-Boltzmann law)
    sig <- 5.670367E-8  # Stefan constant
    if (plots) {
      with(est.dat, plot(as.numeric(ta), as.numeric(rld - rlu),
           main="", xlab=("Mean air temperature"~({}^o~C)),
           ylab=("Net LW radiation"~(W~m^{-2}))))
      if (emismeth == "both") {
        par(mfrow=c(2, 1), mar=c(1, 5, 2, 1))
        with(est.dat,
             plot(as.numeric(emis.brunt), as.numeric(rld - rlu), xaxt="n",
                  main="", xlab="Net emissivity",
                  ylab=(Net~LW~radiation~(W~m^{-2}))))
        text(0.22, -80, "Brunt")
        par(mar=c(5, 5, 0, 1))
        with(est.dat,
             plot(as.numeric(emis.idso), as.numeric(rld - rlu),
                  main="", xlab="Net emissivity",
                  ylab=(Net~LW~radiation~(W~m^{-2}))))
        text(0.18, -80, "Idso & Jackson")
      } else {
        par(mfrow=c(1, 1))
        with(est.dat,
             plot(as.numeric(emis), as.numeric(rld - rlu),
                  main=emismeth, xlab="Net emissivity",
                  ylab=("Net LW radiation"~(W~m^{-2}))))
      }
    }
    if (emismeth == "both") {
      est.dat$f.brunt <- with(est.dat,
                              -(rld - rlu) /
                                (emis.brunt * sig * (ta + 273.15) ^ 4))
      est.dat$f.idso <- with(est.dat,
                             -(rld - rlu) /
                               (emis.idso * sig * (ta + 273.15) ^ 4))
    } else {
      est.dat$f <- with(est.dat, -(rld - rlu) / (emis * sig * (ta + 273.15) ^ 4))
    }

    # estimate fcorr_a, fcorr_b from fcorr, rsd, rx
    ix <- as.numeric(format(index(est.dat), "%H")) < 17 &
          as.numeric(format(index(est.dat), "%H")) > 7 &
          est.dat$rx != 0
    est.dat$rsdmax <- (radex_a + radex_b) * est.dat$rx
    if (emismeth == "both") {
      lmod.brunt <- with(est.dat[ix],
                         lm(as.numeric(f.brunt) ~ as.numeric(rsd / rsdmax)))
      lmod.idso <- with(est.dat[ix],
                        lm(as.numeric(f.idso) ~ as.numeric(rsd / rsdmax)))
      isct.brunt <- coef(lmod.brunt)[1]
      isct.idso <- coef(lmod.idso)[1]
      # Force models to explain (x, y) == (1, 1)
      # because fcorr_a + fcorr_b must = 1.
      # Intersect of model taken from original linear regression.
      mod.brunt <- lm(c(isct.brunt, 1) ~ c(0, 1))
      mod.idso <- lm(c(isct.idso, 1) ~ c(0, 1))
    } else {
      lmod <- with(est.dat[ix], 
                   lm(as.numeric(f) ~ as.numeric(rsd / rsdmax)))
      # See previous comment.
      mod <- lm(c(coef(lmod)[1], 1) ~ c(0, 1))
    }
    # suggested model by Shuttleworth in Maidment (1993)
    mod.maid <- lm(c(-0.35, 1) ~ c(0, 1))

    if (plots) {
      if (emismeth == "both") {
        pdf("../doku/fig/plot_fcorr_both.pdf")
        par(mfrow=c(2, 1), mar=c(3, 4, 1, 1))
        # plot data with Brunt model
        with(est.dat[ix],
             plot(as.numeric(rsd / rsdmax), as.numeric(f.brunt),
                  xaxt="n", main="", xlab="", ylab="fcorr"))
        axis(1, at=seq(0, 1, 0.2), labels=seq(0, 1, 0.2))
        abline(mod.brunt, col=4)
        abline(mod.maid, lty="dashed", col=4)
        legend("topleft", c("adapted regression", "Maidment (1993)"),
               lty=c("solid", "dashed"), col=c(4, 4))
        text(0.5, 1.2, "emis: Brunt (1932)")
        par(mar=c(4, 4, 0, 1))
        with(est.dat[ix],
             plot(as.numeric(rsd / rsdmax), as.numeric(f.idso),
                  main="", xlab=(R[inS]/R[inS*","*cs]),
                  ylab="fcorr"))
        abline(mod.idso, col=4)
        abline(mod.maid, lty="dashed", col=4)
        legend("topleft", c("adapted regression", "Maidment (1993)"),
               lty=c("solid", "dashed"), col=c(4, 4))
        text(0.5, 1.3, "emis: Idso & Jackson (1969)")
        dev.off()
      } else {
        with(est.dat[ix],
             plot(as.numeric(rsd / rsdmax), as.numeric(f),
                  main=emismeth, xlab=(R[inS]/R[inS,cs]),
                  ylab="fcorr"))
        abline(mod, col=4)
        abline(mod.maid, lty="dashed", col=4)
        legend("topleft", c("adapted regression", "Maidment (1993)"),
               lty=c("solid", "dashed"), col=c(4, 4))
      }
    }

    # return parameters
    if (emismeth == "both") {
      return(data.frame(Method=c("Brunt", "Idso & Jackson"),
                        a=c(as.numeric(coef(mod.brunt)[2]),
                            as.numeric(coef(mod.idso)[2])),
                        b=c(as.numeric(coef(mod.brunt)[1]),
                            as.numeric(coef(mod.idso)[1]))))
    } else {
      return(data.frame(a=as.numeric(coef(mod)[2]),  # fcorr_a
                        b=as.numeric(coef(mod)[1])))  # fcorr_b
    }

  } else if (length(grep("emis", parname)) != 0) {
  # estimation of emis parameters
  # requires: hr, rsd, rld, rlu, rx, ta, radex_a, radex_b

    # collect estimation data
    est.dat <- GenerateEstDat(c("rsd", "rx", "rld", "rlu", "ta", "hr"))
    est.dat$rsdmax <- (radex_a + radex_b) * est.dat$rx

    # calculate vapor pressure, Magnus equation
    est.dat$vap <- VapMagnus(est.dat$ta, est.dat$hr)
    sig <- 5.670367E-8  # Stefan constant

    # compare "observed" emissivity with models of Brunt and Idso-Jackson:
    # (1) select times when global radiation is approximately "clear-sky"
    ix.rsdmax <- with(est.dat, rsd / rsdmax > .9 & rsd / rsdmax <= 1)
    # (2) select noon hours (10 am to 2 pm); just out of interest
    ix.noon <- as.numeric(format(index(est.dat), "%H")) > 9 &
               as.numeric(format(index(est.dat), "%H")) < 15 &
               ix.rsdmax  # take only noon hours from pre-selected data
    # (3) calculate net emissivity with Stefan-Boltzmann (f assumed to be 1)
    est.dat$emis <- with(est.dat[ix.rsdmax],
                         - (rld - rlu) / (sig * (ta + 273.15) ^ 4))
    # (4) plot observation-based emissivity against models
    pdf(paste0("../doku/fig/plot_emis_both_", fs, ".pdf"), height=5, width=9)
    par(mfrow=c(1, 2))
    with(est.dat[ix.rsdmax & !ix.noon],
         plot(as.numeric(EmisBrunt(0.34, -0.14,
                                   est.dat[ix.rsdmax & !ix.noon]$vap / 10)),
              emis, xlim=c(0, 0.25), ylim=c(0, 0.25),
              xlab=expression(epsilon*", predicted by Brunt model"),
              ylab=expression(epsilon*", derived from observations")))
    with(est.dat[ix.noon],
         points(as.numeric(EmisBrunt(0.34, -0.14,
                                     est.dat[ix.noon]$vap / 10)),
                emis, pch=20))
    lines(0:1, 0:1)
    legend("topleft", c("noon", "rest of day"), pch=c(20, 1), bty="n")
    with(est.dat[ix.rsdmax & !ix.noon],
         plot(as.numeric(EmisIdso(est.dat[ix.rsdmax & !ix.noon]$ta)),
              emis, xlim=c(0, 0.25), ylim=c(0, 0.25), ylab="",
              xlab=expression(epsilon*", predicted by Idso-Jackson model")))
    with(est.dat[ix.noon],
         points(as.numeric(EmisIdso(est.dat[ix.noon]$ta)),
                emis, pch=20))
    lines(0:1, 0:1)
    dev.off()

    # It's not possible to estimate emis_a, emis_b from the available data.
    return(c(.34, -.14))

  } else if (length(grep("f", parname)) != 0) {
  # estimation of soil heat fraction parameters
  # requires rnet, sheat
  # requires the RAtmosphere package!

    # collect estimation data
    est.dat <- GenerateEstDat(c("rnet", "sheat"))

    # divide into daytime and nighttime
    sun <- suncalc(as.numeric(format(index(est.dat$rnet), "%j")), lat, lon)
    ix.day <- as.numeric(format(index(est.dat$rnet), "%H")) > sun$sunrise &
              as.numeric(format(index(est.dat$rnet), "%H")) < sun$sunset
    ix.night <- as.numeric(format(index(est.dat$rnet), "%H")) < sun$sunrise |
                as.numeric(format(index(est.dat$rnet), "%H")) > sun$sunset
    est.dat$rnet.day <- est.dat$rnet[ix.day]
    est.dat$rnet.night <- est.dat$rnet[ix.night]
    est.dat$sheat.day <- est.dat$sheat[ix.day]
    est.dat$sheat.night <- est.dat$sheat[ix.night]
    names(est.dat)[1:2] <- c("rnet.day", "sheat.day")

    # diagnostic plots
    if (plots) {
      # time window
      t.win <- "2014-05-01/2014-05-20"
      # heat ratio
      heat.ratio.day <- with(est.dat[t.win],
                             abs(sheat.day) / abs(rnet.day))
      heat.ratio.night <- with(est.dat[t.win],
                               abs(sheat.night) / abs(rnet.night))
      # daytime plots
      plot(est.dat$sheat.day[t.win], ylim=c(-22, 750),
           ylab="black: sheat.day, red: rnet.day", main="")
      lines(est.dat$rnet.day, col=2)
      plot(heat.ratio.day, ylab="soil heat/net radiation", main="day")
      # nighttime plots
      plot(est.dat$sheat.night[t.win], ylim=c(-50, 100),
           ylab="black: sheat.night, red: rnet.night", main="")
      lines(est.dat$rnet.night, col=2)
      plot(heat.ratio.night, ylab="soil heat/net radiation", main="night")
    }

    # return parameters
    return(with(est.dat,
                c(# f_day
                  mean(c(abs(sheat.day) / abs(rnet.day)), na.rm=T),
                  # f_night
                  mean(c(abs(sheat.night) / abs(rnet.night)), na.rm=T))))

  } else {
    
    stop("Unknown parameter name. Possible choices: radex*, fcorr*, f*, emis*, alb.")
  
  }
  
}
