# Data Digest & Database Bible: Push Media Pipeline

This document serves as the comprehensive schema registry and field dictionary for all databases in the Phase 2 Push Media Pipeline.

---

## 🌌 1. Core Push Media Database (DuckDB: `newsletters.db`)
This column-oriented OLAP database houses all processed article contents, metadata, and generated vector embeddings.

### Table: `newsletters`
Stores parsed, translated, summarized, and vectorized posts.

| Column | Type | Description |
| :--- | :--- | :--- |
| `uid` | `VARCHAR` | Primary Key. A unique stable identifier. For emails, it is the Gmail Message ID; for others, it is an MD5 hash of the source URL/text. |
| `datetime` | `TIMESTAMP` | The publication or receipt date and time of the content. |
| `source` | `VARCHAR` | The canonical source name/handle (e.g., email address, Telegram channel link, RSS feed name). |
| `sender` | `VARCHAR` | The sender or author display name (e.g., "South Africa Ministry of Energy"). |
| `title` | `VARCHAR` | The original title or generated summary header of the article/post. |
| `url` | `VARCHAR` | The direct external link to the full original article or webpage. |
| `summary` | `TEXT` | The English-translated summary of the article body. |
| `original_language_summary` | `TEXT` | The summary written in the article's original language (before translation). |
| `detected_language` | `VARCHAR` | ISO 639-1 code of the language detected by the LLM (e.g., `en`, `fr`, `xh`, `zu`). |
| `truncated` | `BOOLEAN` | Flags if the raw source content was truncated because it exceeded maximum processing limits. |
| `content_type` | `VARCHAR` | Broad category classification (e.g., `news`, `press_release`, `editorial`, `marketing`). |
| `topics` | `TEXT` | Extracted topics represented as a comma-separated list of tags. |
| `themes` | `TEXT` | Stance, policy positions, or structural themes extracted by the LLM. |
| `keywords` | `TEXT` | Comma-separated list of relevant keywords for classic query search fallbacks. |
| `subscription_marketing` | `BOOLEAN` | Flags (`TRUE`/`FALSE`) if the LLM flagged the text as promotional spam or marketing material. |
| `english_embedding` | `FLOAT[]` | 768-dimensional vector embedding of the English summary (injected with topics & themes). |
| `multilingual_embedding` | `FLOAT[]` | 768-dimensional vector embedding of the original language summary. |
| `raw_email` | `TEXT` | Unmodified, raw body payload (for email ingestion debugging purposes). |
| `flag_status` | `VARCHAR` | Custom administrative flag status (defaults to `NULL`). |
| `ingested_at` | `TIMESTAMP` | Record insertion timestamp (default: `CURRENT_TIMESTAMP`). |

### Table: `entities`
Stores resolved named entities extracted from newsletters.

| Column | Type | Description |
| :--- | :--- | :--- |
| `entity_id` | `INTEGER` | Primary Key. Automatically generated using the sequence `entity_id_seq`. |
| `uid` | `VARCHAR` | Foreign reference mapping to the originating newsletter article (`newsletters.uid`). |
| `entity_type` | `VARCHAR` | Classification category of the entity (e.g., `PERSON`, `ORGANIZATION`, `LOCATION`, `GEOPOLITICAL`). |
| `raw_name` | `VARCHAR` | The exact literal text string extracted from the article. |
| `canonical_name` | `VARCHAR` | The resolved, deduplicated name mapped via Jaro-Winkler string similarity. |

### Table: `entity_lexicon`
A dynamic dictionary table mapping raw entities to canonical names to optimize future resolutions.

| Column | Type | Description |
| :--- | :--- | :--- |
| `raw_name` | `VARCHAR` | Primary Key. The unique raw literal spelling variation detected. |
| `canonical_name` | `VARCHAR` | The canonical spelling target mapped to this raw variation. |
| `entity_type` | `VARCHAR` | The entity classification category. |
| `created_at` | `TIMESTAMP` | Timestamp of lexicon record insertion (default: `CURRENT_TIMESTAMP`). |

---

## 📋 2. Regional Media Survey Database (SQLite: `sources.db`)
This database manages media feed assets entered by regional auditors.

### Table: `sources`
Main repository of tracked platforms and ingestion streams.

