#!/bin/bash
# Ejecutado por EC2 al arrancar (Launch Template UserData).
# Asume Amazon Linux 2 / Amazon Linux 2023.

set -e

yum update -y
yum install -y python3 python3-pip git postgresql15

# Clonar el repo de la aplicacion
git clone https://github.com/<TU_ORG>/asr-disponibilidad.git /home/ec2-user/app
cd /home/ec2-user/app/app

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# Variables de entorno (reemplazar con Parameter Store o Secrets Manager en produccion)
export DB_HOST="${db_host}"
export DB_NAME="bitedb"
export DB_USER="biteadmin"
export DB_PASSWORD="${db_password}"
export JWT_SECRET="${jwt_secret}"
export S3_REPORTS_BUCKET="${s3_bucket}"
export SES_SENDER="${ses_sender}"
export AWS_REGION="us-east-1"

# Iniciar gunicorn como servicio
cat > /etc/systemd/system/bite-app.service <<EOF
[Unit]
Description=BITE.co App
After=network.target

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user/app/app
Environment="DB_HOST=${db_host}"
Environment="DB_NAME=bitedb"
Environment="DB_USER=biteadmin"
Environment="DB_PASSWORD=${db_password}"
Environment="JWT_SECRET=${jwt_secret}"
Environment="S3_REPORTS_BUCKET=${s3_bucket}"
Environment="SES_SENDER=${ses_sender}"
Environment="AWS_REGION=us-east-1"
ExecStart=/home/ec2-user/app/app/venv/bin/gunicorn -w 4 -b 0.0.0.0:5000 main:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bite-app
systemctl start bite-app
