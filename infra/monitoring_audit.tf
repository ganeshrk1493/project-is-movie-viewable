# Grant BigQuery read access to ingestor_sa so it can query audit counts
resource "google_project_iam_member" "ingestor_bq_audit_roles" {
  for_each = toset([
    "roles/bigquery.jobUser",
    "roles/bigquery.dataViewer"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ingestor_sa.email}"
}

# Cloud Run Job running send_daily_audit.py using the same container image
resource "google_cloud_run_v2_job" "daily_pipeline_auditor" {
  name                = "daily-pipeline-auditor"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.ingestor_sa.email
      timeout         = "300s"
      max_retries     = 1

      containers {
        image   = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.movie_pipelines_repo.repository_id}/movie-batch-ingestor:latest"
        command = ["python", "monitoring/send_daily_audit.py"]

        env {
          name  = "GCP_PROJECT_ID"
          value = var.project_id
        }
        env {
          name = "GMAIL_APP_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = "gmail-app-password"
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].template[0].containers[0].image]
  }
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_audit_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.daily_pipeline_auditor.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

# Runs daily at 04:00 IST (2 hours after 02:00 IST Dataform Gold build)
resource "google_cloud_scheduler_job" "daily_audit_email_schedule" {
  name        = "daily-pipeline-audit-email"
  description = "Sends daily Raw/Silver/Gold row counts and watermark status to Gmail at 04:00 IST"
  schedule    = "0 4 * * *"
  time_zone   = "Asia/Kolkata"
  region      = var.region

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.daily_pipeline_auditor.name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler_sa.email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_audit_invoker]
}

# Industry-standard Cloud Monitoring Email Channel & Job Failure Alert
resource "google_monitoring_notification_channel" "gmail_alert_channel" {
  display_name = "CineViewable Owner Gmail"
  type         = "email"
  labels = {
    email_address = "YOUR_EMAIL@gmail.com"
  }
}

resource "google_monitoring_alert_policy" "cloud_run_job_failure_alert" {
  display_name = "CineViewable Cloud Run Job Failure Alert"
  combiner     = "OR"

  conditions {
    display_name = "Cloud Run Job Failed Execution"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_job\" AND metric.type = \"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result = \"failed\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.gmail_alert_channel.id]
}

# 1. Dataflow Batch Job Failure Alert (Metric-Based)
resource "google_monitoring_alert_policy" "dataflow_job_failure_alert" {
  display_name = "CineViewable Dataflow Job Failure Alert"
  combiner     = "OR"

  conditions {
    display_name = "Dataflow Job Terminated in Failed State"
    condition_threshold {
      filter          = "resource.type = \"dataflow_job\" AND metric.type = \"dataflow.googleapis.com/job/is_failed\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.gmail_alert_channel.id]

  alert_strategy {
    auto_close = "86400s"
  }

  documentation {
    content   = "A Dataflow ingestion job in project-is-movie-viewable failed. Check Dataflow logs in asia-south1 and inspect gs://project-is-movie-viewable-bronze-lake/raw/."
    mime_type = "text/markdown"
  }
}

# 2. Dataform Workflow Invocation Failure Alert (Log-Based)
resource "google_monitoring_alert_policy" "dataform_workflow_failure_alert" {
  display_name = "CineViewable Dataform Execution Failure Alert"
  combiner     = "OR"

  conditions {
    display_name = "Dataform Workflow Invocation Error"
    condition_matched_log {
      filter = "resource.type = \"dataform.googleapis.com/Repository\" AND severity >= ERROR"
    }
  }

  notification_channels = [google_monitoring_notification_channel.gmail_alert_channel.id]

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "86400s"
  }

  documentation {
    content   = "A Dataform Silver/Gold build failed in project-is-movie-viewable. Open BigQuery > Dataform > movie-warehouse-transforms > Workflow Execution Logs to inspect the failing SQLX node."
    mime_type = "text/markdown"
  }
}

