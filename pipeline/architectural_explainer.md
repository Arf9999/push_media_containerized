# Architectural Design & Structural Rationale

This document explains the **strategic reasoning, trade-offs, and design decisions** that dictate the structure of the Phase 2 Push Media Pipeline. It focuses on *why* the pipeline is built this way, rather than *how* the technology works.

---

## 1. Central Configuration Manifest (`manifest.json`) & Model Hierarchy
The pipeline's model dependency mappings are declared in a project-level manifest file (`manifest.json`), working in tandem with the environmental configuration layer (`config.R`) and translation module (`translation_ollama.R`) to establish a resilient, multi-tiered model hierarchy.

### Granular Settings & Model Roles:
1. **Main LLM (`metadata_extraction`)**:
   - **Declared In**: `manifest.json` under `pipeline_models.metadata_extraction`.
   - **Default Model**: `liquid/lfm-2-24b-a2b` (via OpenRouter).
   - **Role**: Serves as the primary workhorse of the ingestion pipeline. It performs initial text parsing, language detection, translation (for high-resource languages), English summarization, structured entity extraction, and category classification.
2. **Low-Resource Local LLM (`translation_model`)**:
   - **Declared In**: Configured via the `TRANSLATION_MODEL` environment variable (parsed in `config.R` with a default fallback to the local `mzansilm` model).
   - **Active Models**: Dedicated local translation models (such as `afriqueqwen-14b-multiturn` or `mzansilm` running locally via Ollama).
   - **Role**: Invoked specifically when the pipeline detects low-resource regional African languages (`xh`, `zu`, `tn`, `rw`, `st`, `ss`, `wo`) to translate summaries locally while preserving rhetorical idioms and regional vocabulary.
3. **Failover LLM (Secondary Translation Model)**:
   - **Declared In**: Hardcoded as the ultimate API translation fallback (`qwen/qwen3.6-plus` via OpenRouter) in `translation_ollama.R`'s `translate_generic()` function.
   - **Role**: Automatically engaged if the primary model fails or returns empty/untranslated output during translation tasks, ensuring the pipeline recovers gracefully without user intervention.
4. **Vector Embedding Model (`vector_embeddings`)**:
   - **Declared In**: `manifest.json` under `pipeline_models.vector_embeddings`.
   - **Default Model**: `nomic-embed-text:latest` (via Ollama).
   - **Role**: Vectorizes text summaries to generate dual 768-dimensional float arrays (multilingual original and English) for semantic vector search.
5. **Translation Quality Evaluator (`translation_evaluation`)**:
   - **Declared In**: `manifest.json` under `pipeline_models.translation_evaluation`.
   - **Default Model**: `liquid/lfm-2-24b-a2b` (via OpenRouter).
   - **Role**: An LLM-as-a-judge model used to programmatically audit translation quality, accuracy, and semantic alignment during verification phases.

### The Rationale:
- **Model Agnosticism & Tiered Resilience**: Standardizing API communications through a unified adapter allows administrators to update models, change vendors (e.g., from an external API provider to a local model running on Ollama), or upgrade versions by modifying `manifest.json` without altering any R or Python code in the ingestion pipeline.
- **Failover Autonomy**: If external APIs face rate limits or network dropouts, the system falls back to secondary alternatives. If both primary and fallback cloud endpoints fail entirely during ingestion, the translation layer prepends a `[Translation Failed - Original Language: {lang}]` warning header to prevent database poisoning and silent omissions.
- **Operational Decoupling**: Hardcoding provider properties inside ingest scripts leads to configuration drift and operational fragility. Consuming settings from `manifest.json` as runtime defaults ensures that pipeline components share a synchronized, single source of truth that is easily overridden via local environment variables during deployment.

---

## 2. Database Segregation: SQLite vs. DuckDB
The architecture splits data persistence into two entirely separate databases: **SQLite** (`sources.db`) for the Regional Media Survey Tool and **DuckDB** (`newsletters.db`) for the core Push Media repository.

### The Rationale:
- **Transactional Input (SQLite)**: The survey tool is an auditor-facing CRUD (Create, Read, Update, Delete) application. It requires fast, multi-user concurrency locks, simple relational integrity, and standard user credential lookups. SQLite is highly optimized for transactional database operations (OLTP) and manages multiple concurrent auditor logins and session writes without overhead.
- **Analytical Search (DuckDB)**: The search engine requires heavy, column-oriented analytical operations (OLAP), complex keyword regex matches, and native vector math (`list_dot_product` calculations on 768-dimensional float arrays). DuckDB excels at scanning millions of vector rows in milliseconds.
- **Why Separate Them?**
  - **Zero Blockage**: Running heavy vector similarity searches or massive batch writes during cron runs would lock the database file. If they shared a database, auditors entering new feeds in the survey tool would suffer connection timeouts and save errors.
  - **State Isolation**: The list of *sources* (feeds) is a metadata state. The *newsletters* database is the data lake. Separating them ensures that a failure, corruption, or reconstruction of the data lake does not affect or delete the audited registry of media feeds.

---

## 3. Hybrid Language Pipeline: Python Daemon vs. R Runner
The Gmail ingestion uses a real-time Python daemon (`email_daemon.py`), while the multi-source orchestrator (`run_cron.R`) is written in R.

