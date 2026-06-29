#' Model-Agnostic LLM Completion and Embeddings Adapter
#'
#' Unified wrapper for calling chat completion and embedding endpoints
#' across OpenRouter, Ollama, OpenAI, and Gemini.
#'
#' @importFrom httr2 request req_headers req_body_json req_perform resp_body_json req_retry
#' @importFrom jsonlite fromJSON
#' @export

#' Generate Chat Completion
#'
#' Call chat completion endpoint of the configured provider.
#'
#' @param prompt User prompt text.
#' @param system_prompt Optional system instructions.
#' @param json_mode Boolean, whether to request JSON response formatting.
#' @param config Configuration list containing api keys and model settings.
#' @return A list containing the generated text or parsed JSON.
generate_completion <- function(prompt, system_prompt = NULL, json_mode = FALSE, config = NULL, image_url = NULL) {
    if (is.null(config)) {
        stop("Configuration list must be provided.")
    }
    
    provider <- tolower(config$llm_provider)
    model <- config$llm_model
    
    # Check if this is a vision/OCR request
    has_image <- !is.null(image_url) && !is.na(image_url) && image_url != ""
    if (has_image) {
        # Switch model to vision model for image processing
        model <- config$vision_model
    }
    
    # 1. Build messages structure
    messages <- list()
    if (!is.null(system_prompt) && system_prompt != "") {
        messages[[length(messages) + 1]] <- list(role = "system", content = system_prompt)
    }
    
    if (has_image) {
        user_content <- list(
            list(type = "text", text = prompt),
            list(type = "image_url", image_url = list(url = image_url))
        )
        messages[[length(messages) + 1]] <- list(role = "user", content = user_content)
    } else {
        messages[[length(messages) + 1]] <- list(role = "user", content = prompt)
    }
    
    max_retries <- 3
    attempt <- 1
    content <- NULL
    reasoning <- NULL
    
    while (attempt <= max_retries) {
        content <- NULL
        reasoning <- NULL
        
        # 2. Execute call depending on provider
        err_msg <- tryCatch({
            if (provider == "openrouter") {
                if (config$openrouter_api_key == "") {
                    stop("OPENROUTER_API_KEY is not configured.")
                }
                
                req <- httr2::request("https://openrouter.ai/api/v1/chat/completions") %>%
                    httr2::req_headers(
                        "Authorization" = paste("Bearer", config$openrouter_api_key),
                        "HTTP-Referer" = "https://github.com/Arf9999/newsletter_phase2",
                        "X-Title" = "Push Media Pipeline"
                    )
                    
                body <- list(
                    model = model,
                    messages = messages,
                    max_tokens = 1500
                )
                if (json_mode) {
                    body$response_format <- list(type = "json_object")
                }
                
                req <- req %>%
                    httr2::req_body_json(body) %>%
                    httr2::req_timeout(120) %>%
                    httr2::req_retry(max_tries = 3)
                resp <- httr2::req_perform(req)
                res_json <- httr2::resp_body_json(resp)
                
                content <- res_json$choices[[1]]$message$content
                reasoning <- res_json$choices[[1]]$message$reasoning_content
                if (is.null(reasoning)) {
                    reasoning <- res_json$choices[[1]]$message$reasoning
                }
                
            } else if (provider == "ollama") {
                use_gen <- !is.null(config$use_generate) && config$use_generate
                
                if (use_gen) {
                    url <- paste0(config$ollama_host, "/api/generate")
                    # Construct prompt for base completion models by prepending system instructions
                    raw_prompt <- if (!is.null(system_prompt) && system_prompt != "") {
                        paste0(system_prompt, "\n\n", prompt)
                    } else {
                        prompt
                    }
                    body <- list(
                        model = model,
                        prompt = raw_prompt,
                        stream = FALSE
                    )
                } else {
                    url <- paste0(config$ollama_host, "/api/chat")
                    body <- list(
                        model = model,
                        messages = messages,
                        stream = FALSE
                    )
                    if (json_mode) {
                        body$format <- "json"
                    }
                }
                
                if (!is.null(config$ollama_options)) {
                    body$options <- config$ollama_options
                }
                
                req <- httr2::request(url) %>%
                    httr2::req_body_json(body) %>%
                    httr2::req_timeout(120) %>%
                    httr2::req_retry(max_tries = 2)
                    
                resp <- httr2::req_perform(req)
                res_json <- httr2::resp_body_json(resp)
                
                if (use_gen) {
                    content <- res_json$response
                    if ((is.null(content) || content == "") && !is.null(res_json$thinking)) {
                        content <- res_json$thinking
                    }
                } else {
                    content <- res_json$message$content
                    if ((is.null(content) || content == "") && !is.null(res_json$message$thinking)) {
                        content <- res_json$message$thinking
                    }
                }
                
            } else if (provider == "openai") {
                if (config$openai_api_key == "") {
                    stop("OPENAI_API_KEY is not configured.")
                }
                
                req <- httr2::request("https://api.openai.com/v1/chat/completions") %>%
                    httr2::req_headers("Authorization" = paste("Bearer", config$openai_api_key))
                    
                body <- list(
                    model = model,
                    messages = messages
                )
                if (json_mode) {
                    body$response_format <- list(type = "json_object")
                }
                
                req <- req %>%
                    httr2::req_body_json(body) %>%
                    httr2::req_timeout(120) %>%
                    httr2::req_retry(max_tries = 3)
                resp <- httr2::req_perform(req)
                res_json <- httr2::resp_body_json(resp)
                
                content <- res_json$choices[[1]]$message$content
                reasoning <- res_json$choices[[1]]$message$reasoning_content
                
            } else if (provider == "gemini") {
                if (config$gemini_api_key == "") {
                    stop("GEMINI_API_KEY is not configured.")
                }
                
                url <- paste0("https://generativelanguage.googleapis.com/v1beta/models/", model, ":generateContent?key=", config$gemini_api_key)
                
                # Build contents structure for Gemini
                contents <- list(
                    parts = list(
                        list(text = prompt)
                    )
                )
                
                # System instructions if provided
                body <- list(contents = list(contents))
                if (!is.null(system_prompt) && system_prompt != "") {
                    body$systemInstruction <- list(parts = list(list(text = system_prompt)))
                }
                if (json_mode) {
                    body$generationConfig <- list(responseMimeType = "application/json")
                }
                
                req <- httr2::request(url) %>%
                    httr2::req_body_json(body) %>%
                    httr2::req_timeout(120) %>%
                    httr2::req_retry(max_tries = 3)
                    
                resp <- httr2::req_perform(req)
                res_json <- httr2::resp_body_json(resp)
                
                content <- res_json$candidates[[1]]$content$parts[[1]]$text
                
                # Gemini thought extraction if reasoning model and parts contain thought field
                parts <- res_json$candidates[[1]]$content$parts
                if (length(parts) > 1) {
                    for (i in seq_along(parts)) {
                        if (!is.null(parts[[i]]$thought)) {
                            reasoning <- parts[[i]]$text
                            break
                        }
                    }
                }
                
            } else {
                stop("Unknown LLM provider specified: ", provider)
            }
            NULL
        }, error = function(e) {
            e$message
        })
        
        if (!is.null(err_msg)) {
            message("LLM API call failed on attempt ", attempt, ": ", err_msg)
            attempt <- attempt + 1
            if (attempt <= max_retries) Sys.sleep(1)
            next
        }
        
        # 3. Validate response
        if (!is.null(content) && content != "") {
            has_repeats <- grepl("(.{3,})\\1{8,}", content, perl = TRUE)
            json_invalid <- FALSE
            
            if (json_mode) {
                json_parsed <- tryCatch({
                    jsonlite::fromJSON(content)
                    TRUE
                }, error = function(e) FALSE)
                if (!json_parsed) {
                    json_invalid <- TRUE
                }
            }
            
            if (has_repeats || json_invalid) {
                reason <- if (has_repeats) "recurring characters detected" else "malformed JSON/truncated"
                message("LLM output rejected (", reason, ") on attempt ", attempt, ". Retrying...")
                
                # Log failed attempt to forensic log for audit trace
                log_forensic_response(
                    provider = paste0(provider, "-rejected-", reason),
                    model = model,
                    prompt = prompt,
                    system_prompt = system_prompt,
                    response_text = content,
                    reasoning_content = reasoning,
                    config = config
                )
                
                attempt <- attempt + 1
                if (attempt <= max_retries) Sys.sleep(1)
            } else {
                # Success! Log and return
                log_forensic_response(
                    provider = provider,
                    model = model,
                    prompt = prompt,
                    system_prompt = system_prompt,
                    response_text = content,
                    reasoning_content = reasoning,
                    config = config
                )
                return(content)
            }
        } else {
            message("Empty response on attempt ", attempt, ". Retrying...")
            attempt <- attempt + 1
            if (attempt <= max_retries) Sys.sleep(1)
        }
    }
    
    stop("Failed to obtain a valid, non-repeating completion after ", max_retries, " attempts.")
}

