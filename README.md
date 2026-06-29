# Phase 2 Push Media Ingestion, Analysis, and Querying Pipeline (Beta)

This repository contains the containerized production-ready **Beta** release of the Phase 2 Push Media Pipeline and Search Dashboard.

## Architecture Overview

The application is structured into two main container services orchestrated via `docker-compose`:

1. **`survey` (Media Survey App)**: Port `8081`. Used by coordinators/auditors to manage media channels, RSS feeds, email addresses, and subscription details. Writes targets to `sources.db`.
2. **`pipeline` (Dashboard & Ingest Pipeline)**: Port `8080`. Serves the Search and Personalization dashboard, and runs the daily R ingestion pipeline which updates `newsletters.db`.

Both services share a data volume mounted at `./data` on the host to persist databases and files:
- `sources.db`: SQLite database of active ingestion streams.
- `newsletters.db`: DuckDB corpus containing ingested and enriched articles/emails.
- `users.db`: SQLite database for user sessions, search history, and personalization.

---

## Getting Started

### 1. Configuration

1. Place your API keys and configuration in a `credentials.json` file in `pipeline/credentials.json`:
   ```json
   {
     "OPENROUTER_API_KEY": "your_openrouter_key",
     "GMAIL_USERNAME": "your_email@gmail.com",
     "GMAIL_APP_PASSWORD": "your_app_password"
   }
   ```
2. Configure settings inside `pipeline/manifest.json` if needed to point to specific model endpoints.

### 2. Running the Services

To build and start both the FastAPI dashboard and the FastAPI survey tool, run:
```bash
docker compose up --build -d
```

- **Dashboard UI**: Access `http://localhost:8080/static/index.html` (mounts API at `http://localhost:8080`)
- **Survey Tool UI**: Access `http://localhost:8081/static/index.html` (mounts API at `http://localhost:8081`)

To stop the services:
```bash
docker compose down
```

---

## Running the Ingestion Pipeline

The ingestion pipeline is designed to be triggered on a schedule (e.g. daily cron job). You can invoke it inside the running `pipeline` container manually:

```bash
docker compose exec pipeline Rscript run_cron.R
```

This script will query active streams from `sources.db` (managed by the survey app) and pull new content into the DuckDB `newsletters.db` database.
