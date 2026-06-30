import os
import datetime
import re
import csv
import io
import logging
import hashlib
import psycopg
from psycopg.rows import dict_row
from fastapi import FastAPI, HTTPException, Query, Header, status
from fastapi.staticfiles import StaticFiles
from fastapi.responses import StreamingResponse, FileResponse
from pydantic import BaseModel, Field

# Base Directory Paths and Configurable Storage Paths for GCP/GCS Deployment Portability
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# PostgreSQL connection. In Docker this points at the local postgres service; in AWS
# it can point at RDS without code changes.
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://pushmedia:pushmedia@postgres:5432/pushmedia")
LOG_DIR = os.environ.get("SURVEY_LOG_DIR", os.path.join(BASE_DIR, "logs"))
LOG_PATH = os.path.join(LOG_DIR, "survey_activity.log")

# Ensure target directories exist
os.makedirs(LOG_DIR, exist_ok=True)

# Configure Activity Logging
logger = logging.getLogger("survey_activity")
logger.setLevel(logging.INFO)

# File handler
file_handler = logging.FileHandler(LOG_PATH, encoding="utf-8")
file_handler.setLevel(logging.INFO)
formatter = logging.Formatter('%(asctime)s - %(levelname)s - %(message)s')
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)

# Stream handler for stdout visibility
stream_handler = logging.StreamHandler()
stream_handler.setLevel(logging.INFO)
stream_handler.setFormatter(formatter)
logger.addHandler(stream_handler)

# Admin Security Config
ADMIN_PASSCODE = os.environ.get("SURVEY_ADMIN_PASSCODE", "admin123")

def verify_admin_token(x_admin_token: str = Header(None)):
    """Dependency to enforce passcode-based admin authentication."""
    if not x_admin_token or x_admin_token != ADMIN_PASSCODE:
        logger.warning("Authentication failure: Blocked unauthorized admin action.")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing Admin passcode."
        )

# Secure password hashing helper
def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode('utf-8')).hexdigest()

def get_db_conn(rows=None):
    if rows is None:
        return psycopg.connect(DATABASE_URL)
    return psycopg.connect(DATABASE_URL, row_factory=rows)

# Initialize Database Schema with migration handling
def init_db():
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("CREATE SCHEMA IF NOT EXISTS survey")
    
    # Sources Table
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS survey.sources (
            source_id TEXT PRIMARY KEY,
            source_name TEXT NOT NULL,
            platform TEXT NOT NULL,
            ingest_url TEXT UNIQUE NOT NULL,
            primary_language TEXT NOT NULL,
            languages_spoken TEXT,
            geographic_focus TEXT,
            publisher_type TEXT,
            input_by TEXT DEFAULT 'unknown',
            date_added DATE NOT NULL,
            gating_passed BOOLEAN DEFAULT FALSE,
            activity_passed BOOLEAN DEFAULT FALSE,
            telegram_passed BOOLEAN DEFAULT FALSE,
            is_verified BOOLEAN DEFAULT FALSE,
            is_deleted BOOLEAN DEFAULT FALSE
        )
    """)
    
    # Users Table for credentials verification
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS survey.users (
            username TEXT PRIMARY KEY,
            password TEXT NOT NULL
        )
    """)
    
    # Seed default user accounts if table is empty
    cursor.execute("SELECT COUNT(*) FROM survey.users")
    if cursor.fetchone()[0] == 0:
        defaults = [
            ("ra_amina", hash_password("amina2026")),
            ("ra_bob", hash_password("bob2026")),
            ("ra_coordinator", hash_password("coord2026")),
            ("andrew", hash_password("1234"))
        ]
        cursor.executemany("INSERT INTO survey.users (username, password) VALUES (%s, %s)", defaults)
        logger.info("Database: Seeded default allocated accounts: ra_amina, ra_bob, ra_coordinator, andrew.")
    
    # Handle DB Schema Migrations for existing deployments
    cursor.execute("ALTER TABLE survey.sources ADD COLUMN IF NOT EXISTS input_by TEXT DEFAULT 'unknown'")
        
    conn.commit()
    conn.close()
    logger.info("Postgres survey schema initialized successfully.")

init_db()

# Initialize FastAPI App
app = FastAPI(
    title="Regional Media Ingestion Survey API",
    description="Backend API for mapping public Telegram channels, Substack newsletters, and RSS feeds.",
    version="1.3.0"
)

