# 1. Enable Cloud Scheduler API
resource "google_project_service" "scheduler_api" {
  project            = var.project_id
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

# 2. Artifact Registry Repository for Ingestion & Dashboard Containers
resource "google_artifact_registry_repository" "movie_pipelines_repo" {
  location      = var.region
  repository_id = "movie-pipelines"
  description   = "Docker images for CineViewable ingestion jobs and dashboard"
  format        = "DOCKER"
}

# 3. Dedicated Service Account for Movie Ingestion Job
resource "google_service_account" "ingestor_sa" {
  account_id   = "movie-ingestor-sa"
  display_name = "Movie Batch Ingestor Cloud Run SA"
}

resource "google_project_iam_member" "ingestor_sa_roles" {
  for_each = toset([
    "roles/storage.objectAdmin",
    "roles/secretmanager.secretAccessor",
    "roles/logging.logWriter"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ingestor_sa.email}"
}

# 4. Cloud Run v2 Job (Stateful TMDB + OMDb Batch Ingestor)
resource "google_cloud_run_v2_job" "movie_batch_ingestor" {
  name                = "movie-batch-ingestor"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.ingestor_sa.email
      timeout         = "1800s" # 30 mins max per 100-movie batch
      max_retries     = 1

      containers {
        image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.movie_pipelines_repo.repository_id}/movie-batch-ingestor:latest"

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "BRONZE_BUCKET_NAME"
          value = google_storage_bucket.bronze_lake.name
        }
        env {
          name  = "MAX_RECORDS_PER_RUN"
          value = "100"
        }
        env {
          name  = "DEFAULT_START_DATE"
          value = "2000-01-01"
        }
        env {
          name  = "MIN_VOTE_COUNT"
          value = "100"
        }
        env {
          name = "TMDB_API_KEY"
          value_source {
            secret_key_ref {
              secret  = "tmdb-api-key"
              version = "latest"
            }
          }
        }
        env {
          name = "OMDB_API_KEY"
          value_source {
            secret_key_ref {
              secret  = "omdb-api-key"
              version = "latest"
            }
          }
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image
    ]
  }

  depends_on = [
    google_artifact_registry_repository.movie_pipelines_repo,
    google_project_iam_member.ingestor_sa_roles
  ]
}

# 5. Service Account & Schedule for Cloud Scheduler (01:00 IST Daily)
resource "google_service_account" "scheduler_sa" {
  account_id   = "scheduler-invoker-sa"
  display_name = "Cloud Scheduler Job Invoker SA"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_run_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.movie_batch_ingestor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

resource "google_cloud_scheduler_job" "daily_movie_ingest_schedule" {
  name        = "daily-movie-ingestion-trigger"
  description = "Triggers stateful movie batch ingestion (100 movies/run) daily at 01:00 IST"
  schedule    = "0 1 * * *"
  time_zone   = "Asia/Kolkata"
  region      = var.region

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.movie_batch_ingestor.name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler_sa.email
    }
  }

  depends_on = [
    google_project_service.scheduler_api,
    google_cloud_run_v2_job_iam_member.scheduler_run_invoker
  ]
}