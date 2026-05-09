"""
CDK entry point para el experimento ASR Disponibilidad – BITE.co

Al ejecutarse (cdk synth / cdk deploy), este script usa boto3 para
auto-descubrir la VPC default y las subredes de la sesion activa de
AWS Academy, sin necesidad de configurar VPC_ID manualmente.
"""
from __future__ import annotations

import json
import sys

import boto3
import aws_cdk as cdk

from bite_stack import BiteStack

CONFIG_FILE = "config.json"


def discover_default_network(region: str) -> dict:
    client = boto3.client("ec2", region_name=region)

    vpcs = client.describe_vpcs(
        Filters=[{"Name": "isDefault", "Values": ["true"]}]
    )
    if not vpcs["Vpcs"]:
        print(
            "\nERROR: No existe una VPC default en la region.\n"
            "Crea una con:\n"
            f"  aws ec2 create-default-vpc --region {region}\n"
        )
        sys.exit(1)

    vpc_id = vpcs["Vpcs"][0]["VpcId"]

    subnets_resp = client.describe_subnets(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "defaultForAz", "Values": ["true"]},
        ]
    )
    subnets = subnets_resp["Subnets"]

    if len(subnets) < 2:
        print(
            f"\nERROR: Se requieren >= 2 subredes default (encontradas: {len(subnets)}).\n"
            "Crea subredes default con:\n"
            f"  aws ec2 create-default-subnet --availability-zone <AZ> --region {region}\n"
        )
        sys.exit(1)

    return {
        "vpc_id": vpc_id,
        "subnet_ids": [s["SubnetId"] for s in subnets],
        "availability_zones": [s["AvailabilityZone"] for s in subnets],
    }


# ── Cargar configuracion estatica ──────────────────────────────────────────
with open(CONFIG_FILE) as f:
    config = json.load(f)

# ── Auto-descubrir red de la sesion activa ─────────────────────────────────
print(f"\nDescubriendo VPC default en {config['region']}...")
network = discover_default_network(config["region"])
config.update(network)
print(f"  VPC       : {config['vpc_id']}")
print(f"  Subredes  : {', '.join(config['subnet_ids'])}")
print(f"  AZs       : {', '.join(config['availability_zones'])}\n")

# ── Sintetizar stack ───────────────────────────────────────────────────────
app = cdk.App()

BiteStack(
    app,
    "BiteStack",
    config=config,
    env=cdk.Environment(region=config["region"]),
)

app.synth()
