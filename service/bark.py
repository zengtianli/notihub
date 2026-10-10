"""Private Bark archive and one-attempt relay in the existing cloud runtime."""
import asyncio
import datetime as dt
import hashlib
import hmac
import http.client
import json
import re
import socket
import time
import uuid
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

TZ = ZoneInfo("Asia/Shanghai")
KEY_PATH = re.compile(r"^/[A-Za-z0-9_-]{10,80}/?$")
SAFE_FIELDS = ("title", "subtitle", "body", "group", "url", "icon", "level", "sound")
FILTER_CATEGORIES = (
    {"id": "jd", "label": "京东 / JD"},
    {"id": "sf", "label": "顺丰"},
    {"id": "ck", "label": "CK / 登录续期"},
)
CATEGORY_IDS = {item["id"] for item in FILTER_CATEGORIES}
CATEGORY_LABELS = {item["id"]: item["label"] for item in FILTER_CATEGORIES}
TOPIC_PATTERNS = {
    "ck": re.compile(r"(?<![a-z0-9])ck(?![a-z0-9])|(?:京东|顺丰|青龙).{0,20}(?:cookie|登录续期|登录失效)", re.I),
    "sf": re.compile(r"顺丰|(?<![a-z0-9])sf(?:-express)?(?![a-z0-9])", re.I),
    "jd": re.compile(r"京东|京豆|beandeck|jdpro|qinglong-jd|(?<![a-z0-9])jd(?![a-z0-9])", re.I),
}
IGNORED_SQL = "bark_ignored(title,body,group_name,source,payload)"
SECRET_PATTERN = re.compile(
    r"(?i)(\b(?:device[_-]?key|bark[_-]?(?:key|push)|api[_-]?key|access[_-]?token|"
    r"refresh[_-]?token|password|passwd|client[_-]?secret|authorization|pt_key|pt_pin)"
    r"[\"']?\s*[:=]\s*)(?:\"[^\"\n]*\"|'[^'\n]*'|[^\s,;}&]+)")


def safe(value, secrets=()):
    if isinstance(value, str):
        for secret in sorted((s for s in secrets if s), key=len, reverse=True):
            value = value.replace(secret, "[已隐藏凭证]")
        value = re.sub(r"(?i)Bearer\s+[A-Za-z0-9._~+/-]+", "Bearer [已隐藏凭证]", value)
        value = re.sub(r"https://(?:api\.day\.app|bark\.example\.invalid)/[A-Za-z0-9_-]{10,80}(?=/|\b)",
                       "[已隐藏推送地址]", value)
        return SECRET_PATTERN.sub(r"\1[已隐藏凭证]", value)
    if isinstance(value, dict):
        return {safe(str(k), secrets): safe(v, secrets) for k, v in value.items()
                if str(k).lower() not in ("device_key", "device_keys", "token", "password", "authorization")}
    if isinstance(value, list):
        return [safe(v, secrets) for v in value]
    return value if value is None or isinstance(value, (bool, int, float)) else None


def initialize(db):
    db.executescript("""
        CREATE TABLE IF NOT EXISTS bark_messages(
            id TEXT PRIMARY KEY, ts REAL NOT NULL, date TEXT NOT NULL,
            title TEXT NOT NULL, body TEXT NOT NULL, group_name TEXT NOT NULL,
            source TEXT NOT NULL, status TEXT NOT NULL, error TEXT,
            payload TEXT NOT NULL, import_key TEXT UNIQUE);
        CREATE INDEX IF NOT EXISTS bark_messages_date ON bark_messages(date,ts);
        CREATE TABLE IF NOT EXISTS bark_reviews(
            date TEXT PRIMARY KEY, text TEXT NOT NULL, updated REAL NOT NULL);
    """)


def archive(db, payload, *, secrets=(), ts=None, status="pending", import_key=None):
    ts = time.time() if ts is None else ts
    clean = safe({k: payload[k] for k in SAFE_FIELDS if k in payload}, secrets)
    if isinstance(payload.get("origin"), dict):
        clean["origin"] = safe(payload["origin"], secrets)
    origin = clean.get("origin", {})
    source = " · ".join(str(origin[k]) for k in ("host", "component") if origin.get(k)) or "来源未记录"
    identifier = str(uuid.uuid4())
    db.execute("INSERT OR IGNORE INTO bark_messages VALUES(?,?,?,?,?,?,?,?,?,?,?)", (
        identifier, ts, dt.datetime.fromtimestamp(ts, TZ).date().isoformat(),
        str(clean.get("title") or "Bark 提醒"), str(clean.get("body") or ""),
        str(clean.get("group") or "其他"), source, status, None,
        json.dumps(clean, ensure_ascii=False), import_key))
    return identifier


