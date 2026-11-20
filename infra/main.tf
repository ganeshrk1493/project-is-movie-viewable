# 1. GCS Bronze Bucket (Raw API payloads & Dataflow Classic Template/temp/staging)
resource "google_storage_bucket" "bronze_lake" {
  name                        = "${var.project_id}-bronze-lake"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = true
  }
}

# 2. Pub/Sub Topic for GCS File-Drop Events
resource "google_pubsub_topic" "movie_ingest_topic" {
  name = "movie-ingest-events"
}

# Grant Google Cloud Storage's internal service agent permission to publish to Pub/Sub
data "google_storage_project_service_account" "gcs_account" {}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic  = google_pubsub_topic.movie_ingest_topic.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# Trigger Pub/Sub notification only when new files finish uploading under `raw/`
resource "google_storage_notification" "raw_file_notification" {
  bucket             = google_storage_bucket.bronze_lake.name
  payload_format     = "JSON_API_V1"
  topic              = google_pubsub_topic.movie_ingest_topic.id
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = "raw/"

  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# 3. BigQuery Medallion Datasets (Raw, Silver, Gold)
resource "google_bigquery_dataset" "raw" {
  dataset_id                 = "movie_raw"
  friendly_name              = "Movie Raw Layer"
  location                   = var.region
  delete_contents_on_destroy = true
}

resource "google_bigquery_dataset" "silver" {
  dataset_id                 = "movie_silver"
  friendly_name              = "Movie Silver Layer"
  location                   = var.region
  delete_contents_on_destroy = true
}

resource "google_bigquery_dataset" "gold" {
  dataset_id                 = "movie_gold"
  friendly_name              = "Movie Gold & Semantic Search Layer"
  location                   = var.region
  delete_contents_on_destroy = true
}

# 4. Raw Movies Table in BigQuery (Valid Records)
resource "google_bigquery_table" "raw_movies" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "raw_movies_payload"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "ingested_at"
  }

  schema = jsonencode([
    { name = "imdb_id", type = "STRING", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED" },
    { name = "source_file", type = "STRING", mode = "NULLABLE" },
    { name = "raw_json", type = "JSON", mode = "NULLABLE" },
    { name = "ingested_at", type = "TIMESTAMP", mode = "REQUIRED" }
  ])
}

# 5. Raw Movies Dead-Letter Table in BigQuery (Parse & Schema Errors)
resource "google_bigquery_table" "raw_movies_dlq" {
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "raw_movies_dlq"
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "failed_at"
  }

  schema = jsonencode([
    { name = "source_file", type = "STRING", mode = "NULLABLE" },
    { name = "raw_line", type = "STRING", mode = "NULLABLE" },
    { name = "error_stage", type = "STRING", mode = "REQUIRED" },
    { name = "error_message", type = "STRING", mode = "REQUIRED" },
    { name = "failed_at", type = "TIMESTAMP", mode = "REQUIRED" }
  ])
}