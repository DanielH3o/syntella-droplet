#!/usr/bin/env python3
import base64
import binascii
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


PLUGIN_ID = "syntella-ghost"
ACCEPT_VERSION = "v5.0"
DEFAULT_USER_AGENT = os.environ.get("SYNTELLA_GHOST_USER_AGENT", "curl/8.7.1")
SITE_ALIASES = {
    "asima": "asima",
    "asima.co.uk": "asima",
    "wonderful": "wonderful",
    "wonderful-payments": "wonderful",
    "wonderful_payments": "wonderful",
    "wonderful.co.uk": "wonderful",
}
POST_STATUSES = {"draft", "published", "scheduled", "sent"}


class GhostError(RuntimeError):
    pass


def read_request():
    raw = sys.stdin.read().strip()
    if not raw:
        return {}
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise GhostError(f"Invalid JSON input: {exc}") from exc
    if not isinstance(payload, dict):
        raise GhostError("Input payload must be a JSON object.")
    return payload


def config_path():
    return Path(os.environ.get("OPENCLAW_CONFIG", os.path.expanduser("~/.openclaw/openclaw.json")))


def load_plugin_entry():
    try:
        with config_path().open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except Exception as exc:
        raise GhostError(f"Could not read OpenClaw config: {exc}") from exc

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


def normalize_admin_url(raw):
    value = str(raw or "").strip()
    if not value:
        raise GhostError("Ghost admin URL is missing.")
    parsed = urllib.parse.urlparse(value)
    if not parsed.scheme or not parsed.netloc:
        raise GhostError(f"Ghost admin URL is invalid: `{value}`.")

    path = (parsed.path or "").rstrip("/")
    if not path or path == "/":
        path = "/ghost/api/admin"
    elif path.endswith("/ghost/api/admin"):
        pass
    elif path.endswith("/ghost"):
        path = f"{path}/api/admin"
    else:
        path = f"{path}/ghost/api/admin"

    normalized = urllib.parse.urlunparse((parsed.scheme, parsed.netloc, path, "", "", ""))
    return normalized.rstrip("/") + "/"


def configured_sites(config):
    sites = []
    asima_url = str(config.get("asimaAdminUrl") or "").strip()
    asima_key = str(config.get("asimaAdminKey") or "").strip()
    if asima_url or asima_key:
        sites.append(
            {
                "site": "asima",
                "adminUrl": normalize_admin_url(asima_url) if asima_url else "",
                "adminKey": asima_key,
            }
        )

    wonderful_url = str(config.get("wonderfulAdminUrl") or "").strip()
    wonderful_key = str(config.get("wonderfulAdminKey") or "").strip()
    if wonderful_url or wonderful_key:
        sites.append(
            {
                "site": "wonderful",
                "adminUrl": normalize_admin_url(wonderful_url) if wonderful_url else "",
                "adminKey": wonderful_key,
            }
        )
    return sites


def ensure_configured(entry):
    config = dict(entry.get("config") or {})
    sites = configured_sites(config)
    configured = any(site.get("adminUrl") and site.get("adminKey") for site in sites)
    return {
        "enabled": bool(entry.get("enabled")),
        "configured": configured,
        "sites": sites,
    }


def normalize_site(site_value, config):
    sites = {site["site"]: site for site in configured_sites(config)}
    complete_sites = {name: site for name, site in sites.items() if site.get("adminUrl") and site.get("adminKey")}

    if site_value is None or str(site_value).strip() == "":
        if len(complete_sites) == 1:
            return next(iter(complete_sites.values()))
        raise GhostError("This action needs a site. Use `wonderful` or `asima`.")

    alias = SITE_ALIASES.get(str(site_value).strip().lower())
    if not alias or alias not in complete_sites:
        raise GhostError(f"Unknown or unconfigured site `{site_value}`. Use `wonderful` or `asima`.")
    return complete_sites[alias]


