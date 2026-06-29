# benchmark_lfm_vs_mzansi.R
# Experimental benchmark to compare translation and summarization in stages
# between the LFM model (via OpenRouter) and MzansiLM model (via Ollama).

library(digest)
library(readr)
library(magrittr)
library(jsonlite)

# Load credentials from credentials.json if present
creds_path <- file.path('alpha', 'credentials.json')
if (file.exists(creds_path)) {
  creds <- jsonlite::read_json(creds_path)
  for (name in names(creds)) {
    if (Sys.getenv(name) == "") {
      val_list <- list(creds[[name]])
      names(val_list) <- name
      do.call(Sys.setenv, val_list)
    }
  }
}

# Load the model adapter functions
source(file.path('alpha', 'model_adapter.R'))

# Sample Xhosa sentences (representative of pipeline inputs)
sample_texts <- c(
  "Ndiyavuya ukubona umhlobo wam.",
  "Le ndawo inezityalo ezimnandi.",
  "Umsebenzi wethu udinga ukunyaniseka.",
  "Kudala ndikhangele iindaba ezimnandi.",
  "Siyabulela ngalo msebenzi omhle."
)

# Helper to run a staged completion
run_stage <- function(text, sys_prompt, provider, model_name, cfg) {
  start <- Sys.time()
  result <- tryCatch(
    generate_completion(text, system_prompt = sys_prompt, json_mode = FALSE, config = cfg),
    error = function(e) {
      paste0('ERROR: ', e$message)
    }
  )
  duration <- as.numeric(difftime(Sys.time(), start, units = 'secs'))
  list(text = result, time_sec = duration)
}

results <- data.frame(
  model = character(),
  provider = character(),
  original_text = character(),
  translation = character(),
  summary_orig = character(),
  summary_en = character(),
  time_sec_translation = numeric(),
  time_sec_summary_orig = numeric(),
  time_sec_summary_en = numeric(),
  time_sec_total = numeric(),
  stringsAsFactors = FALSE
)

# Define the setups
# Define the setups
benchmarks <- list(
  list(model = 'liquid/lfm-2-24b-a2b', provider = 'openrouter', use_generate = FALSE, options = NULL),
  list(model = 'gemma4:latest', provider = 'ollama', use_generate = FALSE, options = NULL),
  list(
    model = 'huggingface.co/mradermacher/AfriqueQwen-8B-i1-GGUF:Q4_K_M',
    provider = 'ollama',
    use_generate = TRUE,
    options = list(
      temperature = 0.1,
      stop = list("\n", "isiXhosa:", "Summary:")
    )
  )
)

for (bm in benchmarks) {
  cat('Testing model:', bm$model, 'via provider', bm$provider, "\n")
  cfg <- list(
    llm_provider = bm$provider,
    llm_model = bm$model,
    openrouter_api_key = Sys.getenv('OPENROUTER_API_KEY'),
    ollama_host = 'http://127.0.0.1:11434',
    ollama_options = bm$options,
    use_generate = bm$use_generate
  )
  
  for (txt in sample_texts) {
    cat('  Processing text:', txt, '\n')
    
    # Stage 1: Translation
    cat('    Stage 1: Translation...\n')
    t_sys <- "You are a professional translator. Translate the user's input from isiXhosa to English. Output only the direct English translation without any explanation, conversational filler, or introductory text."
    out_trans <- run_stage(txt, t_sys, bm$provider, bm$model, cfg)
    
    # Stage 2: Original Language Summary
    cat('    Stage 2: Original Language Summary...\n')
    so_sys <- "You are an expert editor. Write a short, direct summary of the provided text in isiXhosa. Do not use conversational filler, introduction, or explanations."
    out_orig_sum <- run_stage(txt, so_sys, bm$provider, bm$model, cfg)
    
    # Stage 3: English Summary
    cat('    Stage 3: English Summary...\n')
    se_sys <- "You are an expert editor. Write a short, direct summary of the provided text in English. Do not use conversational filler, introduction, or explanations."
    out_en_sum <- run_stage(txt, se_sys, bm$provider, bm$model, cfg)
    
    total_time <- out_trans$time_sec + out_orig_sum$time_sec + out_en_sum$time_sec
    
    results <- rbind(results, data.frame(
      model = bm$model,
      provider = bm$provider,
      original_text = txt,
      translation = out_trans$text,
      summary_orig = out_orig_sum$text,
      summary_en = out_en_sum$text,
      time_sec_translation = out_trans$time_sec,
      time_sec_summary_orig = out_orig_sum$time_sec,
      time_sec_summary_en = out_en_sum$time_sec,
      time_sec_total = total_time,
      stringsAsFactors = FALSE
    ))
  }
}

# Write results to CSV for downstream analysis
out_path <- file.path('scratch', 'benchmark_lfm_vs_mzansi.csv')
write_csv(results, out_path)
cat('Benchmark completed. Results saved to', out_path, "\n")
