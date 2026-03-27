#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, timedelta
from pathlib import Path


PLUGIN_ID = "syntella-analytics"
DATA_API_BASE = "https://analyticsdata.googleapis.com/v1beta"
READONLY_SCOPE = "https://www.googleapis.com/auth/analytics.readonly"
SITE_ALIASES = {
    "asima": "asimaPropertyId",
    "asima.co.uk": "asimaPropertyId",
    "wonderful": "wonderfulPropertyId",
    "wonderful_payments": "wonderfulPropertyId",
    "wonderful-payments": "wonderfulPropertyId",
    "wonderful.co.uk": "wonderfulPropertyId",
}


class AnalyticsError(RuntimeError):
    pass


def read_request():
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AnalyticsError(f"Invalid JSON input: {exc}") from exc
    if not isinstance(payload, dict):
        raise AnalyticsError("Input payload must be a JSON object.")
    return payload


def config_path():
    return Path(os.environ.get("OPENCLAW_CONFIG", os.path.expanduser("~/.openclaw/openclaw.json")))


def load_plugin_entry():
    try:
        with config_path().open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        raise AnalyticsError(f"Could not read OpenClaw config: {exc}") from exc

    plugins = payload.get("plugins") if isinstance(payload, dict) else {}
    entries = plugins.get("entries") if isinstance(plugins, dict) else {}
    entry = entries.get(PLUGIN_ID) if isinstance(entries, dict) else {}
    if not isinstance(entry, dict):
        entry = {}
    config = entry.get("config")
    if not isinstance(config, dict):
        config = {}
    return {
        "enabled": bool(entry.get("enabled")),
        "config": config,
    }


def normalize_property_id(value):
    raw = str(value or "").strip()
    if not raw:
        return ""
    if raw.startswith("properties/"):
        raw = raw.split("/", 1)[1]
    return raw


def configured_sites(config):
    sites = []
    asima_property = normalize_property_id(config.get("asimaPropertyId"))
    if asima_property:
        sites.append({"site": "asima", "propertyId": asima_property})
    wonderful_property = normalize_property_id(config.get("wonderfulPropertyId"))
    if wonderful_property:
        sites.append({"site": "wonderful", "propertyId": wonderful_property})
    return sites


def ensure_configured(entry):
    config = dict(entry.get("config") or {})
    service_account_raw = str(config.get("serviceAccountJson") or "").strip()
    sites = configured_sites(config)
    return {
        "enabled": bool(entry.get("enabled")),
        "configured": bool(service_account_raw and sites),
        "service_account_raw": service_account_raw,
        "sites": sites,
    }


def normalize_site(site_value, config):
    if site_value is None or str(site_value).strip() == "":
        sites = configured_sites(config)
        if len(sites) == 1:
            return sites[0]
        raise AnalyticsError("This action needs a site. Use `wonderful` or `asima`.")

    raw = str(site_value).strip()
    alias_key = raw.lower()
    config_key = SITE_ALIASES.get(alias_key)
    if config_key:
        property_id = normalize_property_id(config.get(config_key))
        if not property_id:
            raise AnalyticsError(f"No Analytics property id is configured for `{raw}`.")
        return {"site": "asima" if config_key == "asimaPropertyId" else "wonderful", "propertyId": property_id}

    property_id = normalize_property_id(raw)
    if property_id.isdigit():
        return {"site": "custom", "propertyId": property_id}

    raise AnalyticsError(f"Unknown site `{raw}`. Use `wonderful`, `asima`, or a GA property id.")


def parse_service_account(service_account_raw):
    try:
        service_account = json.loads(service_account_raw)
    except json.JSONDecodeError as exc:
        raise AnalyticsError(f"Service account JSON is invalid: {exc}") from exc
    if not isinstance(service_account, dict):
        raise AnalyticsError("Service account JSON must decode to an object.")
    required_keys = ["client_email", "private_key", "token_uri"]
    missing = [key for key in required_keys if not str(service_account.get(key) or "").strip()]
    if missing:
        raise AnalyticsError(f"Service account JSON is missing: {', '.join(missing)}.")
    return service_account


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def sign_jwt(unsigned_token, private_key):
    key_path = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(private_key)
            key_path = handle.name
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, "-binary"],
            input=unsigned_token.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError as exc:
        raise AnalyticsError("`openssl` is required to sign Google service-account tokens but is not installed.") from exc
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode("utf-8", errors="ignore").strip()
        raise AnalyticsError(f"Could not sign Google service-account token: {stderr or exc}") from exc
    finally:
        if key_path:
            try:
                os.unlink(key_path)
            except OSError:
                pass
    return base64url(proc.stdout)


