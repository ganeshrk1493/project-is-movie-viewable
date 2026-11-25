import datetime
import json
import os
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import yaml
from google.cloud import bigquery, storage

PROJECT_ID = os.getenv("GCP_PROJECT_ID", "project-is-movie-viewable")
GMAIL_APP_PASSWORD = os.environ["GMAIL_APP_PASSWORD"].strip()


def load_config(path: str = "monitoring/audit_config.yaml") -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def get_watermark_info(bucket_name: str, blob_path: str) -> dict:
    client = storage.Client(project=PROJECT_ID)
    blob = client.bucket(bucket_name).blob(blob_path)
    if not blob.exists():
        return {"status": "No watermark file found"}
    return json.loads(blob.download_as_text())


def query_table_stats(bq: bigquery.Client, table_id: str, ts_col: str) -> dict:
    sql = f"""
    SELECT
      COUNT(*) AS total_rows,
      COUNTIF(DATE({ts_col}, 'Asia/Kolkata') = CURRENT_DATE('Asia/Kolkata')) AS rows_today,
      FORMAT_TIMESTAMP('%Y-%m-%d %H:%M IST', MAX({ts_col}), 'Asia/Kolkata') AS latest_run_ist
    FROM `{table_id}`
    """
    row = list(bq.query(sql).result())[0]
    return {
        "total_rows": row["total_rows"],
        "rows_today": row["rows_today"],
        "latest_run_ist": row["latest_run_ist"] or "N/A",
    }


def main():
    cfg = load_config()
    bq = bigquery.Client(project=PROJECT_ID)
    ist_now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=5, minutes=30)))
    date_str = ist_now.strftime("%Y-%m-%d")

    watermark = get_watermark_info(cfg["watermark_bucket"], cfg["watermark_blob"])

    rows_html = ""
    has_zero_gold = False

    for item in cfg["tables"]:
        stats = query_table_stats(bq, item["table_id"], item["ts_column"])
        if "gold" in item["table_id"] and stats["rows_today"] == 0:
            has_zero_gold = True
        rows_html += f"""
        <tr>
          <td style="padding:8px;border:1px solid #ddd;"><b>{item['label']}</b><br><small>{item['table_id']}</small></td>
          <td style="padding:8px;border:1px solid #ddd;text-align:right;"><b>+{stats['rows_today']:,}</b></td>
          <td style="padding:8px;border:1px solid #ddd;text-align:right;">{stats['total_rows']:,}</td>
          <td style="padding:8px;border:1px solid #ddd;">{stats['latest_run_ist']}</td>
        </tr>
        """

    status_badge = "⚠️ ACTION NEEDED (0 Gold Rows Today)" if has_zero_gold else "✅ HEALTHY"

    html_body = f"""
    <html>
      <body style="font-family:Arial,sans-serif;color:#222;">
        <h2>{cfg['subject_prefix']} ({date_str})</h2>
        <p><b>Pipeline Status:</b> {status_badge}</p>
        <table style="border-collapse:collapse;width:100%;max-width:750px;">
          <thead>
            <tr style="background:#f4f6f8;">
              <th style="padding:8px;border:1px solid #ddd;text-align:left;">Layer / Table</th>
              <th style="padding:8px;border:1px solid #ddd;text-align:right;">Added Today</th>
              <th style="padding:8px;border:1px solid #ddd;text-align:right;">Total Rows</th>
              <th style="padding:8px;border:1px solid #ddd;text-align:left;">Latest Load (IST)</th>
            </tr>
          </thead>
          <tbody>{rows_html}</tbody>
        </table>
        <h3>GCS Ingestion Watermark State</h3>
        <pre style="background:#f4f6f8;padding:10px;border-radius:4px;">{json.dumps(watermark, indent=2)}</pre>
      </body>
    </html>
    """

    msg = MIMEMultipart("alternative")
    msg["Subject"] = f"{status_badge} | {cfg['subject_prefix']} ({date_str})"
    msg["From"] = cfg["sender_email"]
    msg["To"] = cfg["recipient_email"]
    msg.attach(MIMEText(html_body, "html"))

    with smtplib.SMTP_SSL("smtp.gmail.com", 465) as server:
        server.login(cfg["sender_email"], GMAIL_APP_PASSWORD)
        server.send_message(msg)

    print(f"Sent daily pipeline report to {cfg['recipient_email']}")


if __name__ == "__main__":
    main()