#' Subscription Newsletter Ingestion Module (Substack & Ghost)
#'
#' Scrapes and extracts content from Substack/Ghost public pages or RSS feeds.
#'
#' @importFrom httr2 request req_perform resp_body_string req_retry
#' @importFrom rvest read_html html_node html_nodes html_text html_attr
#' @importFrom stringr str_trim str_squish str_replace_all str_detect
#' @importFrom lubridate ymd_hms parse_date_time
#' @importFrom digest digest
#' @importFrom xml2 read_xml xml_find_all xml_find_first xml_text
#' @importFrom dplyr %>%
#' @export

#' Scrape a Single Substack or Ghost Web Article
#'
#' Parses a public web article to extract the main content.
#'
#' @param url Direct URL to the article page.
#' @param publisher_name Friendly name of the publication.
#' @return A parsed newsletter record.
#' @export
scrape_subscription_article <- function(url, publisher_name = "Subscription Publication") {
    message("Scraping subscription article from: ", url)
    
    req <- httr2::request(url) %>% httr2::req_retry(max_tries = 3)
    resp <- tryCatch({
        httr2::req_perform(req)
    }, error = function(e) {
        message("Error loading article page: ", e$message)
        return(NULL)
    })
    
    if (is.null(resp)) return(NULL)
    
    html_content <- httr2::resp_body_string(resp)
    web_page <- tryCatch({
        rvest::read_html(html_content)
    }, error = function(e) {
        message("Error parsing page HTML: ", e$message)
        return(NULL)
    })
    
    if (is.null(web_page)) return(NULL)
    
    # 1. Extract Title
    title_node <- rvest::html_node(web_page, "h1.post-title, h1.post-full-title, h1.title, h1")
    title <- rvest::html_text(title_node)
    title <- ifelse(is.na(title) || title == "", "Untitled Article", stringr::str_trim(title))
    
    # 2. Extract Body Content (Substack: .available-content-body, Ghost: .gh-content, .post-content)
    body_node <- rvest::html_node(web_page, ".available-content-body, .gh-content, .post-content, article")
    if (is.na(body_node)) {
        # Fallback to general paragraph aggregation
        p_nodes <- rvest::html_nodes(web_page, "p")
        body <- paste(rvest::html_text(p_nodes), collapse = "\n\n")
    } else {
        body <- rvest::html_text(body_node)
    }
    body <- stringr::str_squish(body)
    
    # 3. Extract Published Date
    time_node <- rvest::html_node(web_page, "time")
    date_str <- rvest::html_attr(time_node, "datetime")
    
    parsed_dt <- tryCatch({
        if (!is.na(date_str)) {
            lubridate::parse_date_time(date_str, orders = c("Y-m-d H:M:S", "Y-m-dTH:M:Sz", "Y-m-d"))
        } else {
            Sys.time()
        }
    }, error = function(e) Sys.time())
    if (is.na(parsed_dt)) parsed_dt <- Sys.time()
    
    uid <- digest::digest(url, algo = "md5")
    
    return(list(
        uid = uid,
        datetime = as.character(parsed_dt),
        source = publisher_name,
        sender = publisher_name,
        title = title,
        url = url,
        body = body,
        platform = "subscription",
        raw_source = html_content,
        image_url = NULL
    ))
}

#' Fetch Articles via Substack/Ghost Feed
#'
#' Standard Substack feeds: publisher.substack.com/feed
#' Standard Ghost feeds: publisher.com/rss/
#'
#' @param feed_url URL of the Substack or Ghost RSS feed.
#' @param publisher_name Friendly name of the publication.
#' @return A list of parsed article records.
#' @export
fetch_subscription_feed <- function(feed_url, publisher_name = "Subscription Publication") {
    message("Fetching newsletter feed from: ", feed_url)
    
    # Reuses our standard RSS feed fetching logic
    # but cleans it specifically for subscription styling.
    # Substack/Ghost feeds return standard RSS structures.
    req <- httr2::request(feed_url) %>% httr2::req_retry(max_tries = 3)
    resp <- tryCatch({
        httr2::req_perform(req)
    }, error = function(e) {
        message("Error loading subscription feed: ", e$message)
        return(NULL)
    })
    
    if (is.null(resp)) return(list())
    
    xml_str <- httr2::resp_body_string(resp)
    
    # Check if this looks like XML
    if (!stringr::str_detect(xml_str, "^\\s*<")) {
        message("Feed response is not XML content.")
        return(list())
    }
    
    # We can parse the XML items using the xml2 package
    xml_doc <- tryCatch({
        xml2::read_xml(xml_str)
    }, error = function(e) {
        message("Error parsing subscription XML: ", e$message)
        return(NULL)
    })
    
    if (is.null(xml_doc)) return(list())
    
    items <- xml2::xml_find_all(xml_doc, "//item")
    records <- list()
    
    for (item in items) {
        title_node <- xml2::xml_find_first(item, "./title")
        title <- xml2::xml_text(title_node)
        
        link_node <- xml2::xml_find_first(item, "./link")
        link <- xml2::xml_text(link_node)
        
        desc_node <- xml2::xml_find_first(item, "./content:encoded")
        if (is.na(desc_node)) desc_node <- xml2::xml_find_first(item, "./description")
        desc <- xml2::xml_text(desc_node)
        
        date_node <- xml2::xml_find_first(item, "./pubDate")
        date_str <- xml2::xml_text(date_node)
        
        # Strip HTML markup
        body <- stringr::str_replace_all(desc, "<[^>]+>", " ")
        body <- stringr::str_replace_all(body, "&nbsp;", " ")
        body <- stringr::str_replace_all(body, "&amp;", "&")
        body <- stringr::str_replace_all(body, "&quot;", "\"")
        body <- stringr::str_squish(body)
        
        parsed_dt <- tryCatch({
            lubridate::parse_date_time(date_str, orders = c("a, d b Y H:M:S z", "Y-m-d H:M:S"))
        }, error = function(e) Sys.time())
        if (is.na(parsed_dt)) parsed_dt <- Sys.time()
        
        uid <- digest::digest(link, algo = "md5")
        
        records[[length(records) + 1]] <- list(
            uid = uid,
            datetime = as.character(parsed_dt),
            source = publisher_name,
            sender = publisher_name,
            title = title,
            url = link,
            body = body,
            platform = "subscription",
            raw_source = desc,
            image_url = NULL
        )
    }
    
    return(records)
}