def fetch_access_token(service_account):
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {
        "iss": service_account["client_email"],
        "scope": READONLY_SCOPE,
        "aud": service_account["token_uri"],
        "iat": now,
        "exp": now + 3600,
    }
    encoded_header = base64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    encoded_payload = base64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    unsigned = f"{encoded_header}.{encoded_payload}"
    signature = sign_jwt(unsigned, service_account["private_key"])
    assertion = f"{unsigned}.{signature}"
    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        service_account["token_uri"],
        data=body,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    response = request_json(request, include_auth=False)
    token = str(response.get("access_token") or "").strip()
    if not token:
        raise AnalyticsError("Google token exchange did not return an access token.")
    return token


def request_json(request, include_auth=True, token=None):
    if include_auth and token:
        request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="ignore")
        try:
            payload = json.loads(error_body)
        except json.JSONDecodeError:
            payload = {}
        detail = payload.get("error") if isinstance(payload, dict) else None
        if isinstance(detail, dict):
            message = detail.get("message") or error_body or str(exc)
        else:
            message = error_body or str(exc)
        raise AnalyticsError(f"Google Analytics API request failed ({exc.code}): {message.strip()}") from exc
    except urllib.error.URLError as exc:
        raise AnalyticsError(f"Could not reach Google Analytics API: {exc.reason}") from exc

    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise AnalyticsError(f"Google Analytics API returned invalid JSON: {exc}") from exc


def api_post(url, payload, token):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    return request_json(request, token=token)


def api_date_range(days):
    normalized_days = max(1, min(int(days or 28), 365))
    end_date = date.today() - timedelta(days=1)
    start_date = end_date - timedelta(days=normalized_days - 1)
    return {
        "days": normalized_days,
        "startDate": start_date.isoformat(),
        "endDate": end_date.isoformat(),
    }


def previous_date_range(current_window):
    current_start = date.fromisoformat(current_window["startDate"])
    previous_end = current_start - timedelta(days=1)
    previous_start = previous_end - timedelta(days=current_window["days"] - 1)
    return {
        "days": current_window["days"],
        "startDate": previous_start.isoformat(),
        "endDate": previous_end.isoformat(),
    }


def metric(metric_name):
    return {"name": metric_name}


def dimension(dimension_name):
    return {"name": dimension_name}


def metric_order(metric_name, desc=True):
    return {"metric": {"metricName": metric_name}, "desc": bool(desc)}


def string_dimension_filter(field_name, value, match_type="EXACT"):
    return {
        "filter": {
            "fieldName": field_name,
            "stringFilter": {
                "matchType": match_type,
                "value": str(value),
                "caseSensitive": False,
            },
        }
    }


def and_filter(*filters):
    active = [item for item in filters if item]
    if not active:
        return None
    if len(active) == 1:
        return active[0]
    return {"andGroup": {"expressions": active}}


def organic_search_filter():
    return string_dimension_filter("sessionDefaultChannelGroup", "Organic Search")


def normalize_page_value(url_or_path):
    raw = str(url_or_path or "").strip()
    if not raw:
        return ""
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme and parsed.netloc:
        path = parsed.path or "/"
        return path if path.startswith("/") else f"/{path}"
    return raw if raw.startswith("/") else f"/{raw}"


def parse_metric_value(raw):
    value = str(raw or "").strip()
    if not value:
        return 0.0
    try:
        return float(value)
    except ValueError:
        return 0.0


def run_report(token, property_id, payload):
    property_ref = f"properties/{normalize_property_id(property_id)}"
    body = dict(payload or {})
    body["property"] = property_ref
    return api_post(f"{DATA_API_BASE}/{property_ref}:runReport", body, token)


