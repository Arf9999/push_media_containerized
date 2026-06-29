#' Email Ingestion Module
#'
#' Rewritten ingestion script for secure IMAP Gmail retrieval and parsing.
#' Decoupled from orchestrator, with custom text extraction and cursor tracking.
#'
#' @importFrom mRpostman configure_imap
#' @importFrom stringr str_match str_c str_detect str_split str_trim str_squish str_replace_all
#' @importFrom XML htmlParse xpathSApply xmlValue
#' @importFrom purrr map_chr map
#' @importFrom tibble tibble
#' @importFrom dplyr %>%
#' @export

#' Connect to Gmail IMAP Server
#'
#' @param username Gmail username (email address).
#' @param password Gmail App Password.
#' @return An IMAP connection object.
connect_to_gmail <- function(username, password) {
    if (username == "" || password == "") {
        stop("Gmail username or App Password is not configured.")
    }
    
    con <- mRpostman::configure_imap(
        url = "imaps://imap.gmail.com",
        username = username,
        password = password,
        use_ssl = TRUE,
        verbose = FALSE,
        timeout_ms = 30000
    )
    
    # Increase buffer size from 16KB default to 1MB to speed up raw MIME downloads
    con$reset_buffersize(1048576)
    
    return(con)
}

#' Remove Junk Email Headers
#'
#' @param text Raw text lines.
#' @return Cleaned string.
remove_junk_lines <- function(text) {
    if (is.na(text) || text == "") return("")
    lines <- stringr::str_split(text, "\n")[[1]]
    junk_patterns <- c("(?i)^\\s*content-type:", "(?i)^\\s*content-transfer-encoding:")
    combined_pattern <- paste0("(", paste(junk_patterns, collapse = ")|("), ")")
    keep_lines <- !grepl(combined_pattern, lines, perl = TRUE)
    cleaned <- paste(lines[keep_lines], collapse = "\n")
    cleaned <- stringr::str_replace_all(cleaned, "\n{2,}", "\n")
    stringr::str_squish(cleaned)
}

#' Extract Canonical Browser URL from Parsed HTML
#'
#' Scrapes HTML structure for view-in-browser / read-online links.
#'
#' @param parsed_html XMLInternalDocument parsed from email HTML body.
#' @return Extracted URL string, or NA_character_ if not found.
extract_browser_url_from_parsed_html <- function(parsed_html) {
    if (is.null(parsed_html)) return(NA_character_)
    
    a_nodes <- XML::xpathSApply(parsed_html, "//a")
    if (length(a_nodes) == 0) return(NA_character_)
    
    for (node in a_nodes) {
        text <- XML::xmlValue(node)
        href <- XML::xmlGetAttr(node, "href")
        
        if (!is.null(href) && !is.na(href) && href != "") {
            text_clean <- tolower(stringr::str_trim(text))
            
            # Common patterns for view in browser links
            patterns <- c(
                "view in browser", "view online", "read online", "read in browser",
                "view this email in your browser", "view this post in your browser",
                "open in browser", "view on web", "read on the web", "read on substack",
                "read on ghost", "view on substack"
            )
            
            if (any(vapply(patterns, function(pat) grepl(pat, text_clean, fixed = TRUE), logical(1)))) {
                return(stringr::str_trim(href))
            }
        }
    }
    return(NA_character_)
}

