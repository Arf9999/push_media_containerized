#' Load Phase 2 Pipeline Configuration
#'
#' Reads environment variables and returns a structured list of configuration options.
#'
#' @return A list containing configuration values.
#' @export
get_config <- function() {
    # Ingestion configuration
    gmail_username <- Sys.getenv("GMAIL_USERNAME", unset = "")
    gmail_app_password <- Sys.getenv("GMAIL_APP_PASSWORD", unset = "")
    
    # DB configuration. Kept as db_path for existing callers; it now carries a
    # Postgres connection string locally and can point at RDS later.
    db_path <- Sys.getenv("DATABASE_URL", unset = "postgresql://pushmedia:pushmedia@postgres:5432/pushmedia")
    
    # Helper to traverse manifest JSON safely
    get_manifest_val <- function(manifest, path, default) {
        val <- manifest
        for (p in path) {
            if (is.null(val) || !p %in% names(val)) return(default)
            val <- val[[p]]
        }
        if (is.null(val) || is.na(val)) return(default)
        return(val)
    }
    
    # Load manifest model settings if file exists
    manifest_defaults <- list()
    if (file.exists("manifest.json")) {
        tryCatch({
            manifest_defaults <- jsonlite::read_json("manifest.json", simplifyVector = TRUE)
        }, error = function(e) {
            message("Warning: Failed to parse manifest.json: ", e$message)
        })
    }
    
    default_llm_provider <- get_manifest_val(manifest_defaults, c("pipeline_models", "metadata_extraction", "provider"), "openrouter")
    default_llm_model <- get_manifest_val(manifest_defaults, c("pipeline_models", "metadata_extraction", "model"), "deepseek/deepseek-chat")
    
    default_emb_provider <- get_manifest_val(manifest_defaults, c("pipeline_models", "vector_embeddings", "provider"), "openrouter")
    default_emb_model <- get_manifest_val(manifest_defaults, c("pipeline_models", "vector_embeddings", "model"), "nomic-embed-text")
    
    # Model agnosticism configuration
    llm_provider <- Sys.getenv("LLM_PROVIDER", unset = default_llm_provider)
    llm_model <- Sys.getenv("LLM_MODEL", unset = default_llm_model)
    
    embedding_provider <- Sys.getenv("EMBEDDING_PROVIDER", unset = default_emb_provider)
    embedding_model <- Sys.getenv("EMBEDDING_MODEL", unset = default_emb_model)
    
    # Provider keys & hosts
    openrouter_api_key <- Sys.getenv("OPENROUTER_API_KEY", unset = "")
    ollama_host <- Sys.getenv("OLLAMA_HOST", unset = "http://localhost:11434")
    openai_api_key <- Sys.getenv("OPENAI_API_KEY", unset = "")
    gemini_api_key <- Sys.getenv("GEMINI_API_KEY", unset = "")
    
    # Sync configuration
    gcs_bucket_name <- Sys.getenv("GCS_BUCKET_NAME", unset = "")
    
    # State tracking configuration
    last_email_id_file <- Sys.getenv("LAST_EMAIL_ID_FILE", unset = "/app/data/last_email_id.txt")
    
    # Forensic Logging configuration
    forensic_log_path <- Sys.getenv("FORENSIC_LOG_PATH", unset = "FORENSIC_LOG")
    
    # Translation model configuration
    translation_model <- Sys.getenv("TRANSLATION_MODEL", unset = "mzansilm")
    
    # Vision model configuration
    vision_model <- Sys.getenv("VISION_MODEL", unset = "qwen/qwen3.6-plus")
    
    config <- list(
        gmail_username = gmail_username,
        gmail_app_password = gmail_app_password,
        db_path = db_path,
        llm_provider = llm_provider,
        llm_model = llm_model,
        embedding_provider = embedding_provider,
        embedding_model = embedding_model,
        openrouter_api_key = openrouter_api_key,
        ollama_host = ollama_host,
        openai_api_key = openai_api_key,
        gemini_api_key = gemini_api_key,
        gcs_bucket_name = gcs_bucket_name,
        last_email_id_file = last_email_id_file,
        forensic_log_path = forensic_log_path,
        translation_model = translation_model,
        vision_model = vision_model
    )
    
    return(config)
}
