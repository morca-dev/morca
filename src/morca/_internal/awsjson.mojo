"""One signed call to an AWS service's JSON API (Secrets Manager's
`GetSecretValue`, SSM's `GetParameter`): SigV4 over objectstore's HTTP,
with the credentials of the `AWS_*` environment or else the instance
role. A low module: `morca._internal.control` and `morca._internal.machines_ec2` both use it.
"""

from std.os import getenv

from objectstore.crypto import sha256_hex
from objectstore.http import Header, HttpClient, Response
from objectstore.s3 import S3Credentials, instance_credentials
from objectstore.sigv4 import AmzTime, QueryParam, sign_request


def aws_region() -> String:
    return getenv("AWS_REGION", getenv("AWS_DEFAULT_REGION"))


def aws_json(
    service: String,
    target: String,
    endpoint_env: String,
    body: String,
) raises -> Tuple[Int, String]:
    """POSTs `body` to `service` (`secretsmanager`, `ssm`) as `target`
    (`secretsmanager.GetSecretValue`): the status and the answer. The
    endpoint is `https://<service>.<region>.amazonaws.com`, or
    `endpoint_env`'s value (tests' stand-ins). Raises without a region or
    credentials, or when it can't be reached."""
    var region = aws_region()
    if not region:
        raise Error("no AWS_REGION")
    var endpoint = String(
        getenv(
            endpoint_env,
            String("https://", service, ".", region, ".amazonaws.com"),
        ).rstrip("/")
    )
    var host = String(endpoint[byte = endpoint.find("://").or_else(-1) + 3 :])
    var cred = S3Credentials(
        getenv("AWS_ACCESS_KEY_ID"),
        getenv("AWS_SECRET_ACCESS_KEY"),
        getenv("AWS_SESSION_TOKEN"),
    )
    if not cred.is_set():
        var role = instance_credentials()
        if not role:
            raise Error("no AWS credentials")
        cred = role.take()
    var when = AmzTime.now()
    var headers: List[Header] = [
        Header("content-type", "application/x-amz-json-1.1"),
        Header("host", host),
        Header("x-amz-date", when.amz_date),
        Header("x-amz-target", target),
    ]
    if cred.session_token:
        headers.append(Header("x-amz-security-token", cred.session_token))
    var signed = sign_request(
        "POST",
        "/",
        List[QueryParam](),
        headers,
        sha256_hex(body),
        cred.access_key_id,
        cred.secret_access_key,
        region,
        service,
        when,
    )
    headers.append(Header("authorization", signed.authorization))
    var resp: Response
    try:
        resp = HttpClient().post(
            String(endpoint, "/"), body.as_bytes(), headers
        )
    except e:
        raise Error(e)
    return (Int(resp.status), String(from_utf8_lossy=Span(resp.body)))
