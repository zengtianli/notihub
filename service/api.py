"""One process, one database, one domain. No tenant identifier is accepted from clients."""
import contextlib
import datetime
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sqlite3
import time
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from markdown_it import MarkdownIt
from pydantic import BaseModel, Field
import bark

ROOT = Path(__file__).resolve().parent
TABLES = ("events", "notes", "agenda", "summaries")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
markdown = MarkdownIt("commonmark", {"html": False}).enable("table")
# App 说明文字的覆盖项（分组名、空状态、出错建议）；只写要改的键，缺的用 App 自带的。
# 每次请求重读：改完文件即生效，不用重启，也不用发版。
UI = ROOT / "ui.json"
UI_SHAPE = {"copy": dict, "vocab": dict, "order": list, "limits": dict}


def ui():
    """ui.json 的四段；文件缺失、写坏或某段类型不对时给空的，App 全用自带文案，接口不因此出错。"""
    try:
        doc = json.loads(UI.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        doc = {}
    doc = doc if isinstance(doc, dict) else {}
    return {key: doc[key] if isinstance(doc.get(key), kind) else kind()
            for key, kind in UI_SHAPE.items()}


class NoteInput(BaseModel):
    text: str = Field(min_length=1, max_length=20000)
    date: str
    idempotencyKey: str = Field(min_length=8, max_length=100)


class StatusInput(BaseModel):
    status: str


def valid_date(value):
    if not DATE.fullmatch(value):
        raise HTTPException(422, "日期格式应为 YYYY-MM-DD")
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        raise HTTPException(422, "日期无效")
    return value


def create_app(settings=None):
    cfg = settings or {
        "id": os.environ["NOTIFHUB_ID"],
        "url": os.environ["NOTIFHUB_URL"],
        "database": os.environ["NOTIFHUB_DATABASE"],
        "token": Path(os.environ["NOTIFHUB_SYNC_TOKEN_FILE"]).read_text().strip(),
        "proxy": Path(os.environ["NOTIFHUB_PROXY_TOKEN_FILE"]).read_text().strip(),
    }
    cfg = dict(cfg)
    if settings is None:
        cfg["bark_url"] = os.environ.get("NOTIFHUB_BARK_URL", "")
        key_file = os.environ.get("NOTIFHUB_BARK_KEY_FILE", "")
        cfg["bark_key"] = Path(key_file).read_text().strip() if key_file else ""
    bark_url = cfg.get("bark_url", "")
    bark_host = ""
    if bark_url:
        parsed_bark = urlsplit(bark_url)
        if (parsed_bark.scheme != "https" or not parsed_bark.hostname or parsed_bark.path
                or parsed_bark.username or parsed_bark.password or parsed_bark.query or parsed_bark.fragment
                or len(cfg.get("bark_key", "")) < 10):
            raise ValueError("Invalid Bark relay configuration")
        bark_host = parsed_bark.netloc
    parsed = urlsplit(cfg["url"])
    if (len(cfg["token"]) < 32 or len(cfg["proxy"]) < 32 or cfg["token"] == cfg["proxy"]
            or parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.path or parsed.query or parsed.fragment):
        raise ValueError("Missing strong per-instance secrets")
    host = urlsplit(cfg["url"]).netloc
    path = Path(cfg["database"])
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    @contextlib.contextmanager
    def database():
        db = sqlite3.connect(path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    with database() as db:
        db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS source_records(kind TEXT,key TEXT,payload TEXT NOT NULL,
            PRIMARY KEY(kind,key));
        CREATE TABLE IF NOT EXISTS feeds(key TEXT PRIMARY KEY,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS cloud_notes(id INTEGER PRIMARY KEY,request_key TEXT UNIQUE,
            date TEXT NOT NULL,ts REAL NOT NULL,text TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS agenda_overrides(id INTEGER PRIMARY KEY,status TEXT NOT NULL,
            updated REAL NOT NULL,identity TEXT NOT NULL);
        """)
    path.chmod(0o600)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    templates = Jinja2Templates(directory=str(ROOT/"templates"))

    @app.middleware("http")
    async def security(request, call_next):
        # Header is overwritten by nginx, never forwarded from an external caller.
        request_host = request.headers.get("host")
        on_bark = bool(bark_host and request_host == bark_host)
        ingress = on_bark and request.method == "POST" and (request.url.path == "/push" or bark.KEY_PATH.fullmatch(request.url.path))
        if request_host != host and not on_bark:
            return JSONResponse({"detail": "Unknown domain"}, 404)
        if on_bark and not (request.url.path in ("/", "/index.html") or request.url.path.startswith("/api/bark/") or ingress):
            return JSONResponse({"detail": "Unknown Bark endpoint"}, 404)
        native = request.url.path.startswith("/native/")
        if native:
            route = request.url.path[len("/native"):]
            allowed = ((request.method == "GET" and
                        (route in ("/api/index", "/api/open") or
                         re.fullmatch(r"/api/day/\d{4}-\d{2}-\d{2}", route))) or
                       (request.method == "POST" and route == "/api/notes") or
                       (request.method == "PATCH" and
                        re.fullmatch(r"/api/agenda/[0-9]+", route)))
            if not allowed:
                return JSONResponse({"detail": "Unknown native endpoint"}, 404)
        if ingress:
            pass  # Write-only relay independently verifies the configured device key.
        elif native or request.url.path == "/api/sync":
            expected = "Bearer "+cfg["token"]
            if not hmac.compare_digest(request.headers.get("authorization", ""), expected):
                return JSONResponse({"detail": "Sync authentication required"}, 401)
        elif not hmac.compare_digest(request.headers.get("x-notifhub-proxy", ""), cfg["proxy"]):
            return JSONResponse({"detail": "Website authentication required"}, 401)
        if request.method not in ("GET", "HEAD") and request.url.path != "/api/sync" and not ingress:
            if ((not native and request.headers.get("origin") != (bark_url if on_bark else cfg["url"]))
                    or request.headers.get("x-notifhub-request") != "1"
                    or request.headers.get("content-type", "").split(";")[0] != "application/json"):
                return JSONResponse({"detail": "请从本站页面操作"}, 403)
        if native:
            request.scope["path"] = route
            request.scope["raw_path"] = route.encode("ascii")
        response = await call_next(request)
        response.headers["Cache-Control"] = "private, no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-Notifhub-Runtime"] = "sqlite-v1"
        return response

    def feed(db, key, default=None):
        row = db.execute("SELECT payload FROM feeds WHERE key=?", (key,)).fetchone()
        if row:
            return json.loads(row[0])
        if default is not None:
            return default
        raise HTTPException(404, "这一天还没有同步")

    def overrides(db, items):
        states = {r["id"]: r["status"] for r in db.execute("SELECT * FROM agenda_overrides")}
        return [{**a, "status": states.get(a["id"], a["status"])} for a in items]

    def agenda_identity(a):
        # Numeric IDs can be reused after local LLM recalculation deletes a row.
        return a.get("dedup_key") or hashlib.sha256(json.dumps(
            [a["id"], a.get("created_at"), a["title"], a.get("due_ts")],
            ensure_ascii=False).encode()).hexdigest()

    def all_agenda(db):
        records = [json.loads(r[0]) for r in db.execute(
            "SELECT payload FROM source_records WHERE kind='agenda'")]
        return overrides(db, [{
            "id": a["id"], "title": a["title"], "kind": a.get("kind", "todo"),
            "status": a.get("status", "open"), "dueTS": a.get("due_ts"),
            "srcDate": a.get("src_date"), "note": a.get("note"),
            "endTS": a.get("end_ts"), "allDay": bool(a.get("all_day", False)),
            "who": a.get("who"), "evidence": a.get("evidence"),
            "source": a.get("source", "manual"),
            "pushed": a.get("pushed_at") is not None
        } for a in records])

    @app.get("/api/health")
    def health():
        with database() as db:
            counts = dict(db.execute("SELECT kind,count(*) FROM source_records GROUP BY kind"))
            meta = dict(db.execute("SELECT key,value FROM metadata"))
            return {"ok": True, "instance": cfg["id"], "records": counts,
                    "lastSync": float(meta.get("lastSync", "0")),
                    "cloudNotes": db.execute("SELECT count(*) FROM cloud_notes").fetchone()[0]}

    @app.get("/api/index")
    @app.get("/index.json")
    def index():
        with database() as db:
            result = feed(db, "index", {"generatedAt": 0, "days": []})
            meta = dict(db.execute("SELECT key,value FROM metadata"))
            result["lastSync"] = float(meta.get("lastSync", "0"))
            result["timezone"] = meta.get("timezone", "UTC")
            known = {d["date"] for d in result["days"]}
            for row in db.execute("SELECT date,count(*) n FROM cloud_notes GROUP BY date"):
                if row["date"] not in known:
                    result["days"].append({"date": row["date"], "total": 0, "merged": row["n"],
                                          "headline": "", "agendaOpen": 0, "whos": ["随手记"]})
            counts = {}
            for a in all_agenda(db):
                if a["status"] == "open":
                    counts[a["srcDate"]] = counts.get(a["srcDate"], 0)+1
            for d in result["days"]:
                d["agendaOpen"] = counts.get(d["date"], 0)
            result["days"].sort(key=lambda d: d["date"], reverse=True)
            result["ui"] = ui()
            return result

    @app.get("/api/day/{date}")
    def day(date: str):
        valid_date(date)
        with database() as db:
            notes = [dict(r) for r in db.execute(
                "SELECT id,text,ts,date FROM cloud_notes WHERE date=? ORDER BY ts", (date,))]
            blank = {"date": date, "total": 0, "muted": 0, "notes": 0, "items": [],
                     "agenda": [], "apps": [], "whos": [], "byHour": [0]*24}
            result = feed(db, date, blank if notes else None)
            result["cloudNotes"] = notes
            result["agenda"] = overrides(db, result.get("agenda", []))
            if result.get("summary"):
                result["summary"]["html"] = markdown.render(result["summary"]["text"])
            return result

    @app.get("/api/open")
    @app.get("/open.json")
    def opened():
        with database() as db:
            items = [a for a in all_agenda(db) if a["status"] == "open"]
            items.sort(key=lambda a: (a["dueTS"] is None, a["dueTS"] or 0, a["id"]))
            return {"generatedAt": time.time(), "items": items}

    @app.post("/api/notes")
    def add_note(value: NoteInput):
        valid_date(value.date)
        text = value.text.strip()
        if not text:
            raise HTTPException(422, "请输入内容")
        with database() as db:
            db.execute("INSERT INTO cloud_notes(request_key,date,ts,text) VALUES(?,?,?,?) "
                       "ON CONFLICT(request_key) DO NOTHING",
                       (value.idempotencyKey, value.date, time.time(), text))
            row = db.execute("SELECT * FROM cloud_notes WHERE request_key=?",
                             (value.idempotencyKey,)).fetchone()
            if row["text"] != text or row["date"] != value.date:
                raise HTTPException(409, "重复请求的内容不一致")
            return dict(row)

    @app.patch("/api/agenda/{item_id}")
    def change_status(item_id: int, value: StatusInput):
        if value.status not in ("open", "done", "dropped"):
            raise HTTPException(422, "状态无效")
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT payload FROM source_records WHERE kind='agenda' AND key=?",
                             (str(item_id),)).fetchone()
            if not row:
                raise HTTPException(404, "待办不存在")
            identity = agenda_identity(json.loads(row[0]))
            db.execute("INSERT INTO agenda_overrides VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE "
                       "SET status=excluded.status,updated=excluded.updated,identity=excluded.identity",
                       (item_id, value.status, time.time(), identity))
            return {"id": item_id, "status": value.status}

    @app.post("/api/sync")
    async def sync(request: Request):
        # Stream bounded body, including chunked requests (no dependence on Content-Length).
        chunks, length = [], 0
        async for chunk in request.stream():
            length += len(chunk)
            if length > 64*1024*1024:
                raise HTTPException(413, "同步数据超过 64MB")
            chunks.append(chunk)
        try:
            value = json.loads(b"".join(chunks))
            # The parsed snapshot owns its strings now; retaining request chunks
            # through validation and SQL insertion duplicates the entire payload.
            chunks.clear()
            if value["version"] != 1 or value["instance"] != cfg["id"]:
                raise ValueError("实例或协议不匹配")
            tables, feeds = value["tables"], value["feeds"]
            if set(tables) != set(TABLES) or "index" not in feeds:
                raise ValueError("同步必须包含完整数据")
            ZoneInfo(value["timezone"])
            for name in TABLES:
                if not isinstance(tables[name], list):
                    raise ValueError("数据表无效")
                keys = [str(r["date"] if name == "summaries" else r["id"]) for r in tables[name]]
                if len(set(keys)) != len(keys):
                    raise ValueError("重复数据主键")
            for a in tables["agenda"]:
                if (not isinstance(a["title"], str) or a["status"] not in ("open", "done", "dropped")
                        or not isinstance(a["id"], int)):
                    raise ValueError("待办字段无效")
            if len(tables["events"]) == 0:
                raise ValueError("拒绝空通知库覆盖")
            if not isinstance(feeds["index"]["days"], list):
                raise ValueError("日期索引无效")
            for d in feeds["index"]["days"]:
                valid_date(d["date"])
                f = feeds[d["date"]]
                if f["date"] != d["date"] or not isinstance(f["items"], list):
                    raise ValueError("日期数据缺失")
                for a in f.get("agenda", []):
                    if not isinstance(a["title"], str) or a["status"] not in ("open", "done", "dropped"):
                        raise ValueError("日期待办字段无效")
                for item in f["items"]:
                    if not isinstance(item["lines"], list) or not all(isinstance(s, str) for s in item["lines"]):
                        raise ValueError("时间线字段无效")
                    for key in ("ts", "app", "who"):
                        if key not in item:
                            raise ValueError("时间线字段缺失")
                if f.get("summary") and not isinstance(f["summary"]["text"], str):
                    raise ValueError("总结字段无效")
            stamp = float(value["generatedAt"])
            if not 0 < stamp <= time.time()+300:
                raise ValueError("同步时间无效")
        except (ValueError, TypeError, KeyError) as error:
            raise HTTPException(422, str(error))
        digest = hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT value FROM metadata WHERE key='generation'").fetchone()
            if previous and stamp < float(previous[0]):
                raise HTTPException(409, "拒绝旧快照覆盖新数据")
            old_hash = db.execute("SELECT value FROM metadata WHERE key='digest'").fetchone()
            if previous and stamp == float(previous[0]) and old_hash and old_hash[0] != digest:
                raise HTTPException(409, "同一代快照内容发生冲突")
            identities = {a["id"]: agenda_identity(a) for a in tables["agenda"]}
            for row in db.execute("SELECT id,identity FROM agenda_overrides").fetchall():
                if identities.get(row["id"]) != row["identity"]:
                    db.execute("DELETE FROM agenda_overrides WHERE id=?", (row["id"],))
            # A coherent transaction; web-owned tables never participate in replacement.
            db.execute("DELETE FROM source_records")
            for name in TABLES:
                db.executemany("INSERT INTO source_records VALUES(?,?,?)",
                    ((name, str(r["date"] if name == "summaries" else r["id"]),
                      json.dumps(r, ensure_ascii=False)) for r in tables[name]))
            db.execute("DELETE FROM feeds")
            db.executemany("INSERT INTO feeds VALUES(?,?)",
                           ((k, json.dumps(v, ensure_ascii=False)) for k, v in feeds.items()))
            for k, v in {"generation": stamp, "lastSync": time.time(), "digest": digest,
                         "timezone": value["timezone"]}.items():
                db.execute("INSERT OR REPLACE INTO metadata VALUES(?,?)", (k, str(v)))
        return {"ok": True, "instance": cfg["id"],
                "counts": {k: len(v) for k, v in tables.items()}}

    @app.get("/")
    @app.get("/index.html")
    def home(request: Request):
        return templates.TemplateResponse(request=request,
            name="bark.html" if bark_host and request.headers.get("host") == bark_host else "app.html",
            context={"instance": cfg["id"], "site_url": cfg["url"]})

    @app.get("/remain.html")
    def remain():
        return RedirectResponse("/?view=open", 302)

    @app.get("/{filename}")
    def legacy(filename: str):
        if filename.endswith(".json"):
            return day(filename[:-5])
        if filename.endswith(".html"):
            return RedirectResponse("/?date="+valid_date(filename[:-5]), 302)
        raise HTTPException(404)

    if bark_host:
        bark.install(app, cfg, database, templates, valid_date)
    return app
