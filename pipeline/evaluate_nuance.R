#' Translation Nuance and Idiom Evaluation Suite
#'
#' Quantitatively benchmarks semantic fidelity of translated English outputs
#' against original-language texts using LLM-as-a-judge grading.
#'
#' @importFrom DBI dbGetQuery
#' @importFrom jsonlite fromJSON
#' @export

#' Evaluate Translation Nuance using LLM-as-a-judge
#'
#' @param orig_text Original text or original summary.
#' @param english_text Translated English summary.
#' @param config Configuration list containing LLM keys.
#' @return A list containing grades (1-5) and justifications.
evaluate_translation <- function(orig_text, english_text, config) {
    if (is.null(orig_text) || is.na(orig_text) || orig_text == "" ||
        is.null(english_text) || is.na(english_text) || english_text == "") {
        return(NULL)
    }
    
    system_prompt <- paste(
        "You are an expert multilingual linguistic judge evaluating translation quality.",
        "Compare TEXT A (original language summary) with TEXT B (translated English summary).",
        "Evaluate the quality on a 1-5 integer scale (1 = Poor, 5 = Excellent) across these criteria:",
        "1. Semantic Accuracy: Does the English translation accurately capture the facts and assertions of the original text?",
        "2. Tone Alignment: Is the rhetorical weight, bias, or political tone preserved correctly?",
        "3. Nuance Retention: Are subtle implications, metaphors, or context preserved?",
        "4. Idiomatic Mapping: Are original idioms translated into natural English equivalents rather than literal/awkward translations?",
        "",
        "You must return a valid JSON object with the following fields:",
        "- \"semantic_accuracy\": (integer 1-5)",
        "- \"tone_alignment\": (integer 1-5)",
        "- \"nuance_retention\": (integer 1-5)",
        "- \"idiomatic_mapping\": (integer 1-5)",
        "- \"justification\": (string detailing your feedback)",
        "",
        "Return ONLY the raw JSON string. Do not wrap it in markdown formatting or code blocks.",
        sep = "\n"
    )
    
    user_prompt <- paste0(
        "TEXT A (Original Language):\n", orig_text, "\n\n",
        "TEXT B (English Translation):\n", english_text
    )
    
    # We call the completion endpoint via our model adapter
    # Import model adapter functions inline
    source("alpha/model_adapter.R", local = TRUE)
    
    resp_text <- tryCatch({
        generate_completion(user_prompt, system_prompt = system_prompt, json_mode = TRUE, config = config)
    }, error = function(e) {
        message("Error calling judge LLM: ", e$message)
        return(NULL)
    })
    
    if (is.null(resp_text)) return(NULL)
    
    # Clean response in case LLM wrapped it in markdown codeblocks
    resp_text_clean <- gsub("^```json\\s*", "", resp_text)
    resp_text_clean <- gsub("\\s*```$", "", resp_text_clean)
    
    parsed <- tryCatch({
        jsonlite::fromJSON(resp_text_clean)
    }, error = function(e) {
        message("JSON parse error on judge output: ", e$message)
        message("Raw response: ", resp_text)
        return(NULL)
    })
    
    return(parsed)
}

#' Run Nuance Benchmarking Against Database Records
#'
#' Queries DuckDB for articles that required translation, runs evaluation on them,
#' and outputs a summary quality metric report.
#'
#' @param sample_size Max number of records to evaluate.
#' @param config Configuration list.
#' @export
run_nuance_benchmark <- function(sample_size = 10, config = NULL) {
    if (is.null(config)) {
        source("alpha/config.R", local = TRUE)
        config <- get_config()
    }
    
    source("alpha/db_manager.R", local = TRUE)
    con <- get_db_connection(config$db_path)
    on.exit(close_db_connection(con))
    
    # Query non-English newsletters with summary pairs
    query <- "
        SELECT uid, title, detected_language, original_language_summary, summary
        FROM newsletters
        WHERE detected_language != 'en' AND original_language_summary IS NOT NULL AND summary IS NOT NULL
        LIMIT ?;
    "
    records <- DBI::dbGetQuery(con, query, params = list(as.integer(sample_size)))
    
    if (nrow(records) == 0) {
        message("No multilingual translation pairs found in database for benchmarking.")
        return(invisible(NULL))
    }
    
    message("Found ", nrow(records), " translation pairs to evaluate.")
    
    scores <- list()
    for (i in seq_len(nrow(records))) {
        rec <- records[i, ]
        message("Evaluating [", rec$detected_language, "] translation for: '", rec$title, "'")
        
        eval_res <- evaluate_translation(rec$original_language_summary, rec$summary, config)
        if (!is.null(eval_res)) {
            eval_res$uid <- rec$uid
            eval_res$title <- rec$title
            eval_res$lang <- rec$detected_language
            scores[[length(scores) + 1]] <- eval_res
        }
    }
    
    if (length(scores) == 0) {
        message("Evaluation failed for all records.")
        return(invisible(NULL))
    }
    
    # Compute averages
    acc_scores <- sapply(scores, function(s) as.numeric(s$semantic_accuracy))
    tone_scores <- sapply(scores, function(s) as.numeric(s$tone_alignment))
    nuance_scores <- sapply(scores, function(s) as.numeric(s$nuance_retention))
    idiom_scores <- sapply(scores, function(s) as.numeric(s$idiomatic_mapping))
    
    cat("\n==================================================\n")
    cat("        Multilingual Nuance Benchmark Report       \n")
    cat("==================================================\n")
    cat("Sample Size evaluated:", length(scores), "records\n")
    cat(sprintf("Average Semantic Accuracy : %.2f / 5.0\n", mean(acc_scores, na.rm = TRUE)))
    cat(sprintf("Average Tone Alignment    : %.2f / 5.0\n", mean(tone_scores, na.rm = TRUE)))
    cat(sprintf("Average Nuance Retention  : %.2f / 5.0\n", mean(nuance_scores, na.rm = TRUE)))
    cat(sprintf("Average Idiomatic Mapping : %.2f / 5.0\n", mean(idiom_scores, na.rm = TRUE)))
    cat("==================================================\n\n")
    
    # Return raw results dataframe
    results_df <- data.frame(
        uid = sapply(scores, function(s) s$uid),
        title = sapply(scores, function(s) s$title),
        lang = sapply(scores, function(s) s$lang),
        accuracy = acc_scores,
        tone = tone_scores,
        nuance = nuance_scores,
        idiom = idiom_scores,
        justification = sapply(scores, function(s) s$justification),
        stringsAsFactors = FALSE
    )
    
    return(results_df)
}
