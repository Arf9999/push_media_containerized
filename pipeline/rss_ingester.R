#' RSS Feed Ingestion Module
#'
#' Fetches and parses RSS/XML news feeds for parallel narrative analysis.
#'
#' @importFrom httr2 request req_perform resp_body_string req_retry
#' @importFrom xml2 read_xml xml_find_all xml_find_first xml_text xml_attr
#' @importFrom stringr str_trim str_replace_all str_squish
#' @importFrom lubridate parse_date_time
#' @importFrom digest digest
#' @importFrom dplyr %>%
#' @export

#' Clean HTML Tags From Text
#'
#' @param html_text String containing HTML.
#' @return Sanitized text string.
clean_html <- function(html_text) {
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

#' Parse RSS/XML pubDate to POSIXct
#'
#' @param date_str Date string.
#' @return A POSIXct object.
parse_rss_date <- function(date_str) {
    if (is.na(date_str) || date_str == "") return(Sys.time())
    
    # Clean up leading/trailing whitespaces
    date_str <- stringr::str_trim(date_str)
    
    # Try formats using standard R functions first (faster & warning-free)
    dt <- as.POSIXct(date_str, format = "%a, %d %b %Y %H:%M:%S %z", tz = "UTC")
    if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%a %d %b %Y %H:%M:%S %z", tz = "UTC")
    if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%d %b %Y %H:%M:%S %z", tz = "UTC")
    if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%Y-%m-%d %H:%M:%S", tz = "UTC")
    if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    if (is.na(dt)) dt <- as.POSIXct(date_str, format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC")
    
    # Fallback to lubridate if none of the above matched
    if (is.na(dt)) {
        dt <- tryCatch({
            lubridate::parse_date_time(date_str, orders = c("a, d b Y H:M:S z", "a d b Y H:M:S z", "d b Y H:M:S z", "Y-m-d H:M:S", "Y-m-dTH:M:Sz"))
        }, error = function(e) Sys.time())
    }
    
    if (is.na(dt)) dt <- Sys.time()
    return(dt)
}

#' Fetch and Parse a Single RSS Feed
#'
#' @param feed_url URL of the RSS feed.
#' @param feed_name Friendly name of the feed publisher.
#' @return A list of parsed article records.
#' @export
fetch_rss_feed <- function(feed_url, feed_name = "RSS Feed") {
    message("Fetching RSS feed from: ", feed_url)
    
    # Fetch XML string
    req <- httr2::request(feed_url) %>% httr2::req_retry(max_tries = 3)
    resp <- tryCatch({
        httr2::req_perform(req)
    }, error = function(e) {
        message("Error fetching RSS feed: ", e$message)
        return(NULL)
    })
    
    if (is.null(resp)) return(list())
    
    xml_str <- httr2::resp_body_string(resp)
    
    # Read XML
    xml_doc <- tryCatch({
        xml2::read_xml(xml_str)
    }, error = function(e) {
        message("Error parsing XML document: ", e$message)
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
        message("No items found in feed.")
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
        link <- stringr::str_trim(link)
        body <- clean_html(desc)
        
        # Parse datetime with robust helper
        parsed_dt <- parse_rss_date(date_str)
        
        # Generate stable UID based on link hash
        uid <- digest::digest(link, algo = "md5")
        
        records[[length(records) + 1]] <- list(
            uid = uid,
            datetime = as.character(parsed_dt),
            source = feed_name,
            sender = feed_name,
            title = title,
            url = link,
            body = body,
            platform = "rss",
            raw_source = desc,
            image_url = NULL
        )
    }
    
    message("Successfully parsed ", length(records), " items from ", feed_name)
    return(records)
}