def forward(payload):
    """One fixed upstream request, no redirects, with a six-second wall budget."""
    deadline = time.monotonic() + 5.5
    conn = http.client.HTTPSConnection("api.day.app", timeout=5)
    try:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        conn.request("POST", "/push", body, {"Content-Type": "application/json; charset=utf-8"})
        if conn.sock:
            conn.sock.settimeout(max(.01, deadline-time.monotonic()))
        response = conn.getresponse()
        chunks, total = [], 0
        while total <= 65536:
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                return "unknown", "upstream_timeout", 504
            if conn.sock:
                conn.sock.settimeout(remaining)
            chunk = response.read1(min(4096, 65537-total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > 65536:
            return "unknown", "upstream_response_too_large", 502
        try:
            result = json.loads(b"".join(chunks))
        except (ValueError, UnicodeError):
            return "unknown", "upstream_invalid_response", 502
        if response.status == 200 and isinstance(result, dict) and result.get("code") == 200:
            return "sent", None, 200
        if isinstance(result, dict) and isinstance(result.get("code"), int):
            return "failed", "upstream_rejected", 502
        return "unknown", "upstream_unconfirmed", 502
    except (socket.timeout, TimeoutError):
        return "unknown", "upstream_timeout", 504
    except (OSError, http.client.HTTPException):
        # A disconnected response does not prove APNs rejected the request.
        return "unknown", "upstream_connection_error", 502
    finally:
        conn.close()


class ReviewInput(BaseModel):
    date: str
    text: str = Field(max_length=100000)


class PreferenceInput(BaseModel):
    enabled: bool = True
    hiddenCategories: list[str] = Field(default_factory=list, max_length=3)
    hiddenKeywords: list[str] = Field(default_factory=list, max_length=30)


def category(title, body, group, source, payload):
    """Topic/source classification; arbitrary mentions in a development report are not its topic."""
    try:
        origin = json.loads(payload).get("origin", {}) if isinstance(payload, str) else payload.get("origin", {})
        origin = origin if isinstance(origin, dict) else {}
    except (ValueError, AttributeError):
        origin = {}
    strong = "\n".join(str(value or "") for value in (title, group, source, origin.get("job")))
    # Old unknown-source notifications and business reports can identify their
    # subject in an opening heading; later discussion is not the report's topic.
    business = bool(TOPIC_PATTERNS["jd"].search(str(source or "")+" "+str(origin.get("job") or "")))
    unknown = not origin.get("component") and not origin.get("job") and source in ("", "来源未记录", None)
    lines = str(body or "").lstrip().splitlines()
    header = lines[0][:200] if lines and (business or unknown) else ""
    for identifier in ("ck", "sf", "jd"):
        if TOPIC_PATTERNS[identifier].search(strong+"\n"+header):
            return identifier
    return None


def keyword_pattern(word):
    left = r"(?<![a-z0-9])" if word and word[0].isascii() and word[0].isalnum() else ""
    right = r"(?![a-z0-9])" if word and word[-1].isascii() and word[-1].isalnum() else ""
    return re.compile(left+re.escape(word)+right, re.I)


def read_preferences(db):
    default = {"enabled": True, "hiddenCategories": ["jd", "sf", "ck"], "hiddenKeywords": []}
    row = db.execute("SELECT value FROM metadata WHERE key='bark.preferences'").fetchone()
    if not row:
        return default
    try:
        value = PreferenceInput.model_validate_json(row[0]).model_dump()
        if not set(value["hiddenCategories"]).issubset(CATEGORY_IDS) or any(not 1 <= len(w.strip()) <= 80 for w in value["hiddenKeywords"]):
            return default
        return value
    except (ValueError, TypeError):
        return default


def prepare_filter(db):
    prefs = read_preferences(db)
    patterns = [(word, keyword_pattern(word)) for word in prefs["hiddenKeywords"]]

    def reasons(title, body, group, source, payload):
        if not prefs["enabled"]:
            return []
        result = []
        if prefs["hiddenCategories"]:
            identifier = category(title, body, group, source, payload)
            if identifier in prefs["hiddenCategories"]:
                result.append(CATEGORY_LABELS[identifier])
        text = "\n".join(str(v or "") for v in (title, body, group, source))
        result.extend("关键词："+word for word, pattern in patterns if pattern.search(text))
        return result

    db.create_function("bark_ignored", 5, lambda *args: bool(reasons(*args)), deterministic=True)
    return prefs, reasons


def visibility_clause(visibility):
    if visibility not in ("focus", "all", "hidden"):
        raise HTTPException(422, "显示范围无效")
    return {"focus": "NOT "+IGNORED_SQL, "all": "1", "hidden": IGNORED_SQL}[visibility]


def install(app, cfg, database, templates, valid_date):
    with database() as db:
        initialize(db)
    secrets = (cfg.get("bark_key", ""), cfg["token"], cfg["proxy"])

    @app.get("/api/bark/index")
    def index(visibility: str = "focus"):
        clause = visibility_clause(visibility)
        with database() as db:
            prefs, _ = prepare_filter(db)
            full = {r["date"]: dict(r) for r in db.execute(
                "SELECT date,count(*) archiveTotal,sum("+IGNORED_SQL+") hidden FROM bark_messages GROUP BY date")}
            dates = {r["date"]: dict(r) for r in db.execute(
                "SELECT date,count(*) total,sum(status='sent') sent,sum(status='unknown') unknown "
                "FROM bark_messages WHERE "+clause+" GROUP BY date")}
            for date, row in full.items():
                dates.setdefault(date, {"date": date, "total": 0, "sent": 0, "unknown": 0}).update(row)
            for r in db.execute("SELECT date,updated FROM bark_reviews"):
                dates.setdefault(r["date"], {"date": r["date"], "total": 0, "sent": 0, "unknown": 0})
                dates[r["date"]]["reviewUpdated"] = r["updated"]
            return {"timezone": "Asia/Shanghai", "today": dt.datetime.now(TZ).date().isoformat(),
                    "days": sorted(dates.values(), key=lambda r: r["date"], reverse=True),
                    "total": sum(row["total"] for row in dates.values()),
                    "archiveTotal": sum(row["archiveTotal"] for row in full.values()),
                    "hiddenTotal": sum(row["hidden"] for row in full.values()),
                    "visibility": visibility,
                    "filters": {**prefs, "categories": FILTER_CATEGORIES},
                    "groups": [r[0] for r in db.execute("SELECT DISTINCT group_name FROM bark_messages ORDER BY group_name")],
                    "sources": [r[0] for r in db.execute("SELECT DISTINCT source FROM bark_messages ORDER BY source")],
                    "latest": db.execute("SELECT max(ts) FROM bark_messages").fetchone()[0]}

    @app.get("/api/bark/messages")
    def messages(date: str = "", q: str = "", group: str = "", source: str = "", offset: int = 0, limit: int = 50, visibility: str = "focus"):
        visible = visibility_clause(visibility)
        if date:
            valid_date(date)
        if len(q) > 200 or len(group) > 200 or len(source) > 300 or not 1 <= limit <= 100 or offset < 0:
            raise HTTPException(422, "筛选或分页参数无效")
        clauses, values = [], []
        for col, value in (("date", date), ("group_name", group), ("source", source)):
            if value:
                clauses.append(col+"=?"); values.append(value)
        if q:
            clauses.append("(instr(lower(title),lower(?))>0 OR instr(lower(body),lower(?))>0 OR instr(lower(source),lower(?))>0)")
            values += [q, q, q]
        where = " WHERE "+" AND ".join(clauses) if clauses else ""
        with database() as db:
            _, reasons = prepare_filter(db)
            summary = db.execute("SELECT count(*) matchedTotal,coalesce(sum("+IGNORED_SQL+"),0) hiddenTotal FROM bark_messages"+where, values).fetchone()
            filtered_where = where+(" AND " if where else " WHERE ")+visible
            total = db.execute("SELECT count(*) FROM bark_messages"+filtered_where, values).fetchone()[0]
            rows = db.execute("SELECT * FROM bark_messages"+filtered_where+" ORDER BY ts DESC,id DESC LIMIT ? OFFSET ?",
                              values+[limit, offset]).fetchall()
            items = []
            for row in rows:
                item = dict(row); item.pop("import_key", None)
                item["payload"] = json.loads(item["payload"])
                item["hiddenReasons"] = reasons(item["title"], item["body"], item["group_name"], item["source"], item["payload"])
                item["hidden"] = bool(item["hiddenReasons"])
                items.append(item)
            return {"items": items, "total": total, "offset": offset, "limit": limit,
                    "matchedTotal": summary["matchedTotal"], "hiddenTotal": summary["hiddenTotal"], "visibility": visibility,
                    "hasMore": offset+len(items) < total}

    @app.get("/api/bark/preferences")
    def preferences():
        with database() as db:
            return {**read_preferences(db), "categories": FILTER_CATEGORIES}

    @app.post("/api/bark/preferences")
    def save_preferences(value: PreferenceInput):
        if not set(value.hiddenCategories).issubset(CATEGORY_IDS):
            raise HTTPException(422, "隐藏类别无效")
        words = []
        for word in value.hiddenKeywords:
            word = word.strip()
            if not 1 <= len(word) <= 80:
                raise HTTPException(422, "每个关键词需为 1 至 80 个字")
            if word.casefold() not in {v.casefold() for v in words}:
                words.append(safe(word, secrets))
        prefs = {"enabled": value.enabled, "hiddenCategories": list(dict.fromkeys(value.hiddenCategories)), "hiddenKeywords": words}
        with database() as db:
            db.execute("INSERT INTO metadata VALUES('bark.preferences',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       (json.dumps(prefs, ensure_ascii=False),))
        return {"ok": True, **prefs, "categories": FILTER_CATEGORIES}

    @app.get("/api/bark/review")
    def review(date: str):
        valid_date(date)
        with database() as db:
            row = db.execute("SELECT * FROM bark_reviews WHERE date=?", (date,)).fetchone()
            return dict(row) if row else {"date": date, "text": "", "updated": None}

    @app.post("/api/bark/review")
    def save_review(value: ReviewInput):
        valid_date(value.date)
        now = time.time()
        with database() as db:
            db.execute("INSERT INTO bark_reviews VALUES(?,?,?) ON CONFLICT(date) DO UPDATE SET text=excluded.text,updated=excluded.updated",
                       (value.date, safe(value.text, secrets), now))
            return {"ok": True, "date": value.date, "updated": now}

    async def relay(request, key_from_path=None):
        if request.headers.get("host") != urlsplit(cfg.get("bark_url", "")).netloc or not cfg.get("bark_key"):
            raise HTTPException(404)
        if request.headers.get("content-type", "").split(";")[0].strip() != "application/json":
            return JSONResponse({"code": 415, "message": "JSON required"}, 415)
        raw = await request.body()
        if len(raw) > 65536:
            return JSONResponse({"code": 413, "message": "Request too large"}, 413)
        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeError):
            return JSONResponse({"code": 400, "message": "Invalid JSON"}, 400)
        if not isinstance(payload, dict) or "device_keys" in payload:
            return JSONResponse({"code": 400, "message": "Single device required"}, 400)
        key = key_from_path if key_from_path is not None else payload.get("device_key")
        if not isinstance(key, str) or not hmac.compare_digest(key, cfg["bark_key"]):
            return JSONResponse({"code": 401, "message": "Invalid device key"}, 401)
        if "device_key" in payload and payload["device_key"] != cfg["bark_key"]:
            return JSONResponse({"code": 401, "message": "Invalid device key"}, 401)
        if not isinstance(payload.get("body", ""), str) or not isinstance(payload.get("title", ""), str):
            return JSONResponse({"code": 422, "message": "Invalid message"}, 422)
        payload["device_key"] = cfg["bark_key"]
        with database() as db:
            identifier = archive(db, payload, secrets=secrets)
        try:
            status, error, http_status = await asyncio.wait_for(asyncio.to_thread(forward, payload), 6)
        except asyncio.TimeoutError:
            status, error, http_status = "unknown", "upstream_timeout", 504
        except Exception:
            status, error, http_status = "unknown", "upstream_unconfirmed", 502
        with database() as db:
            db.execute("UPDATE bark_messages SET status=?,error=? WHERE id=?", (status, error, identifier))
        return JSONResponse({"code": 200 if status == "sent" else http_status,
                             "message": "success" if status == "sent" else error,
                             "archive_id": identifier, "timestamp": int(time.time())}, http_status)

    @app.post("/push")
    async def push(request: Request):
        return await relay(request)

    # Qinglong's original sendNotify.js POSTs JSON to /<key>, not /push.
    @app.post("/{device_key}")
    async def key_push(device_key: str, request: Request):
        if not KEY_PATH.fullmatch(request.url.path):
            raise HTTPException(404)
        return await relay(request, device_key)
