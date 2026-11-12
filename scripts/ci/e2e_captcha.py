#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AMS E2E captcha client (pure black-box, standard library only).

Fetches a graphic captcha via GET /api/auth/captcha. The answer is read ONLY
from the explicitly-gated, non-production ``devHint`` field of the JSON
response. Path-only SVG no longer exposes the answer as text, so this client
intentionally does NOT parse SVG text nodes and does NOT silently degrade.

``devHint`` is emitted by the server only when BOTH conditions hold:
    * AMS_ENV is not production/prod
    * AMS_E2E_CAPTCHA_HINT == "true"
Production never returns it (SEC-001 credential gate). This is a strictly
non-production test channel, enabled explicitly for local / self-hosted E2E.

CLI:
    python3 scripts/ci/e2e_captcha.py --base http://127.0.0.1:PORT
        -> two captured lines: ID=... / CODE=... (consumed by the caller via
           command substitution only; never written to any log or report)

    python3 scripts/ci/e2e_captcha.py --base http://127.0.0.1:PORT --probe
        -> structure diagnostics only (field names, svg length, element
           counts, devHint presence). NEVER prints the answer.

    python3 scripts/ci/e2e_captcha.py --base http://127.0.0.1:PORT --assert-denied
        -> security regression: a registration WITHOUT captcha fields must be
           rejected (proves production captcha validation is not weakened).