#' Extract Body Content and Browser URL from Email
#'
#' Handles multipart boundary slicing and HTML-to-text conversion.
#' Supports Base64 and Quoted-Printable transfer encodings.
#'
#' @param email_text Raw MIME email string.
#' @return A list containing `body` (extracted plain body text) and `browser_url`.
extract_email_body <- function(email_text) {
    browser_url <- NA_character_
    decode_body_content <- function(content, encoding) {
        encoding_lower <- tolower(encoding)
        if (encoding_lower == "base64") {
            tryCatch({
                raw_bytes <- jsonlite::base64_dec(content)
                rawToChar(raw_bytes)
            }, error = function(e) content)
        } else if (encoding_lower == "quoted-printable") {
            tryCatch(decode_qp(content), error = function(e) content)
        } else {
            content
        }
    }

    # 1. Attempt to find the boundary string
    boundary_match <- stringr::str_match(email_text, '(?i)boundary="?([^";\\r\\n]+)"?')
    boundary <- if (!is.na(boundary_match[, 2])) boundary_match[, 2] else NA_character_
    
    body_part <- NA_character_
    encoding <- "7bit" # default
    
    if (!is.na(boundary)) {
        # Split by boundary
        parts <- stringr::str_split(email_text, stringr::fixed(stringr::str_c("--", boundary)))[[1]]
        
        # Search for text/plain part first
        for (part in parts) {
            if (stringr::str_detect(part, "(?i)Content-Type:\\s*text/plain")) {
                split_part <- stringr::str_split(part, "\\r?\\n\\r?\\n", n = 2)[[1]]
                if (length(split_part) > 1) {
                    headers_part <- split_part[1]
                    body_part <- split_part[2]
                    
                    # Check encoding of this part
                    enc_match <- stringr::str_match(headers_part, "(?i)Content-Transfer-Encoding:\\s*([^\\r\\n]+)")
                    if (!is.na(enc_match[, 2])) {
                        encoding <- stringr::str_trim(enc_match[, 2])
                    }
                    
                    # Clean up trailing boundary marker if included in this part
                    body_part <- stringr::str_replace(body_part, stringr::str_c("--\\s*$"), "")
                    # Decode immediately
                    body_part <- decode_body_content(body_part, encoding)
                    break
                }
            }
        }
        
        # If no text/plain, search for text/html
        if (is.na(body_part)) {
            for (part in parts) {
                if (stringr::str_detect(part, "(?i)Content-Type:\\s*text/html")) {
                    split_part <- stringr::str_split(part, "\\r?\\n\\r?\\n", n = 2)[[1]]
                    if (length(split_part) > 1) {
                        headers_part <- split_part[1]
                        html_body <- split_part[2]
                        
                        enc_match <- stringr::str_match(headers_part, "(?i)Content-Transfer-Encoding:\\s*([^\\r\\n]+)")
                        if (!is.na(enc_match[, 2])) {
                            encoding <- stringr::str_trim(enc_match[, 2])
                        }
                        
                        # Clean up trailing boundary marker if included in this part
                        html_body <- stringr::str_replace(html_body, stringr::str_c("--\\s*$"), "")
                        # Decode immediately
                        decoded_html <- decode_body_content(html_body, encoding)
                        
                        # Convert HTML to text
                        body_part <- tryCatch({
                            parsed_html <- XML::htmlParse(decoded_html, asText = TRUE)
                            # Extract browser URL if available
                            browser_url <<- extract_browser_url_from_parsed_html(parsed_html)
                            XML::xpathSApply(parsed_html, "//text()[not(ancestor::script)][not(ancestor::style)]", XML::xmlValue) %>%
                                paste(collapse = " ")
                        }, error = function(e) decoded_html)
                        break
                    }
                }
            }
        }
    }
    
    # 2. If no boundary found or parts extraction failed, fall back to parsing the email as a single part
    if (is.na(body_part) || stringr::str_trim(body_part) == "") {
        parts <- stringr::str_split(email_text, "\\r?\\n\\r?\\n", n = 2)[[1]]
        candidate <- if (length(parts) > 1) parts[2] else email_text
        
        # Check overall headers for encoding
        enc_match <- stringr::str_match(email_text, "(?i)Content-Transfer-Encoding:\\s*([^\\r\\n]+)")
        if (!is.na(enc_match[, 2])) {
            encoding <- stringr::str_trim(enc_match[, 2])
        }
        
        # Decode first
        decoded_candidate <- decode_body_content(candidate, encoding)
        
        if (stringr::str_detect(decoded_candidate, "<html")) {
            body_part <- tryCatch({
                parsed_html <- XML::htmlParse(decoded_candidate, asText = TRUE)
                # Extract browser URL if available
                browser_url <<- extract_browser_url_from_parsed_html(parsed_html)
                XML::xpathSApply(parsed_html, "//text()[not(ancestor::script)][not(ancestor::style)]", XML::xmlValue) %>%
                    paste(collapse = " ")
            }, error = function(e) decoded_candidate)
        } else {
            body_part <- decoded_candidate
        }
    }
    
    if (is.na(body_part)) return(list(body = "", browser_url = NA_character_))
    
    cleaned <- stringr::str_squish(body_part)
    cleaned <- stringr::str_replace_all(cleaned, "[\\u200b\\u200c\\u200d\\uFEFF\\u200e\\u200f]+", " ")
    cleaned <- remove_junk_lines(cleaned)
    return(list(body = cleaned, browser_url = browser_url))
}