@app.get("/health")
def health():
    try:
        with get_db_conn() as conn:
            with conn.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()
        return {"status": "ok", "database": "connected"}
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Database unavailable") from exc

# Pydantic Schemas for Requests
class SourceCreate(BaseModel):
    source_name: str = Field(..., min_length=2, max_length=150)
    platform: str = Field(..., pattern="^(telegram|rss|newsletter|fediverse)$")
    ingest_url: str = Field(..., min_length=5)
    primary_language: str = Field(..., min_length=2, max_length=10)
    languages_spoken: str = Field(None, max_length=200)
    geographic_focus: str = Field(None, max_length=200)
    publisher_type: str = Field(..., pattern="^(state_media|independent_journalist|civil_society|anonymous_influencer|consumer_news|cultural_music_art|gossip_celebrity|newsfluencer|mainstream_publication|sport|technology_science|pr_news_agency|other)$")
    input_by: str = Field(..., min_length=2, max_length=100)
    gating_passed: bool
    activity_passed: bool
    telegram_passed: bool
    country_iso: str = Field(..., min_length=2, max_length=5)
    topic_code: str = Field(..., min_length=2, max_length=10)

class UserAuth(BaseModel):
    username: str = Field(..., min_length=2, max_length=50)
    password: str = Field(..., min_length=4, max_length=100)

# Automated source_id Generation Logic
def generate_source_id(country_iso: str, platform: str, topic_code: str) -> str:
    country = country_iso.strip().upper()
    platform_map = {
        "telegram": "TEL",
        "rss": "RSS",
        "newsletter": "NEW",
        "fediverse": "FED"
    }
    plat = platform_map.get(platform.lower(), "SRC")
    
    topic = topic_code.strip().upper()
    topic = re.sub(r'[^A-Z0-9]', '', topic)[:4]
    if not topic:
        topic = "GEN"
        
    prefix = f"{country}_{plat}_{topic}_"
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute(
        "SELECT source_id FROM survey.sources WHERE source_id LIKE %s",
        (f"{prefix}%",)
    )
    rows = cursor.fetchall()
    conn.close()
    
    max_num = 0
    for (sid,) in rows:
        parts = sid.split("_")
        if parts:
            try:
                num = int(parts[-1])
                if num > max_num:
                    max_num = num
            except ValueError:
                continue
                
    next_num = max_num + 1
    suffix = f"{next_num:03d}"
    return f"{prefix}{suffix}"

# API Endpoints

@app.post("/api/login")
def login_user(auth: UserAuth):
    """Authenticate an Auditor user."""
    username_clean = auth.username.strip().lower()
    hashed = hash_password(auth.password)
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT username FROM survey.users WHERE username = %s AND password = %s", (username_clean, hashed))
    user = cursor.fetchone()
    conn.close()
    
    if not user:
        logger.warning(f"Auth failure: Failed login attempt for user '{username_clean}'")
        raise HTTPException(status_code=401, detail="Invalid username or password.")
        
    logger.info(f"Auth: Successful login for auditor: '{username_clean}'")
    return {"status": "success", "username": username_clean}

# Admin User Management Endpoints (Coordinator Allocation)

@app.get("/api/admin/users")
def get_allocated_users(x_admin_token: str = Header(None)):
    """Fetch all allocated user accounts. Restricted to Admin."""
    verify_admin_token(x_admin_token)
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT username FROM survey.users ORDER BY username ASC")
    users = [row[0] for row in cursor.fetchall()]
    conn.close()
    return users

@app.post("/api/admin/users")
def allocate_user(auth: UserAuth, x_admin_token: str = Header(None)):
    """Allocate a new Auditor user account. Restricted to Admin."""
    verify_admin_token(x_admin_token)
    username_clean = auth.username.strip().lower()
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT username FROM survey.users WHERE username = %s", (username_clean,))
    if cursor.fetchone():
        conn.close()
        raise HTTPException(status_code=400, detail="Username is already allocated.")
        
    hashed = hash_password(auth.password)
    try:
        cursor.execute("INSERT INTO survey.users (username, password) VALUES (%s, %s)", (username_clean, hashed))
        conn.commit()
        logger.info(f"Action: Admin allocated new auditor: '{username_clean}'")
    except Exception as e:
        conn.close()
        logger.error(f"Auth error during registration: {e}")
        raise HTTPException(status_code=500, detail="Internal server error during registration.")
    finally:
        conn.close()
        
    return {"status": "success", "username": username_clean}

