# PostgreSQL Migration and Parity

The containerized application uses one PostgreSQL database with three schemas:

- `corpus`: newsletters, entities, entity lexicon, and translation cache
- `dashboard`: users, search history, saved searches, and notifications
- `survey`: ingestion sources and survey users

The local image is `pgvector/pgvector:pg16`. Production may supply any compatible
PostgreSQL connection through `DATABASE_URL` after enabling the `vector`
extension.

`DATABASE_URL` is the only application database setting. The literal local URL
exists once in `docker-compose.yml` as a development fallback. Container images
require the variable to be injected and do not embed a fallback. Startup logs
identify only `host:port/database`, never credentials.

## Functional Parity

| Previous behavior | PostgreSQL implementation |
| --- | --- |
| DuckDB `newsletters` and `FLOAT[]` embeddings | `corpus.newsletters` and pgvector `vector` columns |
| DuckDB cosine calculation with `list_dot_product` | pgvector cosine distance: `1 - (embedding <=> query)` |
| DuckDB keyword, Boolean, phrase, and proximity search | Parameterized PostgreSQL predicates and case-insensitive regex |
| DuckDB transaction for newsletter/entity commits | One PostgreSQL transaction with conflict-safe inserts |
| DuckDB entity and lexicon tables | `corpus.entities` with a foreign key and `corpus.entity_lexicon` |
| SQLite dashboard state | `dashboard.users`, `search_history`, `saved_searches`, and `notifications` |
| SQLite translation cache | `corpus.translation_cache` |
| SQLite survey sources/users and soft deletion | `survey.sources` and `survey.users` |
| SQLite/DuckDB schema checks | `CREATE ... IF NOT EXISTS` and `ADD COLUMN IF NOT EXISTS` |
| Local file lock retry behavior | PostgreSQL connection retry; row-level concurrency replaces file locks |

## Deliberate Differences

- The migration creates a fresh PostgreSQL database. It does not import existing
  `.db` or `.duckdb` files.
- Vector columns are dimensionless because configured embedding providers may
  return different dimensions. This preserves provider flexibility but prevents
  a fixed-dimension HNSW/IVFFlat index until one dimension is selected.
- PostgreSQL enforces the entity-to-newsletter foreign key that the DuckDB
  implementation omitted due to DuckDB locking behavior.
- Database and model credentials remain runtime configuration; they are not
  embedded into application images.

## Reviewer Validation

The reviewer only needs Docker Desktop. PostgreSQL, pgvector, Python, and R are
provided by the containers; no local database setup or SQL initialization is
required.

Build and start the complete local stack, including one ingestion run:

```bash
docker compose --profile jobs up --build -d
docker compose ps
curl --fail http://localhost:8080/health
curl --fail http://localhost:8081/health
```

Verify schemas and pgvector:

```bash
docker compose exec postgres psql -U pushmedia -d pushmedia -c \
  "SELECT extname FROM pg_extension WHERE extname = 'vector';
   SELECT table_schema, table_name
   FROM information_schema.tables
   WHERE table_schema IN ('corpus', 'dashboard', 'survey')
   ORDER BY 1, 2;"
```

To rerun only the one-shot ingestion task later:

```bash
docker compose --profile jobs run --rm pipeline-job
```

With a new database the dashboard is intentionally empty. Add active sources at
`http://localhost:8081/` and configure model credentials before expecting
ingested articles. The dashboard is at `http://localhost:8080/`.
