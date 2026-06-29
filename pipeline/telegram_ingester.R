#' Telegram Channel Ingestion Module
#'
#' Scrapes public Telegram channel previews via their web interface (`t.me/s/`)
#' to ingest updates without needing API keys.
#'
#' @importFrom httr2 request req_perform resp_body_string req_retry
#' @importFrom rvest read_html html_nodes html_node html_text html_attr
#' @importFrom stringr str_trim str_squish
#' @importFrom lubridate ymd_hms
#' @importFrom digest digest
#' @importFrom dplyr %>%
#' @export

#' Scrape Public Telegram Channel Posts
#'
#' @param channel_name Username/slug of the public Telegram channel.
#' @return A list of parsed message records.
#' @export
fetch_telegram_channel <- function(channel_name) {
    url <- paste0("https://t.me/s/", channel_name)
    message("Scraping Telegram channel preview from: ", url)
    
    req <- httr2::request(url) %>% httr2::req_retry(max_tries = 3)
    resp <- tryCatch({
        httr2::req_perform(req)
    }, error = function(e) {
        message("Error loading Telegram web page: ", e$message)
        return(NULL)
    })
    
    if (is.null(resp)) return(list())
    
    html_content <- httr2::resp_body_string(resp)
    web_page <- tryCatch({
        rvest::read_html(html_content)
    }, error = function(e) {
        message("Error parsing Telegram HTML: ", e$message)
        return(NULL)
    })
    
    if (is.null(web_page)) return(list())
    
    # Locate all message wraps
    msg_nodes <- rvest::html_nodes(web_page, ".tgme_widget_message_wrap")
    if (length(msg_nodes) == 0) {
        # Fallback to direct message class
        msg_nodes <- rvest::html_nodes(web_page, ".tgme_widget_message")
    }
    
    if (length(msg_nodes) == 0) {
        message("No messages found in the Telegram preview.")
        return(list())
    }
    
    records <- list()
    for (node in msg_nodes) {
        # 1. Extract image URL if present
        img_url <- NULL
        photo_node <- rvest::html_node(node, ".tgme_widget_message_photo_wrap")
        if (!is.na(photo_node)) {
            style_attr <- rvest::html_attr(photo_node, "style")
            if (!is.na(style_attr)) {
                img_url_match <- regmatches(style_attr, regexec("background-image:\\s*url\\(\\s*['\"]?(.*?)['\"]?\\s*\\)", style_attr))
                if (length(img_url_match[[1]]) >= 2) {
                    img_url <- img_url_match[[1]][2]
                }
            }
        }
        
        # 2. Locate message text node
        text_node <- rvest::html_node(node, ".tgme_widget_message_text")
        
        # If there is neither text nor image, skip the post (e.g. service messages or empty nodes)
        if (is.na(text_node) && is.null(img_url)) next
        
        raw_text <- ""
        text <- ""
        if (!is.na(text_node)) {
            raw_text <- rvest::html_text(text_node)
            text <- stringr::str_squish(raw_text)
        }
        
        # 3. Extract datetime attribute from time tag
        time_node <- rvest::html_node(node, "time")
        date_str <- rvest::html_attr(time_node, "datetime")
        
        parsed_dt <- tryCatch({
            lubridate::ymd_hms(date_str)
        }, error = function(e) Sys.time())
        if (is.na(parsed_dt)) parsed_dt <- Sys.time()
        
        # 4. Extract direct link to message
        link_node <- rvest::html_node(node, ".tgme_widget_message_date")
        msg_link <- rvest::html_attr(link_node, "href")
        if (is.na(msg_link) || msg_link == "") {
            # Generate dummy link based on text/image hash
            h_val <- if (text != "") text else img_url
            msg_link <- paste0("https://t.me/", channel_name, "/", digest::digest(h_val, algo = "md5"))
        }
        
        uid <- digest::digest(msg_link, algo = "md5")
        
        records[[length(records) + 1]] <- list(
            uid = uid,
            datetime = as.character(parsed_dt),
            source = paste0("Telegram: @", channel_name),
            sender = channel_name,
            title = paste0("Telegram Post - @", channel_name),
            url = msg_link,
            body = text,
            platform = "telegram",
            raw_source = if (raw_text != "") raw_text else "[Photo-Only Update]",
            image_url = img_url
        )
    }
    
    message("Successfully scraped ", length(records), " messages from @", channel_name)
    return(records)
}
