# install_packages.R for containerized pipeline

# Use a fast precompiled package mirror (Posit Package Manager) to speed up container build times
options(repos = c(CRAN = "https://packagemanager.posit.co/cran/__linux__/jammy/latest"))

required_packages <- c(
  "jsonlite",
  "DBI",
  "duckdb",
  "digest",
  "dplyr",
  "httr",
  "rvest",
  "xml2",
  "stringdist",
  "mRpostman",
  "RSQLite"
)

install_if_missing <- function(pkg) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    message(paste("Installing package:", pkg))
    install.packages(pkg)
  } else {
    message(paste("Package already installed:", pkg))
  }
}

invisible(sapply(required_packages, install_if_missing))

# Verify all packages load successfully
message("Verifying package imports...")
for (pkg in required_packages) {
  library(pkg, character.only = TRUE)
}
message("All R packages successfully installed and verified!")