### The Rationale:
- **Asynchronous Event Handling**: Real-time email capture requires subscribing to Gmail's **IMAP IDLE** protocol. This is a long-lived, persistent TCP connection where the server pushes new events. Implementing a stable socket listener in R is extremely difficult due to its single-threaded, synchronous nature. Python's `imapclient` handles connection persistence, network drops, and auto-syncing out-of-the-box.
- **Rate Limit & Bandwidth Protection**: Gmail IMAP has strict daily download limits (2.5 GB) and command rate throttling. A standard R client fetching the entire mailbox would quickly cause account lockouts. The Python daemon selectively parses MIME structures in memory and fetches *only* the envelope headers and textual body blocks. Massive image/media attachments are bypassed entirely, saving bandwidth and keeping the pipeline under Google's download threshold.
- **Why R for the Main Cron?** The downstream analysis, entity resolution, and vector embedding code are deeply integrated with R's statistical environment and package system (`stringdist`, database drivers, etc.). By keeping the ingestion orchestrator in R, we leverage R's power for data manipulation while using the Python daemon as a low-latency "intake sidecar" that pushes raw payloads directly into DuckDB.

---

## 4. Decoupled Ingest Schema
Each ingestion module (Email, RSS, Telegram, Fediverse, Substack) parses different payloads, but they all output a standardized R list containing identical keys.

### The Rationale:
- **Decoupling Intake from Extraction**: If each platform passed its own unique record schema, the LLM metadata extraction and translation systems would need custom logic for every platform. By enforcing a uniform schema at the boundary of the ingestion modules, the downstream enrichment pipeline treats every post simply as an abstract "document."
- **Extensibility**: Adding support for a new platform (e.g., a WhatsApp scaper or LinkedIn API) only requires writing a small isolated parser that maps input to the uniform schema. The core LLM prompting, OCR vision logic, translation fallbacks, and database writing layers remain completely untouched.

---

## 5. In-Memory Processing & Short-Lived Transactions
During a pipeline run, all network requests, LLM completions, translations, and embedding calculations are performed in memory before any connection to the main database is opened.

### The Rationale:
- **Concurrency & Lock Prevention**: DuckDB uses file-level locking. If a process opens a connection in read-write mode, all other read connections (such as the FastAPI dashboard queries) are blocked.
- **The API Bottleneck**: Generating summaries, translating low-resource languages, and vectorizing strings takes seconds—sometimes minutes—per document. If we opened a database transaction at the start and wrote records as they were processed, the database would remain locked for the duration of the API call chain.
- **The Solution**: By doing all heavy API work in-memory and opening a DuckDB transaction *only at the very end*, the database is written to and committed in a few milliseconds. The dashboard server remains unlocked and responsive to user queries throughout active ingestion.

---

## 6. Cost-Benefit Translation Failover
The translation module attempts translations using a cheap model first, failing over to a more expensive model, and finally writing a warning if both fail.

### The Rationale:
- **Cost Efficiency**: Liquid LFM-2 is extremely inexpensive, making it the ideal primary model for bulk operations. However, for translation tasks, it can return empty responses.
- **Graceful Failover**: When LFM-2 fails, calling Qwen 3.6 Plus ensures we get high-quality English summaries. We only pay for the expensive model's tokens when the cheap model struggles.
- **No Database Poisoning**: Prepending a `[Translation Failed - Original Language: {lang}]` warning header to the original summary (if both models fail) prevents the pipeline from silently saving untranslated French or Portuguese text as the English summary. Administrators can instantly see where API limits or routing issues occurred directly on the dashboard.

---

## 7. Split Translation Routing: Low-Resource Language Check
The pipeline inspects the detected language code and routes low-resource African languages (`xh`, `zu`, `tn`, `rw`, `st`, `ss`, `wo`) through local specialized models (like `AfriqueQwen-14B-multiturn` via Ollama) while routing high-resource languages (like French or Portuguese) through general LLM API calls.

### The Rationale:
- **Preserving Rhetorical Nuance**: General-purpose cloud LLMs are trained predominantly on Western corpora. They perform poorly on low-resource African languages, often hallucinating or losing structural idioms during translation. Specialized local models are fine-tuned specifically on regional dialects to preserve accurate translations and rhetorical fidelity.
- **Latency Optimization**: Running a large, specialized 14B parameter translation model locally on a CPU incurs a significant latency penalty (~53 seconds per sentence). If we routed *all* incoming articles (including French or Portuguese) through local Ollama models, the daily cron ingestion pipeline would take hours to run.
- **The Split Strategy**:
  - **High-Resource**: Routed to cheap, low-latency general cloud APIs, maintaining fast ingestion speeds.
  - **Low-Resource**: Isolated and sent through the slow, high-quality local model, paying the performance cost *only* when specialized translation is required.

---

## 8. Removing Database Foreign Keys
We removed the database-level `FOREIGN KEY` constraint linking the `entities` table to the `newsletters` table.

### The Rationale:
- **DuckDB Internal Delete-Insert Bug**: Under the hood, DuckDB implements `UPDATE` statements by executing a `DELETE` on the old row followed by an `INSERT` of the new row. 
- **Catalog Deadlock**: If a foreign key is defined, DuckDB's engine executes complex verification routines during this internal delete phase. In certain catalog states, this check triggers a fatal assertion crash (`Attempting to dereference an optional pointer that is not set`) that can permanently invalidate the database file on disk.
- **Removing the Constraint**: Dropping the foreign key removes this check entirely, safeguarding the database against catalog crashes during updates, while maintaining relational structure programmatically during transaction writes.

---

## 9. Metadata Injection in Vector Embeddings
We append extracted topics and themes to the text summary before generating the vector embedding.

### The Rationale:
- **Embedding Limitations**: Standard vector embedding models (like Nomic Embed) match overall semantic context. They often fail to capture specific, exact metadata terms (such as specific countries or thematic stance tags like "Oil & Gas").
- **Forcing Vector Alignment**: By appending `\nTopics: {topics}\nThemes: {themes}` to the text block, we force the embedding model to encode these exact keywords into the vector space. This allows the vector search query to return highly relevant matches for specific topics and themes naturally without requiring metadata table joins.