#' Decode Quoted-Printable Encoded Strings
#'
#' Pure R implementation to decode quoted-printable text.
#'
#' @param text QP encoded string.
#' @return Decoded plain string.
decode_qp <- function(text) {
    if (is.na(text) || text == "") return(text)
    
    # Remove soft line breaks (equals sign at the end of a line)
    text <- gsub("=\\r?\\n", "", text)
    
    # Split by '=' to decode hex escapes
    parts <- strsplit(text, "=")[[1]]
    if (length(parts) <= 1) return(text)
    
    res_bytes <- charToRaw(parts[1])
    i <- 2
    while (i <= length(parts)) {
        part <- parts[i]
        if (nchar(part) >= 2) {
            hex_str <- substr(part, 1, 2)
            if (grepl("^[0-9A-Fa-f]{2}$", hex_str)) {
                byte_val <- as.raw(as.hexmode(hex_str))
                res_bytes <- c(res_bytes, byte_val)
                if (nchar(part) > 2) {
                    res_bytes <- c(res_bytes, charToRaw(substr(part, 3, nchar(part))))
                }
            } else {
                res_bytes <- c(res_bytes, charToRaw("="), charToRaw(part))
            }
        } else {
            res_bytes <- c(res_bytes, charToRaw("="), charToRaw(part))
        }
        i <- i + 1
    }
    
    tryCatch({
        rawToChar(res_bytes)
    }, error = function(e) {
        iconv(list(res_bytes), to = "UTF-8", sub = "byte")[[1]]
    })
}

#' Decode MIME RFC 2047 Encoded Headers
#'
#' @param string Raw header string.
#' @return Decoded plain string.
decode_mime_header <- function(string) {
    if (is.na(string) || string == "") return(string)
    # Clean adjacent encoded words by joining them (removing whitespace in between)
    string <- stringr::str_replace_all(string, "\\?=[ \\t\\r\\n]+=\\?", "?==?")
    pattern <- "=\\?([^?]+)\\?([BbQq])\\?([^?]+)\\?="
    matches <- stringr::str_match_all(string, pattern)[[1]]
    if (nrow(matches) == 0) return(string)
    for (i in 1:nrow(matches)) {
        full_match <- matches[i, 1]
        charset <- tolower(matches[i, 2])
        encoding <- tolower(matches[i, 3])
        encoded_text <- matches[i, 4]
        decoded <- tryCatch({
            if (encoding == "b") {
                raw_bytes <- jsonlite::base64_dec(encoded_text)
                rawToChar(raw_bytes)
            } else if (encoding == "q") {
                qp_text <- gsub("_", " ", encoded_text)
                decode_qp(qp_text)
            } else {
                full_match
            }
        }, error = function(e) full_match)
        string <- gsub(full_match, decoded, string, fixed = TRUE)
    }
    return(string)
}

#' Unfold Folded RFC 2822 Headers
#'
#' @param email_text Raw MIME email string.
#' @return A list with "headers" (unfolded header section) and "body" (the rest).
unfold_headers <- function(email_text) {
    parts <- stringr::str_split(email_text, "\\r?\\n\\r?\\n", n = 2)[[1]]
    headers <- parts[1]
    body <- if (length(parts) > 1) parts[2] else ""
    unfolded_headers <- stringr::str_replace_all(headers, "\\r?\\n[ \\t]+", " ")
    return(list(headers = unfolded_headers, body = body))
}

