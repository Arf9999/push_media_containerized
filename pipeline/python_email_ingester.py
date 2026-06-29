import os
import sys
import traceback
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import datetime
import time
import re
import duckdb
import json
from concurrent.futures import ThreadPoolExecutor, as_completed

from alpha.model_adapter import get_config, generate_completion, generate_embeddings
from alpha.email_ingester import get_gmail_client, fetch_email_metadata_and_text, close_gmail_client
from alpha.entity_resolver import resolve_and_store_entities
from alpha.prompts import get_analysis_system_prompt, construct_analysis_user_prompt

def log(msg, level="INFO"):
    """Timestamped logger — ensures no silent failures."""
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [{level}] {msg}"
    print(line, flush=True)
    sys.stdout.flush()

def main():
    log("=== Starting Fast Python Ingestion of ENTIRE Mailbox ===")
    config = get_config()
    
    db_path = config.get("db_path", "alpha/newsletters.db")
    log(f"Database: {db_path}")
    log(f"LLM Model: {config.get('llm_model')}")
    log(f"Embedding Model: {config.get('embedding_model')}")
    
    # 1. Connect to DuckDB and retrieve existing UIDs
    log("Connecting to DuckDB...")
    import time
    for _ in range(60):
        try:
            con_db = duckdb.connect(db_path)
            break
        except duckdb.IOException as e:
            if "lock" in str(e).lower():
                log("Database is locked. Retrying in 1s...")
                time.sleep(1)
            else:
                raise
    # Create tables if not exists
    # We can execute the setup SQL just in case
    con_db.execute("""
        CREATE TABLE IF NOT EXISTS newsletters (
            uid VARCHAR PRIMARY KEY,
            datetime TIMESTAMP,
            source VARCHAR,
            sender VARCHAR,
            title VARCHAR,
            url VARCHAR,
            summary TEXT,
            original_language_summary TEXT,
            detected_language VARCHAR,
            truncated BOOLEAN,
            content_type VARCHAR,
            topics TEXT,
            themes TEXT,
            keywords TEXT,
            subscription_marketing BOOLEAN,
            english_embedding FLOAT[],
            multilingual_embedding FLOAT[],
            raw_email TEXT,
            ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)
    con_db.execute("CREATE SEQUENCE IF NOT EXISTS entity_id_seq;")
    con_db.execute("""
        CREATE TABLE IF NOT EXISTS entities (
            entity_id INTEGER DEFAULT nextval('entity_id_seq') PRIMARY KEY,
            uid VARCHAR,
            entity_type VARCHAR,
            raw_name VARCHAR,
            canonical_name VARCHAR
        );
    """)
    con_db.execute("""
        CREATE TABLE IF NOT EXISTS entity_lexicon (
            raw_name VARCHAR PRIMARY KEY,
            canonical_name VARCHAR,
            entity_type VARCHAR,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)
    
    # Enable max performance in DuckDB
    con_db.execute("SET max_memory = '1.5GB';")
    con_db.execute("SET threads = 1;")
    
    existing_res = con_db.execute("SELECT uid FROM newsletters;").fetchall()
    existing_uids = {r[0] for r in existing_res}
    con_db.close()
    log(f"Found {len(existing_uids)} existing records in DuckDB.")
    
    # 2. Connect to Gmail using persistent connection
    log("Connecting to Gmail IMAP...")
    client = get_gmail_client(config["gmail_username"], config["gmail_app_password"])
    
    # Search year-by-year
    log("Searching mailbox year-by-year...")
    current_year = datetime.date.today().year
    all_uids = []
    
    for year in range(current_year, 2015, -1):
        start_date = datetime.date(year, 1, 1)
        end_date = datetime.date(year, 12, 31)
        if year == current_year:
            end_date = datetime.date.today()
            
        start_date_str = start_date.strftime("%d-%b-%Y")
        end_date_str = end_date.strftime("%d-%b-%Y")
        print(f"Searching year {year} ({start_date_str} to {end_date_str})...")
        try:
            year_uids = client.search(['SINCE', start_date_str, 'BEFORE', end_date_str])
            log(f"Found {len(year_uids)} UIDs in {year}.")
            all_uids.extend(year_uids)
        except Exception as e:
            log(f"Search failed for {year}: {e}", level="ERROR")
            
    all_uids = sorted(list(set(all_uids)))
    log(f"Found total {len(all_uids)} unique UIDs across search periods.")
    
    # Filter new UIDs
    new_uids = []
    for u in all_uids:
        u_str = str(u)
        if u_str not in existing_uids and f"body{u_str}" not in existing_uids:
            new_uids.append(u)
            
    log(f"{len(all_uids) - len(new_uids)} UIDs already in DB. {len(new_uids)} new emails to process.")
    
    if not new_uids:
        log("No new emails to ingest. Complete.")
        close_gmail_client()
        return
        
    # Process in chunks
    # Large chunk size = fewer IMAP FETCH commands = less request-count pressure.
    # Overquota appears bandwidth/time-window based (~30 min window) so we also
    # proactively reconnect every N chunks to reset the session before hitting the limit.
    chunk_size = 50
    INTER_CHUNK_SLEEP_SECS = 3       # Brief pause between chunks
    OVERQUOTA_SLEEP_SECS = 600       # 10-min reactive cooldown (fallback if proactive fails)
    MAX_FETCH_ATTEMPTS = 5           # Max retries per chunk before skipping
    PROACTIVE_RECONNECT_EVERY = 30   # Reconnect every N chunks (~1,500 emails) before hitting limit
    PROACTIVE_RECONNECT_PAUSE = 300  # 5-min pause on proactive reconnect
    total_new = len(new_uids)
    
    def process_single_email(uid, rec):
        try:
            # Word truncation (limit to 12,000 words)
            words = rec["body"].split()
            truncated = False
            content_to_llm = rec["body"]
            if len(words) > 12000:
                content_to_llm = " ".join(words[:12000])
                truncated = True
                
            # LLM Analysis
            sys_prompt = get_analysis_system_prompt()
            user_prompt = construct_analysis_user_prompt(rec["title"], rec["sender"], content_to_llm)
            
            llm_resp = generate_completion(user_prompt, system_prompt=sys_prompt, json_mode=True, config=config)
            
            # Clean JSON response
            llm_resp = re.sub(r'^```json\s*', '', llm_resp)
            llm_resp = re.sub(r'\s*```$', '', llm_resp)
            
            analysis = json.loads(llm_resp)
            
            if analysis.get("detected_language") == "en":
                analysis["summary_orig"] = analysis["summary_en"]
                
            topics_str = ", ".join(analysis.get("topics", []))
            themes_str = ", ".join(analysis.get("themes", []))
            keywords_str = ", ".join(analysis.get("keywords", []))
            
            # Embeddings
            emb_text_en = f"{analysis['summary_en']}\nTopics: {topics_str}\nThemes: {themes_str}"
            orig_sum = analysis.get("summary_orig") or analysis.get("summary_en")
            emb_text_orig = f"{orig_sum}\nTopics: {topics_str}\nThemes: {themes_str}"
            
            en_emb = generate_embeddings(emb_text_en, config)
            multiling_emb = generate_embeddings(emb_text_orig, config)
            
            if not en_emb or not multiling_emb:
                log(f"Skipping UID {uid} — embedding generation failed.", level="WARN")
                return None
                
            pub_author = analysis.get("publisher_metadata", {}).get("author") or "Unknown"
            pub_pub = analysis.get("publisher_metadata", {}).get("publisher") or rec["source"]
            platform = rec.get("platform", "email")
            
            return {
                "uid": rec["uid"],
                "datetime": rec["datetime"],
                "source": pub_pub,
                "sender": rec["sender"],
                "title": rec["title"],
                "url": rec["url"],
                "summary": analysis["summary_en"],
                "original_language_summary": analysis["summary_orig"],
                "detected_language": analysis.get("detected_language", "en"),
                "truncated": truncated,
                "content_type": platform,
                "topics": topics_str,
                "themes": themes_str,
                "keywords": keywords_str,
                "subscription_marketing": bool(analysis.get("subscription_marketing")),
                "english_embedding": en_emb,
                "multilingual_embedding": multiling_emb,
                "raw_email": rec["raw_email"],
                "entities": analysis.get("entities", [])
            }
        except Exception as e:
            log(f"FAILED processing UID {uid}: {e}", level="ERROR")
            traceback.print_exc()
            return None

    # Start loop
    for chunk_idx in range(0, total_new, chunk_size):
        chunk_uids = new_uids[chunk_idx:chunk_idx+chunk_size]
        chunk_num = chunk_idx // chunk_size + 1
        total_chunks = -(-total_new // chunk_size)
        log(f"--- Fetching Chunk {chunk_num} / {total_chunks} (UIDs {chunk_uids[0]} to {chunk_uids[-1]}) ---")

        # Proactive reconnect: reset the IMAP session before hitting the quota window.
        # Every PROACTIVE_RECONNECT_EVERY chunks we close, pause, and reconnect
        # rather than waiting for Gmail to throw [OVERQUOTA].
        if chunk_num > 1 and (chunk_num - 1) % PROACTIVE_RECONNECT_EVERY == 0:
            log(f"[PROACTIVE] Chunk {chunk_num}: preemptive reconnect after {PROACTIVE_RECONNECT_EVERY} chunks. Pausing {PROACTIVE_RECONNECT_PAUSE}s...", level="WARN")
            close_gmail_client()
            time.sleep(PROACTIVE_RECONNECT_PAUSE)
            log("[PROACTIVE] Reconnecting to Gmail IMAP...")
            client = get_gmail_client(config["gmail_username"], config["gmail_app_password"])
        
        # Fetch with retry + reconnect on Gmail [OVERQUOTA] / abort
        email_records = {}
        for fetch_attempt in range(1, MAX_FETCH_ATTEMPTS + 1):
            try:
                email_records = fetch_email_metadata_and_text(client, chunk_uids)
                break  # success
            except Exception as fetch_err:
                err_str = str(fetch_err)
                log(f"IMAP fetch error (attempt {fetch_attempt}/{MAX_FETCH_ATTEMPTS}): {fetch_err}", level="ERROR")
                is_quota = 'OVERQUOTA' in err_str or 'abort' in err_str.lower() or 'timeout' in err_str.lower() or 'BYE' in err_str
                if is_quota and fetch_attempt < MAX_FETCH_ATTEMPTS:
                    log(f"[OVERQUOTA/ABORT] Gmail throttling. Cooling down {OVERQUOTA_SLEEP_SECS}s then reconnecting...", level="WARN")
                    close_gmail_client()
                    time.sleep(OVERQUOTA_SLEEP_SECS)
                    log("Reconnecting to Gmail IMAP...")
                    client = get_gmail_client(config["gmail_username"], config["gmail_app_password"])
                else:
                    log(f"Skipping chunk after {fetch_attempt} failed attempt(s).", level="WARN")
                    break

        if not email_records:
            log(f"Chunk {chunk_num}: no records returned (fetch skipped or all empty). Continuing.", level="WARN")
            continue
            
        log(f"Chunk {chunk_num}: processing {len(email_records)} records in parallel...")
        valid_results = []
        
        # Parallel LLM extraction and embedding using ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as executor:
            future_to_uid = {
                executor.submit(process_single_email, uid, email_records[uid]): uid 
                for uid in email_records
            }
            for future in as_completed(future_to_uid):
                res = future.result()
                if res:
                    valid_results.append(res)
                    
        if valid_results:
            log(f"Chunk {chunk_num}: writing {len(valid_results)} records to DB...")
            try:
                con_db = duckdb.connect(db_path)
                con_db.execute("SET max_memory = '1.5GB';")
                con_db.execute("SET threads = 1;")
                for item in valid_results:
                    con_db.execute("""
                        INSERT INTO newsletters (
                            uid, datetime, source, sender, title, url, summary,
                            original_language_summary, detected_language, truncated, content_type,
                            topics, themes, keywords, subscription_marketing,
                            english_embedding, multilingual_embedding, raw_email
                        ) VALUES (
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                        ) ON CONFLICT(uid) DO NOTHING;
                    """, [
                        item["uid"],
                        item["datetime"],
                        item["source"],
                        item["sender"],
                        item["title"],
                        item["url"],
                        item["summary"],
                        item["original_language_summary"],
                        item["detected_language"],
                        item["truncated"],
                        item["content_type"],
                        item["topics"],
                        item["themes"],
                        item["keywords"],
                        item["subscription_marketing"],
                        item["english_embedding"],
                        item["multilingual_embedding"],
                        item["raw_email"]
                    ])
                    
                    if item["entities"]:
                        resolve_and_store_entities(item["uid"], item["entities"], con_db)
                con_db.close()
                log(f"Chunk {chunk_num}: committed to database.")
            except Exception as e:
                try:
                    con_db.close()
                except Exception:
                    pass
                log(f"CRITICAL: Error committing chunk {chunk_num} to DuckDB: {e}", level="ERROR")
                traceback.print_exc()
                
        log(f"Progress: {min(chunk_idx + chunk_size, total_new)} / {total_new} emails processed.")
        time.sleep(INTER_CHUNK_SLEEP_SECS)  # Rate-limit: brief pause between chunks
        
    close_gmail_client()
    log("=== Bulk Ingestion Complete ===")

if __name__ == "__main__":
    try:
        main()
    except Exception as fatal_err:
        log(f"=== FATAL UNHANDLED EXCEPTION — SCRIPT TERMINATING ===", level="FATAL")
        log(f"{fatal_err}", level="FATAL")
        traceback.print_exc()
        sys.exit(1)
