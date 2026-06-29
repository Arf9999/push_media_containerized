#' Local Ollama Translation Module
#'
#' Provides translation from low-resource African languages to English using local Ollama models.
#' Uses SQLite cache db to prevent duplicate calls and logs raw output to scratch logs.
#'
#' @importFrom DBI dbConnect dbExecute dbDisconnect dbGetQuery
#' @importFrom RSQLite SQLite
#' @importFrom digest digest
#' @importFrom httr2 request req_body_json req_timeout req_retry req_perform resp_body_json
#' @export

#' Translate Text Using Local Ollama Model
#'
#' @param text Text string to translate.
#' @param lang Source language ISO 639-1 code (e.g., 'xh', 'zu').
#' @param model_name Model name to use (default: 'mzansilm').
#' @return Translated English text string.
#' @export
translate_ollama <- function(text, lang, model_name = "mzansilm") {
  # Compute cache key
  key <- digest::digest(list(text = text, lang = lang, model = model_name), algo = "sha256")
  cache_db <- file.path('alpha', 'ollama_cache.db')
  if (!file.exists(cache_db)) {
    con_create <- DBI::dbConnect(RSQLite::SQLite(), cache_db)
    DBI::dbExecute(con_create, 'CREATE TABLE cache (key TEXT PRIMARY KEY, translation TEXT)')
    DBI::dbDisconnect(con_create)
  }
  con <- DBI::dbConnect(RSQLite::SQLite(), cache_db)
  res <- DBI::dbGetQuery(con, sprintf("SELECT translation FROM cache WHERE key='%s'", key))
  if (nrow(res) > 0) {
    DBI::dbDisconnect(con)
    return(res$translation[1])
  }
  # Map ISO 639-1 codes to human-readable names for prompt construction
  lang_names <- list(
    xh = "isiXhosa", zu = "isiZulu", tn = "Setswana",
    rw = "Kinyarwanda", st = "Sesotho", ss = "siSwati", wo = "Wolof"
  )
  lang_name <- if (!is.null(lang_names[[lang]])) lang_names[[lang]] else lang

  # Check if model should be routed via OpenRouter
  is_openrouter <- grepl("^(qwen|liquid|meta|deepseek|openai|google|anthropic|mistral)/", model_name) || grepl("^openrouter/", model_name)

  if (is_openrouter) {
    config <- get_config()
    if (is.null(config$openrouter_api_key) || config$openrouter_api_key == "") {
      stop("OPENROUTER_API_KEY is not configured but an OpenRouter translation model was requested.")
    }
    
    url <- "https://openrouter.ai/api/v1/chat/completions"
    messages <- list(
      list(role = "system", content = paste0("You are a professional translator. Translate the following text from ", lang_name, " to English. Output ONLY the direct English translation. Do not add explanations, commentary, or extra text.")),
      list(role = "user", content = text)
    )
    body <- list(
      model = model_name,
      messages = messages,
      temperature = 0.3
    )
    
    log_dir <- file.path('scratch', 'openrouter_logs')
    if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)
    log_file <- file.path(log_dir, sprintf('%s.log', key))
    
    translation <- tryCatch({
      req <- httr2::request(url)
      req <- httr2::req_headers(req,
        "Authorization" = paste("Bearer", config$openrouter_api_key),
        "HTTP-Referer" = "https://github.com/Arf9999/newsletter_phase2",
        "X-Title" = "Push Media Pipeline Translation"
      )
      req <- httr2::req_body_json(req, body)
      req <- httr2::req_timeout(req, seconds = 120)
      req <- httr2::req_retry(req, max_tries = 3)
      
      resp <- httr2::req_perform(req)
      res_json <- httr2::resp_body_json(resp)
      out <- res_json$choices[[1]]$message$content
      writeLines(out, con = log_file)
      out
    }, error = function(e) {
      writeLines(as.character(e), con = log_file)
      stop(e)
    })
  } else {
    # Build prompt for Ollama model
    prompt <- paste0(
      "Translate the following text from ", lang_name, " to English.\n",
      "Output ONLY the English translation. Do not add explanations, commentary, or extra text.\n\n",
      "Text: ", text, "\n\n",
      "English translation:"
    )
    # Log directory
    log_dir <- file.path('scratch', 'ollama_logs')
    if (!dir.exists(log_dir)) dir.create(log_dir, recursive = TRUE)
    log_file <- file.path(log_dir, sprintf('%s.log', key))
    translation <- tryCatch({
      # Perform HTTP request to local Ollama instance
      url <- "http://localhost:11434/api/generate"
      body <- list(
        model = model_name,
        prompt = prompt,
        stream = FALSE,
        keep_alive = -1L  # keep model loaded in RAM between calls (integer, not string)
      )
      req <- httr2::request(url)
      req <- httr2::req_body_json(req, body)
      req <- httr2::req_timeout(req, seconds = 1200)  # 20 min: large CPU models need time to load + generate
      req <- httr2::req_retry(req, max_tries = 2)
      resp <- httr2::req_perform(req)
      res_json <- httr2::resp_body_json(resp)
      
      out <- res_json$response
      writeLines(out, con = log_file)
      out
    }, error = function(e) {
      writeLines(as.character(e), con = log_file)
      stop(e)
    })
  }
  # Store in cache
  DBI::dbExecute(con, "INSERT INTO cache (key, translation) VALUES (?, ?)", params = list(key, translation))
  DBI::dbDisconnect(con)
  return(translation)
}

#' Generic Translation Fallback
#'
#' Translates text using the primary LLM configured in the adapter.
#' Falls back to Qwen 3.6 Plus if the primary model fails or returns empty,
#' and prepends a warning header if both fail.
#'
#' @param text Text to translate.
#' @param lang Source language ISO code.
#' @param config Config list.
#' @return Translated English text.
translate_generic <- function(text, lang, config = NULL) {
  if (is.null(config)) {
    config <- get_config()
  }
  sys_prompt <- paste0("You are a professional translator. Translate the following text from ", lang, " to English. Output only the direct English translation without any explanation, conversational filler, or introductory text.")
  
  # Attempt 1: primary config model
  translation <- tryCatch({
    generate_completion(text, system_prompt = sys_prompt, json_mode = FALSE, config = config)
  }, error = function(e) {
    message("Generic translation (Primary model) failed: ", e$message)
    NULL
  })
  
  # Attempt 2: fallback to Qwen 3.6 Plus via OpenRouter
  if (is.null(translation) || trimws(translation) == "" || translation == text) {
    message("Primary model translation failed or returned empty. Attempting secondary fallback translation via Qwen 3.6 Plus...")
    fallback_config <- config
    fallback_config$llm_provider <- "openrouter"
    fallback_config$llm_model <- "qwen/qwen3.6-plus"
    
    translation <- tryCatch({
      generate_completion(text, system_prompt = sys_prompt, json_mode = FALSE, config = fallback_config)
    }, error = function(e) {
      message("Generic translation fallback (Qwen 3.6 Plus) failed: ", e$message)
      NULL
    })
  }
  
  # If still failed, append warning header
  if (is.null(translation) || trimws(translation) == "") {
    warning_header <- paste0("[Translation Failed - Original Language: ", lang, "]\n\n")
    return(paste0(warning_header, text))
  }
  
  return(translation)
}


