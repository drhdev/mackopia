"""Minimal SigV4 verification for loopback fixture requests, not a service."""

import hashlib
import hmac
from urllib.parse import parse_qsl, quote, urlsplit


def authorized(method, target, headers, access_key, secret_key, session_token, methods=("GET", "HEAD")):
    try:
        authorization = headers.get("Authorization", "")
        if not authorization.startswith("AWS4-HMAC-SHA256 ") or method not in methods:
            return False
        fields = dict(item.strip().split("=", 1) for item in authorization[17:].split(","))
        credential = fields["Credential"].split("/")
        if len(credential) != 5:
            return False
        identity, date, region, service, suffix = credential
        if (identity != access_key or service != "s3" or suffix != "aws4_request"
                or headers.get("X-Amz-Security-Token", "") != session_token):
            return False
        signed = fields["SignedHeaders"].split(";")
        if signed != sorted(set(signed)) or not {"host", "x-amz-date"}.issubset(signed):
            return False
        timestamp = headers["X-Amz-Date"]
        if not timestamp.startswith(date + "T"):
            return False
        canonical_headers = "".join(name + ":" + " ".join(headers[name].split()) + "\n" for name in signed)
        url = urlsplit(target)
        query = "&".join(key + "=" + value for key, value in sorted(
            (quote(key, safe="-_.~"), quote(value, safe="-_.~"))
            for key, value in parse_qsl(url.query, keep_blank_values=True)))
        canonical = "\n".join((method, url.path or "/", query, canonical_headers,
                                fields["SignedHeaders"], headers["X-Amz-Content-Sha256"]))
        scope = "/".join(credential[1:])
        string_to_sign = "\n".join(("AWS4-HMAC-SHA256", timestamp, scope,
                                    hashlib.sha256(canonical.encode()).hexdigest()))
        key = ("AWS4" + secret_key).encode()
        for value in (date, region, service, suffix):
            key = hmac.new(key, value.encode(), hashlib.sha256).digest()
        expected = hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(expected, fields["Signature"])
    except (KeyError, ValueError, AttributeError, TypeError):
        return False
