import datetime
import json
import logging
import apache_beam as beam
from apache_beam.io.gcp.bigquery import WriteToBigQuery
from apache_beam.options.pipeline_options import PipelineOptions


class MovieIngestOptions(PipelineOptions):
    """Runtime parameters supported by the Dataflow Classic Template."""

    @classmethod
    def _add_argparse_args(cls, parser):
        parser.add_value_provider_argument(
            "--input_file",
            type=str,
            help="GCS path to input .jsonl file (e.g., gs://project-is-movie-viewable-bronze-lake/raw/batch.jsonl)",
        )


class ParseAndValidateMovieFn(beam.DoFn):
    """Parses raw JSON lines and separates valid movie payloads from malformed records."""

    VALID_TAG = "valid"
    DLQ_TAG = "dlq"

    def __init__(self, input_file_vp):
        self.input_file_vp = input_file_vp

    def process(self, element):
        now_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
        source_file = (
            self.input_file_vp.get() if self.input_file_vp.is_accessible() else "unknown"
        )

        line = element.strip()
        if not line:
            return

        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("JSON root must be an object/dict")

            imdb_id = record.get("imdb_id")
            source = record.get("source")

            if not imdb_id or not source:
                raise ValueError("Missing required field: 'imdb_id' or 'source'")

            yield beam.pvalue.TaggedOutput(
                self.VALID_TAG,
                {
                    "imdb_id": str(imdb_id).strip(),
                    "source": str(source).strip(),
                    "source_file": source_file,
                    "raw_json": json.dumps(record),
                    "ingested_at": now_utc,
                },
            )

        except Exception as exc:
            yield beam.pvalue.TaggedOutput(
                self.DLQ_TAG,
                {
                    "source_file": source_file,
                    "raw_line": line[:10000],
                    "error_stage": "JSON_PARSE_VALIDATION",
                    "error_message": str(exc)[:1000],
                    "failed_at": now_utc,
                },
            )


def run():
    pipeline_options = PipelineOptions(save_main_session=True)
    custom_options = pipeline_options.view_as(MovieIngestOptions)

    valid_table = "project-is-movie-viewable:movie_raw.raw_movies_payload"
    dlq_table = "project-is-movie-viewable:movie_raw.raw_movies_dlq"

    with beam.Pipeline(options=pipeline_options) as p:
        parsed_results = (
            p
            | "ReadJsonlFromGCS" >> beam.io.ReadFromText(custom_options.input_file)
            | "ParseAndValidate"
            >> beam.ParDo(ParseAndValidateMovieFn(custom_options.input_file)).with_outputs(
                ParseAndValidateMovieFn.VALID_TAG,
                ParseAndValidateMovieFn.DLQ_TAG,
            )
        )

        # Write valid rows to BigQuery Raw via free batch FILE_LOADS
        parsed_results[ParseAndValidateMovieFn.VALID_TAG] | "WriteValidToBQ" >> WriteToBigQuery(
            table=valid_table,
            write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
            create_disposition=beam.io.BigQueryDisposition.CREATE_NEVER,
            method=WriteToBigQuery.Method.FILE_LOADS,
        )

        # Write malformed / missing-field rows to BigQuery DLQ
        parsed_results[ParseAndValidateMovieFn.DLQ_TAG] | "WriteDlqToBQ" >> WriteToBigQuery(
            table=dlq_table,
            write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
            create_disposition=beam.io.BigQueryDisposition.CREATE_NEVER,
            method=WriteToBigQuery.Method.FILE_LOADS,
        )


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()