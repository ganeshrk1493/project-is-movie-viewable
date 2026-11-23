# 1. Enable Dataform, Vertex AI, BigQuery Connection, and Secret Manager APIs
resource "google_project_service" "dataform_ai_apis" {
  for_each = toset([
    "dataform.googleapis.com",
    "aiplatform.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "secretmanager.googleapis.com"
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# 2. BigQuery External Connection to Vertex AI (for Gemini & Embeddings)
resource "google_bigquery_connection" "vertex_ai_conn" {
  connection_id = "vertex-ai-conn"
  location      = var.region
  friendly_name = "Vertex AI Gemini & Embeddings Connection"
  cloud_resource {}

  depends_on = [google_project_service.dataform_ai_apis]
}

# Grant Vertex AI User to the BigQuery Connection's service account
resource "google_project_iam_member" "bq_conn_vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_bigquery_connection.vertex_ai_conn.cloud_resource[0].service_account_id}"
}

# 3. Dedicated Service Account for Dataform Pipeline Execution
resource "google_service_account" "dataform_sa" {
  account_id   = "dataform-runner-sa"
  display_name = "Dataform Transformation & AI Runner SA"
}

resource "google_project_iam_member" "dataform_sa_roles" {
  for_each = toset([
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/bigquery.connectionUser",
    "roles/aiplatform.user"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.dataform_sa.email}"
}

# 4. Materialize and grant permissions to the Google-managed Dataform Service Agent
resource "google_project_service_identity" "dataform_sa_identity" {
  provider = google-beta
  project  = var.project_id
  service  = "dataform.googleapis.com"

  depends_on = [google_project_service.dataform_ai_apis]
}

resource "google_project_iam_member" "dataform_service_agent_roles" {
  for_each = toset([
    "roles/secretmanager.secretAccessor",
    "roles/iam.serviceAccountTokenCreator",
    "roles/iam.serviceAccountUser"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_project_service_identity.dataform_sa_identity.email}"
}


# Reference the existing GitHub PAT secret
data "google_secret_manager_secret_version" "github_pat" {
  secret  = "github-dataform-pat"
  version = "latest"
}

# 5. Enterprise Dataform Repository bound to your GitHub repo
resource "google_dataform_repository" "movie_dataform_repo" {
  provider        = google-beta
  name            = "movie-warehouse-transforms"
  region          = var.region
  service_account = google_service_account.dataform_sa.email

  git_remote_settings {
    url                                 = "https://github.com/ganeshrk1493/project-is-movie-viewable.git"
    default_branch                      = "main"
    authentication_token_secret_version = data.google_secret_manager_secret_version.github_pat.id
  }

  workspace_compilation_overrides {
    default_database = var.project_id
  }

  depends_on = [
    google_project_service.dataform_ai_apis,
    google_project_iam_member.dataform_service_agent_roles
  ]
}

# 6. Production Release Config (compiles main branch every 6 hours)
resource "google_dataform_repository_release_config" "prod_release" {
  provider      = google-beta
  project       = var.project_id
  region        = var.region
  repository    = google_dataform_repository.movie_dataform_repo.name
  name          = "production"
  git_commitish = "main"
  cron_schedule = "0 */6 * * *"
  time_zone     = "Asia/Kolkata"

  code_compilation_config {
    default_database = var.project_id
    default_location = var.region
  }
}

# 7. Scheduled Workflow Execution Config (runs Silver -> Gold daily at 02:00 IST)
resource "google_dataform_repository_workflow_config" "daily_warehouse_run" {
  provider       = google-beta
  project        = var.project_id
  region         = var.region
  repository     = google_dataform_repository.movie_dataform_repo.name
  name           = "daily-silver-gold-build"
  release_config = google_dataform_repository_release_config.prod_release.id
  cron_schedule  = "0 2 * * *"
  time_zone      = "Asia/Kolkata"

  invocation_config {
    service_account = google_service_account.dataform_sa.email
  }
}