#' Identify regions data by a coverage filter and get a count matrix from
#' BigWig files
#'
#' Rail (available at http://rail.bio) generates coverage BigWig files. These
#' files are faster to load in R and to process. Rail creates an un-adjusted
#' coverage BigWig file per sample and an adjusted summary coverage BigWig file
#' by chromosome (median or mean). [railMatrix] reads in the mean (or
#' median) coverage BigWig file and applies a threshold cutoff to identify
#' expressed regions (ERs). Then it goes back to the sample coverage BigWig
#' files and extracts the base level coverage for each sample. Finally it
#' summarizes this information in a matrix with one row per ERs and one column
#' per sample. This function is similar to [regionMatrix] but is faster
#' thanks to the advantages presented by BigWig files.
#'
#' Given a set of un-filtered coverage data (see [fullCoverage]), create
#' candidate regions by applying a cutoff on the coverage values,
#' and obtain a count matrix where the number of rows corresponds to the number
#' of candidate regions and the number of columns corresponds to the number of
#' samples. The values are the mean coverage for a given sample for a given
#' region.
#'
#'
#' @param chrs A character vector with the names of the chromosomes.
#' @param summaryFiles A character vector (or BigWigFileList) with the paths to
#' the summary BigWig files created by Rail. Either mean or median files. These
#' are library size adjusted by default in Rail. The order of the files in this
#' vector must match the order in `chrs`.
#' @param sampleFiles A character vector with the paths to the BigWig files
#' by sample. These files are unadjusted for library size.
#' @param targetSize The target library size to adjust the coverage to. Used
#' only when `totalMapped` is specified. By default, it adjusts to
#' libraries with 40 million reads, which matches the default used in Rail.
#' @inheritParams filterData
#' @param L The width of the reads used. Either a vector of length 1 or length
#' equal to the number of samples.
#' @param maxClusterGap This determines the maximum gap between candidate ERs.
#' @param file.cores Number of cores used for loading the BigWig files per chr.
#' @param chrlens The chromosome lengths in base pairs. If it's `NULL`,
#' the chromosome length is extracted from the BAM files. Otherwise, it should
#' have the same length as `chrs`.
#' @param ... Arguments passed to other methods and/or advanced arguments.
#' Advanced arguments:
#' \describe{
#' \item{verbose }{ If `TRUE` basic status updates will be printed along
#' the way. Default: `TRUE`.}
#' \item{verbose.load }{ If `TRUE` basic status updates will be printed
#' along the way when loading data. Default: `TRUE`.}
#' \item{BPPARAM.railChr }{ A BPPARAM object to use for the chr step. Set to
#' [SerialParam][BiocParallel::SerialParam-class] when `file.cores = 1` and
#' [SnowParam][BiocParallel::SnowParam-class] otherwise.}
#' \item{chunksize }{ Chunksize to use. Default: 1000.}
#' }
#' Passed to [filterData], [findRegions] and [define_cluster].
#'
#' @return A list with one entry per chromosome. Then per chromosome, a list
#' with two components.
#' \describe{
#' \item{regions }{ A set of regions based on the coverage filter cutoff as
#' returned by [findRegions].}
#' \item{coverageMatrix }{  A matrix with the mean coverage by sample for each
#' candidate region.}
#' }
#'
#' @details This function uses several other [derfinder-package]
#' functions. Inspect the code if interested.
#'
#' You should use at most one core per chromosome.
#'
#' @author Leonardo Collado-Torres
#' @export
#'
#' @importFrom BiocParallel bpmapply
#' @importFrom GenomeInfoDb 'seqlengths<-'
#' @importMethodsFrom GenomicRanges reduce
#' @importFrom stats runif
#'
#' @examples
#'
#' ## BigWig files are not supported in Windows
#' if (.Platform$OS.type != "windows") {
#'     ## Get data
#'     library("derfinderData")
#'
#'     ## Identify sample files
#'     sampleFiles <- rawFiles(system.file("extdata", "AMY",
#'         package =
#'             "derfinderData"
#'     ), samplepatt = "bw", fileterm = NULL)
#'     names(sampleFiles) <- gsub(".bw", "", names(sampleFiles))
#'
#'     ## Create the mean bigwig file. This file is normally created by Rail
#'     ## but in this example we'll create it manually.
#'     library("GenomicRanges")
#'     fullCov <- fullCoverage(files = sampleFiles, chrs = "chr21")
#'     meanCov <- Reduce("+", fullCov$chr21) / ncol(fullCov$chr21)
#'     createBw(list("chr21" = DataFrame("meanChr21" = meanCov)),
#'         keepGR =
#'             FALSE
#'     )
#'
#'     summaryFile <- "meanChr21.bw"
#'
#'     ## Get the regions
#'     regionMat <- railMatrix(
#'         chrs = "chr21", summaryFiles = summaryFile,
#'         sampleFiles = sampleFiles, L = 76, cutoff = 5.1,
#'         maxClusterGap = 3000L
#'     )
#'
#'     ## Explore results
#'     names(regionMat$chr21)
#'     regionMat$chr21$regions
#'     dim(regionMat$chr21$coverageMatrix)
#' }
railMatrix <- function(
        chrs, summaryFiles, sampleFiles, L, cutoff = NULL,
        maxClusterGap = 300L, totalMapped = NULL, targetSize = 40e6,
        file.cores = 1L, chrlens = NULL, ...) {
    stopifnot(length(chrs) == length(summaryFiles))
    ## In the future, summaryFiles might be a vector or a list, but the length
    ## check must be maintained. It might be a list if the mean bigwig info
    ## is split into different files.

    ## Have to filter by something
    stopifnot(!is.null(cutoff))
    stopifnot(length(L) != 1 | length(L) != length(sampleFiles))
    if (!is.null(totalMapped)) stopifnot(length(totalMapped) != 1 | length(totalMapped) != length(sampleFiles))

    ## Verbose value
    verbose <- .advanced_argument("verbose", TRUE, ...)
    verbose.load <- .advanced_argument("verbose.load", TRUE, ...)

    ## For the bpmapply call to work
    if (is.null(chrlens)) chrlens <- rep(list(NULL), length(chrs))

    ## Define cluster used for per chromosome
    BPPARAM <- define_cluster(...)

    ## Define cluster used for loading BigWig files
    if (file.cores == 1L) {
        BPPARAM.railChr <- .advanced_argument(
            "BPPARAM.railChr", SerialParam(),
            ...
        )
    } else {
        mc.log <- .advanced_argument("mc.log", TRUE, ...)
        BPPARAM.railChr <- .advanced_argument(
            "BPPARAM.railChr",
            SnowParam(workers = file.cores, log = mc.log), ...
        )
    }

    if (!is.null(totalMapped) & targetSize != 0) {
        mappedPerXM <- totalMapped / targetSize
    } else {
        mappedPerXM <- rep(list(NULL), length(sampleFiles))
    }

    ## Chunksize to use
    chunksize <- .advanced_argument("chunksize", 1000, ...)


    regionMat <- bpmapply(.railMatrixChr, chrs, summaryFiles, chrlens,
        SIMPLIFY = FALSE, MoreArgs = list(
            sampleFiles = sampleFiles, L = L,
            maxClusterGap = maxClusterGap, cutoff = cutoff,
            mappedPerXM = mappedPerXM, regionschunk = chunksize,
            BPPARAM.railChr = BPPARAM.railChr, verbose = verbose,
            verboseLoad = verbose.load, ...
        ),
        BPPARAM = BPPARAM
    )
    return(regionMat)
}