def parse_admin_key(raw):
    value = str(raw or "").strip()
    if ":" not in value:
        raise GhostError("Ghost admin key must be in `id:secret` format.")
    key_id, secret_hex = value.split(":", 1)
    key_id = key_id.strip()
    secret_hex = secret_hex.strip()
    if not key_id or not secret_hex:
        raise GhostError("Ghost admin key must include both an id and a secret.")
    try:
        secret = binascii.unhexlify(secret_hex)
    except (binascii.Error, ValueError) as exc:
        raise GhostError("Ghost admin key secret is not valid hexadecimal.") from exc
    return key_id, secret


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def build_token(admin_key):
    key_id, secret = parse_admin_key(admin_key)
    now = int(time.time())
    header = {"alg": "HS256", "kid": key_id, "typ": "JWT"}
    payload = {"iat": now, "exp": now + 300, "aud": "/admin/"}
    encoded_header = base64url(json.dumps(header, separators=(",", ":")).encode("utf-8"))
    encoded_payload = base64url(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    unsigned = f"{encoded_header}.{encoded_payload}".encode("utf-8")
    signature = hmac.new(secret, unsigned, hashlib.sha256).digest()
    return f"{unsigned.decode('utf-8')}.{base64url(signature)}"


def ghost_request(site, method, resource_path, payload=None, params=None):
    base_url = site["adminUrl"]
    token = build_token(site["adminKey"])
    url = urllib.parse.urljoin(base_url, resource_path.lstrip("/"))
    if params:
        query = urllib.parse.urlencode({key: value for key, value in params.items() if value is not None})
        if query:
            url = f"{url}?{query}"

    body = None
    headers = {
        "Accept": "application/json",
        "Accept-Version": ACCEPT_VERSION,
        "Authorization": f"Ghost {token}",
        "User-Agent": DEFAULT_USER_AGENT,
    }
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="ignore")
        try:
            parsed = json.loads(error_body) if error_body else {}
        except json.JSONDecodeError:
            parsed = {}
        errors = parsed.get("errors") if isinstance(parsed, dict) else None
        if isinstance(errors, list) and errors and isinstance(errors[0], dict):
            message = errors[0].get("message") or error_body or str(exc)
        else:
            message = error_body or str(exc)
        raise GhostError(f"Ghost API request failed ({exc.code}): {message.strip()}") from exc
    except urllib.error.URLError as exc:
        raise GhostError(f"Could not reach Ghost API: {exc.reason}") from exc

    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise GhostError(f"Ghost API returned invalid JSON: {exc}") from exc


def api_get(site, resource_path, params=None):
    return ghost_request(site, "GET", resource_path, params=params)


def api_post(site, resource_path, payload, params=None):
    return ghost_request(site, "POST", resource_path, payload=payload, params=params)


def api_put(site, resource_path, payload, params=None):
    return ghost_request(site, "PUT", resource_path, payload=payload, params=params)


def normalize_tag_names(tags):
    normalized = []
    for tag in tags or []:
        if not isinstance(tag, str):
            raise GhostError("Ghost tags must be an array of strings.")
        value = tag.strip()
        if value:
            normalized.append(value)
    return normalized


def normalize_post(post, include_content=False):
    if not isinstance(post, dict):
        return {}
    tags = []
    for tag in post.get("tags") or []:
        if isinstance(tag, dict):
            value = str(tag.get("name") or tag.get("slug") or "").strip()
            if value:
                tags.append(value)
    authors = []
    for author in post.get("authors") or []:
        if isinstance(author, dict):
            value = str(author.get("name") or author.get("email") or "").strip()
            if value:
                authors.append(value)
    normalized = {
        "id": post.get("id"),
        "uuid": post.get("uuid"),
        "title": post.get("title"),
        "slug": post.get("slug"),
        "status": post.get("status"),
        "url": post.get("url"),
        "excerpt": post.get("custom_excerpt") or post.get("excerpt"),
        "custom_excerpt": post.get("custom_excerpt"),
        "meta_title": post.get("meta_title"),
        "meta_description": post.get("meta_description"),
        "canonical_url": post.get("canonical_url"),
        "created_at": post.get("created_at"),
        "updated_at": post.get("updated_at"),
        "published_at": post.get("published_at"),
        "tags": tags,
        "authors": authors,
    }
    if include_content:
        normalized["html"] = post.get("html")
        normalized["lexical"] = post.get("lexical")
    return normalized


