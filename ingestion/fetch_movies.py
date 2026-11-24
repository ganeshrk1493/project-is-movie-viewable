import datetime
import json
import os
import time
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from google.cloud import storage

PROJECT_ID = os.getenv("GCP_PROJECT_ID", "project-is-movie-viewable")
BUCKET_NAME = os.getenv("BRONZE_BUCKET_NAME", "project-is-movie-viewable-bronze-lake")
STATE_BLOB_PATH = "state/ingestion_watermark.json"

TMDB_API_KEY = os.environ["TMDB_API_KEY"].strip()
OMDB_API_KEY = os.environ["OMDB_API_KEY"].strip()

MAX_RECORDS_PER_RUN = int(os.getenv("MAX_RECORDS_PER_RUN", "100"))
DEFAULT_START_DATE = os.getenv("DEFAULT_START_DATE", "2000-01-01")
MIN_VOTE_COUNT = int(os.getenv("MIN_VOTE_COUNT", "100"))


def create_http_session():
    session = requests.Session()
    retry_strategy = Retry(
        total=5,
        backoff_factor=1.5,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry_strategy, pool_connections=10, pool_maxsize=10)
    session.mount("https://", adapter)
    session.headers.update({"User-Agent": "MovieViewableDEPipeline/2.0"})
    return session


HTTP = create_http_session()


def load_watermark(bucket: storage.Bucket) -> dict:
    """Loads the last saved release_date + page cursor from GCS."""
    blob = bucket.blob(STATE_BLOB_PATH)
    if blob.exists():
        state = json.loads(blob.download_as_text())
        print(f"Loaded watermark from GCS: {state}")
        return state
    initial_state = {
        "cursor_date": DEFAULT_START_DATE,
        "cursor_page": 1,
        "total_ingested_all_time": 0,
    }
    print(f"No existing watermark found. Starting fresh from: {initial_state}")
    return initial_state