@app.delete("/api/admin/users/{username}")
def revoke_user(username: str, x_admin_token: str = Header(None)):
    """Revoke/Delete an Auditor user account. Restricted to Admin."""
    verify_admin_token(x_admin_token)
    username_clean = username.strip().lower()
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT username FROM survey.users WHERE username = %s", (username_clean,))
    if not cursor.fetchone():
        conn.close()
        raise HTTPException(status_code=404, detail="User account not found.")
        
    cursor.execute("DELETE FROM survey.users WHERE username = %s", (username_clean,))
    conn.commit()
    conn.close()
    
    logger.warning(f"Action: Admin revoked auditor account: '{username_clean}'")
    return {"status": "success", "message": f"User account '{username_clean}' revoked."}

@app.post("/api/verify_admin")
def verify_admin(payload: dict):
    """Verify admin passcode and return credentials."""
    passcode = payload.get("passcode")
    if passcode == ADMIN_PASSCODE:
        logger.info("Auth: Admin passcode verified successfully.")
        return {"status": "success", "token": ADMIN_PASSCODE}
    logger.warning("Auth: Unauthorized admin passcode attempt.")
    raise HTTPException(status_code=401, detail="Invalid admin passcode.")

@app.get("/api/sources")
def get_sources(include_deleted: bool = Query(False), input_by: str = Query(None)):
    """Fetch all logged sources. Optionally filtered by auditor username."""
    conn = get_db_conn(dict_row)
    cursor = conn.cursor()
    
    query = "SELECT * FROM survey.sources WHERE 1=1"
    params = []
    
    if not include_deleted:
        query += " AND is_deleted = FALSE"
        
    if input_by:
        query += " AND input_by = %s"
        params.append(input_by.strip().lower())
        
    query += " ORDER BY date_added DESC, source_id DESC"
    
    cursor.execute(query, params)
    rows = cursor.fetchall()
    conn.close()
    return [dict(row) for row in rows]

@app.post("/api/sources", status_code=status.HTTP_201_CREATED)
def create_source(source: SourceCreate):
    """Validate and insert a new source, generating a unique source_id."""
    # Telegram Ingestion Check
    if source.platform == "telegram":
        url = source.ingest_url.strip()
        if not ("t.me/" in url or "telegram.me/" in url):
            raise HTTPException(status_code=400, detail="Telegram URLs must contain t.me/ or telegram.me/")
        if "+" in url or "#" in url or "joinchat" in url:
            logger.warning(f"Rejection: Private Telegram link blocked: '{url}'")
            raise HTTPException(status_code=400, detail="Private Telegram invite links are prohibited. Access must be public.")

    conn = get_db_conn()
    cursor = conn.cursor()
    
    # Perform strict duplicate check on active records
    cursor.execute("SELECT source_id, source_name FROM survey.sources WHERE ingest_url = %s AND is_deleted = FALSE", (source.ingest_url.strip(),))
    existing = cursor.fetchone()
    if existing:
        conn.close()
        logger.warning(f"Rejection: Duplicate active ingest URL submitted: '{source.ingest_url}' (existing ID: {existing[0]})")
        raise HTTPException(
            status_code=400, 
            detail=f"A source with this URL already exists under ID {existing[0]} ('{existing[1]}')."
        )
        
    # Generate unique source identifier
    source_id = generate_source_id(source.country_iso, source.platform, source.topic_code)
    date_added = datetime.date.today().isoformat()
    
    try:
        cursor.execute("""
            INSERT INTO survey.sources (
                source_id, source_name, platform, ingest_url, primary_language,
                languages_spoken, geographic_focus, publisher_type, input_by, date_added,
                gating_passed, activity_passed, telegram_passed, is_verified, is_deleted
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, FALSE, FALSE)
        """, (
            source_id,
            source.source_name.strip(),
            source.platform,
            source.ingest_url.strip(),
            source.primary_language.strip().lower(),
            source.languages_spoken.strip() if source.languages_spoken else "",
            source.geographic_focus.strip() if source.geographic_focus else "",
            source.publisher_type,
            source.input_by.strip(),
            date_added,
            source.gating_passed,
            source.activity_passed,
            source.telegram_passed
        ))
        conn.commit()
        logger.info(f"Action: Source created. ID: {source_id} | Name: {source.source_name} | By: {source.input_by} | URL: {source.ingest_url}")
    except psycopg.IntegrityError as e:
        conn.close()
        logger.error(f"Error: Database integrity violation on insert: {e}")
        raise HTTPException(status_code=400, detail="Database write conflict. Please retry.")
    finally:
        conn.close()
        
    return {"status": "success", "source_id": source_id}

