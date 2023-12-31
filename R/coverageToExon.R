#' Extract coverage information for exons
#'
#' This function extracts the coverage information calculated by
#' [fullCoverage] for a set of exons determined by
#' [makeGenomicState]. The underlying code is similar to
#' [getRegionCoverage] with additional tweaks for calculating RPKM values.
#'
#' @inheritParams getRegionCoverage
#' @inheritParams annotateRegions
#' @param L The width of the reads used. Either a vector of length 1 or length
#' equal to the number of samples.
#' @param returnType If `raw`, then the raw coverage information per exon
#' is returned. If `rpkm`, RPKM values are calculated for each exon.
#' @inheritParams fullCoverage
#' @param ... Arguments passed to other methods and/or advanced arguments.
#' Advanced arguments:
#' \describe{
#' \item{verbose }{ If `TRUE` basic status updates will be printed along
#' the way.}
#' \item{BPPARAM.strandStep }{ A BPPARAM object to use for the strand step. If
#' not specified, then `strandCores` specifies the number of cores to use
#' for the strand step. The actual number of cores used is the minimum of
#' `strandCores`, `mc.cores` and the number of strands in the data.}
#' \item{BPPARAM.chrStep }{ A BPPRAM object to use for the chr step. If not
#' specified, then `mc.cores` specifies the number of cores to use for
#' the chr step. The actual number of cores used is the minimum of
#' `mc.cores` and the number of samples.}
#' }
#' Passed to [extendedMapSeqlevels] and [define_cluster].
#'
#' @return A matrix (nrow = number of exons in `genomicState`
#' corresponding to the chromosomes in `fullCov`, ncol = number of
#' samples) with the number of reads (or RPKM) per exon. The row names
#' correspond to the row indexes of `genomicState$fullGenome`  (if
#' `fullOrCoding='full'`) or `genomicState$codingGenome` (if
#' `fullOrCoding='coding'`).
#'
#' @details
#' Parallelization is used twice.
#' First, it is used by strand. Second, for processing the exons by
#' chromosome. So there is no gain in using `mc.cores` greater than the
#' maximum of the number of strands and number of chromosomes.
#'
#' If `fullCov` is `NULL` and `files` is specified, this function
#' will attempt to read the coverage from the files. Note that if you used
#' 'totalMapped' and 'targetSize' before, you will have to specify them again
#' to get the same results.
#'
#' @author Andrew Jaffe, Leonardo Collado-Torres
#' @seealso [fullCoverage], [getRegionCoverage]
#' @export
#' @importFrom GenomicRanges seqnames
#' @importFrom GenomeInfoDb seqlevels renameSeqlevels
#' mapSeqlevels seqlevelsInUse
#' @importMethodsFrom GenomicRanges names 'names<-' length '[' coverage sort
#' width strand as.data.frame
#' @importMethodsFrom IRanges as.data.frame
#' @import S4Vectors
#' @importFrom BiocParallel bplapply bpmapply
#' @importFrom methods is
#'
#' @examples
#' ## Obtain fullCov object
#' fullCov <- list("21" = genomeDataRaw$coverage)
#'
#' ## Use only the first two exons
#' smallGenomicState <- genomicState
#' smallGenomicState$fullGenome <- smallGenomicState$fullGenome[
#'     which(smallGenomicState$fullGenome$theRegion == "exon")[1:2]
#' ]
#'
#' ## Finally, get the coverage information for each exon
#' exonCov <- coverageToExon(
#'     fullCov = fullCov,
#'     genomicState = smallGenomicState$fullGenome, L = 36
#' )
coverageToExon <- function(
        fullCov = NULL, genomicState, L = NULL,
        returnType = "raw", files = NULL, ...) {
    ## Run some checks
    stopifnot(length(intersect(returnType, c("raw", "rpkm"))) == 1)
    stopifnot(is(genomicState, "GRanges"))
    stopifnot("theRegion" %in% names(mcols(genomicState)))

    if (is.null(L)) {
        stop("'L' has to be specified")
    }

    ## Advanged argumentsa
    # @param verbose If \code{TRUE} basic status updates will be printed along the
    # way.
    verbose <- .advanced_argument("verbose", TRUE, ...)


    ## Use UCSC names for homo_sapiens by default
    genomicState <- renameSeqlevels(
        genomicState,
        extendedMapSeqlevels(seqlevels(genomicState), ...)
    )

    # just the reduced exons
    etab <- genomicState[genomicState$theRegion == "exon"]

    ## Load data if 'fullCov' is not specified
    if (is.null(fullCov)) {
        fullCov <- .load_fullCov(
            files = files, regs = etab,
            fun = "coverageToExon", verbose = verbose, ...
        )
    }
    ## Fix naming style
    names(fullCov) <- extendedMapSeqlevels(names(fullCov), ...)



    ## Check that the names are unique
    stopifnot(length(etab) == length(unique(names(etab))))

    ## Keep only the exons from the chromosomes in fullCov
    chrKeep <- names(fullCov)
    etab <- etab[seqnames(etab) %in% chrKeep]

    # split by strand
    strandIndexes <- split(seq_len(length(etab)), as.character(strand(etab)))

    # count reads covering exon on each strand
    strandCores <- min(.advanced_argument(
        "mc.cores", getOption("mc.cores", 1L),
        ...
    ), .advanced_argument(
        "strandCores", getOption("mc.cores", 1L),
        ...
    ), length(unique(runValue(strand(etab)))))

    ## Define cluster
    BPPARAM <- .advanced_argument(
        "BPPARAM.strandStep",
        define_cluster(cores = "strandCores", strandCores = strandCores), ...
    )
    if (verbose) print(BPPARAM)

    # Use at most n cores where n is the number of unique strands
    exonByStrand <- bplapply(strandIndexes, .coverageToExonStrandStep,
        fullCov = fullCov, etab = etab, L = L,
        nCores = .advanced_argument("mc.cores", getOption("mc.cores", 1L), ...),
        chromosomes = chrKeep, BPPARAM = BPPARAM, ...
    )

    # combine two strands
    exons <- do.call("rbind", exonByStrand)

    # put back in annotation order
    theExons <- exons[names(etab), ]

    if (returnType == "rpkm") {
        Mchr <- t(sapply(fullCov, function(z) {
            sapply(z, function(xx) {
                sum(as.numeric(runValue(xx)))
            })
        }))
        M <- colSums(Mchr) / L / 1e+06
        theExons <- theExons / (width(etab) / 1000) / M
    }
    return(theExons)
}

