"""Focused private-runner API checks; no Azure calls or real database mutations."""

import sys
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import Mock, patch
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi import HTTPException
from starlette.requests import Request

from api.app import main
from api.app.models import FailureRunner, FailureInjectionResult


def request(key="test-presenter"):
    return Request({
        "type": "http", "method": "POST", "path": "/",
        "headers": [(b"x-zava-presenter-key", key.encode())],
    })


class FaultRunnerAPI(unittest.TestCase):
    def setUp(self):
        self.settings = patch.object(main, "settings", replace(
            main.settings, presenter_key="test-presenter",
        ))
        self.settings.start()
        self.addCleanup(self.settings.stop)
        self.db = Mock()

    def test_all_control_operations_require_presenter_authentication(self):
        runner = FailureRunner(runner_id=uuid4())
        result = FailureInjectionResult(runner_id=runner.runner_id, succeeded=True)
        operations = [
            lambda: main.failure_injection_status(7, request("wrong"), self.db),
            lambda: main.request_failure_injection(7, request("wrong"), self.db),
            lambda: main.claim_failure_injection(runner, request("wrong"), self.db),
            lambda: main.finish_failure_injection(7, result, request("wrong"), self.db),
        ]
        for operation in operations:
            with self.assertRaises(HTTPException) as error:
                operation()
            self.assertEqual(error.exception.status_code, 403)
        self.db.query_one.assert_not_called()

    def test_offline_and_unlocked_requests_are_explicit_failures(self):
        for reason, status in [("runner_offline", 503), ("poll_not_locked", 409),
                               ("fault_unresolved", 409)]:
            self.db.query_one.return_value = {"reason": reason}
            with self.assertRaises(HTTPException) as error:
                main.request_failure_injection(7, request(), self.db)
            self.assertEqual(error.exception.status_code, status)

    def test_duplicate_request_returns_existing_job_without_reinjection(self):
        self.db.query_one.side_effect = [
            {"reason": "already_requested"}, {"online": True},
            {"state": "running", "runner_online": True},
        ]
        self.assertEqual(
            main.request_failure_injection(7, request(), self.db),
            {"runner_online": True, "state": "running"},
        )
        self.assertEqual(self.db.query_one.call_args_list[0].args,
                         ("EXEC dbo.usp_request_failure_injection %s", (7,)))

    def test_another_online_runner_does_not_hide_a_crashed_injector(self):
        self.db.query_one.side_effect = [
            {"online": True}, {"state": "running", "runner_online": False},
        ]
        self.assertEqual(
            main.failure_injection_status(7, request(), self.db),
            {"runner_online": False, "state": "running"},
        )

    def test_result_cannot_be_recorded_by_another_runner(self):
        self.db.query_one.return_value = {"updated": False}
        result = FailureInjectionResult(runner_id=uuid4(), succeeded=True)
        with self.assertRaises(HTTPException) as error:
            main.finish_failure_injection(7, result, request(), self.db)
        self.assertEqual(error.exception.status_code, 409)

    def test_new_voting_is_blocked_during_unresolved_injection(self):
        self.db.query_one.return_value = {"opened": False, "poll_id": None}
        with self.assertRaises(HTTPException) as error:
            main.open_failure_poll(request(), self.db)
        self.assertEqual(error.exception.status_code, 409)


if __name__ == "__main__":
    unittest.main()
