# 1. Enable Eventarc & Cloud Build APIs required by Cloud Functions 2nd Gen
resource "google_project_service" "cf2_apis" {
  for_each = toset([
    "eventarc.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com"
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# 2. Dedicated Service Account for the Dispatcher Cloud Function
resource "google_service_account" "dispatcher_sa" {
  account_id   = "dataflow-dispatcher-sa"
  display_name = "Dataflow Dispatcher Cloud Function SA"
}



# Grant permissions to build the function, launch Dataflow jobs, act as worker SA, read/write GCS, and load BQ
resource "google_project_iam_member" "dispatcher_roles" {
  for_each = toset([
    "roles/dataflow.admin",
    "roles/dataflow.worker",
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/iam.serviceAccountUser",
    "roles/storage.objectAdmin",
    "roles/eventarc.eventReceiver",
    "roles/run.invoker",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/cloudbuild.builds.builder",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# 3. Zip the Cloud Function source code automatically
data "archive_file" "dispatcher_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/dataflow_dispatcher"
  output_path = "${path.module}/build/dataflow_dispatcher.zip"
}

# 4. Upload zipped code to GCS (MD5 hash ensures Terraform redeploys when code changes)
resource "google_storage_bucket_object" "dispatcher_source" {
  name   = "cf-source/dataflow-dispatcher-${data.archive_file.dispatcher_zip.output_md5}.zip"
  bucket = google_storage_bucket.bronze_lake.name
  source = data.archive_file.dispatcher_zip.output_path
}

# 5. Deploy Cloud Function (2nd Gen) triggered by Pub/Sub `movie-ingest-events`
resource "google_cloudfunctions2_function" "dataflow_dispatcher" {
  name        = "gcs-to-dataflow-dispatcher"
  location    = var.region
  description = "Launches Dataflow batch job when a .jsonl file drops into GCS raw/"


  build_config {
    runtime         = "python311"
    entry_point     = "trigger_dataflow"
    service_account = google_service_account.dispatcher_sa.id
    source {
      storage_source {
        bucket = google_storage_bucket.bronze_lake.name
        object = google_storage_bucket_object.dispatcher_source.name
      }
    }
  }

  service_config {
    max_instance_count    = 2
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = google_service_account.dispatcher_sa.email

    environment_variables = {
      PROJECT_ID        = var.project_id
      REGION            = var.region
      TEMPLATE_GCS_PATH = "gs://${google_storage_bucket.bronze_lake.name}/templates/movie-ingest-classic"
      TEMP_GCS_LOCATION = "gs://${google_storage_bucket.bronze_lake.name}/temp"
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.movie_ingest_topic.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.dispatcher_sa.email
  }

  depends_on = [
    google_project_service.cf2_apis,
    google_project_iam_member.dispatcher_roles
  ]
}