| Column | Type | Description |
| :--- | :--- | :--- |
| `source_id` | `TEXT` | Primary Key. Unique string identifier auto-generated based on country, platform, and topic (e.g., `ZA_TEL_POL_001`). |
| `source_name` | `TEXT` | Human-readable name or label representing the feed. |
| `platform` | `TEXT` | The intake channel type: `telegram`, `rss`, `newsletter`, or `fediverse`. |
| `ingest_url` | `TEXT` | Unique. The URL endpoint scanned by the pipeline (e.g., RSS XML link, public Telegram join page). |
| `primary_language` | `TEXT` | Main ISO 639-1 language code used in the feed. |
| `languages_spoken` | `TEXT` | Comma-separated list of secondary spoken/written languages. |
| `geographic_focus` | `TEXT` | Target region, country, or municipality covered. |
| `publisher_type` | `TEXT` | Classification (e.g., `state_media`, `independent_journalist`, `civil_society`, `newsfluencer`, etc.). |
| `input_by` | `TEXT` | Username of the Auditor who entered the record (defaults to `'unknown'`). |
| `date_added` | `TEXT` | ISO Date string representing when the record was created. |
| `gating_passed` | `INTEGER` | Boolean flag (`1`/`0`) verifying if basic gating checks passed. |
| `activity_passed` | `INTEGER` | Boolean flag (`1`/`0`) verifying if feed activity validation passed. |
| `telegram_passed` | `INTEGER` | Boolean flag (`1`/`0`) verifying if Telegram-specific validation succeeded. |
| `is_verified` | `INTEGER` | Boolean flag (`1`/`0`) indicating coordinator verification. |
| `is_deleted` | `INTEGER` | Boolean flag (`1`/`0`) supporting soft-deletion. |

### Table: `users`
Auditor account credentials.

| Column | Type | Description |
| :--- | :--- | :--- |
| `username` | `TEXT` | Primary Key. Unique auditor handle. |
| `password` | `TEXT` | Hex-encoded SHA-256 password hash. |

---

## 🔒 3. Dashboard State Database (SQLite: `users.db`)
This database tracks local user sessions, notifications, and search parameters.

### Table: `users`
Dashboard login credentials.

| Column | Type | Description |
| :--- | :--- | :--- |
| `username` | `TEXT` | Primary Key. Dashboard login handle. |
| `password_hash` | `TEXT` | Salted SHA-256 password hash. |
| `salt` | `TEXT` | Unique cryptographically secure salt generated during registration. |
| `created_at` | `TIMESTAMP` | Timestamp of account registration. |

### Table: `search_history`
Maintains user search queries for UI autocomplete/recent tabs.

| Column | Type | Description |
| :--- | :--- | :--- |
| `id` | `INTEGER` | Primary Key. Auto-incremented sequence ID. |
| `username` | `TEXT` | Handle of the user who ran the query. |
| `search_text` | `TEXT` | The literal query query string. |
| `space` | `TEXT` | The target search space: `english` or `multilingual`. |
| `searched_at` | `TIMESTAMP` | Timestamp of query execution. |

### Table: `saved_searches`
Saves user notification queries (high-watermark alerts).

| Column | Type | Description |
| :--- | :--- | :--- |
| `id` | `INTEGER` | Primary Key. Auto-incremented sequence ID. |
| `username` | `TEXT` | Handle of the user who saved the search. |
| `search_text` | `TEXT` | The search phrase. |
| `space` | `TEXT` | Target search space: `english` or `multilingual`. |
| `threshold` | `REAL` | Minimum Cosine Similarity score required to trigger alert. |
| `latest_id` | `TEXT` | High-Watermark tracker: `uid` of the newest matching article processed. |
| `created_at` | `TIMESTAMP` | Timestamp of saved search creation. |

### Table: `notifications`
Stores notification records triggered by saved searches.

| Column | Type | Description |
| :--- | :--- | :--- |
| `id` | `INTEGER` | Primary Key. Auto-incremented sequence ID. |
| `username` | `TEXT` | Recipient user handle. |
| `search_text` | `TEXT` | The query terms that triggered this alert. |
| `new_results_count` | `INTEGER` | Number of matching articles detected since the last cursor run. |
| `newest_title` | `TEXT` | The title of the newest matching article. |
| `created_at` | `TIMESTAMP` | Timestamp when notification was issued. |
| `is_read` | `INTEGER` | Read state flag (`1` = read, `0` = unread). |

---

*All tables follow SQLite/DuckDB conventions and use ISO‑8601 timestamps where appropriate. This file is intended as the single source of truth for downstream developers and data analysts.*
