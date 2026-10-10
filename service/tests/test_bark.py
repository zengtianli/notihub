import datetime as dt
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from api import create_app
import bark


class BarkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.cfg = dict(id="personal", url="https://day.example.test",
                        database=str(Path(self.tmp.name)/"cloud.sqlite"),
                        token="sync-"+"a"*40, proxy="proxy-"+"b"*40,
                        bark_url="https://bark.example.test", bark_key="test-device-0123456789")
        self.client = TestClient(create_app(self.cfg), base_url=self.cfg["bark_url"])
        self.addCleanup(self.client.close)
        self.read = {"X-Notifhub-Proxy": self.cfg["proxy"]}
        self.write = {**self.read, "Origin": self.cfg["bark_url"], "X-Notifhub-Request": "1"}

    def push(self, body="完整\n正文\n\n第二段", path="/push", extra=None):
        payload = dict(title="工作结果", body=body, group="任务", device_key=self.cfg["bark_key"],
                       origin={"host": "DemoHost", "component": "Codex", "run_id": "synthetic-run"})
        payload.update(extra or {})
        return self.client.post(path, json=payload)

    def test_wrong_key_never_forwards_or_archives(self):
        with patch("bark.forward") as forward:
            self.assertEqual(self.push(extra={"device_key": "wrong"}).status_code, 401)
            self.assertEqual(self.push(extra={"device_keys": [self.cfg["bark_key"]]}).status_code, 400)
            forward.assert_not_called()
        self.assertEqual(self.client.get("/api/bark/index", headers=self.read).json()["total"], 0)

    def test_long_text_preserved_and_credentials_removed(self):
        body = "第一行\n\n"+"完整细节 "*1800
        with patch("bark.forward", return_value=("sent", None, 200)) as forward:
            result = self.push(body)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json()["code"], 200)
        forward.assert_called_once()
        row = self.client.get("/api/bark/messages", headers=self.read).json()["items"][0]
        self.assertEqual(row["body"], body)
        self.assertEqual(row["payload"]["origin"]["run_id"], "synthetic-run")
        self.assertNotIn("device_key", row["payload"])
        self.assertEqual(row["status"], "sent")
        with patch("bark.forward", return_value=("sent", None, 200)):
            self.push(self.cfg["bark_key"]+"\nAuthorization: Bearer private-token",
                      extra={"url": "https://api.day.app/"+self.cfg["bark_key"],
                             "origin": {"host": self.cfg["proxy"], "token": self.cfg["token"]}})
        with sqlite3.connect(self.cfg["database"]) as db:
            stored = json.dumps(db.execute("SELECT * FROM bark_messages").fetchall())
        for secret in (self.cfg["bark_key"], self.cfg["proxy"], self.cfg["token"], "private-token"):
            self.assertNotIn(secret, stored)

    def test_original_qinglong_key_url(self):
        with patch("bark.forward", return_value=("sent", None, 200)) as forward:
            result = self.client.post("/"+self.cfg["bark_key"], json={"title": "京豆", "body": "完整报告"})
        self.assertEqual(result.status_code, 200)
        self.assertEqual(forward.call_args.args[0]["device_key"], self.cfg["bark_key"])
        with patch("bark.forward") as forward:
            self.assertEqual(self.client.post("/unregistered-key-1234", json={"body": "bad"}).status_code, 401)
            forward.assert_not_called()

    def test_no_history_without_website_auth(self):
        for path in ("/", "/api/bark/index", "/api/bark/messages", "/api/bark/review?date=2026-10-08"):
            self.assertEqual(self.client.get(path).status_code, 401)
        self.assertEqual(self.client.get("/api/index", headers=self.read).status_code, 404)
        self.assertEqual(self.client.post("/api/sync", headers={"Authorization": "Bearer "+self.cfg["token"]}, json={}).status_code, 404)
        self.assertEqual(self.client.get("/native/api/index", headers={"Authorization": "Bearer "+self.cfg["token"]}).status_code, 404)

    def test_review_origin_and_persistence(self):
        value = {"date": "2026-10-08", "text": "做完了什么\n\n明天的改进"}
        self.assertEqual(self.client.post("/api/bark/review", headers=self.read, json=value).status_code, 403)
        self.assertEqual(self.client.post("/api/bark/review", headers={**self.write,"Origin":"https://evil.test"}, json=value).status_code, 403)
        self.assertEqual(self.client.post("/api/bark/review", headers=self.write, json=value).status_code, 200)
        with TestClient(create_app(self.cfg), base_url=self.cfg["bark_url"]) as restarted:
            self.assertEqual(restarted.get("/api/bark/review?date=2026-10-08", headers=self.read).json()["text"], value["text"])

    def test_failure_and_unknown_are_archived_without_retry(self):
        for outcome in (("failed", "upstream_rejected", 502), ("unknown", "upstream_timeout", 504)):
            with patch("bark.forward", return_value=outcome) as forward:
                response = self.push(outcome[0])
                self.assertEqual(response.status_code, outcome[2]); forward.assert_called_once()
        items = self.client.get("/api/bark/messages", headers=self.read).json()["items"]
        self.assertEqual({r["status"] for r in items}, {"failed", "unknown"})

    def test_search_pagination_and_shanghai_dates(self):
        with sqlite3.connect(self.cfg["database"]) as db:
            for i in range(3):
                # UTC 16:01 belongs to the next Shanghai date.
                ts = dt.datetime(2026,10,7,16,1,tzinfo=dt.timezone.utc).timestamp()+i
                bark.archive(db, {"title": "关键字"+str(i), "body": "全文", "group": "复盘"}, ts=ts, status="sent")
        result = self.client.get("/api/bark/messages?date=2026-10-08&q=关键字&group=复盘&limit=2",headers=self.read).json()
        self.assertEqual(result["total"],3); self.assertTrue(result["hasMore"])
        self.assertEqual(len(result["items"]),2)
        self.assertEqual(len(self.client.get("/api/bark/messages?offset=2&limit=2",headers=self.read).json()["items"]),1)
        self.assertEqual(self.client.get("/api/bark/messages?date=2026-02-30",headers=self.read).status_code,422)

    def test_sync_does_not_erase_bark(self):
        with patch("bark.forward", return_value=("sent", None, 200)):
            self.push()
        # Real sync replacement of feeds/source_records must leave the archive untouched.
        from test_runtime import RuntimeTests
        fixture=RuntimeTests(); fixture.setUp()
        try:
            snapshot=fixture.snapshot(); snapshot["instance"]="personal"
            with TestClient(create_app(self.cfg),base_url=self.cfg["url"]) as original:
                response=original.post("/api/sync", headers={"Authorization":"Bearer "+self.cfg["token"]},json=snapshot)
                self.assertEqual(response.status_code,200)
        finally:
            fixture.doCleanups()
        self.assertEqual(self.client.get("/api/bark/index",headers=self.read).json()["total"],1)

    def test_ingress_content_limits_and_old_day(self):
        self.assertEqual(self.client.post("/push",content="x").status_code,415)
        self.assertEqual(self.client.post("/push",content="x"*65537,headers={"Content-Type":"application/json"}).status_code,413)
        cfg={k:v for k,v in self.cfg.items() if not k.startswith("bark_")}
        with TestClient(create_app(cfg),base_url=cfg["url"]) as original:
            self.assertEqual(original.get("/api/index",headers=self.read).status_code,200)
            self.assertEqual(original.post("/push",json={}).status_code,401)

    def seed_filter_examples(self):
        values = [
            ("JD 京豆日报", "奖励详情", "beandeck", "qinglong-jd:daily"),
            ("顺丰蜂蜜日报", "完整报告", "beandeck", "qinglong-jd:sf-express"),
            ("CK 已失效", "等待手机续期", "beandeck", "qinglong-jd:ck_refresh"),
            ("网站过滤设置完成", "正文里提到 JD、顺丰和 CK；check、SDK、workbench 均保留", "Bark网站", "website-filter"),
        ]
        with sqlite3.connect(self.cfg["database"]) as db:
            for title, body, component, job in values:
                bark.archive(db, {"title": title, "body": body, "group": "报告",
                             "origin": {"host": "DemoHost", "component": component, "job": job}}, status="sent")

    def test_filter_defaults_remove_only_unrelated_topics_and_count_correctly(self):
        self.seed_filter_examples()
        data = self.client.get("/api/bark/messages", headers=self.read).json()
        self.assertEqual(data["total"], 1)
        self.assertEqual(data["matchedTotal"], 4)
        self.assertEqual(data["hiddenTotal"], 3)
        self.assertEqual(data["items"][0]["title"], "网站过滤设置完成")
        all_rows = self.client.get("/api/bark/messages?visibility=all", headers=self.read).json()
        self.assertEqual(all_rows["total"], 4)
        self.assertEqual(sum(r["hidden"] for r in all_rows["items"]), 3)
        index = self.client.get("/api/bark/index", headers=self.read).json()
        self.assertEqual((index["total"], index["archiveTotal"], index["hiddenTotal"]), (1, 4, 3))
        self.assertTrue(index["filters"]["enabled"])

    def test_filter_switch_off_persists_across_reopen_without_deleting_archive(self):
        self.seed_filter_examples()
        prefs = {"enabled": False, "hiddenCategories": ["jd", "sf", "ck"], "hiddenKeywords": []}
        self.assertEqual(self.client.post("/api/bark/preferences", headers=self.write, json=prefs).status_code, 200)
        with TestClient(create_app(self.cfg), base_url=self.cfg["bark_url"]) as restarted:
            result = restarted.get("/api/bark/messages", headers=self.read).json()
            self.assertEqual((result["total"], result["hiddenTotal"]), (4, 0))
            self.assertFalse(restarted.get("/api/bark/preferences", headers=self.read).json()["enabled"])
        with sqlite3.connect(self.cfg["database"]) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM bark_messages").fetchone()[0], 4)

    def test_custom_keywords_are_literal_and_have_english_word_boundaries(self):
        with sqlite3.connect(self.cfg["database"]) as db:
            for title in ("CK 续期", "工作完成", "check socket workbench SDK", "排队%结束"):
                bark.archive(db, {"title": title, "body": "完整记录"}, status="sent")
        prefs = {"enabled": True, "hiddenCategories": [], "hiddenKeywords": ["CK", "%"]}
        self.client.post("/api/bark/preferences", headers=self.write, json=prefs)
        data = self.client.get("/api/bark/messages", headers=self.read).json()
        self.assertEqual(data["hiddenTotal"], 2)
        self.assertEqual({r["title"] for r in data["items"]}, {"工作完成", "check socket workbench SDK"})

    def test_hidden_filter_precedes_pagination_and_combines_with_search(self):
        with sqlite3.connect(self.cfg["database"]) as db:
            for i in range(6):
                bark.archive(db, {"title": "项目完成 "+str(i), "body": "成果"}, status="sent")
            for i in range(4):
                bark.archive(db, {"title": "JD 日报 "+str(i), "body": "奖励"}, status="sent")
        first = self.client.get("/api/bark/messages?limit=2", headers=self.read).json()
        self.assertEqual((first["total"], first["hiddenTotal"], len(first["items"])), (6, 4, 2))
        last = self.client.get("/api/bark/messages?limit=2&offset=4", headers=self.read).json()
        self.assertEqual(len(last["items"]), 2)
        self.assertFalse(last["hasMore"])
        search = self.client.get("/api/bark/messages?q=奖励", headers=self.read).json()
        self.assertEqual((search["total"], search["hiddenTotal"]), (0, 4))

    def test_preference_writes_keep_existing_authentication_and_validate_categories(self):
        self.assertEqual(self.client.get("/api/bark/preferences").status_code, 401)
        self.assertEqual(self.client.post("/api/bark/preferences", headers=self.read, json={}).status_code, 403)
        invalid = {"hiddenCategories": ["unknown"], "hiddenKeywords": []}
        self.assertEqual(self.client.post("/api/bark/preferences", headers=self.write, json=invalid).status_code, 422)
        self.assertEqual(self.client.get("/api/bark/preferences", headers=self.read).json()["hiddenCategories"], ["jd", "sf", "ck"])

    def test_filter_does_not_change_relay_or_archive_hidden_notifications(self):
        with patch("bark.forward", return_value=("sent", None, 200)) as forward:
            result = self.push("完整京豆奖励", extra={"title": "JD 京豆日报"})
            self.assertEqual(result.status_code, 200)
            forward.assert_called_once()
        self.assertEqual(self.client.get("/api/bark/messages", headers=self.read).json()["total"], 0)
        all_rows = self.client.get("/api/bark/messages?visibility=all", headers=self.read).json()
        self.assertEqual(all_rows["items"][0]["body"], "完整京豆奖励")
        self.assertEqual(all_rows["items"][0]["status"], "sent")

    def test_old_unknown_source_development_reports_keep_unrelated_mentions(self):
        with sqlite3.connect(self.cfg["database"]) as db:
            for title, body in (
                    ("虚构开发甲完成", "合成技术说明甲\n正文提到 JD、顺丰和 CK。"),
                    ("虚构开发乙完成", "合成技术说明乙\n京东与顺丰只作技术名词。"),
                    ("虚构开发丙完成", "合成技术说明丙\n这里不是京东或顺丰通知主题。")):
                bark.archive(db, {"title": title, "body": body}, status="sent")
        result=self.client.get("/api/bark/messages",headers=self.read).json()
        self.assertEqual((result["total"],result["hiddenTotal"]),(3,0))


if __name__ == "__main__":
    unittest.main()