#' Generate Vector Embeddings
#'
#' Generate embeddings for a vector of texts using the configured provider.
#'
#' @param texts A character vector of texts to embed.
#' @param config Configuration list.
#' @param space Either "english" or "multilingual" to toggle models if needed.
#' @return A list of numeric vectors containing the embeddings.
generate_embeddings <- function(texts, config = NULL, space = "english") {
    if (is.null(config)) {
        stop("Configuration list must be provided.")
    }
    if (length(texts) == 0) {
        return(list())
    }
    
    provider <- tolower(config$embedding_provider)
    # Check if we should override model based on vector space target
    model <- config$embedding_model
    
    embeddings <- list()
    
    for (txt in texts) {
        if (txt == "" || is.na(txt)) {
            embeddings[[length(embeddings) + 1]] <- NA
            next
        }
        
        if (provider == "openrouter") {
            # OpenRouter typically doesn't host embeddings natively, so we fall back to OpenAI API format
            # or custom endpoint. Let's build OpenAI/OpenRouter fallback for embeddings.
            api_key <- ifelse(config$openrouter_api_key != "", config$openrouter_api_key, config$openai_api_key)
            if (api_key == "") {
                stop("Neither OPENROUTER_API_KEY nor OPENAI_API_KEY is configured for embeddings.")
            }
            
            # Use OpenAI embeddings endpoint (which many API hosts share)
            req <- httr2::request("https://api.openai.com/v1/embeddings") %>%
                httr2::req_headers("Authorization" = paste("Bearer", api_key)) %>%
                httr2::req_body_json(list(
                    model = model,
                    input = txt
                )) %>%
                httr2::req_timeout(60) %>%
                httr2::req_retry(max_tries = 3)
                
            resp <- httr2::req_perform(req)
            res_json <- httr2::resp_body_json(resp)
            embeddings[[length(embeddings) + 1]] <- as.numeric(res_json$data[[1]]$embedding)
            
        } else if (provider == "openai") {
            if (config$openai_api_key == "") {
                stop("OPENAI_API_KEY is not configured.")
            }
            
            req <- httr2::request("https://api.openai.com/v1/embeddings") %>%
                httr2::req_headers("Authorization" = paste("Bearer", config$openai_api_key)) %>%
                httr2::req_body_json(list(
                    model = model,
                    input = txt
                )) %>%
                httr2::req_timeout(60) %>%
                httr2::req_retry(max_tries = 3)
                
            resp <- httr2::req_perform(req)
            res_json <- httr2::resp_body_json(resp)
            embeddings[[length(embeddings) + 1]] <- as.numeric(res_json$data[[1]]$embedding)
            
        } else if (provider == "ollama") {
            url <- paste0(config$ollama_host, "/api/embed")
            req <- httr2::request(url) %>%
                httr2::req_body_json(list(
                    model = model,
                    input = txt
                )) %>%
                httr2::req_timeout(60) %>%
                httr2::req_retry(max_tries = 2)
                
            resp <- httr2::req_perform(req)
            res_json <- httr2::resp_body_json(resp)
            embeddings[[length(embeddings) + 1]] <- as.numeric(res_json$embeddings[[1]])
            
        } else if (provider == "gemini") {
            if (config$gemini_api_key == "") {
                stop("GEMINI_API_KEY is not configured.")
            }
            
            # Use developer API embedContent
            url <- paste0("https://generativelanguage.googleapis.com/v1beta/models/", model, ":embedContent?key=", config$gemini_api_key)
            
            req <- httr2::request(url) %>%
                httr2::req_body_json(list(
                    content = list(
                        parts = list(
                            list(text = txt)
                        )
                    )
                )) %>%
                httr2::req_timeout(60) %>%
                httr2::req_retry(max_tries = 3)
                
            resp <- httr2::req_perform(req)
            res_json <- httr2::resp_body_json(resp)
            embeddings[[length(embeddings) + 1]] <- as.numeric(res_json$embedding$values)
            
        } else {
            stop("Unknown embedding provider specified: ", provider)
        }
    }
    
    return(embeddings)
}

