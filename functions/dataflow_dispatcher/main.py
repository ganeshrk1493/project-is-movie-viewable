import base64
import datetime
import json
import logging
import os
import functions_framework
from googleapiclient.discovery import build

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
TEMPLATE_GCS_PATH = os.environ["TEMPLATE_GCS_PATH"]
TEMP_GCS_LOCATION = os.environ["TEMP_GCS_LOCATION"]


@functions_framework.cloud_event
def trigger_dataflow(cloud_event):
    """Triggered by a Pub/Sub message from GCS OBJECT_FINALIZE notification."""
    pubsub_message = cloud_event.data.get("message", {})
    raw_data = pubsub_message.get("data")
    attributes = pubsub_message.get("attributes", {})

    if not raw_data:
        logging.warning("Received empty Pub/Sub message; skipping.")
        return

    payload = json.loads(base64.b64decode(raw_data).decode("utf-8"))
    bucket_name = payload.get("bucket")
    object_name = payload.get("name")

    # Safety filter: only trigger Dataflow for .jsonl files inside raw/
    if not object_name or not object_name.startswith("raw/") or not object_name.endswith(".jsonl"):
        logging.info(f"Ignoring non-target object: gs://{bucket_name}/{object_name}")
        return

    # Ignore folder placeholder objects (0-byte directories)
    if str(payload.get("size", "0")) == "0":
        logging.info(f"Ignoring 0-byte object: gs://{bucket_name}/{object_name}")
        return

    input_gcs_path = f"gs://{bucket_name}/{object_name}"
    timestamp_slug = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S")
    job_name = f"movie-ingest-{timestamp_slug}"

    logging.info(f"Launching Dataflow Classic Template '{job_name}' for {input_gcs_path}")

    dataflow = build("dataflow", "v1b3", cache_discovery=False)
    request = (
        dataflow.projects()
        .locations()
        .templates()
        .launch(
            projectId=PROJECT_ID,
            location=REGION,
            gcsPath=TEMPLATE_GCS_PATH,
            body={
                "jobName": job_name,
                "parameters": {
                    "input_file": input_gcs_path,
                },
                "environment": {
                    "tempLocation": TEMP_GCS_LOCATION,
                    "zone": f"{REGION}-a",
                },
            },
        )
    )
    response = request.execute()
    launched_job_id = response.get("job", {}).get("id")
    logging.info(f"Successfully launched Dataflow job ID: {launched_job_id}")