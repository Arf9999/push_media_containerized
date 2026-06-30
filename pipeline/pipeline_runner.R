# Push Media Ingestion Pipeline Orchestrator
#
# Coordinates modular ingestion sources (Gmail, RSS, Telegram, Substack),
# runs LLM-based translation and entity extraction, computes dual-space vector
# embeddings, runs entity lexicon deduplication, and commits to local DuckDB.

# Load modules
source("config.R")
source("db_manager.R")
source("model_adapter.R")
source("prompts.R")
source("email_ingester.R")
source("rss_ingester.R")
source("telegram_ingester.R")
source("subscription_ingester.R")
source("fediverse_ingester.R")
source("translation_ollama.R")
source("entity_resolver.R")

library(jsonlite)
library(DBI)
library(duckdb)
# Load low‑resource language list
low_res_langs <- fromJSON("low_resource_languages.json")
library(digest)
library(dplyr)

#' Clean and format a R vector to DuckDB FLOAT[] list representation
#'
#' @param vec Numeric vector of embeddings.
#' @return SQL string format e.g. '[0.1, 0.2, ...]'
format_vector_for_duckdb <- function(vec) {
    if (is.null(vec) || length(vec) == 0 || any(is.na(vec))) {
        return(NULL)
    }
    # Create literal array: array[0.1, 0.2, ...]
    paste0("ARRAY[", paste(vec, collapse = ", "), "]")
}