def fetch_post(site, post_id=None, slug=None):
    params = {"include": "tags,authors", "formats": "html,lexical"}
    if post_id:
        response = api_get(site, f"posts/{urllib.parse.quote(str(post_id), safe='')}/", params=params)
    elif slug:
        response = api_get(site, f"posts/slug/{urllib.parse.quote(str(slug), safe='')}/", params=params)
    else:
        raise GhostError("A Ghost post id or slug is required.")
    posts = response.get("posts")
    if not isinstance(posts, list) or not posts:
        raise GhostError("Ghost did not return a post for that identifier.")
    return posts[0]


def validate_status_filter(value):
    normalized = str(value or "all").strip().lower()
    if normalized == "all":
        return normalized
    if normalized not in POST_STATUSES:
        raise GhostError(f"Unsupported status `{value}`. Use `all`, `draft`, `published`, `scheduled`, or `sent`.")
    return normalized


def build_post_payload(args, creating=False):
    payload = {"status": "draft"}
    title = str(args.get("title") or "").strip()
    html = args.get("html")
    lexical = args.get("lexical")

    if html is not None and lexical is not None and str(html).strip() and str(lexical).strip():
        raise GhostError("Provide either `html` or `lexical`, not both.")

    if creating and not title:
        raise GhostError("`title` is required for create_draft.")
    if title:
        payload["title"] = title

    if "slug" in args:
        payload["slug"] = str(args.get("slug") or "").strip()
    if "excerpt" in args:
        payload["custom_excerpt"] = str(args.get("excerpt") or "").strip()
    if "meta_title" in args:
        payload["meta_title"] = str(args.get("meta_title") or "").strip()
    if "meta_description" in args:
        payload["meta_description"] = str(args.get("meta_description") or "").strip()
    if "canonical_url" in args:
        payload["canonical_url"] = str(args.get("canonical_url") or "").strip()
    if "tags" in args:
        payload["tags"] = normalize_tag_names(args.get("tags") or [])

    if html is not None:
        payload["html"] = str(html)
    if lexical is not None:
        lexical_value = str(lexical).strip()
        if lexical_value:
            try:
                json.loads(lexical_value)
            except json.JSONDecodeError as exc:
                raise GhostError(f"`lexical` must be a JSON string: {exc}") from exc
            payload["lexical"] = lexical_value

    return payload


def action_inspect(entry, _args):
    config = dict(entry.get("config") or {})
    configured = ensure_configured(entry)
    site_checks = []
    for site in configured["sites"]:
        check = {
            "site": site["site"],
            "adminUrl": site["adminUrl"],
            "configured": bool(site.get("adminUrl") and site.get("adminKey")),
            "reachable": False,
        }
        if not check["configured"]:
            check["error"] = "Missing admin URL or admin key."
            site_checks.append(check)
            continue
        try:
            site_info = api_get(site, "site/")
            check["reachable"] = True
            check["title"] = site_info.get("title") if isinstance(site_info, dict) else None
            check["siteUrl"] = site_info.get("url") if isinstance(site_info, dict) else None
        except GhostError as exc:
            check["error"] = str(exc)
        site_checks.append(check)
    return {
        "ok": True,
        "action": "inspect",
        "enabled": configured["enabled"],
        "configured": configured["configured"],
        "configuredSites": site_checks,
    }