.coverageToExonStrandStep <- function(
        ii, fullCov, etab, L, nCores, chromosomes,
        ...) {
    verbose <- .advanced_argument("verbose", TRUE, ...)

    e <- etab[ii] # subset

    ## use logical rle to subset large coverage matrix
    cc <- coverage(e) # first coverage
    for (i in seq(along = cc)) {
        # then convert to logical
        cc[[i]]@values <- ifelse(cc[[i]]@values > 0, TRUE, FALSE)
    }

    ## Subset data
    # subset using logical rle (fastest way)
    subsets <- mapply(
        function(covInfo, chr) {
            subset(covInfo, cc[[chr]])
        },
        fullCov, chromosomes,
        SIMPLIFY = FALSE
    )

    # now count exons
    moreArgs <- list(e = e, L = L, verbose = verbose)

    ## Define cluster
    exonCores <- min(nCores, length(subsets))

    ## Define cluster
    BPPARAM.chrStep <- .advanced_argument(
        "BPPARAM.chrStep",
        define_cluster(cores = "exonCores", exonCores = exonCores), ...
    )
    if (verbose) print(BPPARAM.chrStep)

    ## Define ChrStep function
    .coverageToExonChrStep <- function(z.DF, chr, e, L, verbose) {
        if (verbose) {
            message(paste(Sys.time(), "coverageToExon: processing chromosome", chr))
        }

        ## Transform to regular data.frame
        z <- as.data.frame(z.DF)

        # only exons from this chr
        g <- e[seqnames(e) == chr]
        ind <- rep(names(g), width(g)) # to split
        tmpList <- split(z, ind) # split
        res <- t(sapply(tmpList, colSums)) # get # reads

        if (length(L) == 1) {
            res <- res / L
        } else if (length(L) == ncol(res)) {
            for (i in length(L)) res[, i] <- res[, i] / L[i]
        } else {
            warning("Invalid 'L' value so it won't be used. It has to either be a integer/numeric vector of length 1 or length equal to the number of samples.")
        }

        # done
        return(res)
    }

    ## Now run it
    exonList <- bpmapply(.coverageToExonChrStep, subsets, chromosomes,
        MoreArgs = moreArgs, BPPARAM = BPPARAM.chrStep, SIMPLIFY = FALSE
    )

    # combine
    out <- do.call("rbind", exonList)

    # done
    return(out)
}
