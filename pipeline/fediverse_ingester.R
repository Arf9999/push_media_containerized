#' Fediverse Ingestion Module
#'
#' Fetches and parses public posts from Mastodon/Fediverse handles via RSS feeds.
#' Handles formatting, retry logic, and fallback paths.
#'
#' @importFrom httr2 request req_perform resp_body_string req_retry
#' @importFrom xml2 read_xml xml_find_all xml_find_first xml_text xml_attr
#' @importFrom stringr str_trim str_replace_all str_squish
#' @importFrom lubridate parse_date_time
#' @importFrom digest digest
#' @importFrom dplyr %>%
#' @importFrom rvest read_html html_node html_nodes html_text html_attr
#' @export

#' Clean HTML Tags From Text
#'
#' @param html_text String containing HTML.
#' @return Sanitized text string.
clean_fediverse_html <- function(html_text) {
    if (is.na(html_text) || html_text == "") return("")
    # Strip HTML tags
    cleaned <- stringr::str_replace_all(html_text, "<[^>]+>", " ")
    # Replace common HTML entities
    cleaned <- stringr::str_replace_all(cleaned, "&nbsp;", " ")
    cleaned <- stringr::str_replace_all(cleaned, "&amp;", "&")
    cleaned <- stringr::str_replace_all(cleaned, "&lt;", "<")
    cleaned <- stringr::str_replace_all(cleaned, "&gt;", ">")
    cleaned <- stringr::str_replace_all(cleaned, "&quot;", "\"")
    cleaned <- stringr::str_squish(cleaned)
    return(cleaned)
}

#' Check if a Link is an Actual External Article
#'
#' Filters out typical internal Fediverse structure URLs (profiles, statuses, tags, media).
#'
#' @param url Target URL.
#' @return Logical indicating if it is an external article link.
is_actual_article_link <- function(url) {
    if (is.na(url) || url == "") return(FALSE)
    if (!grepl("^https?://", url)) return(FALSE)
    
    # Exclude typical Fediverse structures (profiles, statuses, tags, media)
    if (grepl("/tags/|/explore/|/media/|/files/|/assets/", url, ignore.case = TRUE)) return(FALSE)
    if (grepl("/@", url, fixed = TRUE)) return(FALSE)
    if (grepl("/users/", url, fixed = TRUE)) return(FALSE)
    if (grepl("/statuses/", url, fixed = TRUE)) return(FALSE)
    
    return(TRUE)
}

#' Scrape Webpage Content
#'
#' Fetches and extracts main text content from a general external article URL.
#'
#' @param url External article URL.
#' @return Scraped text string or NULL if failed.
scrape_webpage_content <- function(url) {
    message("Scraping external page: ", url)
    req <- httr2::request(url) %>% httr2::req_retry(max_tries = 3)
    resp <- tryCatch({
        httr2::req_perform(req)
    }, error = function(e) {
        message("Failed to fetch external URL: ", e$message)
        return(NULL)
    })
    
    if (is.null(resp)) return(NULL)
    
    html_content <- httr2::resp_body_string(resp)
    web_page <- tryCatch({
        rvest::read_html(html_content)
    }, error = function(e) {
        message("Failed to parse external HTML: ", e$message)
        return(NULL)
    })
    
    if (is.null(web_page)) return(NULL)
    
    # Try common article containers
    body_node <- rvest::html_node(web_page, "article, .post-content, .article-content, .entry-content")
    if (!is.na(body_node)) {
        text_content <- rvest::html_text(body_node)
    } else {
        # Fallback to fetching all paragraphs
        p_nodes <- rvest::html_nodes(web_page, "p")
        text_content <- paste(rvest::html_text(p_nodes), collapse = "\n\n")
    }
    
    cleaned_text <- stringr::str_squish(text_content)
    if (cleaned_text == "") return(NULL)
    return(cleaned_text)
}


#' Parse Fediverse Handle
#'
#' Parses `@user@domain` or `user@domain` into a list with username and domain.
#'
#' @param handle Fediverse handle string.
#' @return A list with `username` and `domain`.
parse_fediverse_handle <- function(handle) {
    handle_clean <- stringr::str_trim(handle)
    handle_clean <- gsub("^@", "", handle_clean)
    
    parts <- strsplit(handle_clean, "@")[[1]]
    if (length(parts) != 2) {
        stop(paste("Invalid Fediverse handle format:", handle, ". Expected @username@domain or username@domain"))
    }
    
    list(
        username = parts[1],
        domain = parts[2]
    )
}