def action_list_posts(entry, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    limit = max(1, min(int(args.get("limit") or 10), 50))
    page = max(1, min(int(args.get("page") or 1), 100))
    status = validate_status_filter(args.get("status"))
    params = {
        "include": "tags,authors",
        "limit": limit,
        "page": page,
        "order": "updated_at desc",
    }
    if status != "all":
        params["filter"] = f"status:{status}"
    response = api_get(site, "posts/", params=params)
    posts = response.get("posts") if isinstance(response, dict) else []
    normalized = [normalize_post(post, include_content=False) for post in (posts or [])]
    meta = response.get("meta") if isinstance(response, dict) else {}
    pagination = meta.get("pagination") if isinstance(meta, dict) else {}
    return {
        "ok": True,
        "action": "list_posts",
        "site": site["site"],
        "status": status,
        "posts": normalized,
        "pagination": pagination if isinstance(pagination, dict) else {},
    }


def action_get_post(entry, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    post = fetch_post(site, post_id=args.get("post_id"), slug=args.get("slug"))
    return {
        "ok": True,
        "action": "get_post",
        "site": site["site"],
        "post": normalize_post(post, include_content=True),
    }


def action_create_draft(entry, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    payload = build_post_payload(args, creating=True)
    params = {"formats": "html,lexical"}
    if payload.get("html") and not payload.get("lexical"):
        params["source"] = "html"
    response = api_post(site, "posts/", {"posts": [payload]}, params=params)
    posts = response.get("posts") if isinstance(response, dict) else []
    if not isinstance(posts, list) or not posts:
        raise GhostError("Ghost did not return the created draft.")
    return {
        "ok": True,
        "action": "create_draft",
        "site": site["site"],
        "post": normalize_post(posts[0], include_content=True),
    }


def action_update_draft(entry, args):
    config = dict(entry.get("config") or {})
    site = normalize_site(args.get("site"), config)
    existing = fetch_post(site, post_id=args.get("post_id"), slug=args.get("slug"))
    existing_status = str(existing.get("status") or "").strip().lower()
    if existing_status != "draft":
        raise GhostError("Only existing draft posts can be updated. This tool will not edit published or scheduled posts.")

    payload = build_post_payload(args, creating=False)
    updated_at = str(existing.get("updated_at") or "").strip()
    if not updated_at:
        raise GhostError("Ghost did not return `updated_at` for the draft, so a safe update is not possible.")
    payload["updated_at"] = updated_at
    payload["status"] = "draft"

    post_id = str(existing.get("id") or "").strip()
    if not post_id:
        raise GhostError("Ghost did not return an id for the draft.")

    params = {"formats": "html,lexical"}
    if payload.get("html") and not payload.get("lexical"):
        params["source"] = "html"
    response = api_put(site, f"posts/{urllib.parse.quote(post_id, safe='')}/", {"posts": [payload]}, params=params)
    posts = response.get("posts") if isinstance(response, dict) else []
    if not isinstance(posts, list) or not posts:
        raise GhostError("Ghost did not return the updated draft.")
    return {
        "ok": True,
        "action": "update_draft",
        "site": site["site"],
        "post": normalize_post(posts[0], include_content=True),
    }


def main():
    try:
        args = read_request()
        action = str(args.get("action") or "inspect").strip().lower() or "inspect"
        entry = load_plugin_entry()
        actions = {
            "inspect": action_inspect,
            "list_posts": action_list_posts,
            "get_post": action_get_post,
            "create_draft": action_create_draft,
            "update_draft": action_update_draft,
        }
        if action not in actions:
            raise GhostError(f"Unsupported Ghost action `{action}`.")
        result = actions[action](entry, args)
    except GhostError as exc:
        result = {"ok": False, "error": str(exc)}
    except Exception as exc:
        result = {"ok": False, "error": f"Unexpected Ghost tool failure: {exc}"}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