def save_watermark(bucket: storage.Bucket, state: dict):
    """Persists the updated watermark cursor to GCS after raw batch upload succeeds."""
    state["updated_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    blob = bucket.blob(STATE_BLOB_PATH)
    blob.upload_from_string(json.dumps(state, indent=2), content_type="application/json")
    print(f"Saved updated watermark to gs://{BUCKET_NAME}/{STATE_BLOB_PATH}: {state}")


def discover_movies_page(cursor_date: str, end_date: str, page: int) -> dict:
    """Fetches a page of movies sorted chronologically by primary_release_date."""
    url = (
        f"https://api.themoviedb.org/3/discover/movie"
        f"?api_key={TMDB_API_KEY}"
        f"&language=en-US"
        f"&sort_by=primary_release_date.asc"
        f"&primary_release_date.gte={cursor_date}"
        f"&primary_release_date.lte={end_date}"
        f"&vote_count.gte={MIN_VOTE_COUNT}"
        f"&page={page}"
    )
    resp = HTTP.get(url, timeout=20)
    resp.raise_for_status()
    return resp.json()


def enrich_movie_record(tmdb_id: int) -> dict | None:
    """Fetches TMDB details, Indian OTT watch providers, reviews, certifications, and OMDb ratings."""
    detail_url = (
        f"https://api.themoviedb.org/3/movie/{tmdb_id}"
        f"?api_key={TMDB_API_KEY}"
        f"&append_to_response=watch/providers,reviews,release_dates,credits"
    )
    try:
        tmdb_resp = HTTP.get(detail_url, timeout=20)
        if tmdb_resp.status_code != 200:
            return None
        details = tmdb_resp.json()
    except requests.RequestException as exc:
        print(f"Network error for TMDB ID {tmdb_id}, skipping: {exc}")
        return None

    imdb_id = details.get("imdb_id")
    if not imdb_id:
        return None

    in_providers = details.get("watch/providers", {}).get("results", {}).get("IN", {})

    raw_reviews = details.get("reviews", {}).get("results", [])[:5]
    top_reviews = [
        {
            "author": r.get("author"),
            "rating": r.get("author_details", {}).get("rating"),
            "content": r.get("content", "")[:2000],
            "created_at": r.get("created_at"),
        }
        for r in raw_reviews
    ]

    certifications = {}
    for entry in details.get("release_dates", {}).get("results", []):
        iso = entry.get("iso_3166_1")
        if iso in ("IN", "US"):
            certs = [rd.get("certification") for rd in entry.get("release_dates", []) if rd.get("certification")]
            if certs:
                certifications[iso] = certs[0]

    omdb_data = {}
    try:
        omdb_url = f"https://www.omdbapi.com/?i={imdb_id}&plot=full&apikey={OMDB_API_KEY}"
        omdb_resp = HTTP.get(omdb_url, timeout=20)
        if omdb_resp.status_code == 200:
            omdb_data = omdb_resp.json()
    except requests.RequestException as exc:
        print(f"OMDb lookup failed for {imdb_id}, continuing with TMDB data only: {exc}")

    return {
        "imdb_id": imdb_id,
        "tmdb_id": tmdb_id,
        "source": "tmdb_omdb_batch",
        "title": details.get("title"),
        "release_date": details.get("release_date"),
        "runtime_mins": details.get("runtime"),
        "genres": [g["name"] for g in details.get("genres", [])],
        "overview": details.get("overview"),
        "full_plot": omdb_data.get("Plot"),
        "poster_url": f"https://image.tmdb.org/t/p/w500{details.get('poster_path')}" if details.get("poster_path") else None,
        "imdb_rating": omdb_data.get("imdbRating"),
        "imdb_votes": omdb_data.get("imdbVotes"),
        "critic_ratings": omdb_data.get("Ratings", []),
        "metascore": omdb_data.get("Metascore"),
        "parental_certifications": {
            "in_cert": certifications.get("IN"),
            "us_cert": certifications.get("US"),
            "omdb_rated": omdb_data.get("Rated"),
        },
        "indian_ott": {
            "link": in_providers.get("link"),
            "flatrate": [p["provider_name"] for p in in_providers.get("flatrate", [])],
            "rent": [p["provider_name"] for p in in_providers.get("rent", [])],
            "buy": [p["provider_name"] for p in in_providers.get("buy", [])],
        },
        "top_5_reviews": top_reviews,
    }


def upload_jsonl_to_gcs(bucket: storage.Bucket, records: list[dict]):
    now = datetime.datetime.now(datetime.timezone.utc)
    date_partition = now.strftime("%Y-%m-%d")
    timestamp_slug = now.strftime("%Y%m%d_%H%M%S")
    blob_path = f"raw/ingest_date={date_partition}/movies_{timestamp_slug}.jsonl"

    jsonl_payload = "\n".join(json.dumps(r) for r in records)
    blob = bucket.blob(blob_path)
    blob.upload_from_string(jsonl_payload, content_type="application/x-ndjson")
    print(f"Uploaded {len(records)} movies to gs://{BUCKET_NAME}/{blob_path}")


def main():
    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET_NAME)

    state = load_watermark(bucket)
    cursor_date = state["cursor_date"]
    page = state["cursor_page"]
    today_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")

    enriched_records = []
    latest_release_date = cursor_date

    while len(enriched_records) < MAX_RECORDS_PER_RUN:
        data = discover_movies_page(cursor_date, today_str, page)
        results = data.get("results", [])
        total_pages = min(data.get("total_pages", 1), 500)  # TMDB caps pagination at page 500

        if not results:
            print("Caught up to present date! No more new movies in window.")
            latest_release_date = today_str
            page = 1
            break

        for item in results:
            if len(enriched_records) >= MAX_RECORDS_PER_RUN:
                break

            record = enrich_movie_record(item["id"])
            if record:
                enriched_records.append(record)
                if record.get("release_date"):
                    latest_release_date = max(latest_release_date, record["release_date"])
                print(
                    f"[{len(enriched_records)}/{MAX_RECORDS_PER_RUN}] "
                    f"{record['release_date']} | {record['title']} ({record['imdb_id']})"
                )
            time.sleep(0.25)

        if len(enriched_records) < MAX_RECORDS_PER_RUN:
            if page >= total_pages:
                # Advance cursor_date past the last processed date so TMDB's 500-page cap is never hit
                cursor_date = latest_release_date
                page = 1
                if cursor_date >= today_str:
                    break
            else:
                page += 1

    if enriched_records:
        upload_jsonl_to_gcs(bucket, enriched_records)

    # If we hit MAX_RECORDS_PER_RUN mid-batch, advance cursor_date to latest_release_date and reset page to 1
    # (Dataform deduplicates any boundary-date overlap cleanly by imdb_id)
    next_state = {
        "cursor_date": latest_release_date,
        "cursor_page": 1 if latest_release_date > state["cursor_date"] else page,
        "total_ingested_all_time": state.get("total_ingested_all_time", 0) + len(enriched_records),
    }
    save_watermark(bucket, next_state)


if __name__ == "__main__":
    main()