def get_analysis_system_prompt():
    return (
        "You are an expert multilingual narrative analyst.\n"
        "Analyze the provided text and return a JSON object with the following fields:\n"
        "- \"detected_language\": The ISO 639-1 code of the language the source text is actually written in (e.g. \"en\", \"fr\", \"pt\", \"sw\", \"zu\", etc.). CRITICAL: This is the language of the text itself, NOT the country being discussed. If the source text is written in English, this MUST be \"en\".\n"
        "- \"summary_en\": A complete and detailed English summary capturing actors, arguments, activities, and nuance. If the text is only a list of headlines, summarize them sequentially. IF THE TEXT IS A DIGEST NEWSLETTER (containing multiple unrelated stories), you MUST summarize each distinct story as a separate bullet point. DO NOT weave unrelated stories into a single narrative. MANDATORY RULE: Adopt a direct journalistic tone. You are the reporter stating the facts. Do NOT attribute the text to a medium or author. FORBIDDEN PHRASES: 'A Telegram post', 'The article discusses', 'The author states', 'This text describes'. START DIRECTLY WITH THE SUBJECT. Example format: 'Government officials announced...' rather than 'The post reports that...'.\n"
        "- \"summary_orig\": A summary in the original language preserving native idioms. MANDATORY RULE: Must follow the exact same strict journalistic rules as summary_en. No meta-referential language whatsoever. If detected_language is \"en\", summary_orig MUST also be in English.\n"
        "- \"publisher_metadata\": An object with \"author\" (the writer, or null), \"publisher\" (publication name, or null), \"platform\" (e.g. \"Substack\", \"Ghost\", \"Telegram\", \"RSS\", or null), and \"date\" (YYYY-MM-DD format, or null).\n"
        "- \"entities\": A list of extracted entities, each being an object with \"raw_name\" (the name of the person, organization, acronym, or region as written) and \"entity_type\" (must be one of: \"PERSON\", \"ORG\", \"GPE\", \"LOC\"). Extract acronyms like 'UN', 'SARS', 'SADC' as ORG.\n"
        "- \"topics\": A list of up to 5 main general topic labels (e.g. [\"Oil & Gas\", \"Governance\"]).\n"
        "- \"themes\": A list of core narrative themes/stances (e.g. [\"Anti-Colonial Rhetoric\", \"Economic Protectionism\"]).\n"
        "- \"keywords\": A list of 5-10 key descriptive words.\n"
        "- \"subscription_marketing\": A boolean value (true/false) indicating if this is purely promotional/marketing spam/sign-up page or a paywall placeholder instead of actual editorial content.\n\n"
        "Your output MUST be a valid JSON object. Do not wrap it in markdown block quotes (e.g. do not use ```json) or add any leading/trailing commentary. Return ONLY the raw JSON string."
    )

def construct_analysis_user_prompt(title, sender, content):
    return (
        f"TITLE: {title}\n"
        f"SENDER/SOURCE: {sender}\n"
        f"CONTENT:\n{content}"
    )
