FROM python:3.10-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code and static assets
COPY . .

# Expose FastAPI's default port
EXPOSE 8080

# Configure environment variables to use the shared database volume
ENV SURVEY_DB_PATH=/app/data/sources.db
ENV SURVEY_LOG_DIR=/app/data/logs

# Run the FastAPI server
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