.railMatrixChr <- function(
        chr, summaryFile, chrlen, sampleFiles, L = NULL,
        cutoff = NULL, maxClusterGap = 300L, mappedPerXM = mappedPerXM,
        regionschunk = 1000, BPPARAM.railChr = BPPARAM.railChr, verbose = TRUE,
        verboseLoad = TRUE, ...) {
    meanCov <- loadCoverage(files = summaryFile, chr = chr, chrlen = chrlen)

    filteredMean <- filterData(meanCov$coverage, cutoff = cutoff, filter = "mean", returnMean = TRUE, ...)
    regs <- findRegions(
        position = filteredMean$position,
        fstats = filteredMean$meanCoverage, chr = chr,
        maxClusterGap = maxClusterGap, cutoff = cutoff, verbose = verbose, ...
    )

    ## If there are no regions, return NULL
    if (is.null(regs)) {
        return(list(regions = GRanges(), coverageMatrix = NULL))
    }

    ## Format appropriately
    names(regs) <- seq_len(length(regs))

    ## Set the length
    seqlengths(regs) <- length(meanCov$coverage[[1]])

    ## No longer needed, delete to save memory
    rm(meanCov)

    ## Get coverage matrix by chunks of regions
    nChunks <- length(regs) %/% regionschunk
    if (length(regs) %% regionschunk > 0) nChunks <- nChunks + 1

    ## Split regions into chunks
    if (nChunks == 1) {
        regs_split <- list(regs)
        names(regs_split) <- "1"
    } else {
        regs_split <- split(regs, cut(seq_len(length(regs)),
            breaks = nChunks, labels = FALSE
        ))
    }

    ## Actually calculate the coverage matrix
    resChunks <- lapply(regs_split, .railMatChrRegion,
        sampleFiles = sampleFiles, chr = chr, mappedPerXM = mappedPerXM,
        L = L, verbose = verbose, BPPARAM.railChr = BPPARAM.railChr,
        verboseLoad = verboseLoad, chrlen = chrlen
    )


    ## Finish
    result <- list(
        regions = regs,
        coverageMatrix = do.call(rbind, lapply(
            resChunks, "[[",
            "coverageMatrix"
        ))
    )
    return(result)
}