def run_tabular_report(token, property_id, *, metrics, dimensions=None, date_ranges=None, dimension_filter=None, order_bys=None, limit=None):
    payload = {
        "metrics": [metric(name) for name in metrics],
        "dateRanges": date_ranges or [api_date_range(28)],
    }
    if dimensions:
        payload["dimensions"] = [dimension(name) for name in dimensions]
    if dimension_filter:
        payload["dimensionFilter"] = dimension_filter
    if order_bys:
        payload["orderBys"] = order_bys
    if limit is not None:
        payload["limit"] = str(max(1, min(int(limit), 1000)))

    response = run_report(token, property_id, payload)
    dimension_headers = [header.get("name") for header in response.get("dimensionHeaders") or [] if isinstance(header, dict)]
    metric_headers = [header.get("name") for header in response.get("metricHeaders") or [] if isinstance(header, dict)]
    rows = []
    for row in response.get("rows") or []:
        if not isinstance(row, dict):
            continue
        entry = {}
        dimension_values = row.get("dimensionValues") or []
        metric_values = row.get("metricValues") or []
        for index, header_name in enumerate(dimension_headers):
            if not header_name:
                continue
            raw_value = dimension_values[index].get("value") if index < len(dimension_values) and isinstance(dimension_values[index], dict) else None
            entry[header_name] = raw_value
        for index, header_name in enumerate(metric_headers):
            if not header_name:
                continue
            raw_value = metric_values[index].get("value") if index < len(metric_values) and isinstance(metric_values[index], dict) else None
            entry[header_name] = parse_metric_value(raw_value)
        rows.append(entry)
    return {
        "rows": rows,
        "totals": rows[0] if len(rows) == 1 and not dimensions else {},
        "metadata": response.get("metadata") if isinstance(response.get("metadata"), dict) else {},
        "rowCount": int(response.get("rowCount") or len(rows)),
    }


def safe_divide(numerator, denominator):
    denominator_value = float(denominator or 0)
    if not denominator_value:
        return 0.0
    return float(numerator or 0) / denominator_value


def percentage_change(current, previous):
    previous_value = float(previous or 0)
    current_value = float(current or 0)
    if previous_value == 0:
        return None if current_value == 0 else 1.0
    return (current_value - previous_value) / previous_value


def summarize_comparison(current, previous, metric_names):
    summary = {}
    for metric_name in metric_names:
        current_value = float(current.get(metric_name) or 0)
        previous_value = float(previous.get(metric_name) or 0)
        summary[metric_name] = {
            "current": current_value,
            "previous": previous_value,
            "delta": round(current_value - previous_value, 2),
            "deltaPct": percentage_change(current_value, previous_value),
        }
    return summary


def format_trend_rows(rows):
    formatted = []
    for item in rows:
        date_value = str(item.get("date") or "")
        formatted.append(
            {
                "date": date_value,
                "sessions": float(item.get("sessions") or 0),
                "activeUsers": float(item.get("activeUsers") or 0),
                "keyEvents": float(item.get("keyEvents") or 0),
                "averageSessionDuration": float(item.get("averageSessionDuration") or 0),
                "engagementRate": float(item.get("engagementRate") or 0),
            }
        )
    return formatted


def action_inspect(entry, token, args):
    config = dict(entry.get("config") or {})
    configured = ensure_configured(entry)
    configured_site_status = []
    for item in configured["sites"]:
        check = {
            "site": item["site"],
            "propertyId": item["propertyId"],
            "accessible": False,
        }
        try:
            sample = run_tabular_report(
                token,
                item["propertyId"],
                metrics=["sessions"],
                dimensions=["date"],
                date_ranges=[api_date_range(max(3, int(args.get("days") or 7)))],
                limit=1,
            )
            check["accessible"] = True
            check["hasData"] = bool(sample["rows"])
            check["rowCount"] = sample["rowCount"]
        except AnalyticsError as exc:
            check["error"] = str(exc)
        configured_site_status.append(check)
    return {
        "ok": True,
        "action": "inspect",
        "enabled": configured["enabled"],
        "configured": configured["configured"],
        "configuredSites": configured_site_status,
    }


