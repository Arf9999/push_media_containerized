#' System Prompts for Multilingual Narrative Analysis
#'
#' Contains the system prompt and helper functions to construct analysis prompts.

#' Get Ingestion Prompt System Instructions
#'
#' @return System prompt string.
#' @export
get_analysis_system_prompt <- function() {
    prompt <- paste(
        "You are an expert multilingual narrative analyst.",
        "Analyze the provided text and return a JSON object with the following fields:",
        "- \"detected_language\": The ISO 639-1 code of the language the source text is actually written in (e.g. \"en\", \"fr\", \"pt\", \"sw\", \"zu\", etc.). CRITICAL: This is the language of the text itself, NOT the country being discussed. If the source text is written in English, this MUST be \"en\".",
        "- \"summary_en\": A complete and detailed English summary capturing actors, arguments, activities, and nuance. If the text is only a list of headlines, summarize them sequentially. IF THE TEXT IS A DIGEST NEWSLETTER (containing multiple unrelated stories), you MUST summarize each distinct story as a separate bullet point. DO NOT weave unrelated stories into a single narrative. MANDATORY RULE: Adopt a direct journalistic tone. You are the reporter stating the facts. Do NOT attribute the text to a medium or author. FORBIDDEN PHRASES: 'A Telegram post', 'The article discusses', 'The author states', 'This text describes'. START DIRECTLY WITH THE SUBJECT. Example format: 'Government officials announced...' rather than 'The post reports that...'.",
        "- \"summary_orig\": A summary in the original language preserving native idioms. MANDATORY RULE: Must follow the exact same strict journalistic rules as summary_en. No meta-referential language whatsoever. If detected_language is \"en\", summary_orig MUST also be in English.",
        "- \"publisher_metadata\": An object with \"author\" (the writer, or null), \"publisher\" (publication name, or null), \"platform\" (e.g. \"Substack\", \"Ghost\", \"Telegram\", \"RSS\", or null), and \"date\" (YYYY-MM-DD format, or null).",
        "- \"entities\": A list of extracted entities, each being an object with \"raw_name\" (the name of the person, organization, acronym, or region as written) and \"entity_type\" (must be one of: \"PERSON\", \"ORG\", \"GPE\", \"LOC\"). Extract acronyms like 'UN', 'SARS', 'SADC' as ORG.",
        "- \"topics\": A list of up to 5 main general topic labels (e.g. [\"Oil & Gas\", \"Governance\"]).",
        "- \"themes\": A list of core narrative themes/stances (e.g. [\"Anti-Colonial Rhetoric\", \"Economic Protectionism\"]).",
        "- \"keywords\": A list of 5-10 key descriptive words.",
        "- \"contains_text\": A boolean value (true/false) indicating whether the analyzed content (text or image) contains actual written text, document contents, or readable news/data. Set to false if the image contains only graphics, photos, or scenery with no meaningful written text.",
        "- \"subscription_marketing\": A boolean value (true/false) indicating if this is purely promotional/marketing spam/sign-up page or a paywall placeholder instead of actual editorial content.",
        "",
        "Your output MUST be a valid JSON object. Do not wrap it in markdown block quotes (e.g. do not use ```json) or add any leading/trailing commentary. Return ONLY the raw JSON string.",
        sep = "\n"
    )
    return(prompt)
}

#' Construct Ingestion Analysis User Prompt
#'
#' @param title Subject line or title of the post/email.
#' @param sender Sender address or name.
#' @param content Raw body text.
#' @return User prompt string.
#' @export
construct_analysis_user_prompt <- function(title, sender, content) {
    user_prompt <- paste0(
        "TITLE: ", title, "\n",
        "SENDER/SOURCE: ", sender, "\n",
        "CONTENT:\n", content
    )
    return(user_prompt)
}
