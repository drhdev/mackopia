"""Malformed or incomplete fixture authorization must fail closed."""

from email.message import Message
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("s3_fixture_auth", Path(__file__).parents[1] / "s3_fixture_auth.py")
AUTH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTH)


class S3FixtureAuthTests(unittest.TestCase):
    def test_missing_or_malformed_signature_is_rejected(self):
        for value in ("", "Basic fixture", "AWS4-HMAC-SHA256 invalid", "AWS4-HMAC-SHA256 Credential=fixture",
                      "AWS4-HMAC-SHA256 Credential=fixture/date/region/s3/aws4_request, SignedHeaders=host"):
            headers = Message()
            headers["Authorization"] = value
            self.assertFalse(AUTH.authorized("GET", "/bucket/object", headers, "fixture", "synthetic", "token"))

    def test_unexpected_credential_scope_or_unsigned_token_is_rejected(self):
        headers = Message()
        headers["Authorization"] = (
            "AWS4-HMAC-SHA256 Credential=other/20261023/region/s3/aws4_request, "
            "SignedHeaders=host;x-amz-date, Signature=" + "0" * 64)
        headers["X-Amz-Security-Token"] = "token"
        self.assertFalse(AUTH.authorized("GET", "/bucket/object", headers, "fixture", "synthetic", "token"))

    def test_write_methods_are_not_authenticated_by_read_only_s3_fixture(self):
        self.assertFalse(AUTH.authorized("PUT", "/bucket/object", Message(), "fixture", "synthetic", "token"))


if __name__ == "__main__":
    unittest.main()
