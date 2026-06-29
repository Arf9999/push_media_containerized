import os
import math
import json
import httpx
import duckdb
import sqlite3
import hashlib
import secrets
from typing import List, Optional
from fastapi import FastAPI, Query, HTTPException, Header, Depends, Response
from fastapi.responses import FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from dotenv import load_dotenv
from search_parser import build_sql_from_query
# Load environment variables from .env
load_dotenv()

# Load credentials from credentials.json if it exists
credentials_path = "credentials.json"
if os.path.exists(credentials_path):
    try:
        with open(credentials_path, "r") as f:
            creds = json.load(f)
            for k, v in creds.items():
                if v and k not in os.environ:
                    os.environ[k] = str(v)
    except Exception as e:
        print(f"Warning: Failed to load credentials from {credentials_path}: {e}")

# Load manifest model defaults if it exists
manifest_path = "manifest.json"
if os.path.exists(manifest_path):
    try:
        with open(manifest_path, "r") as f:
            manifest = json.load(f)
            models = manifest.get("pipeline_models", {})
            emb_config = models.get("vector_embeddings", {})
            if "EMBEDDING_PROVIDER" not in os.environ and emb_config.get("provider"):
                os.environ["EMBEDDING_PROVIDER"] = emb_config["provider"]
            if "EMBEDDING_MODEL" not in os.environ and emb_config.get("model"):
                os.environ["EMBEDDING_MODEL"] = emb_config["model"]
    except Exception as e:
        print(f"Warning: Failed to parse {manifest_path}: {e}")

USERS_DB_PATH = os.getenv("USERS_DB_PATH", "/app/data/users.db")