@app.get("/api/check_duplicate")
def check_duplicate(url: str = None, name: str = None):
    """Direct helper for debounced UI inputs to prevent duplicates before submission."""
    conn = get_db_conn()
    cursor = conn.cursor()
    
    url_match = None
    name_match = None
    
    if url:
        cursor.execute("SELECT source_id, source_name, ingest_url FROM survey.sources WHERE ingest_url = %s AND is_deleted = FALSE", (url.strip(),))
        row = cursor.fetchone()
        if row:
            url_match = {"source_id": row[0], "source_name": row[1], "ingest_url": row[2]}
            
    if name:
        cursor.execute("SELECT source_id, source_name, ingest_url FROM survey.sources WHERE source_name = %s AND is_deleted = FALSE", (name.strip(),))
        row = cursor.fetchone()
        if row:
            name_match = {"source_id": row[0], "source_name": row[1], "ingest_url": row[2]}
            
    conn.close()
    
    if url_match or name_match:
        return {
            "is_duplicate": True,
            "url_match": url_match,
            "name_match": name_match
        }
    return {"is_duplicate": False}

@app.delete("/api/sources/{source_id}")
def delete_source(source_id: str, x_admin_token: str = Header(None)):
    """Soft-delete a source to allow undeletion failsafes. Restricted to Admin."""
    verify_admin_token(x_admin_token)
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT source_id, ingest_url FROM survey.sources WHERE source_id = %s", (source_id,))
    row = cursor.fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="Source not found.")
        
    cursor.execute("UPDATE survey.sources SET is_deleted = TRUE WHERE source_id = %s", (source_id,))
    conn.commit()
    conn.close()
    
    logger.warning(f"Action: Admin soft-deleted source: {source_id} | URL: {row[1]}")
    return {"status": "success", "message": f"Source {source_id} soft-deleted."}

@app.post("/api/sources/{source_id}/restore")
def restore_source(source_id: str, x_admin_token: str = Header(None)):
    """Restore a previously soft-deleted source. Restricted to Admin."""
    verify_admin_token(x_admin_token)
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT source_id, ingest_url FROM survey.sources WHERE source_id = %s", (source_id,))
    row = cursor.fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="Source not found.")
        
    cursor.execute("UPDATE survey.sources SET is_deleted = FALSE WHERE source_id = %s", (source_id,))
    conn.commit()
    conn.close()
    
    logger.info(f"Action: Admin restored source: {source_id} | URL: {row[1]}")
    return {"status": "success", "message": f"Source {source_id} restored."}

@app.post("/api/sources/{source_id}/verify")
def verify_source(source_id: str, verify: bool = Query(True), x_admin_token: str = Header(None)):
    """Mark a source as reviewed and verified. Restricted to Admin."""
    verify_admin_token(x_admin_token)
    
    conn = get_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT source_id FROM survey.sources WHERE source_id = %s", (source_id,))
    if not cursor.fetchone():
        conn.close()
        raise HTTPException(status_code=404, detail="Source not found.")
        
    cursor.execute("UPDATE survey.sources SET is_verified = %s WHERE source_id = %s", (verify, source_id))
    conn.commit()
    conn.close()
    
    logger.info(f"Action: Admin updated verification status. ID: {source_id} | Verified: {verify}")
    return {"status": "success", "message": f"Verification status for {source_id} updated."}

