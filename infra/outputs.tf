output "bronze_bucket_url" {
  value = google_storage_bucket.bronze_lake.url
}

output "pubsub_topic_id" {
  value = google_pubsub_topic.movie_ingest_topic.id
}