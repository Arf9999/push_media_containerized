# Regional Media Ingestion Survey Application - Handoff Documentation

Welcome to the **Regional Media Ingestion Survey Application** workspace (located under [alpha_survey/](file:///Users/arf/R_projects_local/newsletter_phase2/alpha_survey)). This document outlines the architecture, database schema, configuration, and execution guidelines for deploying and running the survey application.

---

## 1. Directory Layout

The survey application is fully self-contained inside the `alpha_survey/` folder:

```
alpha_survey/
├── logs/
│   └── survey_activity.log        # Activity audit log tracking all CRUD operations and admin exports
├── static/                        # Frontend Single Page App (SPA) assets
│   ├── index.html                 # Glassmorphic dashboard UI with stats & controls
│   ├── styles.css                 # Clean dark mode layout rules and interactive micro-animations
│   └── app.js                     # DOM handler, API caller, and session auth manager
├── app.py                         # FastAPI Backend REST API containing database & logic layers
├── sources.db                     # Local SQLite database containing logged records and user credentials
└── HANDOFF.md                     # This handoff documentation file
```

---

## 2. Technical Architecture & Security Model

The survey application uses a single-page frontend that interacts with a Python FastAPI backend storing data in SQLite.

```mermaid
graph TD
    Client[Browser / Frontend HTML+JS] -->|POST /api/login| API[FastAPI Backend - app.py]
    Client -->|GET /api/sources| API
    Client -->|POST /api/sources| API
    Client -->|POST /api/verify_admin| API
    Client -->|GET /api/stats| API

    subgraph Admin Actions
        Client -->|GET /api/admin/users| API
        Client -->|POST /api/admin/users| API
        Client -->|DELETE /api/admin/users/{user}| API
        Client -->|DELETE /api/sources/{id}| API
        Client -->|POST /api/sources/{id}/restore| API
        Client -->|POST /api/sources/{id}/verify| API
        Client -->|GET /api/export| API
        Client -->|GET /api/admin/logs| API
    end

    API -->|Read/Write| DB[(SQLite: sources.db)]
    API -->|Log Action| Log[(logs/survey_activity.log)]
    
    subgraph Access Control Gate
        API -.--->|X-Admin-Token / admin_token Check| AdminAuth[Admin Passcode: admin123]
    end
```

### Access Control & Privacy
1. **Auditor Accounts:** Access is restricted to credentials-based logins. Auditors are allocated by the Coordinator using Admin Mode.
2. **Auditor-Scoped Views:** Regular auditors can only view, filter, and export their own ingest inputs. They cannot view other auditors' data.
3. **Admin Mode:** Gatekept by passcode `admin123`. Unlocking Admin Mode reveals coordinator controls, including deleting, restoring, verifying entries, allocating/revoking auditor accounts, filtering statistics/directories by specific auditors, and performing global CSV/Log database exports.

---

## 3. Database Schema (`sources.db`)

The SQLite database contains two tables: `sources` (storing logged media feeds) and `users` (storing credentials).

### `sources` Table
| Column | Type | Constraints | Description |
|:---|:---|:---|:---|
| `source_id` | TEXT | PRIMARY KEY | Unique ID automatically generated as `{Country}_{Platform}_{Topic}_{Num}` |
| `source_name` | TEXT | NOT NULL | Human-readable name of the feed |
| `platform` | TEXT | NOT NULL | Ingest platform type (`telegram`, `rss`, `newsletter`, `fediverse`) |
| `ingest_url` | TEXT | UNIQUE, NOT NULL | Public feed ingestion link (private Telegram links are blocked) |
| `primary_language`| TEXT | NOT NULL | Language ISO code (e.g. `en`, `ar`, `fr`) |
| `languages_spoken`| TEXT | | Optional secondary languages list |
| `geographic_focus`| TEXT | | Geolocation targeting focus area |
| `publisher_type` | TEXT | | Schema-validated type (e.g. `independent_journalist`, `pr_news_agency`, `other`) |
| `input_by` | TEXT | DEFAULT 'unknown'| The auditor account username that logged the source |
| `date_added` | TEXT | NOT NULL | ISO date string when added |
| `gating_passed` | INTEGER| DEFAULT 0 (bool) | Boolean flag confirming ingestion gating check |
| `activity_passed` | INTEGER| DEFAULT 0 (bool) | Boolean flag confirming active channel check |
| `telegram_passed` | INTEGER| DEFAULT 0 (bool) | Boolean flag confirming public channel criteria |
| `is_verified` | INTEGER| DEFAULT 0 (bool) | Boolean flag indicating Coordinator audit approval |
| `is_deleted` | INTEGER| DEFAULT 0 (bool) | Boolean flag for soft deletion / trash bin recovery |

### `users` Table
| Column | Type | Constraints | Description |
|:---|:---|:---|:---|
| `username` | TEXT | PRIMARY KEY | Unique auditor login handle |
| `password` | TEXT | NOT NULL | SHA256 hashed password string |

*Initial seeded default accounts:*
* `ra_amina` / `amina2026`
* `ra_bob` / `bob2026`
* `ra_coordinator` / `coord2026`
* `andrew` / `1234` (testing account)

---

## 4. Key Operational Features & API Reference

### Input Prevention & Verification
- **Automated duplicate validation** on naming and URL before form submission.
- **Strict Telegram gating** blocking private group invite links containing `joinchat`, `+` or `#`.
- **Publisher Types Taxonomy:** State Media (`state_media`), Independent Journalist (`independent_journalist`), Civil Society (`civil_society`), Anonymous Influencer (`anonymous_influencer`), Consumer News (`consumer_news`), Cultural/Music/Art (`cultural_music_art`), Gossip/Celebrity (`gossip_celebrity`), Newsfluencer (`newsfluencer`), Mainstream Publication (`mainstream_publication`), Sport (`sport`), Technology/Science (`technology_science`), PR/News Agency (`pr_news_agency`), and Other (`other`).
- **Topics/Themes:** Politics (`POL`), Climate (`CLM`), Energy (`ENG`), Economy (`ECO`), General News (`GEN`), Consumer News (`CON`), Culture (`CUL`), Gossip (`GOS`), Sport (`SPO`), Technology (`TEC`), and Other (`OTH`).

### Endpoint reference

| Method | Endpoint | Authorization | Description |
|:---|:---|:---|:---|
| **POST** | `/api/login` | Public | Authenticates auditor credentials. |
| **POST** | `/api/verify_admin` | Public | Validates admin passcode and returns token. |
| **GET** | `/api/sources` | Public | Fetch logged sources (hides soft-deleted, filters by `input_by`). |
| **POST** | `/api/sources` | Public | Logs a new source, triggers duplicate check, generates `source_id`. |
| **GET** | `/api/check_duplicate`| Public | In-place helper for UI inputs to check collisions. |
| **GET** | `/api/stats` | Public | Aggregates count summaries (filters by `input_by`). |
| **GET** | `/api/admin/users` | `X-Admin-Token` | List all allocated auditor accounts. |
| **POST** | `/api/admin/users` | `X-Admin-Token` | Allocate a new auditor account. |
| **DELETE**| `/api/admin/users/{user}`| `X-Admin-Token` | Revoke/delete an auditor account. |
| **DELETE**| `/api/sources/{id}` | `X-Admin-Token` | Soft-deletes a source. |
| **POST** | `/api/sources/{id}/restore`| `X-Admin-Token` | Restores a soft-deleted source. |
| **POST** | `/api/sources/{id}/verify`| `X-Admin-Token` | Verify/Review a source. |
| **GET** | `/api/export` | `admin_token` | Stream-export database CSV (supports auditor scoping). |
| **GET** | `/api/admin/logs` | `admin_token` | Download raw `survey_activity.log` file contents. |

---

## 5. Local Deployment & Running Instructions

### 1. Provision Environment & Dependencies
Ensure Python 3.9+ is installed. In the root project folder, create and activate a virtual environment, then install requirements:
```bash
# Navigate to workspace root
cd /Users/arf/R_projects_local/newsletter_phase2

# Create virtual environment if not present
python -m venv .venv
source .venv/bin/activate

# Install required dependencies
pip install fastapi uvicorn pydantic
```

### 2. Start the Application Server
Run the FastAPI application locally:
```bash
# Start uvicorn server on port 8080 (reload enabled for development)
.venv/bin/python -m uvicorn alpha_survey.app:app --host 127.0.0.1 --port 8080 --reload
```
Open your browser and navigate to `http://127.0.0.1:8080` to interact with the application.

### 3. Run Verification Tests
To run the automated API verification test suite (verifies endpoints, logins, duplicate rejections, permissions, and CSV/Log export integrity):
```bash
.venv/bin/python scratch/test_survey_api.py
```
*(This script runs on isolated port 8089 and automatically cleans up its test database configuration upon completion).*

---

## 6. Google Cloud Platform (GCP) & Cloud Storage (GCS) Deployment

For production web hosting, you can deploy the survey application using one of the following methods.

### Option A: Monolithic Deployment on Google Cloud Run (Recommended)
This approach runs the entire application (both frontend and backend) inside a lightweight, containerized Cloud Run instance. Data persistence for the SQLite database (`sources.db`) and audit logs (`survey_activity.log`) is achieved by mounting a Google Cloud Storage (GCS) bucket directly to the container using Cloud Run's native Cloud Storage volume mount.

#### 1. Create a GCS Bucket for Database & Log Storage
Ensure your `gcloud` CLI is configured and authenticated. Create a bucket in the desired region:
```bash
gcloud storage buckets create gs://survey-data-storage --location=us-central1
```

#### 2. Define the `Dockerfile`
Create a `Dockerfile` inside the `alpha_survey/` folder to package the application:
```dockerfile
FROM python:3.10-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code and static assets
COPY . .

# Expose FastAPI's default port
EXPOSE 8080

# Run the FastAPI server
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
```

#### 3. Build the Container Image
Build and push the image to Google Artifact Registry using Google Cloud Build:
```bash
gcloud builds submit --tag gcr.io/<PROJECT-ID>/survey-app alpha_survey/
```

#### 4. Deploy to Google Cloud Run with GCS Volume Mount
Deploy the container to Cloud Run. The native volume mount maps the GCS bucket (`survey-data-storage`) to a directory inside the container (e.g. `/data`). The app's environment variables (`SURVEY_DB_PATH` and `SURVEY_LOG_DIR`) are set to point to this mounted storage to persist SQLite and logs:
```bash
gcloud beta run deploy survey-app \
    --image gcr.io/<PROJECT-ID>/survey-app \
    --platform managed \
    --region us-central1 \
    --allow-unauthenticated \
    --add-volume name=survey-volume,type=cloud-storage,bucket=survey-data-storage \
    --add-volume-mount volume=survey-volume,mount-path=/data \
    --set-env-vars SURVEY_DB_PATH=/data/sources.db,SURVEY_LOG_DIR=/data/logs
```
*Note: Cloud Run's native GCS volume mount feature uses the second generation execution environment, which is selected automatically when deploying with volume mounts.*

---

### Option B: Split Deployment (Static Frontend on GCS + Cloud Run API Backend)
If you prefer to serve the static frontend assets via Google Cloud Storage (GCS) as a CDN and only run the API backend on Cloud Run:

#### 1. Point Frontend to the Backend API
Update the API base URL in `alpha_survey/static/app.js` to point to your deployed Cloud Run URL:
```javascript
// Modify the base URL configuration in app.js if hosting the static assets separately
const API_BASE = "https://<YOUR-CLOUD-RUN-URL>";
```

#### 2. Create the Frontend GCS Bucket & Upload Assets
Create a GCS bucket, upload the static files, and configure it for web hosting:
```bash
# Create public bucket for static hosting
gcloud storage buckets create gs://survey-frontend-cdn --location=us-central1

# Upload index.html, styles.css, app.js
gcloud storage cp -r alpha_survey/static/* gs://survey-frontend-cdn/

# Configure the main web page suffix
gcloud storage buckets update gs://survey-frontend-cdn --web-main-page-suffix=index.html

# Make all objects publicly accessible
gcloud storage buckets add-iam-policy-binding gs://survey-frontend-cdn \
    --member=allUsers \
    --role=roles/storage.objectViewer
```
Your frontend is now publicly accessible at `https://storage.googleapis.com/survey-frontend-cdn/index.html`.

#### 3. Deploy the Containerized API Backend
Deploy the Cloud Run API backend using the same GCS volume mount setup from **Option A** to persist `sources.db` and logs.
*(Note: If hosting frontend assets on a separate domain/bucket, ensure the FastAPI backend is configured to allow CORS requests from the GCS bucket URL).*