.railMatChrRegion <- function(
        regions, sampleFiles, chr, mappedPerXM, L,
        verbose = TRUE, verboseLoad = TRUE, chrlen, BPPARAM.railChr) {
    if (verbose) message(paste(Sys.time(), "railMatrix: processing regions", paste(range(as.integer(names(regions))), collapse = " to ")))

    ## Get the region coverage matrix
    covMat <- bpmapply(.railMatChrRegionCov, sampleFiles, mappedPerXM, L,
        BPPARAM = BPPARAM.railChr, MoreArgs = list(
            chr = chr, regs = regions,
            verbose = verboseLoad
        )
    )

    ## For the case when length(regions) == 1
    if (is.vector(covMat)) covMat <- as.matrix(t(covMat))

    ## Name approopriately if possible
    if (!any(is.na(match(colnames(covMat), sampleFiles)))) {
        colnames(covMat) <- names(sampleFiles)[match(colnames(covMat), sampleFiles)]
    }

    ## Finish
    res <- list(coverageMatrix = covMat)
    return(res)
}

.railMatChrRegionCov <- function(
        sampleFile, mappedPerXM, L, chr, regs,
        verbose = TRUE) {
    if (verbose) message(paste(Sys.time(), "railMatrix: processing file", sampleFile))

    ## Based on http://bioconductor.org/developers/how-to/web-query/
    ## and https://github.com/leekgroup/recount/commit/8da982b309e2d19638166f263057d9f85bb64e3f
    N.TRIES <- 3L
    while (N.TRIES > 0L) {
        regCov <- tryCatch(
            import(sampleFile, selection = reduce(regs), as = "RleList"),
            error = identity
        )
        if (!inherits(regCov, "error")) {
            break
        }
        Sys.sleep(runif(n = 1, min = 2, max = 5))
        N.TRIES <- N.TRIES - 1L
    }
    if (N.TRIES == 0L) stop(conditionMessage(regCov))

    regCov <- regCov[[chr]]
    if (!is.null(mappedPerXM)) {
        regCov <- regCov / mappedPerXM
    }
    sum(Views(regCov, ranges(regs))) / L
}