def action_landing_pages(entry, token, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    days = int(args.get("days") or 28)
    limit = max(1, min(int(args.get("limit") or 10), 50))
    window = api_date_range(days)
    report = run_tabular_report(
        token,
        site["propertyId"],
        metrics=[
            "sessions",
            "activeUsers",
            "screenPageViews",
            "averageSessionDuration",
            "engagementRate",
            "bounceRate",
            "keyEvents",
            "sessionKeyEventRate",
        ],
        dimensions=["landingPage"],
        date_ranges=[window],
        order_bys=[metric_order("sessions")],
        limit=limit,
    )
    pages = []
    for row in report["rows"]:
        pages.append(
            {
                "landingPage": row.get("landingPage") or "/",
                "sessions": float(row.get("sessions") or 0),
                "activeUsers": float(row.get("activeUsers") or 0),
                "screenPageViews": float(row.get("screenPageViews") or 0),
                "averageSessionDuration": float(row.get("averageSessionDuration") or 0),
                "engagementRate": float(row.get("engagementRate") or 0),
                "bounceRate": float(row.get("bounceRate") or 0),
                "keyEvents": float(row.get("keyEvents") or 0),
                "sessionKeyEventRate": float(row.get("sessionKeyEventRate") or 0),
            }
        )
    return {
        "ok": True,
        "action": "landing_pages",
        "site": site["site"],
        "propertyId": site["propertyId"],
        "dateWindow": window,
        "landingPages": pages,
    }


def action_organic_trends(entry, token, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    days = int(args.get("days") or 28)
    window = api_date_range(days)
    previous_window = previous_date_range(window)
    metrics = ["sessions", "activeUsers", "keyEvents", "averageSessionDuration", "engagementRate"]
    trend = run_tabular_report(
        token,
        site["propertyId"],
        metrics=metrics,
        dimensions=["date"],
        date_ranges=[window],
        dimension_filter=organic_search_filter(),
        order_bys=[{"dimension": {"dimensionName": "date"}}],
        limit=days,
    )
    current_total = run_tabular_report(
        token,
        site["propertyId"],
        metrics=metrics,
        date_ranges=[window],
        dimension_filter=organic_search_filter(),
        limit=1,
    )["totals"]
    previous_total = run_tabular_report(
        token,
        site["propertyId"],
        metrics=metrics,
        date_ranges=[previous_window],
        dimension_filter=organic_search_filter(),
        limit=1,
    )["totals"]
    return {
        "ok": True,
        "action": "organic_trends",
        "site": site["site"],
        "propertyId": site["propertyId"],
        "dateWindow": window,
        "previousWindow": previous_window,
        "summary": summarize_comparison(current_total, previous_total, metrics),
        "trend": format_trend_rows(trend["rows"]),
    }


def content_summary_row(report):
    totals = report["totals"]
    return {
        "sessions": float(totals.get("sessions") or 0),
        "activeUsers": float(totals.get("activeUsers") or 0),
        "screenPageViews": float(totals.get("screenPageViews") or 0),
        "averageSessionDuration": float(totals.get("averageSessionDuration") or 0),
        "engagementRate": float(totals.get("engagementRate") or 0),
        "bounceRate": float(totals.get("bounceRate") or 0),
        "keyEvents": float(totals.get("keyEvents") or 0),
        "sessionKeyEventRate": float(totals.get("sessionKeyEventRate") or 0),
    }


def action_content_engagement(entry, token, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    days = int(args.get("days") or 28)
    limit = max(1, min(int(args.get("limit") or 10), 25))
    window = api_date_range(days)
    metrics = [
        "sessions",
        "activeUsers",
        "screenPageViews",
        "averageSessionDuration",
        "engagementRate",
        "bounceRate",
        "keyEvents",
        "sessionKeyEventRate",
    ]
    raw_url = str(args.get("url") or "").strip()

    if raw_url:
        page_path = normalize_page_value(raw_url)
        summary_report = run_tabular_report(
            token,
            site["propertyId"],
            metrics=metrics,
            date_ranges=[window],
            dimension_filter=string_dimension_filter("landingPage", page_path),
            limit=1,
        )
        channels = run_tabular_report(
            token,
            site["propertyId"],
            metrics=["sessions", "averageSessionDuration", "engagementRate", "keyEvents", "sessionKeyEventRate"],
            dimensions=["sessionDefaultChannelGroup"],
            date_ranges=[window],
            dimension_filter=string_dimension_filter("landingPage", page_path),
            order_bys=[metric_order("sessions")],
            limit=8,
        )
        return {
            "ok": True,
            "action": "content_engagement",
            "site": site["site"],
            "propertyId": site["propertyId"],
            "dateWindow": window,
            "url": raw_url,
            "landingPage": page_path,
            "summary": content_summary_row(summary_report),
            "channelBreakdown": channels["rows"],
        }

    overall = run_tabular_report(
        token,
        site["propertyId"],
        metrics=metrics,
        date_ranges=[window],
        limit=1,
    )
    top_engaged = run_tabular_report(
        token,
        site["propertyId"],
        metrics=["sessions", "averageSessionDuration", "engagementRate", "keyEvents"],
        dimensions=["landingPage"],
        date_ranges=[window],
        order_bys=[metric_order("averageSessionDuration"), metric_order("sessions")],
        limit=limit,
    )
    low_engaged = run_tabular_report(
        token,
        site["propertyId"],
        metrics=["sessions", "averageSessionDuration", "engagementRate", "bounceRate", "keyEvents"],
        dimensions=["landingPage"],
        date_ranges=[window],
        order_bys=[metric_order("bounceRate"), metric_order("sessions")],
        limit=limit,
    )
    return {
        "ok": True,
        "action": "content_engagement",
        "site": site["site"],
        "propertyId": site["propertyId"],
        "dateWindow": window,
        "summary": content_summary_row(overall),
        "topEngagedPages": top_engaged["rows"],
        "lowEngagementPages": low_engaged["rows"],
    }


def action_conversion_summary(entry, token, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    days = int(args.get("days") or 28)
    limit = max(1, min(int(args.get("limit") or 10), 25))
    window = api_date_range(days)
    previous_window = previous_date_range(window)
    metrics = ["sessions", "keyEvents", "sessionKeyEventRate", "totalRevenue"]
    current_total = run_tabular_report(
        token,
        site["propertyId"],
        metrics=metrics,
        date_ranges=[window],
        limit=1,
    )["totals"]
    previous_total = run_tabular_report(
        token,
        site["propertyId"],
        metrics=metrics,
        date_ranges=[previous_window],
        limit=1,
    )["totals"]
    channel_report = run_tabular_report(
        token,
        site["propertyId"],
        metrics=["sessions", "keyEvents", "sessionKeyEventRate", "totalRevenue"],
        dimensions=["sessionDefaultChannelGroup"],
        date_ranges=[window],
        order_bys=[metric_order("keyEvents"), metric_order("sessions")],
        limit=8,
    )
    landing_page_report = run_tabular_report(
        token,
        site["propertyId"],
        metrics=["sessions", "keyEvents", "sessionKeyEventRate", "totalRevenue"],
        dimensions=["landingPage"],
        date_ranges=[window],
        order_bys=[metric_order("keyEvents"), metric_order("sessions")],
        limit=limit,
    )
    organic_total = run_tabular_report(
        token,
        site["propertyId"],
        metrics=metrics,
        date_ranges=[window],
        dimension_filter=organic_search_filter(),
        limit=1,
    )["totals"]
    return {
        "ok": True,
        "action": "conversion_summary",
        "site": site["site"],
        "propertyId": site["propertyId"],
        "dateWindow": window,
        "previousWindow": previous_window,
        "summary": summarize_comparison(current_total, previous_total, metrics),
        "organicSummary": {
            "sessions": float(organic_total.get("sessions") or 0),
            "keyEvents": float(organic_total.get("keyEvents") or 0),
            "sessionKeyEventRate": float(organic_total.get("sessionKeyEventRate") or 0),
            "totalRevenue": float(organic_total.get("totalRevenue") or 0),
            "keyEventsPerSession": safe_divide(organic_total.get("keyEvents"), organic_total.get("sessions")),
        },
        "channels": channel_report["rows"],
        "landingPages": landing_page_report["rows"],
    }


def run_action(args):
    action = str(args.get("action") or "inspect").strip() or "inspect"
    entry = load_plugin_entry()
    configured = ensure_configured(entry)

    if action == "inspect":
        if not configured["enabled"] or not configured["configured"]:
            return {
                "ok": True,
                "action": "inspect",
                "enabled": configured["enabled"],
                "configured": configured["configured"],
                "configuredSites": configured["sites"],
            }
        service_account = parse_service_account(configured["service_account_raw"])
        token = fetch_access_token(service_account)
        return action_inspect(entry, token, args)

    if not configured["enabled"]:
        raise AnalyticsError("Google Analytics integration is disabled for this workspace.")
    if not configured["configured"]:
        raise AnalyticsError("Google Analytics integration is missing a property id or service-account JSON.")

    service_account = parse_service_account(configured["service_account_raw"])
    token = fetch_access_token(service_account)

    if action == "landing_pages":
        return action_landing_pages(entry, token, args)
    if action == "organic_trends":
        return action_organic_trends(entry, token, args)
    if action == "content_engagement":
        return action_content_engagement(entry, token, args)
    if action == "conversion_summary":
        return action_conversion_summary(entry, token, args)

    raise AnalyticsError(
        "Unknown action. Use `inspect`, `landing_pages`, `organic_trends`, `content_engagement`, or `conversion_summary`."
    )


def main():
    try:
        args = read_request()
        result = run_action(args)
    except AnalyticsError as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:
        result = {"ok": False, "error": f"Unexpected Analytics error: {exc}"}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
