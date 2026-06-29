FROM rocker/r-ver:4.3.0

# Install system dependencies, python, pip, and standard tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    libssl-dev \
    libxml2-dev \
    libcurl4-openssl-dev \
    git \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy dependency files first to utilize Docker build cache
COPY install_packages.R .
COPY requirements.txt .

# Install R packages using Posit Package Manager binaries
RUN Rscript install_packages.R

# Install Python packages
RUN pip3 install --no-cache-dir -r requirements.txt

# Copy the rest of the application
COPY . .

# Default port for FastAPI daemon
EXPOSE 8080

# Environment variables defaults
ENV DUCKDB_PATH=/app/data/newsletters.db
ENV USERS_DB_PATH=/app/data/users.db
ENV SOURCES_DB_PATH=/app/data/sources.db
ENV LAST_EMAIL_ID_FILE=/app/data/last_email_id.txt
ENV FORENSIC_LOG_PATH=/app/data/FORENSIC_LOG

CMD ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
