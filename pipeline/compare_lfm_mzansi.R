# compare_lfm_mzansi.R
# Experimental benchmark script (alpha sandbox) to compare translation speed and output quality
# between the LFM model and the newly installed MzansiLM model using Ollama.

library(digest)
library(readr)

# Sample Xhosa sentences (representative of our pipeline inputs)
sample_texts <- c(
  "Ndiyavuya ukubona umhlobo wam.",
  "Le ndawo inezityalo ezimnandi.",
  "Umsebenzi wethu udinga ukunyaniseka.",
  "Kudala ndikhangele iindaba ezimnandi.",
  "Siyabulela ngalo msebenzi omhle."
)

# Function to translate using a specific Ollama model
translate_ollama_model <- function(text, lang, model_name) {
  prompt <- paste0("Translate the following ", lang, " text to English, preserving idioms and cultural nuance:\n\n", text)
  cmd <- sprintf('ollama run %s "%s"', model_name, shQuote(prompt))
  # Capture output and timing
  start <- Sys.time()
  res <- tryCatch({
    out <- system(cmd, intern = TRUE)
    paste(out, collapse = "\n")
  }, error = function(e) {
    paste0("ERROR: ", e$message)
  })
  duration <- as.numeric(difftime(Sys.time(), start, units = "secs"))
  list(translation = res, time_sec = duration)
}

results <- data.frame(
  model = character(),
  original_text = character(),
  translation = character(),
  time_sec = numeric(),
  stringsAsFactors = FALSE
)

models <- c("lfm", "mzansilm")

for (mdl in models) {
  cat("Testing model:", mdl, "\n")
  for (txt in sample_texts) {
    out <- translate_ollama_model(txt, "xh", mdl)
    results <- rbind(results, data.frame(
      model = mdl,
      original_text = txt,
      translation = out$translation,
      time_sec = out$time_sec,
      stringsAsFactors = FALSE
    ))
  }
}

# Write results to CSV for downstream analysis
out_path <- file.path("scratch", "benchmark_lfm_vs_mzansi.csv")
write_csv(results, out_path)
cat("Benchmark completed. Results saved to", out_path, "\n")