#' Log LLM response activity to a Forensic Log file
#'
#' Appends raw system prompts, user prompts, generated completions, and model thinking processes to a configured path.
#'
#' @param provider The backend provider name.
#' @param model The active model name.
#' @param prompt User prompt text.
#' @param system_prompt System prompt instructions.
#' @param response_text Final answer text.
#' @param reasoning_content Optional model reasoning/thinking process text.
#' @param config Config list.
log_forensic_response <- function(provider, model, prompt, system_prompt, response_text, reasoning_content = NULL, config = NULL) {
    log_path <- if (!is.null(config) && !is.null(config$forensic_log_path) && config$forensic_log_path != "") {
        config$forensic_log_path
    } else {
        "FORENSIC_LOG"
    }
    
    # Ensure parent directory exists if log is placed inside a folder path
    dir_name <- dirname(log_path)
    if (dir_name != "." && dir_name != "" && !dir.exists(dir_name)) {
        dir.create(dir_name, recursive = TRUE, showWarnings = FALSE)
    }
    
    timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    
    system_prompt_str <- if (!is.null(system_prompt) && system_prompt != "") {
        paste0("SYSTEM PROMPT:\n", system_prompt, "\n")
    } else {
        ""
    }
    
    log_entry <- paste0(
        "================================================================================\n",
        "TIMESTAMP: ", timestamp, "\n",
        "PROVIDER:  ", provider, "\n",
        "MODEL:     ", model, "\n",
        system_prompt_str,
        "------------------------------------ PROMPT ------------------------------------\n",
        prompt, "\n",
        "---------------------------------- RESPONSE ------------------------------------\n"
    )
    
    if (!is.null(reasoning_content) && reasoning_content != "") {
        log_entry <- paste0(
            log_entry,
            "--- THINKING PROCESS ---\n",
            reasoning_content, "\n",
            "--- FINAL ANSWER ---\n"
        )
    }
    
    log_entry <- paste0(
        log_entry,
        response_text, "\n",
        "================================================================================\n\n"
    )
    
    # Append to the log file
    tryCatch({
        cat(log_entry, file = log_path, append = TRUE)
    }, error = function(e) {
        warning("Failed to write to FORENSIC_LOG: ", e$message)
    })
}
