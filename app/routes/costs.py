from flask import Blueprint, request, jsonify
from services.cloud_connector import get_aws_costs
from services.report_service import generate_report_async
import threading

costs_bp = Blueprint("costs", __name__)


@costs_bp.route("/summary", methods=["GET"])
def cost_summary():
    company_id = request.args.get("company_id")
    if not company_id:
        return jsonify({"error": "company_id required"}), 400

    data = get_aws_costs(company_id)
    return jsonify(data)


@costs_bp.route("/report", methods=["POST"])
def trigger_report():
    """Fires async report generation; responds immediately."""
    data = request.get_json(silent=True) or {}
    company_id = data.get("company_id")
    email = data.get("email")

    if not company_id or not email:
        return jsonify({"error": "company_id and email required"}), 400

    thread = threading.Thread(
        target=generate_report_async, args=(company_id, email), daemon=True
    )
    thread.start()
    return jsonify({"message": "Report generation started. You will receive an email when ready."}), 202