The answer is only ever used inside a request body; it is never logged,
printed as diagnostics, echoed in errors, or written into any report.
"""
import argparse
import json
import re
import sys
import urllib.error
import urllib.request

# IDs are opaque tokens; codes are alphanumeric. Both kept free of
# shell/JSON-hostile characters so callers can embed them in a JSON body.
_ID_SAFE_RE = re.compile(r"[A-Za-z0-9._:+/=@-]+")
_CODE_SAFE_RE = re.compile(r"[A-Za-z0-9]+")

# Raised when the gated test channel is off. Mentions only configuration,
# never any answer content and never any degraded fallback.
_HINT_ERROR = (
    "captcha response has no devHint (non-production E2E hint channel is off). "
    "Set AMS_E2E_CAPTCHA_HINT=true AND ensure AMS_ENV is not production/prod "
    "on the E2E server, then restart it. Path-only SVG exposes no answer; "
    "refusing to parse SVG text nodes or to silently degrade."
)


class CaptchaError(Exception):
    pass


def _get_json(base_url, timeout):
    url = base_url.rstrip("/") + "/api/auth/captcha"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raise CaptchaError("GET /api/auth/captcha returned HTTP %s" % exc.code)
    except (urllib.error.URLError, OSError) as exc:
        raise CaptchaError("GET /api/auth/captcha failed: %s" % exc)
    try:
        payload = json.loads(raw)
    except ValueError:
        raise CaptchaError(
            "GET /api/auth/captcha did not return JSON (length=%d)" % len(raw)
        )
    if not isinstance(payload, dict):
        raise CaptchaError("GET /api/auth/captcha JSON is not an object")
    return payload


def _locate(payload):
    """Return (object_holding_fields, diagnostic_field_names).

    Compatible with a top-level {captchaId, svg, devHint} shape and with a
    wrapped {code, data: {...}} / {result: {...}} shape.
    """
    top_keys = list(payload.keys())
    if "svg" in payload:
        return payload, top_keys
    for wrap in ("data", "result"):
        inner = payload.get(wrap)
        if isinstance(inner, dict) and "svg" in inner:
            merged = dict(inner)
            for key in ("captchaId", "captcha_id", "id", "devHint"):
                if key in payload and key not in merged:
                    merged[key] = payload[key]
            return merged, top_keys + ["<%s>" % wrap] + list(inner.keys())
    return payload, top_keys


def _svg_of(obj):
    for key in ("svg", "captchaSvg", "svgData", "image"):
        value = obj.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _id_of(obj):
    for key in ("captchaId", "captcha_id", "captchaID", "id"):
        value = obj.get(key)
        if value is not None and str(value) != "":
            return str(value)
    return None


def _hint_of(obj):
    """Return the gated devHint value, or None when the channel is off."""
    value = obj.get("devHint")
    if isinstance(value, str) and value:
        return value
    return None


def fetch_captcha(base_url, timeout=10.0):
    """Return (captcha_id, code) for use in a registration request body.

    The code comes ONLY from devHint: no SVG parsing, no <text> fallback.
    """
    payload = _get_json(base_url, timeout)
    obj, _ = _locate(payload)
    svg = _svg_of(obj)
    if svg is None:
        raise CaptchaError(
            "captcha response has no svg field (fields=%s)"
            % ",".join(sorted(payload.keys()))
        )
    cid = _id_of(obj)
    if cid is None:
        raise CaptchaError("captcha response has no captchaId field")
    code = _hint_of(obj)
    if code is None:
        raise CaptchaError(_HINT_ERROR)
    if not _ID_SAFE_RE.fullmatch(cid):
        raise CaptchaError("captchaId contains unexpected characters")
    if not _CODE_SAFE_RE.fullmatch(code):
        raise CaptchaError("devHint contains unexpected characters")
    return cid, code


def probe(base_url, timeout=10.0):
    """Print structure diagnostics only. Never prints the answer."""
    payload = _get_json(base_url, timeout)
    obj, located_keys = _locate(payload)
    svg = _svg_of(obj) or ""
    print("TOP_FIELDS=" + ",".join(sorted(payload.keys())))
    print("LOCATED_FIELDS=" + ",".join(located_keys))
    print("SVG_LEN=%d" % len(svg))
    print("PATH_COUNT=%d" % svg.count("<path"))
    print("CIRCLE_COUNT=%d" % svg.count("<circle"))
    print("GROUP_COUNT=%d" % svg.count("<g "))
    print("HAS_TEXT_NODE=%s" % ("true" if "<text" in svg else "false"))
    print("DEVHINT_PRESENT=%s" % ("true" if _hint_of(obj) else "false"))


def _post_json(base_url, path, body, timeout):
    url = base_url.rstrip("/") + path
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError:
        return ""  # an HTTP error status itself counts as "rejected"
    except (urllib.error.URLError, OSError) as exc:
        raise CaptchaError("POST %s failed: %s" % (path, exc))


def assert_captcha_required(base_url, timeout=10.0):
    """Security regression: registration without captcha must be rejected.

    Sends no captcha fields and no valid answer; prints no response bodies.
    """
    body = {
        "username": "__captcha_probe__",
        "password": "not-a-real-password",
        "email": "captcha-probe@e2e.local",
        "nickname": "__captcha_probe__",
    }
    raw = _post_json(base_url, "/api/auth/register", body, timeout)
    try:
        parsed = json.loads(raw)
    except ValueError:
        parsed = {}
    code = parsed.get("code") if isinstance(parsed, dict) else None
    if code == "OK":
        raise CaptchaError(
            "security regression: registration WITHOUT captcha was accepted "
            "(production captcha validation appears weakened)"
        )
    print("CAPTCHA_REQUIRED_ASSERTION=PASS")


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="AMS E2E black-box captcha client (standard library only)"
    )
    parser.add_argument("--base", required=True,
                        help="service base, e.g. http://127.0.0.1:18100")
    parser.add_argument("--probe", action="store_true",
                        help="print structure diagnostics only, never characters")
    parser.add_argument("--assert-denied", action="store_true",
                        help="assert captcha-less registration is rejected")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    try:
        if args.probe:
            probe(args.base, args.timeout)
        elif args.assert_denied:
            assert_captcha_required(args.base, args.timeout)
        else:
            cid, code = fetch_captcha(args.base, args.timeout)
            # Captured by the caller via command substitution; never a log/report.
            print("ID=" + cid)
            print("CODE=" + code)
    except CaptchaError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