@app.get("/api/stats")
def get_stats(input_by: str = Query(None)):
    """Retrieve aggregate insights for frontend charts and counters. Optionally filtered by auditor."""
    conn = get_db_conn()
    cursor = conn.cursor()
    
    user_filter = ""
    params = []
    if input_by:
        user_filter = " AND input_by = %s"
        params.append(input_by.strip().lower())
        
    # Active total
    cursor.execute(f"SELECT COUNT(*) FROM survey.sources WHERE is_deleted = FALSE{user_filter}", params)
    total_active = cursor.fetchone()[0]
    
    # Platform counts
    cursor.execute(f"SELECT platform, COUNT(*) FROM survey.sources WHERE is_deleted = FALSE{user_filter} GROUP BY platform", params)
    platform_counts = dict(cursor.fetchall())
    
    # Publisher type counts
    cursor.execute(f"SELECT publisher_type, COUNT(*) FROM survey.sources WHERE is_deleted = FALSE{user_filter} GROUP BY publisher_type", params)
    pub_counts = dict(cursor.fetchall())
    
    # Country counts extracted from source_id
    cursor.execute(f"SELECT source_id FROM survey.sources WHERE is_deleted = FALSE{user_filter}", params)
    sids = cursor.fetchall()
    country_counts = {}
    for (sid,) in sids:
        parts = sid.split("_")
        if parts:
            country = parts[0]
            country_counts[country] = country_counts.get(country, 0) + 1
            
    # Language counts
    cursor.execute(f"SELECT primary_language, COUNT(*) FROM survey.sources WHERE is_deleted = FALSE{user_filter} GROUP BY primary_language", params)
    lang_counts = dict(cursor.fetchall())
    
    # Total verified
    cursor.execute(f"SELECT COUNT(*) FROM survey.sources WHERE is_deleted = FALSE AND is_verified = TRUE{user_filter}", params)
    total_verified = cursor.fetchone()[0]
    
    # Total soft-deleted
    cursor.execute(f"SELECT COUNT(*) FROM survey.sources WHERE is_deleted = TRUE{user_filter}", params)
    total_deleted = cursor.fetchone()[0]
    
    conn.close()
    
    return {
        "total_active": total_active,
        "total_verified": total_verified,
        "total_deleted": total_deleted,
        "by_platform": {
            "telegram": platform_counts.get("telegram", 0),
            "rss": platform_counts.get("rss", 0),
            "newsletter": platform_counts.get("newsletter", 0),
            "fediverse": platform_counts.get("fediverse", 0)
        },
        "by_publisher_type": pub_counts,
        "by_country": country_counts,
        "by_language": lang_counts
    }

@app.get("/api/export")
def export_csv(admin_token: str = Query(None), input_by: str = Query(None)):
    """Export the entire database table as a BOM-encoded CSV. Restricted to Admin."""
    if not admin_token or admin_token != ADMIN_PASSCODE:
        logger.warning("Authentication failure: Blocked unauthorized CSV export attempt.")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing Admin passcode."
        )
        
    conn = get_db_conn(dict_row)
    cursor = conn.cursor()
    
    query = "SELECT * FROM survey.sources WHERE 1=1"
    params = []
    if input_by:
        query += " AND input_by = %s"
        params.append(input_by.strip().lower())
    query += " ORDER BY date_added DESC, source_id DESC"
    
    cursor.execute(query, params)
    rows = cursor.fetchall()
    conn.close()
    
    output = io.StringIO()
    output.write("\ufeff")
    
    if rows:
        headers = list(rows[0].keys())
        writer = csv.DictWriter(output, fieldnames=headers)
        writer.writeheader()
        for row in rows:
            writer.writerow(dict(row))
            
    csv_data = output.getvalue()
    output.close()
    
    logger.info("Action: Admin exported source database to CSV table.")
    
    return StreamingResponse(
        iter([csv_data]),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=sources_export.csv"}
    )

@app.get("/api/admin/logs")
def export_logs(admin_token: str = Query(None)):
    """Export the activity logs. Restricted to Admin."""
    if not admin_token or admin_token != ADMIN_PASSCODE:
        logger.warning("Authentication failure: Blocked unauthorized logs export attempt.")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing Admin passcode."
        )
    
    if not os.path.exists(LOG_PATH):
        logger.error(f"Logs export error: Log file not found at {LOG_PATH}")
        raise HTTPException(
            status_code=404,
            detail="Log file not found."
        )
        
    logger.info("Action: Admin downloaded activity logs.")
    return FileResponse(
        path=LOG_PATH,
        media_type="text/plain",
        filename="survey_activity.log"
    )

# Serve Frontend static assets
static_path = os.path.join(BASE_DIR, "static")
os.makedirs(static_path, exist_ok=True)
app.mount("/", StaticFiles(directory=static_path, html=True), name="static")