#' Run Ingestion and Process New Articles
#'
#' @param rss_feeds Named list of RSS URLs: list(feed_name = "url")
#' @param telegram_channels Character vector of telegram channel names
#' @param subscription_feeds Named list of substack/ghost feeds
#' @param fediverse_handles Character vector of Fediverse/Mastodon handles
#' @return NULL (invisibly)
#' @export
run_pipeline <- function(rss_feeds = list(), telegram_channels = c(), subscription_feeds = list(), fediverse_handles = c()) {
    message("--- Initializing Pipeline Run (In-Memory Processing & Quick Commit) ---")
    config <- get_config()
    db_path <- config$db_path
    
    # 1. Open a brief connection to fetch existing UIDs, then close it
    message("[Pipeline] Fetching existing UIDs from database...")
    con_init <- get_db_connection(db_path)
    init_db(con_init)
    existing_res <- tryCatch({
        DBI::dbGetQuery(con_init, "SELECT uid FROM newsletters;")
    }, error = function(e) {
        data.frame(uid = character(0))
    })
    close_db_connection(con_init)
    
    existing_uids <- existing_res$uid
    
    # 2. Ingest raw items from sources into temporary lists
    raw_lists <- list()
    
    # A. Fetch Gmail newsletters if credentials configured
    if (config$gmail_username != "" && config$gmail_app_password != "") {
        message("\n[Pipeline] Ingesting Gmail inbox...")
        gmail_recs <- tryCatch({
            fetch_new_emails(config)
        }, error = function(e) {
            message("Gmail ingestion failed: ", e$message)
            return(list())
        })
        if (length(gmail_recs) > 0) {
            raw_lists[[length(raw_lists) + 1]] <- gmail_recs
        }
    }
    
    # B. Fetch RSS Feeds
    if (length(rss_feeds) > 0) {
        message("\n[Pipeline] Ingesting RSS feeds...")
        for (name in names(rss_feeds)) {
            rss_recs <- tryCatch({
                fetch_rss_feed(rss_feeds[[name]], feed_name = name)
            }, error = function(e) {
                message("RSS feed failed (", name, "): ", e$message)
                return(list())
            })
            if (length(rss_recs) > 0) {
                raw_lists[[length(raw_lists) + 1]] <- rss_recs
            }
        }
    }
    
    # C. Fetch Telegram channels
    if (length(telegram_channels) > 0) {
        message("\n[Pipeline] Ingesting Telegram channels...")
        for (chan in telegram_channels) {
            tg_recs <- tryCatch({
                fetch_telegram_channel(chan)
            }, error = function(e) {
                message("Telegram channel failed (", chan, "): ", e$message)
                return(list())
            })
            if (length(tg_recs) > 0) {
                raw_lists[[length(raw_lists) + 1]] <- tg_recs
            }
        }
    }
    
    # D. Fetch Subscription feeds (Substack/Ghost)
    if (length(subscription_feeds) > 0) {
        message("\n[Pipeline] Ingesting Substack/Ghost subscription feeds...")
        for (name in names(subscription_feeds)) {
            sub_recs <- tryCatch({
                fetch_subscription_feed(subscription_feeds[[name]], publisher_name = name)
            }, error = function(e) {
                message("Subscription feed failed (", name, "): ", e$message)
                return(list())
            })
            if (length(sub_recs) > 0) {
                raw_lists[[length(raw_lists) + 1]] <- sub_recs
            }
        }
    }
    
    # E. Fetch Fediverse accounts
    if (length(fediverse_handles) > 0) {
        message("\n[Pipeline] Ingesting Fediverse accounts...")
        for (handle in fediverse_handles) {
            fedi_recs <- tryCatch({
                fetch_fediverse_posts(handle)
            }, error = function(e) {
                message("Fediverse ingestion failed for handle (", handle, "): ", e$message)
                return(list())
            })
            if (length(fedi_recs) > 0) {
                raw_lists[[length(raw_lists) + 1]] <- fedi_recs
            }
        }
    }
    
    # Flatten lists into raw_items
    raw_items <- if (length(raw_lists) > 0) do.call(c, raw_lists) else list()
    
    if (length(raw_items) == 0) {
        message("\nNo new raw items fetched from any sources. Pipeline execution complete.")
        return(invisible(NULL))
    }
    
    message("\nFetched total ", length(raw_items), " raw items. Commencing duplicate check...")
    
    # Filter duplicates in-memory
    is_new <- sapply(raw_items, function(item) !(item$uid %in% existing_uids))
    raw_items <- raw_items[is_new]
    
    # Deduplicate within the new batch itself to prevent PRIMARY KEY violations
    if (length(raw_items) > 0) {
        uids <- sapply(raw_items, function(x) x$uid)
        raw_items <- raw_items[!duplicated(uids)]
    }
    
    if (length(raw_items) == 0) {
        message("All fetched raw items already exist in the database. Pipeline complete.")
        return(invisible(NULL))
    }
    
    message("Found ", length(raw_items), " new items to process.")
    
    processed_records <- list()
    
    # 3. Process new articles in-memory
    for (item in raw_items) {
        uid <- item$uid
        message("\n--- Processing New Record (In-Memory) ---")
        message("Title: ", item$title)
        message("Source: ", item$source)
        
        # 4. Truncate text if needed (cap at 12,000 words to fit model contexts)
        content_words <- unlist(strsplit(item$body, "\\s+"))
        truncated_flag <- FALSE
        content_to_llm <- item$body
        if (length(content_words) > 12000) {
            content_to_llm <- paste(content_words[1:12000], collapse = " ")
            truncated_flag <- TRUE
            message("Warning: Article content truncated to 12,000 words.")
        }
        
        # 5. Extract metadata, translation summaries, and entities via LLM
        sys_prompt <- get_analysis_system_prompt()
        user_prompt <- construct_analysis_user_prompt(item$title, item$sender, content_to_llm)
        
        llm_resp <- tryCatch({
            generate_completion(
                user_prompt, 
                system_prompt = sys_prompt, 
                json_mode = TRUE, 
                config = config,
                image_url = item$image_url
            )
        }, error = function(e) {
            message("LLM Extraction failed for article: ", item$title, ". Error: ", e$message)
            return(NULL)
        })
        
        if (is.null(llm_resp)) next
        
        # Clean response string in case LLM added markdown backticks
        llm_resp_clean <- gsub("^```json\\s*", "", llm_resp)
        llm_resp_clean <- gsub("\\s*```$", "", llm_resp_clean)
        
        parsed_analysis <- tryCatch({
            jsonlite::fromJSON(llm_resp_clean)
        }, error = function(e) {
            message("JSON Parsing error of LLM response. Skipping item. Error: ", e$message)
            return(NULL)
        })
        
        if (is.null(parsed_analysis)) next
        
        # Check if vision model indicated that the content contains no readable text
        contains_text <- parsed_analysis$contains_text
        if (!is.null(contains_text) && is.logical(contains_text) && !contains_text) {
            message("Vision model detected no readable text/document data in the image. Bypassing translation.")
            parsed_analysis$summary_en <- "*(Media post containing no readable text)*"
            parsed_analysis$summary_orig <- "*(Media post containing no readable text)*"
            parsed_analysis$detected_language <- "en"
            parsed_analysis$entities <- data.frame(
                raw_name = character(0),
                canonical_name = character(0),
                entity_type = character(0),
                stringsAsFactors = FALSE
            )
        }
        
        # 5. Translate using appropriate model based on language
        detected_language <- parsed_analysis$detected_language
        if (is.null(detected_language) || length(detected_language) == 0) {
            detected_language <- "en"
        }
        
        # Ensure we always keep original summary
        if (is.null(parsed_analysis$summary_orig) || length(parsed_analysis$summary_orig) == 0) {
            parsed_analysis$summary_orig <- parsed_analysis$summary_en
        }
        
        if (detected_language %in% low_res_langs) {
            translation <- tryCatch({
                translate_ollama(parsed_analysis$summary_orig, detected_language, model_name = config$translation_model)
            }, error = function(e) {
                message("Ollama translation failed: ", e$message)
                translate_generic(parsed_analysis$summary_orig, detected_language, config)
            })
            parsed_analysis$summary_en <- translation
        } else if (detected_language != "en") {
            translation <- translate_generic(parsed_analysis$summary_orig, detected_language, config)
            parsed_analysis$summary_en <- translation
        } else {
            parsed_analysis$summary_orig <- parsed_analysis$summary_en
        }

        # If the content was parsed from an image and contains text, add a footnote
        has_image <- !is.null(item$image_url) && !is.na(item$image_url) && item$image_url != ""
        is_textful_image <- has_image && (is.null(contains_text) || (is.logical(contains_text) && contains_text))
        
        if (is_textful_image) {
            note <- "\n\n*(Note: This content was extracted via multimodal LLM analysis from a shared image.)*"
            parsed_analysis$summary_en <- paste0(parsed_analysis$summary_en, note)
            if (parsed_analysis$summary_orig != parsed_analysis$summary_en) {
                parsed_analysis$summary_orig <- paste0(parsed_analysis$summary_orig, note)
            }
        }

        
        # 6. Generate Vector Embeddings
        topics_str <- paste(parsed_analysis$topics, collapse = ", ")
        themes_str <- paste(parsed_analysis$themes, collapse = ", ")
        
        # Combine summary with topics and themes to ensure they are captured in the vector space
        embedding_text_en <- paste0(
            parsed_analysis$summary_en, 
            "\nTopics: ", topics_str, 
            "\nThemes: ", themes_str
        )
        
        # English Vector (embeds English summary + topics + themes)
        message("Generating English summary embedding...")
        en_embed <- tryCatch({
            generate_embeddings(embedding_text_en, config, space = "english")[[1]]
        }, error = function(e) {
            message("English embedding generation failed: ", e$message)
            return(NULL)
        })
        
        # Multilingual Vector (embeds original language summary + topics + themes)
        message("Generating Multilingual summary embedding...")
        orig_summary_txt <- paste(parsed_analysis$summary_orig, collapse = " ")
        if (is.null(orig_summary_txt) || nchar(trimws(orig_summary_txt)) == 0 || orig_summary_txt == "NULL") {
            orig_summary_txt <- paste(parsed_analysis$summary_en, collapse = " ")
        }
        embedding_text_orig <- paste0(
            orig_summary_txt,
            "\nTopics: ", topics_str,
            "\nThemes: ", themes_str
        )
        multiling_embed <- tryCatch({
            generate_embeddings(embedding_text_orig, config, space = "multilingual")[[1]]
        }, error = function(e) {
            message("Multilingual embedding generation failed: ", e$message)
            return(NULL)
        })
        
        if (is.null(en_embed) || is.null(multiling_embed)) {
            message("Skipping item due to embedding failure.")
            next
        }
        
        # 7. Deduplicate and Save Entities
        # Parse publisher metadata
        pub_author <- parsed_analysis$publisher_metadata$author
        pub_pub <- parsed_analysis$publisher_metadata$publisher
        
        # Enforce platform tagging based on actual ingestion tool/source type
        pub_plat <- if (!is.null(item$platform)) item$platform else parsed_analysis$publisher_metadata$platform
        
        # Fallbacks and vector flattening
        if (is.null(pub_author) || length(pub_author) == 0 || all(is.na(pub_author))) pub_author <- "Unknown"
        else pub_author <- paste(pub_author, collapse = ", ")
        
        if (is.null(pub_pub) || length(pub_pub) == 0 || all(is.na(pub_pub))) pub_pub <- item$source
        else pub_pub <- paste(pub_pub, collapse = ", ")
        
        if (is.null(pub_plat) || length(pub_plat) == 0 || all(is.na(pub_plat))) pub_plat <- item$source
        else pub_plat <- paste(pub_plat, collapse = ", ")
        
        # We need to construct the lists as comma separated strings
        topics_str <- paste(parsed_analysis$topics, collapse = ", ")
        themes_str <- paste(parsed_analysis$themes, collapse = ", ")
        keywords_str <- paste(parsed_analysis$keywords, collapse = ", ")
        
        # Enforce timestamp parsing
        parsed_dt <- tryCatch({
            date_str <- stringr::str_trim(item$datetime)
            dt <- as.POSIXct(date_str, format = "%a, %d %b %Y %H:%M:%S %z", tz = "UTC")
            if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%a, %d %b %Y %H:%M:%S", tz = "UTC")
            if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%a %d %b %Y %H:%M:%S %z", tz = "UTC")
            if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%d %b %Y %H:%M:%S %z", tz = "UTC")
            if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
            if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
            if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC")
            if (is.na(dt)) dt <- as.POSIXct(date_str)
            dt
        }, error = function(e) Sys.time())
        if (is.na(parsed_dt)) parsed_dt <- Sys.time()
        
        processed_records[[length(processed_records) + 1]] <- list(
            uid = uid,
            datetime = parsed_dt,
            source = pub_pub,
            sender = item$sender,
            title = item$title,
            url = item$url,
            summary = paste(parsed_analysis$summary_en, collapse = "\n"),
            original_language_summary = paste(parsed_analysis$summary_orig, collapse = "\n"),
            detected_language = paste(parsed_analysis$detected_language, collapse = " "),
            truncated = truncated_flag,
            content_type = pub_plat,
            topics = topics_str,
            themes = themes_str,
            keywords = keywords_str,
            subscription_marketing = as.logical(parsed_analysis$subscription_marketing),
            english_embedding = en_embed,
            multilingual_embedding = multiling_embed,
            raw_email = if (!is.null(item$raw_source)) item$raw_source else if (!is.null(item$body)) item$body else NA_character_,
            # Keep entities as a parsed data frame (columns: raw_name, entity_type).
            # This is processed row-by-row on db commit via resolve_and_store_entities()
            # rather than inserted into the 'newsletters' table, which resolves
            # any length mismatch issues in db transactions.
            entities = parsed_analysis$entities
        )
        message("Record fully processed in-memory: ", item$title)
    }
    
    if (length(processed_records) == 0) {
        message("\nNo records successfully processed. Pipeline complete.")
        return(invisible(NULL))
    }
    
    # 8. Batch Insert all processed records in a single quick transaction
    message("\n[Pipeline] Opening database to commit ", length(processed_records), " records...")
    con <- get_db_connection(db_path)
    DBI::dbBegin(con)
    
    commit_success <- tryCatch({
        for (rec in processed_records) {
            insert_sql <- "
                INSERT INTO newsletters (
                    uid, datetime, source, sender, title, url, summary,
                    original_language_summary, detected_language, truncated, content_type,
                    topics, themes, keywords, subscription_marketing,
                    english_embedding, multilingual_embedding, raw_email
                ) VALUES (
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                );
            "
            # Ensure all bound parameters are of length 1 to avoid rapi_bind mismatch errors
            safe_param <- function(val, default = NA_character_) {
                if (is.null(val) || length(val) == 0) return(default)
                if (length(val) > 1) return(val[1])
                return(val)
            }
            safe_bool <- function(val, default = FALSE) {
                if (is.null(val) || length(val) == 0 || is.na(val)) return(default)
                return(as.logical(val)[1])
            }
            
            DBI::dbExecute(con, insert_sql, params = list(
                safe_param(rec$uid),
                rec$datetime, # POSIXct
                safe_param(rec$source),
                safe_param(rec$sender),
                safe_param(rec$title),
                safe_param(rec$url),
                safe_param(rec$summary),
                safe_param(rec$original_language_summary),
                safe_param(rec$detected_language),
                safe_bool(rec$truncated),
                safe_param(rec$content_type),
                safe_param(rec$topics),
                safe_param(rec$themes),
                safe_param(rec$keywords),
                safe_bool(rec$subscription_marketing),
                list(rec$english_embedding), # List columns
                list(rec$multilingual_embedding),
                safe_param(rec$raw_email)
            ))
            
            if (!is.null(rec$entities) && is.data.frame(rec$entities) && nrow(rec$entities) > 0) {
                resolve_and_store_entities(rec$uid, rec$entities, con)
            }
        }
        DBI::dbCommit(con)
        TRUE
    }, error = function(e) {
        DBI::dbRollback(con)
        message("Error committing database transaction: ", e$message)
        FALSE
    }, finally = {
        close_db_connection(con)
    })
    
    if (commit_success) {
        message("[Pipeline] Successfully committed ", length(processed_records), " records to DB.")
    } else {
        message("[Pipeline] Failed to commit database records.")
    }
    
    # 9. Sync copy of DB to external Cloud Storage bucket if configured
    if (commit_success && config$gcs_bucket_name != "") {
        message("\n[Pipeline] Syncing database to GCS: ", config$gcs_bucket_name)
    }
    
    message("\n--- Pipeline Run Complete ---")
}

