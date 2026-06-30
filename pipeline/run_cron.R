# Daily Cron Ingestion Orchestrator
#
# Unified pure R pipeline entry point for unattended daily ingestion.
# Handles Emails, RSS, Telegram, and Fediverse.

# Ensure we run from the project root directory
if (!file.exists("pipeline_runner.R")) {
    stop("Error: Must run from pipeline root directory.")
}

library(jsonlite)
library(DBI)
library(RPostgres)

# 1. Load credentials into environment
if (file.exists("credentials.json")) {
    creds <- jsonlite::read_json("credentials.json")
    for (key in names(creds)) {
        if (Sys.getenv(key) == "") {
            args <- list(creds[[key]])
            names(args) <- key
            do.call(Sys.setenv, args)
        }
    }
    message("[Cron] Credentials loaded successfully.")
} else {
    message("[Cron] Warning: credentials.json not found. Relying on existing environment variables.")
}

# 2. Source pipeline and components
source("pipeline_runner.R")

# 3. Load Dynamic Sources
message("[Cron] Loading dynamic sources from Postgres survey.sources...")
database_url <- Sys.getenv("DATABASE_URL", "postgresql://pushmedia:pushmedia@postgres:5432/pushmedia")
con <- tryCatch({
    postgres_connect_url(database_url)
}, error = function(e) {
    stop("Failed to connect to Postgres sources database: ", e$message)
})

sources <- tryCatch({
    DBI::dbGetQuery(con, "SELECT platform, source_name, ingest_url FROM survey.sources WHERE is_deleted = FALSE")
}, error = function(e) {
    stop("Failed to query sources database: ", e$message)
})
DBI::dbDisconnect(con)

# Parse RSS Feeds
rss_rows <- sources[sources$platform == "rss", ]
rss_feeds <- as.list(setNames(rss_rows$ingest_url, rss_rows$source_name))

# Parse Telegram Channels
telegram_rows <- sources[sources$platform == "telegram", ]
telegram_channels <- sub(".*/([^/]+)$", "\\1", telegram_rows$ingest_url)

# Parse Fediverse Handles
fediverse_rows <- sources[sources$platform == "fediverse", ]
fediverse_handles <- sapply(fediverse_rows$ingest_url, function(url) {
    if (grepl("^http", url)) {
        domain <- sub("https?://([^/]+)/.*", "\\1", url)
        handle <- sub(".*/(@.*)$", "\\1", url)
        return(paste0(handle, "@", domain))
    } else {
        return(url)
    }
})
fediverse_handles <- unname(fediverse_handles)

message(sprintf("[Cron] Loaded %d RSS feeds, %d Telegram channels, %d Fediverse handles.", length(rss_feeds), length(telegram_channels), length(fediverse_handles)))

# 4. Execute Pipeline
message("=== Starting Daily Pipeline Ingestion ===")

# --- BELT AND BRACES: Python Fallback ---
# If the pure R email ingestion (`fetch_new_emails`) ever struggles with MIME parsing again,
# you can disable the R email ingestion in pipeline_runner.R and uncomment the python execution below:
# 
# message("[Cron] Running Python Email Ingester (Belt & Braces)...")
# system("python3 python_email_ingester.py")
# ----------------------------------------

# Run the native R orchestrator (which automatically does Emails, RSS, Telegram, Fediverse)
run_pipeline(
    rss_feeds = rss_feeds,
    telegram_channels = telegram_channels,
    fediverse_handles = fediverse_handles
)

message("=== Daily Pipeline Ingestion Completed ===")
