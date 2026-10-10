"""Exercise the production app with isolated synthetic SQLite databases."""
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import api
from api import create_app


DAY = "2026-09-07"


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="notifhub-runtime-test-")
        self.addCleanup(self.directory.cleanup)
        self.settings = {}
        self.clients = {}
        self.generation = time.time() - 100
        for name in ("alice", "bob"):
            cfg = {
                "id": name,
                "url": f"https://{name}.example.test",
                "database": str(Path(self.directory.name) / f"{name}.sqlite"),
                "token": f"{name}-sync-secret-" + "a" * 40,
                "proxy": f"{name}-proxy-secret-" + "b" * 40,
            }
            self.settings[name] = cfg
            self.clients[name] = self.client(name)

    def client(self, name):
        cfg = self.settings[name]
        client = TestClient(create_app(cfg), base_url=cfg["url"])
        self.addCleanup(client.close)
        return client

    def headers(self, name="alice", write=False):
        cfg = self.settings[name]
        headers = {"X-Notifhub-Proxy": cfg["proxy"]}
        if write:
            headers.update({"Origin": cfg["url"], "X-Notifhub-Request": "1"})
        return headers

    def snapshot(self, name="alice", generation=None, dedup="todo-original"):
        agenda = {
            "id": 11, "title": f"{name} follow up", "status": "open",
            "kind": "todo", "created_at": self.generation - 20,
            "dedup_key": dedup, "src_date": DAY,
        }
        feed_agenda = {
            "id": 11, "title": agenda["title"], "status": "open",
            "kind": "todo", "srcDate": DAY,
        }
        return {
            "version": 1, "instance": name,
            "generatedAt": self.generation if generation is None else generation,
            "timezone": "Asia/Shanghai",
            "tables": {
                "events": [{"id": 1, "ts": self.generation - 30,
                            "title": f"{name} notification", "body": "synthetic body"}],
                "notes": [{"id": 1, "ts": self.generation - 25,
                           "text": f"{name} local note"}],
                "agenda": [agenda],
                "summaries": [{"date": DAY, "headline": "A synthetic day",
                               "text": "**Progress**", "generated_at": self.generation}],
            },
            "feeds": {
                "index": {"generatedAt": self.generation, "days": [{
                    "date": DAY, "total": 1, "merged": 1, "headline": "A synthetic day",
                    "agendaOpen": 1, "whos": [name],
                }]},
                DAY: {
                    "date": DAY, "total": 1, "muted": 0, "notes": 1,
                    "items": [{"ts": self.generation - 30, "endTs": self.generation - 30,
                               "app": "邮件", "who": name, "lines": [f"{name} body"],
                               "missed": False, "redacted": False}],
                    "agenda": [feed_agenda],
                    "summary": {"headline": "A synthetic day", "text": "**Progress**",
                                "generatedAt": self.generation},
                    "apps": [["邮件", "1"]], "whos": [[name, "1"]], "byHour": [0] * 24,
                },
            },
        }

    def sync(self, snapshot=None, name="alice", client=None, token=None):
        return (client or self.clients[name]).post(
            "/api/sync",
            headers={"Authorization": "Bearer " + (token or self.settings[name]["token"])},
            json=snapshot or self.snapshot(name),
        )

    def seed(self, name="alice"):
        response = self.sync(name=name)
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def get_day(self, name="alice", client=None):
        response = (client or self.clients[name]).get(
            f"/api/day/{DAY}", headers=self.headers(name))
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def save_note(self, text="Cloud note", key="note-request-0001", name="alice", client=None):
        return (client or self.clients[name]).post(
            "/api/notes", headers=self.headers(name, write=True),
            json={"text": text, "date": DAY, "idempotencyKey": key},
        )

    def set_done(self, name="alice", client=None):
        response = (client or self.clients[name]).patch(
            "/api/agenda/11", headers=self.headers(name, write=True), json={"status": "done"})
        self.assertEqual(response.status_code, 200, response.text)

    def test_index_carries_ui_overrides_and_a_broken_file_never_breaks_it(self):
        self.seed()
        empty = {"copy": {}, "vocab": {}, "order": [], "limits": {}}
        native = {"Authorization": "Bearer " + self.settings["alice"]["token"]}

        def index(path="/api/index", headers=None):
            response = self.clients["alice"].get(path, headers=headers or self.headers())
            self.assertEqual(response.status_code, 200, response.text)
            body = response.json()
            self.assertEqual(body["days"][0]["date"], DAY)
            self.assertEqual(body["timezone"], "Asia/Shanghai")
            return body["ui"]

        # The committed file overrides nothing: every client keeps its built-in copy.
        self.assertEqual(json.loads((api.ROOT / "ui.json").read_text(encoding="utf-8")), empty)
        self.assertEqual(index(), empty)
        path = Path(self.directory.name) / "ui.json"
        with patch.object(api, "UI", path):
            self.assertEqual(index(), empty)                      # missing file
            path.write_text(json.dumps({"copy": {"today.group.overdue": "拖过了"}}), encoding="utf-8")
            for route, headers in (("/api/index", None), ("/index.json", None),
                                   ("/native/api/index", native)):
                self.assertEqual(index(route, headers),
                                 {**empty, "copy": {"today.group.overdue": "拖过了"}})
            path.write_text(json.dumps({"copy": {"today.empty": "清空了"}}), encoding="utf-8")
            self.assertEqual(index()["copy"], {"today.empty": "清空了"})   # re-read, no restart
            for broken in ("{broken", "[1, 2]", '"text"', "\xff\xfe",
                           '{"copy": "text", "vocab": [], "order": {}, "limits": 3}'):
                path.write_bytes(broken.encode("latin-1"))
                self.assertEqual(index(), empty, broken)

    def test_native_authentication_and_endpoint_scope(self):
        self.seed()
        client = self.clients["alice"]
        path = "/native/api/index"
        for headers in ({}, self.headers(), {"Authorization": "Bearer wrong"},
                        {"Authorization": "Bearer " + self.settings["bob"]["token"]}):
            self.assertEqual(client.get(path, headers=headers).status_code, 401)
        headers = {"Authorization": "Bearer " + self.settings["alice"]["token"]}
        for route in ("index", "day/" + DAY, "open"):
            response = client.get("/native/api/" + route, headers=headers)
            self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(client.get(path, headers={**headers, "Host": "bob.example.test"}).status_code, 404)
        for method, route in (("post", "sync"), ("get", "health"), ("post", "index"),
                              ("get", "agenda-queue"), ("get", "notes")):
            self.assertEqual(getattr(client, method)("/native/api/" + route,
                                                    headers=headers).status_code, 404)
        self.assertEqual(client.get("/api/index", headers=headers).status_code, 401)

    def test_native_writes_reuse_persistence_without_weakening_browser_csrf(self):
        self.seed()
        client = self.clients["alice"]
        bearer = {"Authorization": "Bearer " + self.settings["alice"]["token"]}
        body = {"text": "Native saved", "date": DAY, "idempotencyKey": "native-note-001"}
        self.assertEqual(client.post("/native/api/notes", headers=bearer, json=body).status_code, 403)
        headers = {**bearer, "X-Notifhub-Request": "1"}
        response = client.post("/native/api/notes", headers=headers, json=body)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(client.patch("/native/api/agenda/11", headers=headers,
                                      json={"status": "done"}).status_code, 200)
        restarted = self.client("alice")
        day = self.get_day(client=restarted)
        self.assertEqual(day["cloudNotes"][0]["text"], "Native saved")
        self.assertEqual(day["agenda"][0]["status"], "done")
        browser = {**self.headers(), "X-Notifhub-Request": "1"}
        for extra in ({}, {"Origin": "https://evil.example"}):
            self.assertEqual(client.post("/api/notes", headers={**browser, **extra},
                                         json=body).status_code, 403)
        self.assertEqual(client.post("/native/api/notes", headers={**self.headers(),
                         "X-Notifhub-Request": "1"}, json=body).status_code, 401)

    def test_complete_import_counts_and_source_records(self):
        for name in self.clients:
            body = self.seed(name)
            self.assertEqual(body["counts"], {"events": 1, "notes": 1, "agenda": 1, "summaries": 1})
            health = self.clients[name].get("/api/health", headers=self.headers(name)).json()
            self.assertTrue(health["ok"])
            self.assertEqual(health["instance"], name)
            self.assertEqual(health["records"], body["counts"])
            self.assertGreater(health["lastSync"], 0)
            day = self.get_day(name)
            self.assertEqual(day["items"][0]["lines"], [f"{name} body"])
            with sqlite3.connect(self.settings[name]["database"]) as db:
                event = json.loads(db.execute(
                    "SELECT payload FROM source_records WHERE kind='events' AND key='1'"
                ).fetchone()[0])
            self.assertEqual(event["title"], f"{name} notification")
        self.assertNotEqual(self.settings["alice"]["database"], self.settings["bob"]["database"])

    def test_ai_work_time_passes_through_sync(self):
        snapshot = self.snapshot()
        work = {"wallMinutes": 95, "idleMinutes": 15, "prompts": 3, "rows": [
            {"project": "Apps/notifhub", "minutes": 80, "prompts": 3,
             "first": self.generation - 3600, "last": self.generation - 60,
             "tools": [["Claude Code", "50"], ["Codex", "30"]]}]}
        snapshot["feeds"][DAY].update({"aiInputs": 3, "work": work})
        snapshot["feeds"]["index"]["days"][0]["aiMinutes"] = 95
        self.assertEqual(self.sync(snapshot).status_code, 200)
        day = self.get_day()
        self.assertEqual(day["work"], work)
        self.assertEqual(day["aiInputs"], 3)
        index = self.clients["alice"].get("/api/index", headers=self.headers()).json()
        self.assertEqual(index["days"][0]["aiMinutes"], 95)
        page = self.clients["alice"].get("/", headers=self.headers()).text
        self.assertIn('id="work-section"', page)
        self.assertIn("renderWork(day.work)", page)

    def test_note_and_agenda_survive_restart_and_resync(self):
        self.seed()
        response = self.save_note()
        self.assertEqual(response.status_code, 200, response.text)
        self.set_done()
        restarted = self.client("alice")
        day = self.get_day(client=restarted)
        self.assertEqual([n["text"] for n in day["cloudNotes"]], ["Cloud note"])
        self.assertEqual(day["agenda"][0]["status"], "done")
        response = self.sync(self.snapshot(generation=self.generation + 1), client=restarted)
        self.assertEqual(response.status_code, 200, response.text)
        day = self.get_day(client=restarted)
        self.assertEqual([n["text"] for n in day["cloudNotes"]], ["Cloud note"])
        self.assertEqual(day["agenda"][0]["status"], "done")
        self.assertEqual(restarted.get("/api/open", headers=self.headers()).json()["items"], [])
        self.seed("bob")
        self.assertEqual(self.get_day("bob")["cloudNotes"], [])
        self.assertEqual(self.get_day("bob")["agenda"][0]["status"], "open")

    def test_cross_instance_credentials_host_and_snapshot_rejected(self):
        self.seed("alice")
        self.seed("bob")
        bob = self.clients["bob"]
        self.assertEqual(bob.get("/api/index", headers=self.headers("alice")).status_code, 401)
        self.assertEqual(self.sync(name="bob", token=self.settings["alice"]["token"]).status_code, 401)
        wrong_host = {**self.headers(), "Host": "bob.example.test"}
        self.assertEqual(self.clients["alice"].get("/api/index", headers=wrong_host).status_code, 404)
        response = self.sync(self.snapshot("alice"), name="bob")
        self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual(self.get_day("bob")["items"][0]["who"], "bob")

    def test_user_writes_require_origin_and_request_header(self):
        self.seed()
        body = {"text": "must not save", "date": DAY, "idempotencyKey": "missing-origin"}
        for headers in [
            self.headers(),
            {**self.headers(), "X-Notifhub-Request": "1"},
            {**self.headers(), "Origin": self.settings["alice"]["url"]},
            {**self.headers(write=True), "Origin": self.settings["bob"]["url"]},
        ]:
            response = self.clients["alice"].post("/api/notes", headers=headers, json=body)
            self.assertEqual(response.status_code, 403, response.text)
        response = self.clients["alice"].patch(
            "/api/agenda/11", headers=self.headers(), json={"status": "done"})
        self.assertEqual(response.status_code, 403, response.text)
        self.assertEqual(self.get_day()["cloudNotes"], [])
        self.assertEqual(self.get_day()["agenda"][0]["status"], "open")

    def test_invalid_snapshot_is_atomic(self):
        self.seed()
        before = self.get_day()
        invalid = self.snapshot(generation=self.generation + 1)
        del invalid["tables"]["agenda"][0]["title"]
        invalid["tables"]["events"][0]["body"] = "must not replace source"
        response = self.sync(invalid)
        self.assertEqual(response.status_code, 422, response.text)
        self.assertEqual(self.get_day(), before)
        with sqlite3.connect(self.settings["alice"]["database"]) as db:
            event = json.loads(db.execute(
                "SELECT payload FROM source_records WHERE kind='events' AND key='1'"
            ).fetchone()[0])
        self.assertEqual(event["body"], "synthetic body")

    def test_old_generation_and_same_generation_changed_payload_rejected(self):
        self.seed()
        self.assertEqual(self.sync(self.snapshot(generation=self.generation - 1)).status_code, 409)
        altered = self.snapshot()
        altered["tables"]["events"][0]["body"] = "different generation payload"
        self.assertEqual(self.sync(altered).status_code, 409)
        identical = self.sync(self.snapshot())
        self.assertEqual(identical.status_code, 200, identical.text)

    def test_reused_agenda_id_does_not_inherit_previous_status(self):
        self.seed()
        self.set_done()
        replacement = self.snapshot(generation=self.generation + 1, dedup="brand-new-todo")
        replacement["tables"]["agenda"][0]["title"] = "A distinct task"
        replacement["feeds"][DAY]["agenda"][0]["title"] = "A distinct task"
        response = self.sync(replacement)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.get_day()["agenda"][0]["status"], "open")
        opened = self.clients["alice"].get("/api/open", headers=self.headers()).json()["items"]
        self.assertEqual([a["title"] for a in opened], ["A distinct task"])

    def test_cloud_note_requests_are_idempotent_and_conflicts_rejected(self):
        self.seed()
        first, repeated = self.save_note(), self.save_note()
        self.assertEqual(first.status_code, 200, first.text)
        self.assertEqual(repeated.status_code, 200, repeated.text)
        self.assertEqual(first.json()["id"], repeated.json()["id"])
        self.assertEqual(len(self.get_day()["cloudNotes"]), 1)
        conflict = self.save_note(text="Different text under same key")
        self.assertEqual(conflict.status_code, 409, conflict.text)
        self.assertEqual(self.get_day()["cloudNotes"][0]["text"], "Cloud note")

    def test_markdown_raw_html_and_dangerous_links_are_not_active(self):
        snapshot = self.snapshot()
        snapshot["feeds"][DAY]["summary"]["text"] = (
            '# Heading\n\n<script>alert("x")</script>\n\n'
            '<img src=x onerror=alert(1)>\n\n'
            '[bad](javascript:alert%281%29)\n\n[good](https://example.com)\n\n**bold**'
        )
        response = self.sync(snapshot)
        self.assertEqual(response.status_code, 200, response.text)
        html = self.get_day()["summary"]["html"]
        self.assertNotIn("<script", html.lower())
        self.assertNotIn("<img", html.lower())
        self.assertNotIn('href="javascript:', html.lower())
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("<strong>bold</strong>", html)
        self.assertIn('href="https://example.com"', html)


if __name__ == "__main__":
    unittest.main(verbosity=2)
