import base64
import os

import boto3

ecr = boto3.client("ecr")
secretsmanager = boto3.client("secretsmanager")


def handler(event, context):
    registry_id = os.environ["ECR_REGISTRY_ID"]
    secret_id = os.environ["SECRET_ID"]

    resp = ecr.get_authorization_token(registryIds=[registry_id])
    token = resp["authorizationData"][0]["authorizationToken"]
    username, password = base64.b64decode(token).decode("utf-8").split(":", 1)

    secretsmanager.put_secret_value(SecretId=secret_id, SecretString=password)

    return {"status": "refreshed", "username": username, "secretId": secret_id}
