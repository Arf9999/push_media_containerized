import os
import sys
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import time
import datetime
import json
import duckdb
import re
import traceback

from alpha.model_adapter import get_config, generate_completion, generate_embeddings
from alpha.email_ingester import get_gmail_client, fetch_email_metadata_and_text, close_gmail_client
from alpha.entity_resolver import resolve_and_store_entities
from alpha.prompts import get_analysis_system_prompt, construct_analysis_user_prompt

def process_uid(uid, rec, config, con_db):
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
            print(f"Skipping UID {uid} due to embedding generation failure.")
            return False
            
        pub_author = analysis.get("publisher_metadata", {}).get("author") or "Unknown"
        pub_pub = analysis.get("publisher_metadata", {}).get("publisher") or rec["source"]
        platform = rec.get("platform", "email")
        
        # Write to DuckDB
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
            rec["uid"],
            rec["datetime"],
            pub_pub,
            rec["sender"],
            rec["title"],
            rec["url"],
            analysis["summary_en"],
            analysis["summary_orig"],
            analysis.get("detected_language", "en"),
            truncated,
            platform,
            topics_str,
            themes_str,
            keywords_str,
            bool(analysis.get("subscription_marketing")),
            en_emb,
            multiling_emb,
            rec["raw_email"]
        ])
        
        if analysis.get("entities"):
            resolve_and_store_entities(rec["uid"], analysis["entities"], con_db)
            
        print(f"Successfully ingested and resolved new email: {rec['title']} (UID {uid})")
        return True
    except Exception as e:
        print(f"Error processing UID {uid}: {e}")
        traceback.print_exc()
        return False

def check_for_new_emails(client, config):
    db_path = config.get("db_path", "alpha/newsletters.db")
    
    # 1. Connect to DB to check existing UIDs
    con_db = duckdb.connect(db_path)
    existing_res = con_db.execute("SELECT uid FROM newsletters;").fetchall()
    existing_uids = {r[0] for r in existing_res}
    
    # 2. Search Gmail for latest UIDs
    # Search last 7 days to keep it very fast and avoid scanning 10k messages
    since_date = (datetime.date.today() - datetime.timedelta(days=7))
    since_date_str = since_date.strftime("%d-%b-%Y")
    uids = client.search(['SINCE', since_date_str])
    
    new_uids = []
    for u in uids:
        u_str = str(u)
        if u_str not in existing_uids and f"body{u_str}" not in existing_uids:
            new_uids.append(u)
            
    if new_uids:
        print(f"Found {len(new_uids)} new emails to process: {new_uids}")
        email_records = fetch_email_metadata_and_text(client, new_uids)
        for uid in new_uids:
            if uid in email_records:
                process_uid(uid, email_records[uid], config, con_db)
    else:
        print("No new emails found in the last 7 days search.")
        
    con_db.close()

def main():
    print("=== Starting Real-Time Gmail Ingestion Daemon (IMAP IDLE) ===")
    config = get_config()
    
    while True:
        try:
            client = get_gmail_client(config["gmail_username"], config["gmail_app_password"])
            
            # Initial sync check on startup
            print("Running initial email synchronization check...")
            check_for_new_emails(client, config)
            
            print("Entering IMAP IDLE monitoring loop. Listening for incoming emails...")
            
            # Start IDLE mode
            client.idle()
            
            while True:
                # Wait for updates. Check every 29 minutes (1740 seconds) to refresh the IDLE session as Gmail drops after 30 mins
                responses = client.idle_check(timeout=1740)
                
                # We received activity
                if responses:
                    print(f"IMAP IDLE Activity Detected: {responses}")
                    
                    # Exit IDLE mode to execute commands
                    client.idle_done()
                    
                    # Sync and process any new emails
                    check_for_new_emails(client, config)
                    
                    # Re-enter IDLE mode
                    client.idle()
                else:
                    # Timeout reached, refresh IDLE session
                    print("Refreshing IMAP IDLE session...")
                    client.idle_done()
                    client.idle()
                    
        except KeyboardInterrupt:
            print("\nShutting down IMAP IDLE daemon...")
            try:
                client.idle_done()
            except Exception:
                pass
            close_gmail_client()
            break
        except Exception as e:
            print(f"Daemon Error: {e}")
            traceback.print_exc()
            print("Reconnecting in 10 seconds...")
            close_gmail_client()
            time.sleep(10)

if __name__ == "__main__":
    main()
