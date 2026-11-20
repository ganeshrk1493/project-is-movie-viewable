# 1. GCS Bronze Bucket (Raw API payloads & Dataflow temp/staging)
resource "google_storage_bucket" "bronze_lake" {
  name                        = "${var.project_id}-bronze-lake"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = true
  }
}

# 2. Pub/Sub Topic + Dead-Letter Topic for Ingestion
resource "google_pubsub_topic" "movie_ingest_dlq" {
  name = "movie-ingest-dlq"
}

resource "google_pubsub_topic" "movie_ingest_topic" {
  name = "movie-ingest-events"
}

resource "google_pubsub_subscription" "movie_ingest_sub" {
  name  = "movie-ingest-beam-sub"
  topic = google_pubsub_topic.movie_ingest_topic.id

  ack_deadline_seconds = 60

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.movie_ingest_dlq.id
    max_delivery_attempts = 5
  }
}

# 3. BigQuery Medallion Datasets (Raw, Silver, Gold)
resource "google_bigquery_dataset" "raw" {
  dataset_id                  = "movie_raw"
  friendly_name               = "Movie Raw Layer"
  location                    = var.region
  delete_contents_on_destroy  = true
}

resource "google_bigquery_dataset" "silver" {
  dataset_id                  = "movie_silver"
  friendly_name               = "Movie Silver Layer"
  location                    = var.region
  delete_contents_on_destroy  = true
}

resource "google_bigquery_dataset" "gold" {
  dataset_id                  = "movie_gold"
  friendly_name               = "Movie Gold & Semantic Search Layer"
  location                    = var.region
  delete_contents_on_destroy  = true
}

# 4. Raw Movies Table in BigQuery
resource "google_bigquery_table" "raw_movies" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "raw_movies_payload"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "ingested_at"
  }

  schema = jsonencode([
    { name = "imdb_id",      type = "STRING",    mode = "REQUIRED" },
    { name = "source",       type = "STRING",    mode = "REQUIRED" },
    { name = "raw_json",     type = "JSON",      mode = "NULLABLE" },
    { name = "ingested_at",  type = "TIMESTAMP", mode = "REQUIRED" }
  ])
}