# Phase 2 Push Media Ingestion, Analysis, and Querying Pipeline (Beta)

This repository contains the containerized production-ready **Beta** release of the Phase 2 Push Media Pipeline and Search Dashboard.

## Architecture Overview

The application is structured into three long-running services and one optional
job service orchestrated via Docker Compose:

1. **`survey` (Media Survey App)**: Port `8081`. Used by coordinators/auditors to manage media channels, RSS feeds, email addresses, and subscription details. Writes targets to Postgres.
2. **`pipeline` (Dashboard & Ingest Pipeline)**: Port `8080`. Serves the Search and Personalization dashboard, and runs the daily R ingestion pipeline which updates the Postgres corpus.
3. **`postgres` (Local Postgres + pgvector)**: Port `5432`. Stores survey sources, dashboard state, and the searchable article corpus. The same `DATABASE_URL` contract can later point at AWS RDS.
4. **`pipeline-job` (One-shot Ingestion Job)**: Runs `Rscript run_cron.R` from the pipeline image. The `jobs` profile keeps it out of normal web-service startup.

The web services still mount `./data` for non-database runtime files such as logs and email cursor state. Database state lives in the Docker-managed `postgres_data` volume:
- `survey.sources`: active ingestion streams.
- `dashboard.*`: user sessions, search history, saved searches, and notifications.
- `corpus.newsletters`, `corpus.entities`, `corpus.entity_lexicon`: ingested and enriched articles/emails with pgvector embeddings.

---

## Getting Started

### 1. Configuration

1. For ingestion, provide model and source credentials as environment variables
   or place them in `pipeline/credentials.json`:
   ```json
   {
     "OPENROUTER_API_KEY": "your_openrouter_key",
     "GMAIL_USERNAME": "your_email@gmail.com",
     "GMAIL_APP_PASSWORD": "your_app_password"
   }
   ```
2. Optional model overrides include `LLM_PROVIDER`, `LLM_MODEL`,
   `EMBEDDING_PROVIDER`, `EMBEDDING_MODEL`, `TRANSLATION_MODEL`, and
   `OLLAMA_HOST`.

### 2. Running the Services

To build and start the complete test stack, including one ingestion run, use:
```bash
docker compose --profile jobs up --build -d
```

The `pipeline-job` container exits after the ingestion run; Postgres and both web
services remain running.

- **Dashboard UI**: `http://localhost:8080/`
- **Survey Tool UI**: `http://localhost:8081/`
- **Health checks**: `http://localhost:8080/health` and `http://localhost:8081/health`

To stop the services:
```bash
docker compose down
```

---

## Running the Ingestion Pipeline

The ingestion pipeline is designed to be triggered by a scheduler. Run the same
one-shot job definition locally:

```bash
docker compose --profile jobs run --rm pipeline-job
```

This script queries active streams from `survey.sources` and writes processed content into the Postgres `corpus` schema.

The job requires at least one active survey source or Gmail credentials before it
can populate the dashboard. Model-backed extraction, translation, embeddings, and
semantic search also require provider credentials or a reachable Ollama server.

## PostgreSQL Migration

See [POSTGRES_MIGRATION.md](POSTGRES_MIGRATION.md) for the DuckDB/SQLite parity
matrix, known non-goals, and reviewer validation commands.
