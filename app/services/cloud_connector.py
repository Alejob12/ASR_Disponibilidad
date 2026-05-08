import boto3
import os
from utils.fallback import call_with_fallback
from datetime import datetime, timedelta


def get_aws_costs(company_id: str) -> dict:
    def _fetch():
        client = boto3.client(
            "ce",
            region_name=os.environ.get("AWS_REGION", "us-east-1"),
        )
        end = datetime.utcnow().date()
        start = end - timedelta(days=30)
        response = client.get_cost_and_usage(
            TimePeriod={"Start": str(start), "End": str(end)},
            Granularity="MONTHLY",
            Filter={"Tags": {"Key": "CompanyID", "Values": [company_id]}},
            Metrics=["UnblendedCost"],
        )
        results = response.get("ResultsByTime", [])
        total = sum(
            float(r["Total"]["UnblendedCost"]["Amount"]) for r in results
        )
        return {"company_id": company_id, "total_cost_usd": round(total, 4)}

    fallback = {"company_id": company_id, "total_cost_usd": None, "source": "fallback"}
    return call_with_fallback(_fetch, fallback, timeout=5)
