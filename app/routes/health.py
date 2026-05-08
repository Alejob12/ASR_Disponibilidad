from flask import Blueprint, jsonify
import psycopg2
import os

health_bp = Blueprint("health", __name__)


@health_bp.route("/health", methods=["GET"])
def health_check():
    db_ok = _check_db()
    status = "healthy" if db_ok else "degraded"
    code = 200 if db_ok else 503
    return jsonify({"status": status, "db": db_ok}), code


def _check_db():
    try:
        conn = psycopg2.connect(
            host=os.environ["DB_HOST"],
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            connect_timeout=3,
        )
        conn.close()
        return True
    except Exception:
        return False
