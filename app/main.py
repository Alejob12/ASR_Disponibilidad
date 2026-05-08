from flask import Flask
from routes.health import health_bp
from routes.auth import auth_bp
from routes.costs import costs_bp

app = Flask(__name__)

app.register_blueprint(health_bp)
app.register_blueprint(auth_bp, url_prefix="/auth")
app.register_blueprint(costs_bp, url_prefix="/costs")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
