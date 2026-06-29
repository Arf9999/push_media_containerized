#' Entity Lexicon and Deduplication Resolver
#'
#' Deduplicates extracted entities (people, organizations, acronyms) against
#' the DuckDB `entity_lexicon` table using Jaro-Winkler string similarity.
#'
#' @importFrom DBI dbGetQuery dbExecute
#' @importFrom stringr str_to_lower str_trim
#' @importFrom stringdist stringsim
#' @importFrom dplyr %>%
#' @export

#' Compute Jaro Similarity between two strings
#'
#' @param str1 First string.
#' @param str2 Second string.
#' @return Jaro similarity value (0 to 1).
jaro_distance <- function(str1, str2) {
    if (is.null(str1) || is.na(str1) || is.null(str2) || is.na(str2)) return(0)
    if (nchar(str1) == 0 || nchar(str2) == 0) return(0)
    sim <- stringdist::stringsim(str1, str2, method = "jw", p = 0)
    if (is.na(sim)) return(0)
    return(sim)
}

#' Compute Jaro-Winkler Similarity between two strings
#'
#' @param str1 First string.
#' @param str2 Second string.
#' @param p Scaling factor (default = 0.1).
#' @return Jaro-Winkler similarity value (0 to 1).
jaro_winkler <- function(str1, str2, p = 0.1) {
    if (is.null(str1) || is.na(str1) || is.null(str2) || is.na(str2)) return(0)
    if (nchar(str1) == 0 || nchar(str2) == 0) return(0)
    sim <- stringdist::stringsim(str1, str2, method = "jw", p = p)
    if (is.na(sim)) return(0)
    return(sim)
}

#' Resolve an Entity to its Canonical Name
#'
#' Checks the entity lexicon for existing mappings. If a close match (Jaro-Winkler >= 0.88)
#' exists under the same type, maps to that canonical name. Otherwise, creates a new canonical entity.
#'
#' @param raw_name Raw entity string.
#' @param entity_type Type of entity (PERSON, ORG, etc.).
#' @param con A DBI database connection.
#' @param threshold Similarity threshold (default = 0.88).
#' @return Canonical name for the entity.
#' @export
resolve_entity <- function(raw_name, entity_type, con, threshold = 0.88) {
    if (is.null(raw_name) || is.na(raw_name) || is.null(entity_type) || is.na(entity_type)) return(NA_character_)
    raw_name_clean <- stringr::str_trim(raw_name)
    if (raw_name_clean == "") return(NA_character_)
    
    # 1. Check exact match in lexicon (case-insensitive)
    query <- "SELECT canonical_name FROM entity_lexicon WHERE LOWER(raw_name) = LOWER(?);"
    res <- DBI::dbGetQuery(con, query, params = list(raw_name_clean))
    
    if (nrow(res) > 0) {
        return(res$canonical_name[1])
    }
    
    # 2. Fetch all canonical names for the same entity type
    lexicon_query <- "SELECT DISTINCT canonical_name FROM entity_lexicon WHERE entity_type = ?;"
    existing_canonicals <- DBI::dbGetQuery(con, lexicon_query, params = list(entity_type))$canonical_name
    
    best_similarity <- 0
    best_canonical <- raw_name_clean
    
    # Check Jaro-Winkler similarity against existing canonical names
    if (length(existing_canonicals) > 0) {
        raw_lower <- stringr::str_to_lower(raw_name_clean)
        for (canon in existing_canonicals) {
            # Direct comparison
            sim <- jaro_winkler(raw_lower, stringr::str_to_lower(canon))
            if (sim > best_similarity) {
                best_similarity <- sim
                best_canonical <- canon
            }
        }
    }
    
    # 3. Determine if we map to an existing canonical or start a new one
    resolved_canonical <- if (best_similarity >= threshold) best_canonical else raw_name_clean
    
    # 4. Insert mapping into the lexicon
    insert_query <- "
        INSERT OR IGNORE INTO entity_lexicon (raw_name, canonical_name, entity_type)
        VALUES (?, ?, ?);
    "
    DBI::dbExecute(con, insert_query, params = list(raw_name_clean, resolved_canonical, entity_type))
    
    return(resolved_canonical)
}

#' Resolve and Store a Batch of Entities for a Newsletter
#'
#' @param uid Newsletter UID.
#' @param entities_df A data frame containing raw columns `raw_name` and `entity_type`.
#' @param con A DBI database connection.
#' @export
resolve_and_store_entities <- function(uid, entities_df, con) {
    if (is.null(entities_df) || nrow(entities_df) == 0) return(invisible(NULL))
    
    # Resolve canonical name for each row
    entities_df$canonical_name <- sapply(seq_len(nrow(entities_df)), function(i) {
        resolve_entity(entities_df$raw_name[i], entities_df$entity_type[i], con)
    })
    
    # Insert resolved entities into the entities table
    for (i in seq_len(nrow(entities_df))) {
        raw <- entities_df$raw_name[i]
        canon <- entities_df$canonical_name[i]
        type <- entities_df$entity_type[i]
        
        insert_query <- "
            INSERT INTO entities (uid, entity_type, raw_name, canonical_name)
            VALUES (?, ?, ?, ?);
        "
        DBI::dbExecute(con, insert_query, params = list(uid, type, raw, canon))
    }
}
