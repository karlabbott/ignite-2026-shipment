"""Browser regressions for voting UI, with mocked APIs and no estate mutations.

Requires playwright, zxing-cpp, Pillow, and the web tier's Jinja2 dependency.
Uses installed Edge on Windows; elsewhere install Playwright Chromium first.
Run: python tools/test-voting-ui.py
"""

import io
import json
import os
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import sys
import threading
import unittest
from urllib.parse import urlsplit

from jinja2 import Environment, FileSystemLoader, select_autoescape
from PIL import Image
from playwright.sync_api import expect, sync_playwright
import zxingcpp


APP = Path(__file__).resolve().parents[1] / "web" / "app"
TEMPLATES = Environment(
    loader=FileSystemLoader(APP / "templates"), autoescape=select_autoescape(),
)
CHOICES = [
    {"code": "freeze_azurelinux", "label": "Freeze the Azure Linux worker"},
    {"code": "degrade_worker_sql", "label": "Degrade worker-to-SQL networking"},
    {"code": "delay_worker_claims", "label": "Delay worker queue claims"},
]


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(APP), **kwargs)

    def log_message(self, *args):
        pass

    def do_GET(self):
        template = {
            "/": "dashboard.html", "/track": "track.html", "/voting": "voting.html",
        }.get(urlsplit(self.path).path)
        if template is None:
            return super().do_GET()
        body = TEMPLATES.get_template(template).render(
            brand="Zava Logistics", track_url="https://track.99b.org",
            return_url="", refresh_ms=100, prefill="",
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class VotingUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.origin = f"http://127.0.0.1:{cls.server.server_port}"
        cls.playwright = sync_playwright().start()
        cls.browser = cls.playwright.chromium.launch(
            channel="msedge" if sys.platform == "win32" else None, headless=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.browser.close()
        cls.playwright.stop()
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def setUp(self):
        self.context = self.browser.new_context(viewport={"width": 1920, "height": 1080})
        self.page = self.context.new_page()
        self.errors = []
        self.page.on("pageerror", lambda error: self.errors.append(str(error)))
        self.poll = {
            "poll_id": 7, "state": "open", "total_votes": 7,
            "winner_code": None, "choices": CHOICES,
        }
        self.poll_available = True
        self.injection = {"runner_online": True, "state": None}
        self.mutations = []
        self.page.route("**/api/**", self.api)

    def tearDown(self):
        self.context.close()
        self.assertEqual(self.errors, [])

    def api(self, route):
        request = route.request
        path = urlsplit(request.url).path
        status = 200
        if request.method == "POST":
            self.mutations.append(path)
            self.assertEqual(request.headers.get("x-zava-presenter-key"), "test-presenter-key")
            if path == "/api/presenter/polls":
                self.injection = {"runner_online": True, "state": None}
                self.poll = {
                    "poll_id": 8, "state": "open", "total_votes": 0,
                    "winner_code": None, "choices": CHOICES,
                }
            elif path == "/api/presenter/polls/8/lock":
                self.poll = {
                    **self.poll, "state": "locked", "winner_code": "freeze_azurelinux",
                }
            elif path == "/api/presenter/polls/8/inject":
                self.injection = {**self.injection, "state": "queued"}
                payload = self.injection
                route.fulfill(status=status, json=payload)
                return
            elif path == "/api/presenter/polls/7/state":
                self.assertEqual(request.post_data_json, {"state": "closed"})
                self.poll = {**self.poll, "state": "closed"}
            else:
                self.fail("Unexpected mutation: " + path)
            payload = self.poll
        elif path == "/api/poll":
            status = 200 if self.poll_available else 503
            payload = self.poll if self.poll_available else {"detail": "Poll unavailable"}
        elif path.endswith("/injection"):
            self.assertEqual(request.headers.get("x-zava-presenter-key"), "test-presenter-key")
            payload = self.injection
        else:
            payload = {
                "/api/estate": {"tiers": [], "degraded": False},
                "/api/stats": {"total": 0, "in_flight": 0, "delivered": 0,
                               "queue_depth": 0, "scans_last_5m": 0},
                "/api/board": [],
                "/api/presentation": {"golden": None, "shipments": []},
            }[path]
        route.fulfill(status=status, json=payload)

    def screenshot(self, name):
        directory = os.environ.get("ZAVA_UI_SCREENSHOTS")
        if directory:
            Path(directory).mkdir(parents=True, exist_ok=True)
            self.page.screenshot(path=str(Path(directory) / name), full_page=True)

    def test_projected_qr_hidden_tallies_and_minimized_state(self):
        self.page.goto(self.origin + "/?view=network")
        expect(self.page.locator("#poll-join")).to_be_visible()
        expect(self.page.locator(".qr-hint")).to_be_hidden()
        expect(self.page.locator("#poll-tally .concealed")).to_have_count(3)
        self.assertNotIn("Results hidden", self.page.locator("#poll-tally").inner_text())
        self.assertNotIn("votes", self.page.locator("#poll-tally").inner_text())
        qr = self.page.locator("#poll-join img")
        decoded = zxingcpp.read_barcode(Image.open(io.BytesIO(qr.screenshot())))
        self.assertIsNotNone(decoded, "Projected QR must be scannable")
        self.assertEqual(decoded.text, "https://track.99b.org/vote")
        self.screenshot("voting-desktop.png")
        self.poll = {
            **self.poll, "state": "locked", "winner_code": "freeze_azurelinux",
            "choices": [{**choice, "votes": votes} for choice, votes in zip(CHOICES, [4, 2, 1])],
        }
        expect(self.page.locator("#poll-stage-label")).to_have_text("VOTING LOCKED")
        expect(self.page.locator("#poll-join")).to_be_hidden()
        expect(self.page.locator("#poll-tally .winner")).to_have_count(1)
        self.page.locator("#poll-display-toggle").click()
        expect(self.page.locator("#poll-stage-status")).to_be_hidden()
        badge = self.page.locator("#poll-state").evaluate(
            "element => getComputedStyle(element, '::before').content",
        )
        self.assertIn("VOTING LOCKED", badge)

    def test_tracking_vote_link_and_clear_only_shipment_history(self):
        self.context.add_init_script("""
            localStorage.setItem("zava-failure-voter", "keep-voter-token");
            localStorage.setItem("zava-audience-client", "keep-client-token");
            localStorage.setItem("zava-presenter-key", "keep-presenter-key");
            localStorage.setItem("zava-created-shipments-v1", JSON.stringify([{
              tracking_number: "ZAVOLD", description: "Old shipment",
              origin: "Seattle", destination: "Toronto"
            }]));
        """)
        self.page.set_viewport_size({"width": 390, "height": 844})
        self.page.goto(self.origin + "/track")
        expect(self.page.locator("#audience-vote-link")).to_be_visible()
        self.screenshot("tracking-mobile.png")
        self.assertTrue(self.page.evaluate("document.documentElement.scrollWidth <= innerWidth"))
        self.page.locator("#clear-shipment-history").click()
        expect(self.page.locator("#recent-card")).to_be_hidden()
        values = self.page.evaluate("""() => [
          localStorage.getItem("zava-created-shipments-v1"),
          localStorage.getItem("zava-failure-voter"),
          localStorage.getItem("zava-audience-client"),
          localStorage.getItem("zava-presenter-key")
        ]""")
        self.assertEqual(values, [None, "keep-voter-token", "keep-client-token", "keep-presenter-key"])
        self.poll = {**self.poll, "state": "locked"}
        expect(self.page.locator("#audience-vote-link")).to_be_hidden()
        self.poll_available = False
        expect(self.page.locator("#audience-vote-status")).to_contain_text("Poll unavailable")
        self.poll_available = True
        self.poll = {**self.poll, "state": "open"}
        expect(self.page.locator("#audience-vote-link")).to_be_visible()
        expect(self.page.locator("#audience-vote-status")).to_be_hidden()
        self.assertEqual(self.mutations, [])

    def test_presenter_saves_reloads_and_forgets_key_without_injecting(self):
        self.poll = {**self.poll, "poll_id": None, "state": "closed", "total_votes": 0}
        self.page.goto(self.origin + "/voting")
        expect(self.page.locator("#presenter-poll-state")).to_have_text("No open voting")
        expect(self.page.locator("#open-voting")).to_be_disabled()
        self.page.locator("#presenter-key").fill("test-presenter-key")
        self.page.locator("#save-presenter-key").click()
        expect(self.page.locator("#open-voting")).to_be_enabled()
        self.page.locator("#open-voting").click()
        expect(self.page.locator("#presenter-poll-state")).to_have_text("Voting open")
        expect(self.page.locator("#open-voting")).to_be_disabled()
        self.page.locator("#close-voting").click()
        expect(self.page.locator("#presenter-poll-state")).to_have_text("Voting closed")
        expect(self.page.locator("#presenter-poll-winner")).to_contain_text("Freeze the Azure Linux worker")
        expect(self.page.locator("#close-voting")).to_be_disabled()
        expect(self.page.locator("#inject-fault")).to_be_enabled()
        self.assertEqual(self.mutations, ["/api/presenter/polls", "/api/presenter/polls/8/lock"])
        self.assertEqual(self.page.evaluate(
            "localStorage.getItem('zava-presenter-key')",
        ), "test-presenter-key")
        self.assertNotIn("test-presenter-key", self.page.url)
        self.screenshot("voting-controls.png")
        self.page.reload()
        expect(self.page.locator("#presenter-key")).to_have_value("test-presenter-key")
        expect(self.page.locator("#inject-fault")).to_be_enabled()
        self.page.locator("#presenter-key").fill("")
        expect(self.page.locator("#forget-presenter-key")).to_be_enabled()
        self.page.locator("#forget-presenter-key").click()
        self.assertIsNone(self.page.evaluate("localStorage.getItem('zava-presenter-key')"))
        expect(self.page.locator("#inject-fault")).to_be_disabled()

    def test_injection_is_explicit_and_disabled_for_offline_or_claimed_runner(self):
        self.poll = {
            **self.poll, "poll_id": 8, "state": "locked",
            "winner_code": "freeze_azurelinux",
        }
        self.injection["runner_online"] = False
        self.page.goto(self.origin + "/voting")
        self.page.locator("#presenter-key").fill("test-presenter-key")
        self.page.locator("#save-presenter-key").click()
        expect(self.page.locator("#injection-status")).to_contain_text("offline")
        expect(self.page.locator("#inject-fault")).to_be_disabled()
        expect(self.page.locator("#injection-disabled-reason")).to_contain_text("offline")
        self.assertEqual(self.page.locator("#inject-fault").evaluate(
            "element => getComputedStyle(element).cursor",
        ), "not-allowed")
        self.injection["runner_online"] = True
        expect(self.page.locator("#inject-fault")).to_be_enabled()
        self.assertEqual(self.mutations, [])
        self.page.locator("#inject-fault").click()
        expect(self.page.locator("#injection-status")).to_contain_text("Waiting")
        expect(self.page.locator("#inject-fault")).to_be_disabled()
        expect(self.page.locator("#open-voting")).to_be_disabled()
        self.assertEqual(self.mutations, ["/api/presenter/polls/8/inject"])
        self.injection["state"] = "running"
        expect(self.page.locator("#injection-status")).to_contain_text("injecting")
        self.injection["state"] = "failed"
        expect(self.page.locator("#injection-status")).to_contain_text("partial fault")
        expect(self.page.locator("#inject-fault")).to_be_disabled()
        expect(self.page.locator("#open-voting")).to_be_enabled()

    def test_reopening_after_repair_requires_confirmation_and_never_injects(self):
        self.poll = {
            **self.poll, "state": "injected", "winner_code": "delay_worker_claims",
        }
        self.injection["state"] = "running"
        self.page.goto(self.origin + "/voting")
        self.page.locator("#presenter-key").fill("test-presenter-key")
        self.page.locator("#save-presenter-key").click()
        expect(self.page.locator("#open-voting")).to_be_disabled()
        self.injection["state"] = "succeeded"
        expect(self.page.locator("#open-voting")).to_be_enabled()
        expect(self.page.locator("#open-voting")).to_have_text("Open voting")
        self.page.once("dialog", lambda dialog: dialog.dismiss())
        self.page.locator("#open-voting").click()
        self.assertEqual(self.mutations, [])
        self.assertEqual(self.poll["state"], "injected")
        self.page.once("dialog", lambda dialog: dialog.accept())
        self.page.locator("#open-voting").click()
        expect(self.page.locator("#presenter-poll-state")).to_have_text("Voting open")
        self.assertEqual(self.mutations, [
            "/api/presenter/polls/7/state", "/api/presenter/polls",
        ])
        self.assertEqual(self.poll["poll_id"], 8)
        self.assertEqual(self.poll["total_votes"], 0)
        expect(self.page.locator("#inject-fault")).to_be_disabled()

    def test_presenter_authentication_error_survives_status_refresh(self):
        self.page.goto(self.origin + "/voting")
        self.page.locator("#presenter-key").fill("incorrect-test-key")
        self.page.route(
            "**/api/presenter/polls/7/lock",
            lambda route: route.fulfill(status=403, json={"detail": "Invalid presenter key"}),
        )
        self.page.route(
            "**/api/presenter/polls/7/injection",
            lambda route: route.fulfill(status=403, json={"detail": "Invalid presenter key"}),
        )
        self.page.locator("#save-presenter-key").click()
        expect(self.page.locator("#banner")).to_contain_text("Invalid presenter key")
        self.page.wait_for_timeout(250)
        expect(self.page.locator("#banner")).to_be_visible()
        self.assertEqual(self.poll["state"], "open")
        self.assertIsNone(self.page.evaluate("localStorage.getItem('zava-presenter-key')"))

    def test_slow_runner_status_is_not_discarded_by_repeated_poll_refreshes(self):
        self.poll = {
            **self.poll, "poll_id": 8, "state": "locked",
            "winner_code": "delay_worker_claims",
        }
        self.page.add_init_script("""
          const originalFetch = window.fetch;
          window.fetch = async (...args) => {
            if (String(args[0]).endsWith("/injection")) {
              await new Promise(resolve => setTimeout(resolve, 350));
            }
            return originalFetch(...args);
          };
        """)
        self.page.goto(self.origin + "/voting")
        self.page.locator("#presenter-key").fill("test-presenter-key")
        self.page.locator("#save-presenter-key").click()
        expect(self.page.locator("#inject-fault")).to_be_enabled(timeout=2000)
        expect(self.page.locator("#injection-disabled-reason")).to_be_hidden()
        self.injection["runner_online"] = False
        expect(self.page.locator("#inject-fault")).to_be_disabled(timeout=2000)
        self.injection["runner_online"] = True
        expect(self.page.locator("#inject-fault")).to_be_enabled(timeout=2000)
        self.assertEqual(self.mutations, [])


if __name__ == "__main__":
    unittest.main()