#' Fetch and Parse Fediverse Profile Posts
#'
#' Resolves a Fediverse handle, fetches its public RSS feed, and parses the posts.
#'
#' @param handle Fediverse handle (e.g. `@Gargron@mastodon.social`).
#' @return A list of parsed article records.
#' @export
fetch_fediverse_posts <- function(handle) {
    parsed <- parse_fediverse_handle(handle)
    username <- parsed$username
    domain <- parsed$domain
    
    # Standard Mastodon RSS feed format
    primary_url <- paste0("https://", domain, "/@", username, ".rss")
    message("Fetching Fediverse posts for ", handle, " from: ", primary_url)
    
    req <- httr2::request(primary_url) %>% httr2::req_retry(max_tries = 3)
    resp <- tryCatch({
        httr2::req_perform(req)
    }, error = function(e) {
        message("Primary RSS feed failed: ", e$message)
        # Try fallback format (some Mastodon / Pleroma instances use /users/username.rss)
        fallback_url <- paste0("https://", domain, "/users/", username, ".rss")
        message("Trying fallback RSS feed: ", fallback_url)
        
        fallback_req <- httr2::request(fallback_url) %>% httr2::req_retry(max_tries = 3)
        tryCatch({
            httr2::req_perform(fallback_req)
        }, error = function(e2) {
            message("Fallback RSS feed also failed: ", e2$message)
            return(NULL)
        })
    })
    
    if (is.null(resp)) {
        message("Could not retrieve RSS feed for Fediverse handle: ", handle)
        return(list())
    }
    
    xml_str <- httr2::resp_body_string(resp)
    
    # Read XML
    xml_doc <- tryCatch({
        xml2::read_xml(xml_str)
    }, error = function(e) {
        message("Error parsing Fediverse XML document: ", e$message)
        return(NULL)
    })
    
    if (is.null(xml_doc)) return(list())
    
    # Find all items
    items <- xml2::xml_find_all(xml_doc, "//item")
    if (length(items) == 0) {
        # Try Atom entry nodes
        items <- xml2::xml_find_all(xml_doc, "//entry")
    }
    
    if (length(items) == 0) {
        message("No posts found in Fediverse feed.")
        return(list())
    }
    
    records <- list()
    for (item in items) {
        # Extract title
        title_node <- xml2::xml_find_first(item, "./title")
        title <- xml2::xml_text(title_node)
        
        # Extract link
        link_node <- xml2::xml_find_first(item, "./link")
        link <- xml2::xml_text(link_node)
        if (is.na(link) || link == "") {
            # Try href attribute (Atom)
            link_node <- xml2::xml_find_first(item, "./link[@rel='alternate']")
            if (is.na(link_node)) link_node <- xml2::xml_find_first(item, "./link")
            link <- xml2::xml_attr(link_node, "href")
        }
        
        # Extract description/content
        desc_node <- xml2::xml_find_first(item, "./description")
        if (is.na(desc_node)) desc_node <- xml2::xml_find_first(item, "./content")
        if (is.na(desc_node)) desc_node <- xml2::xml_find_first(item, "./summary")
        desc <- xml2::xml_text(desc_node)
        
        # Extract date
        date_node <- xml2::xml_find_first(item, "./pubDate")
        if (is.na(date_node)) date_node <- xml2::xml_find_first(item, "./published")
        if (is.na(date_node)) date_node <- xml2::xml_find_first(item, "./updated")
        date_str <- xml2::xml_text(date_node)
        
        # Clean extracted text
        title <- stringr::str_trim(title)
        body <- clean_fediverse_html(desc)
        link <- stringr::str_trim(link)
        
        # Extract links from original description HTML to find candidate external articles
        target_link <- NULL
        if (!is.na(desc) && desc != "") {
            html_doc <- tryCatch({
                rvest::read_html(desc)
            }, error = function(e) NULL)
            
            if (!is.null(html_doc)) {
                a_nodes <- rvest::html_nodes(html_doc, "a")
                hrefs <- rvest::html_attr(a_nodes, "href")
                
                # Filter out NA and empty URLs
                clean_links <- hrefs[!is.na(hrefs) & hrefs != ""]
                
                if (length(clean_links) > 0) {
                    # Filter to find actual article links (exclude profiles, hashtags, attachments, etc.)
                    is_article <- vapply(clean_links, is_actual_article_link, logical(1))
                    external_links <- clean_links[is_article]
                    
                    if (length(external_links) > 0) {
                        target_link <- external_links[1]
                    }
                }
            }
        }
        
        url_to_save <- link
        if (!is.null(target_link)) {
            scraped_content <- tryCatch({
                scrape_webpage_content(target_link)
            }, error = function(e) {
                message("Error during external page scraping: ", e$message)
                NULL
            })
            
            if (!is.null(scraped_content) && scraped_content != "") {
                body <- paste0("[Fediverse Update]: ", body, "\n\n[Scraped Article Content from ", target_link, "]:\n", scraped_content)
                url_to_save <- target_link
            }
        }
        
        # Format/truncate title for display
        if (is.na(title) || title == "" || nchar(title) == 0) {
            title <- paste0("Fediverse post by @", username)
        } else if (nchar(title) > 80) {
            title <- paste0(substr(title, 1, 77), "...")
        }
        
        # Parse datetime with fallback formats
        parsed_dt <- tryCatch({
            lubridate::parse_date_time(date_str, orders = c("a, d b Y H:M:S z", "Y-m-d H:M:S", "Y-m-dTH:M:Sz"))
        }, error = function(e) Sys.time())
        
        if (is.na(parsed_dt)) parsed_dt <- Sys.time()
        
        # Generate stable UID based on link hash
        uid <- digest::digest(link, algo = "md5")
        
        records[[length(records) + 1]] <- list(
            uid = uid,
            datetime = as.character(parsed_dt),
            source = paste0("Fediverse: @", username, "@", domain),
            sender = username,
            title = title,
            url = url_to_save,
            body = body,
            platform = "fediverse",
            raw_source = desc,
            image_url = NULL
        )
    }
    
    message("Successfully parsed ", length(records), " posts for handle ", handle)
    return(records)
}
