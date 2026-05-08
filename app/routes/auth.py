from flask import Blueprint, request, jsonify
import jwt
import os
import datetime

auth_bp = Blueprint("auth", __name__)

SECRET_KEY = os.environ.get("JWT_SECRET", "change-me-in-production")


@auth_bp.route("/login", methods=["POST"])
def login():
    data = request.get_json(silent=True) or {}
    username = data.get("username")
    password = data.get("password")

    if not username or not password:
        return jsonify({"error": "username and password required"}), 400

    # Placeholder: replace with real DB lookup
    if username == "demo" and password == "demo123":
        token = jwt.encode(
            {
                "sub": username,
                "exp": datetime.datetime.utcnow() + datetime.timedelta(hours=1),
            },
            SECRET_KEY,
            algorithm="HS256",
        )
        return jsonify({"token": token})

    return jsonify({"error": "invalid credentials"}), 401


@auth_bp.route("/validate", methods=["GET"])
def validate():
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return jsonify({"error": "missing token"}), 401
    token = auth_header.split(" ", 1)[1]
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=["HS256"])
        return jsonify({"valid": True, "user": payload["sub"]})
    except jwt.ExpiredSignatureError:
        return jsonify({"error": "token expired"}), 401
    except jwt.InvalidTokenError:
        return jsonify({"error": "invalid token"}), 401
