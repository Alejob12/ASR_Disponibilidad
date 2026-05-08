import boto3
import json
import os
import time
from datetime import datetime


def generate_report_async(company_id: str, email: str) -> None:
    """Runs in a background thread. Generates report and uploads to S3, then emails the user."""
    try:
        report = _build_report(company_id)
        s3_url = _upload_to_s3(company_id, report)
        _send_email(email, company_id, s3_url)
    except Exception as exc:
        print(f"[report_service] ERROR for {company_id}: {exc}")


def _build_report(company_id: str) -> dict:
    # Simulates a slow analysis (>2 s) running in background
    time.sleep(3)
    return {
        "company_id": company_id,
        "generated_at": datetime.utcnow().isoformat(),
        "period": "last_30_days",
        "summary": "placeholder — replace with real aggregation logic",
    }


def _upload_to_s3(company_id: str, report: dict) -> str:
    bucket = os.environ["S3_REPORTS_BUCKET"]
    key = f"reports/{company_id}/{datetime.utcnow().strftime('%Y%m')}.json"
    s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(report),
        ContentType="application/json",
    )
    return f"s3://{bucket}/{key}"


def _send_email(email: str, company_id: str, s3_url: str) -> None:
    ses = boto3.client("ses", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    ses.send_email(
        Source=os.environ["SES_SENDER"],
        Destination={"ToAddresses": [email]},
        Message={
            "Subject": {"Data": f"Reporte mensual listo – {company_id}"},
            "Body": {
                "Text": {
                    "Data": f"Tu reporte mensual está disponible en: {s3_url}"
                }
            },
        },
    )