#' Process Raw Email Into Structured Record
#'
#' @param email_text Raw MIME content.
#' @param uid The IMAP unique identifier.
#' @return A list containing parsed metadata fields and body text.
process_email_record <- function(email_text, uid) {
    unfolded <- unfold_headers(email_text)
    header_text <- unfolded$headers
    
    from_field <- stringr::str_match(header_text, stringr::regex("^From:\\s*(.*)", multiline = TRUE))[, 2]
    subj_field <- stringr::str_match(header_text, stringr::regex("^Subject:\\s*(.*)", multiline = TRUE))[, 2]
    date_field <- stringr::str_match(header_text, stringr::regex("^Date:\\s*(.*)", multiline = TRUE))[, 2]
    
    from_field <- ifelse(is.na(from_field), "Unknown Sender", stringr::str_trim(from_field))
    subj_field <- ifelse(is.na(subj_field), "No Subject", stringr::str_trim(subj_field))
    date_field <- ifelse(is.na(date_field), "Unknown Date", stringr::str_trim(date_field))
    
    # Decode MIME headers if present
    from_field <- decode_mime_header(from_field)
    subj_field <- decode_mime_header(subj_field)
    
    body_data <- extract_email_body(email_text)
    body <- body_data$body
    browser_url <- body_data$browser_url
    
    # Parse sender email address from "Name <email@address.com>" formats
    sender_email <- from_field
    email_regex <- "<([^>]+)>"
    if (stringr::str_detect(from_field, email_regex)) {
        sender_email <- stringr::str_match(from_field, email_regex)[, 2]
    }
    
    # Parse publisher name/domain from from_field to avoid hardcoding "Email Intake"
    pub_name <- "Email Intake"
    if (stringr::str_detect(from_field, "<[^>]+>")) {
        name_part <- stringr::str_trim(gsub("<[^>]+>", "", from_field))
        name_part <- gsub("^['\"]|['\"]$", "", name_part)
        name_part <- stringr::str_trim(name_part)
        if (name_part != "") {
            pub_name <- name_part
        }
    } else if (stringr::str_detect(from_field, "@")) {
        domain_part <- stringr::str_match(from_field, "@([^>\\s]+)")[, 2]
        if (!is.na(domain_part) && domain_part != "") {
            pub_name <- domain_part
        }
    }
    
    list(
        uid = uid,
        datetime = date_field,
        source = pub_name,
        sender = sender_email,
        title = subj_field,
        url = browser_url,
        body = body,
        platform = "email",
        raw_source = email_text,
        image_url = NULL
    )
}

#' Fetch and Parse Unread Emails
#'
#' Searches the INBOX for UIDs higher than the last processed UID, fetches their content,
#' parses them, and saves the new high watermark.
#'
#' @param config Config list.
#' @return A list of parsed email records.
#' @export
fetch_new_emails <- function(config) {
    con <- connect_to_gmail(config$gmail_username, config$gmail_app_password)
    on.exit(try(con$close(), silent = TRUE))
    
    con$select_folder("INBOX")
    
    # Read last email ID cursor
    last_uid <- NULL
    if (file.exists(config$last_email_id_file)) {
        last_uid_raw <- readLines(config$last_email_id_file, warn = FALSE)
        if (length(last_uid_raw) > 0 && last_uid_raw != "") {
            last_uid <- as.numeric(last_uid_raw)
        }
    }
    
    # Formulate IMAP search query
    search_query <- if (!is.null(last_uid)) paste0("UID ", last_uid + 1, ":*") else "ALL"
    message("Fetching emails matching query: ", search_query)
    
    emails_uids <- con$search(request = search_query)
    
    if (length(emails_uids) == 0) {
        message("No new emails found.")
        return(list())
    }
    
    # Fetch body text
    message("Fetching ", length(emails_uids), " email body contents...")
    email_data <- con$fetch_body(msg_id = emails_uids)
    
    records <- list()
    for (i in seq_along(email_data)) {
        raw_msg <- email_data[[i]]
        uid_str <- names(email_data)[i]
        
        # Parse email
        rec <- process_email_record(raw_msg, uid_str)
        records[[length(records) + 1]] <- rec
    }
    
    # Update last processed UID cursor
    max_uid <- max(as.numeric(emails_uids))
    writeLines(as.character(max_uid), config$last_email_id_file)
    message("Email ingestion complete. Cursor updated to UID ", max_uid)
    
    return(records)
}