def init_users_db():
    os.makedirs(os.path.dirname(USERS_DB_PATH) or ".", exist_ok=True)
    conn = sqlite3.connect(USERS_DB_PATH)
    cursor = conn.cursor()
    
    # Create tables
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS users (
            username TEXT UNIQUE PRIMARY KEY,
            password_hash TEXT,
            salt TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS search_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT,
            search_text TEXT,
            space TEXT,
            searched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS saved_searches (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT,
            search_text TEXT,
            space TEXT,
            threshold REAL,
            latest_id TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS notifications (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT,
            search_text TEXT,
            new_results_count INTEGER,
            newest_title TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            is_read INTEGER DEFAULT 0
        );
    """)
    conn.commit()
    conn.close()

init_users_db()

def get_users_db_conn():
    conn = sqlite3.connect(USERS_DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

# Password Helpers
def hash_password(password: str, salt: str = None) -> tuple:
    if salt is None:
        salt = secrets.token_hex(16)
    hash_obj = hashlib.sha256((password + salt).encode())
    return hash_obj.hexdigest(), salt

def verify_password(password: str, password_hash: str, salt: str) -> bool:
    h, _ = hash_password(password, salt)
    return h == password_hash

# Auth dependency
def get_current_user(authorization: Optional[str] = Header(None)) -> str:
    if not authorization:
        raise HTTPException(status_code=401, detail="Authentication required")
    token = authorization
    if token.startswith("Bearer "):
        token = token[len("Bearer "):]
    username = token.strip()
    if not username:
        raise HTTPException(status_code=401, detail="Invalid authorization token")
    
    # Check user existence in sqlite
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT username FROM users WHERE username = ?", (username,))
    row = cursor.fetchone()
    conn.close()
    
    if not row:
        raise HTTPException(status_code=401, detail="Invalid user session")
    return username

app = FastAPI(
    title="Push Media Engine API",
    description="Backend API for low-latency SQL-native vector search and narrative analytics."
)

# Enable CORS for local development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

DB_PATH = os.getenv("DUCKDB_PATH", "/app/data/newsletters.db")
EMBEDDING_PROVIDER = os.getenv("EMBEDDING_PROVIDER", "openrouter").lower()
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "nomic-embed-text")
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")

# ---------------------------------------------------------
# Vectorization Helper
# ---------------------------------------------------------
async def vectorize_query(query_text: str) -> List[float]:
    """
    Vectorizes search term by calling the configured embedding provider.
    """
    if not query_text:
        raise HTTPException(status_code=400, detail="Search query cannot be empty")
        
    async with httpx.AsyncClient(timeout=30.0) as client:
        if EMBEDDING_PROVIDER == "openrouter":
            # Fallback to OpenAI API format
            api_key = OPENROUTER_API_KEY if OPENROUTER_API_KEY else OPENAI_API_KEY
            if not api_key:
                raise HTTPException(status_code=500, detail="No API Key configured for OpenRouter/OpenAI embeddings")
            
            headers = {"Authorization": f"Bearer {api_key}"}
            body = {"model": EMBEDDING_MODEL, "input": query_text}
            
            resp = await client.post("https://api.openai.com/v1/embeddings", json=body, headers=headers)
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail=f"Embedding provider error: {resp.text}")
            
            data = resp.json()
            return data["data"][0]["embedding"]
            
        elif EMBEDDING_PROVIDER == "openai":
            if not OPENAI_API_KEY:
                raise HTTPException(status_code=500, detail="OPENAI_API_KEY is not configured")
                
            headers = {"Authorization": f"Bearer {OPENAI_API_KEY}"}
            body = {"model": EMBEDDING_MODEL, "input": query_text}
            
            resp = await client.post("https://api.openai.com/v1/embeddings", json=body, headers=headers)
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail=f"OpenAI error: {resp.text}")
                
            data = resp.json()
            return data["data"][0]["embedding"]
            
        elif EMBEDDING_PROVIDER == "ollama":
            url = f"{OLLAMA_HOST}/api/embed"
            body = {"model": EMBEDDING_MODEL, "input": query_text}
            
            resp = await client.post(url, json=body)
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail=f"Ollama error: {resp.text}")
                
            data = resp.json()
            return data["embeddings"][0]
            
        elif EMBEDDING_PROVIDER == "gemini":
            if not GEMINI_API_KEY:
                raise HTTPException(status_code=500, detail="GEMINI_API_KEY is not configured")
                
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{EMBEDDING_MODEL}:embedContent?key={GEMINI_API_KEY}"
            body = {"content": {"parts": [{"text": query_text}]}}
            
            resp = await client.post(url, json=body)
            if resp.status_code != 200:
                raise HTTPException(status_code=502, detail=f"Gemini error: {resp.text}")
                
            data = resp.json()
            return data["embedding"]["values"]
            
        else:
            raise HTTPException(status_code=500, detail=f"Unsupported embedding provider: {EMBEDDING_PROVIDER}")

# ---------------------------------------------------------
# Database Utility Functions
# ---------------------------------------------------------
def get_db_con():
    """
    Opens connection to DuckDB database in read-only mode to prevent write locks. Caps resources.
    """
    if not os.path.exists(DB_PATH):
        # Create empty db file if it doesn't exist
        os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
        con = duckdb.connect(DB_PATH)
        con.close()
        
    for _ in range(20):
        try:
            con = duckdb.connect(DB_PATH, read_only=True)
            con.execute("SET max_memory = '2GB';")
            con.execute("SET threads = 2;")
            return con
        except duckdb.IOException as e:
            if "Conflicting lock is held" in str(e) or "lock" in str(e).lower():
                import time
                time.sleep(1.0)
                continue
            raise
    raise HTTPException(
        status_code=503,
        detail="Database temporarily locked by background ingestion. Please retry in a few seconds."
    )

# ---------------------------------------------------------
# API Pydantic Schemas
# ---------------------------------------------------------
class UserRegisterSchema(BaseModel):
    username: str
    password: str

class UserLoginSchema(BaseModel):
    username: str
    password: str

class HistoryCreateSchema(BaseModel):
    search_text: str
    space: str

class SavedSearchCreateSchema(BaseModel):
    search_text: str
    space: str
    threshold: float

# ---------------------------------------------------------
# API Routes
# ---------------------------------------------------------
class FlagRequest(BaseModel):
    flag_status: Optional[str] = None

@app.post("/api/auth/register")
async def register(schema: UserRegisterSchema):
    username = schema.username.strip()
    password = schema.password
    if not username or not password:
        raise HTTPException(status_code=400, detail="Username and password cannot be empty")
        
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT username FROM users WHERE username = ?", (username,))
    if cursor.fetchone():
        conn.close()
        raise HTTPException(status_code=400, detail="Username already exists")
        
    p_hash, salt = hash_password(password)
    try:
        cursor.execute(
            "INSERT INTO users (username, password_hash, salt) VALUES (?, ?, ?)",
            (username, p_hash, salt)
        )
        conn.commit()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Registration failed: {str(e)}")
    finally:
        conn.close()
        
    return {"message": "User registered successfully"}

@app.post("/api/auth/login")
async def login(schema: UserLoginSchema):
    username = schema.username.strip()
    password = schema.password
    
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT password_hash, salt FROM users WHERE username = ?", (username,))
    row = cursor.fetchone()
    conn.close()
    
    if not row:
        raise HTTPException(status_code=401, detail="Invalid username or password")
        
    p_hash = row["password_hash"]
    salt = row["salt"]
    
    if not verify_password(password, p_hash, salt):
        raise HTTPException(status_code=401, detail="Invalid username or password")
        
    return {"token": username, "username": username}

# History endpoints
@app.get("/api/history")
async def get_history(username: str = Depends(get_current_user)):
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id, search_text, space, searched_at FROM search_history WHERE username = ? ORDER BY searched_at DESC LIMIT 10",
        (username,)
    )
    rows = cursor.fetchall()
    conn.close()
    
    history = []
    for r in rows:
        history.append({
            "id": r["id"],
            "search_text": r["search_text"],
            "space": r["space"],
            "searched_at": r["searched_at"]
        })
    return {"history": history}

@app.post("/api/history")
async def create_history(schema: HistoryCreateSchema, username: str = Depends(get_current_user)):
    conn = get_users_db_conn()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "INSERT INTO search_history (username, search_text, space) VALUES (?, ?, ?)",
            (username, schema.search_text, schema.space)
        )
        conn.commit()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to log history: {str(e)}")
    finally:
        conn.close()
    return {"message": "History logged successfully"}

# Saved Searches endpoints
@app.post("/api/saved-searches")
async def create_saved_search(schema: SavedSearchCreateSchema, username: str = Depends(get_current_user)):
    # 1. Query DuckDB to seed latest_id
    query_vector = await vectorize_query(schema.search_text)
    query_norm = math.sqrt(sum(x * x for x in query_vector))
    if query_norm == 0:
        query_norm = 1.0
        
    embedding_col = "english_embedding" if schema.space == "english" else "multilingual_embedding"
    
    con = get_db_con()
    latest_id = ""
    try:
        search_query = f"""
            SELECT 
                uid, 
                (list_dot_product({embedding_col}, ?) / (sqrt(list_dot_product({embedding_col}, {embedding_col})) * ?)) as similarity
            FROM newsletters
            WHERE {embedding_col} IS NOT NULL
            ORDER BY datetime DESC, similarity DESC;
        """
        results = con.execute(search_query, [query_vector, query_norm]).fetchall()
        for r in results:
            uid, sim = r[0], r[1]
            sim_val = float(sim) if sim is not None and not math.isnan(sim) else 0.0
            if sim_val >= schema.threshold:
                latest_id = uid
                break
    except Exception as e:
        latest_id = ""
    finally:
        con.close()
        
    # 2. Insert into SQLite
    conn = get_users_db_conn()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "INSERT INTO saved_searches (username, search_text, space, threshold, latest_id) VALUES (?, ?, ?, ?, ?)",
            (username, schema.search_text, schema.space, schema.threshold, latest_id)
        )
        conn.commit()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save search: {str(e)}")
    finally:
        conn.close()
        
    return {"message": "Search saved successfully", "latest_id": latest_id}

@app.get("/api/saved-searches")
async def get_saved_searches(username: str = Depends(get_current_user)):
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id, search_text, space, threshold, latest_id, created_at FROM saved_searches WHERE username = ? ORDER BY created_at DESC",
        (username,)
    )
    rows = cursor.fetchall()
    conn.close()
    
    saved = []
    for r in rows:
        saved.append({
            "id": r["id"],
            "search_text": r["search_text"],
            "space": r["space"],
            "threshold": r["threshold"],
            "latest_id": r["latest_id"],
            "created_at": r["created_at"]
        })
    return {"saved_searches": saved}

@app.delete("/api/saved-searches/{saved_search_id}")
async def delete_saved_search(saved_search_id: int, username: str = Depends(get_current_user)):
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT username FROM saved_searches WHERE id = ?", (saved_search_id,))
    row = cursor.fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="Saved search not found")
        
    if row["username"] != username:
        conn.close()
        raise HTTPException(status_code=403, detail="Not authorized to delete this saved search")
        
    try:
        cursor.execute("DELETE FROM saved_searches WHERE id = ?", (saved_search_id,))
        conn.commit()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete saved search: {str(e)}")
    finally:
        conn.close()
        
    return {"message": "Saved search deleted successfully"}

# Notifications endpoints
@app.get("/api/notifications")
async def get_notifications(username: str = Depends(get_current_user)):
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute(
        "SELECT id, search_text, new_results_count, newest_title, created_at, is_read FROM notifications WHERE username = ? ORDER BY created_at DESC",
        (username,)
    )
    rows = cursor.fetchall()
    conn.close()
    
    notifications = []
    for r in rows:
        notifications.append({
            "id": r["id"],
            "search_text": r["search_text"],
            "new_results_count": r["new_results_count"],
            "newest_title": r["newest_title"],
            "created_at": r["created_at"],
            "is_read": bool(r["is_read"])
        })
    return {"notifications": notifications}

@app.post("/api/notifications/read")
async def mark_notifications_read(username: str = Depends(get_current_user)):
    conn = get_users_db_conn()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "UPDATE notifications SET is_read = 1 WHERE username = ?",
            (username,)
        )
        conn.commit()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to update notifications: {str(e)}")
    finally:
        conn.close()
        
    return {"message": "Notifications marked as read"}

@app.post("/api/notifications/check")
async def check_notifications(username: str = Depends(get_current_user)):
    # Batch check can be triggered by any authenticated user for testing simulation
    conn = get_users_db_conn()
    cursor = conn.cursor()
    cursor.execute("SELECT id, username, search_text, space, threshold, latest_id FROM saved_searches")
    saved_searches = cursor.fetchall()
    
    con = get_db_con()
    try:
        for s in saved_searches:
            s_id = s["id"]
            user = s["username"]
            search_text = s["search_text"]
            space = s["space"]
            threshold = s["threshold"]
            latest_id = s["latest_id"]
            
            latest_datetime = "1970-01-01 00:00:00"
            if latest_id:
                try:
                    dt_res = con.execute("SELECT datetime::VARCHAR FROM newsletters WHERE uid = ?", [latest_id]).fetchone()
                    if dt_res:
                        latest_datetime = dt_res[0]
                except Exception:
                    pass
            
            query_vector = await vectorize_query(search_text)
            query_norm = math.sqrt(sum(x * x for x in query_vector))
            if query_norm == 0:
                query_norm = 1.0
                
            embedding_col = "english_embedding" if space == "english" else "multilingual_embedding"
            
            search_query = f"""
                SELECT 
                    uid, 
                    title,
                    datetime::VARCHAR as datetime,
                    (list_dot_product({embedding_col}, ?) / (sqrt(list_dot_product({embedding_col}, {embedding_col})) * ?)) as similarity
                FROM newsletters
                WHERE {embedding_col} IS NOT NULL AND datetime > ?
                ORDER BY datetime DESC, similarity DESC;
            """
            
            results = con.execute(search_query, [query_vector, query_norm, latest_datetime]).fetchall()
            
            new_matches = []
            for r in results:
                uid, title, dt, sim = r
                sim_val = float(sim) if sim is not None and not math.isnan(sim) else 0.0
                if sim_val >= threshold:
                    new_matches.append({"uid": uid, "title": title, "datetime": dt})
                    
            if new_matches:
                newest_article = new_matches[0]
                new_results_count = len(new_matches)
                newest_title = newest_article["title"]
                new_latest_id = newest_article["uid"]
                
                cursor.execute(
                    """
                    INSERT INTO notifications (username, search_text, new_results_count, newest_title)
                    VALUES (?, ?, ?, ?)
                    """,
                    (user, search_text, new_results_count, newest_title)
                )
                
                cursor.execute(
                    "UPDATE saved_searches SET latest_id = ? WHERE id = ?",
                    (new_latest_id, s_id)
                )
                
        conn.commit()
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        con.close()
        conn.close()
        
    return {"message": "Notifications check completed"}

@app.post("/api/newsletters/{uid}/flag")
async def flag_newsletter(uid: str, req: FlagRequest, current_user: str = Depends(get_current_user)):
    # Open connection in read/write mode to update the flag
    import time
    for attempt in range(10):
        try:
            con = duckdb.connect(DB_PATH, read_only=False)
            break
        except Exception as e:
            if attempt == 9:
                raise HTTPException(status_code=503, detail="Database is locked by ingestion pipeline. Please try again in a few seconds.")
            time.sleep(1.0)
            
    try:
        # Verify it exists
        exists = con.execute("SELECT 1 FROM newsletters WHERE uid = ?", [uid]).fetchone()
        if not exists:
            raise HTTPException(status_code=404, detail="Newsletter not found")
        
        con.execute("UPDATE newsletters SET flag_status = ? WHERE uid = ?", [req.flag_status, uid])
        return {"success": True, "flag_status": req.flag_status}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        con.close()

# ---------------------------------------------------------
# API Routes
# ---------------------------------------------------------
@app.get("/")
async def root():
    """Redirect to static index dashboard"""
    return RedirectResponse(url="/static/index.html")

@app.get("/api/search")
async def search_newsletters(
    q: str = Query(..., description="Query terms to search"),
    search_type: str = Query("semantic", regex="^(semantic|keyword)$", description="Type of search"),
    space: str = Query("english", regex="^(english|multilingual)$"),
    content_type: Optional[str] = Query(None, description="Filter by type of publication"),
    sort_by: str = Query("similarity", regex="^(similarity|date)$", description="Sort by similarity or date"),
    start_date: Optional[str] = Query(None, description="Filter start date (YYYY-MM-DD)"),
    end_date: Optional[str] = Query(None, description="Filter end date (YYYY-MM-DD)"),
    limit: int = Query(20, ge=1, le=10000),
    offset: int = Query(0, ge=0, description="Pagination offset"),
    threshold: float = Query(0.0, ge=0.0, le=1.0, description="Minimum similarity threshold"),
    language: Optional[str] = Query(None, description="Filter by original language code")
):
    """
    Endpoint for SQL-native vector similarity search using list_dot_product.
    Returns paginated results plus a total_count of all matching records.
    """
    embedding_col = "english_embedding" if space == "english" else "multilingual_embedding"
    
    # Build dynamic query and parameters
    filter_params = []
    where_clauses = []
        
    where_clauses.append(f"{embedding_col} IS NOT NULL")
    
    # Similarity expression and ordering depend on search type
    if search_type == "keyword":
        similarity_select = "1.0 as similarity"
        bool_sql, bool_params = build_sql_from_query(q, space)
        where_clauses.append(bool_sql)
        filter_params.extend(bool_params)
        order_clause = "datetime DESC"
    else:
        # 1. Vectorize query string
        query_vector = await vectorize_query(q)
        
        # Compute L2 Norm of query vector: sqrt(sum(x^2))
        query_norm = math.sqrt(sum(x * x for x in query_vector))
        if query_norm == 0:
            query_norm = 1.0
            
        similarity_select = f"(list_dot_product({embedding_col}, ?) / (sqrt(list_dot_product({embedding_col}, {embedding_col})) * ?)) as similarity"
        
        # Apply threshold filtering at the database level
        if threshold > 0:
            where_clauses.append(f"(list_dot_product({embedding_col}, ?) / (sqrt(list_dot_product({embedding_col}, {embedding_col})) * ?)) >= ?")
            filter_params.extend([query_vector, query_norm, threshold])
            
        order_clause = "similarity DESC" if sort_by == "similarity" else "datetime DESC"
    
    if content_type and content_type.lower() != "all":
        types_list = [t.strip().lower() for t in content_type.split(",") if t.strip()]
        if types_list and "all" not in types_list:
            placeholders = ", ".join("?" for _ in types_list)
            where_clauses.append(f"content_type IN ({placeholders})")
            filter_params.extend(types_list)
        
    if start_date:
        where_clauses.append("datetime >= ?")
        filter_params.append(start_date)
        
    if end_date:
        where_clauses.append("datetime <= ?")
        filter_params.append(end_date)
        
    if language and language.lower() != "all":
        where_clauses.append("detected_language = ?")
        filter_params.append(language.lower())
        
    where_str = " AND ".join(where_clauses)
    
    # 2. Run queries in DuckDB
    con = get_db_con()
    try:
        # --- COUNT query: get the total number of matching records ---
        count_query = f"SELECT COUNT(*) FROM newsletters WHERE {where_str}"
        total_count = con.execute(count_query, filter_params).fetchone()[0]
        
        # --- TIMELINE query: date distribution of ALL matching records ---
        timeline_query = f"""
            SELECT datetime::DATE::VARCHAR as dt, COUNT(*) as cnt
            FROM newsletters
            WHERE {where_str}
            GROUP BY datetime::DATE
            ORDER BY dt;
        """
        timeline_rows = con.execute(timeline_query, filter_params).fetchall()
        timeline_data = [{"date": row[0], "count": row[1]} for row in timeline_rows]
        
        # --- Main results query with LIMIT/OFFSET ---
        # For semantic search, the similarity SELECT needs its own params
        # prepended before the filter params.
        select_params = []
        if search_type != "keyword":
            select_params.extend([query_vector, query_norm])
        
        search_query = f"""
            SELECT 
                uid, 
                datetime::VARCHAR as datetime, 
                source, 
                sender, 
                title, 
                url, 
                summary, 
                original_language_summary, 
                detected_language, 
                content_type, 
                topics, 
                themes, 
                keywords,
                {similarity_select},
                (SELECT string_agg(canonical_name || ':' || entity_type, ';') FROM entities WHERE entities.uid = newsletters.uid) as entity_list,
                (raw_email IS NOT NULL AND raw_email != '') as has_raw_email,
                flag_status
            FROM newsletters
            WHERE {where_str}
            ORDER BY {order_clause}
            LIMIT ?
            OFFSET ?;
        """
        all_params = select_params + filter_params + [limit, offset]
        
        results = con.execute(search_query, all_params).fetchall()
        
        newsletters = []
        for r in results:
            entities = []
            if r[14]:
                for ent_str in r[14].split(";"):
                    if ":" in ent_str:
                        name, etype = ent_str.split(":", 1)
                        entities.append({"name": name, "type": etype})
            
            newsletters.append({
                "uid": r[0],
                "datetime": r[1],
                "source": r[2],
                "sender": r[3],
                "title": r[4],
                "url": r[5],
                "summary": r[6],
                "original_language_summary": r[7],
                "detected_language": r[8],
                "content_type": r[9],
                "topics": [t.strip() for t in r[10].split(",")] if r[10] else [],
                "themes": [t.strip() for t in r[11].split(",")] if r[11] else [],
                "keywords": [t.strip() for t in r[12].split(",")] if r[12] else [],
                "similarity": float(r[13]) if r[13] is not None and not math.isnan(r[13]) else 0.0,
                "entities": entities,
                "has_raw_email": bool(r[15]),
                "flag_status": r[16]
            })
            
        return {
            "query": q,
            "space": space,
            "total_count": total_count,
            "offset": offset,
            "limit": limit,
            "timeline": timeline_data,
            "results": newsletters
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database query failed: {str(e)}")
    finally:
        con.close()

@app.get("/api/newsletters/{uid}/download-eml")
async def download_eml(uid: str):
    """
    Endpoint to download the raw payload (MIME email or plain text for RSS/Telegram).
    """
    con = get_db_con()
    try:
        res = con.execute("SELECT raw_email, title, content_type FROM newsletters WHERE uid = ?;", [uid]).fetchone()
        if not res or not res[0]:
            raise HTTPException(status_code=404, detail="Raw content not found for this record.")
        
        raw_email_content = res[0]
        title = res[1] or "content"
        content_type = (res[2] or "email").lower()
        
        # Determine if this is an email or plain text source
        is_email = content_type in ["email", "gmail", "imap"]
        
        # Sanitize title to use as filename
        safe_title = "".join(c for c in title if c.isalnum() or c in (" ", "-", "_")).strip()
        safe_title = safe_title[:50] or "download"
        
        extension = ".eml" if is_email else ".txt"
        mime_type = "message/rfc822" if is_email else "text/plain"
        
        filename = f"{safe_title}{extension}"
        
        headers = {
            "Content-Disposition": f'attachment; filename="{filename}"'
        }
        return Response(content=raw_email_content, media_type=mime_type, headers=headers)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Database retrieval failed: {str(e)}")
    finally:
        con.close()

@app.get("/api/stats")
async def get_stats():
    """
    Analytics endpoint returning high-level metrics for dashboard graphs.
    """
    con = get_db_con()
    try:
        total_articles = con.execute("SELECT COUNT(*) FROM newsletters;").fetchone()[0]
        
        lang_res = con.execute("""
            SELECT detected_language, COUNT(*) as count 
            FROM newsletters 
            GROUP BY detected_language 
            ORDER BY count DESC;
        """).fetchall()
        languages = [{"lang": r[0], "count": r[1]} for r in lang_res]
        
        source_res = con.execute("""
            SELECT source, COUNT(*) as count 
            FROM newsletters 
            GROUP BY source 
            ORDER BY count DESC 
            LIMIT 10;
        """).fetchall()
        sources = [{"source": r[0], "count": r[1]} for r in source_res]
        
        entity_res = con.execute("""
            SELECT canonical_name, entity_type, COUNT(*) as count 
            FROM entities 
            GROUP BY canonical_name, entity_type 
            ORDER BY count DESC 
            LIMIT 10;
        """).fetchall()
        top_entities = [{"name": r[0], "type": r[1], "count": r[2]} for r in entity_res]
        
        marketing_res = con.execute("""
            SELECT COUNT(*) FROM newsletters WHERE subscription_marketing = true;
        """).fetchone()[0]
        
        return {
            "total_articles": total_articles,
            "languages": languages,
            "sources": sources,
            "top_entities": top_entities,
            "marketing_count": marketing_res
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch database metrics: {str(e)}")
    finally:
        con.close()
@app.get("/api/languages")
async def get_languages():
    """
    Fetch distinct detected languages present in the database.
    """
    con = get_db_con()
    try:
        lang_rows = con.execute("""
            SELECT DISTINCT detected_language 
            FROM newsletters 
            WHERE detected_language IS NOT NULL AND detected_language != ''
            ORDER BY detected_language ASC;
        """).fetchall()
        
        languages = [row[0] for row in lang_rows]
        return {"languages": languages}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch languages: {str(e)}")
    finally:
        con.close()

@app.get("/api/entities")
async def get_entities():
    """
    Fetch all canonical entities mapped to their raw aliases.
    """
    con = get_db_con()
    try:
        # Group raw aliases per canonical name
        entity_rows = con.execute("""
            SELECT canonical_name, entity_type, LIST(DISTINCT raw_name) as aliases, COUNT(*) as count
            FROM entities
            GROUP BY canonical_name, entity_type
            ORDER BY count DESC;
        """).fetchall()
        
        entities_list = []
        for r in entity_rows:
            entities_list.append({
                "canonical_name": r[0],
                "type": r[1],
                "aliases": r[2],
                "occurrence_count": r[3]
            })
            
        return {"entities": entities_list}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to fetch entity mappings: {str(e)}")
    finally:
        con.close()

# ---------------------------------------------------------
# Static File Mount
# ---------------------------------------------------------
# Create empty static folder if not exists
os.makedirs("static", exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")
