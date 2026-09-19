"""Offline harness verification, not Nemotron results."""
import copy
import importlib.util
import io
import json
import pathlib
import shutil
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pilot", ROOT / "pilot.py")
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


class ScorerChecks(unittest.TestCase):
    def setUp(self):
        self.data = pilot.load_cases()
        self.by_id = {c["id"]: c for c in self.data["cases"]}

    def response(self, case_id):
        return dict(copy.deepcopy(self.by_id[case_id]["expected"]), speech="Review this response manually.")

    def errors(self, case_id, obj):
        return pilot.grade(json.dumps(obj), self.by_id[case_id]["expected"])[1]

    def test_reviewed_keys_are_not_in_model_envelope(self):
        prompt = (ROOT / "system_prompt.txt").read_text()
        for case in self.data["cases"]:
            payload = pilot.make_request(self.data, case, prompt)
            envelope = json.loads(payload["messages"][1]["content"])
            self.assertEqual(set(envelope), {"environment", "state", "user_request"})
            self.assertEqual(envelope["state"], case["input"]["state"])
            self.assertNotIn("expected", envelope)
            self.assertNotIn("human_checks", envelope)

    def test_correct_fields_all_150(self):
        for case in self.data["cases"]:
            self.assertEqual(self.errors(case["id"], self.response(case["id"])), [])

    def test_wrong_recipient_and_changed_number_fail(self):
        obj = self.response("H1")
        obj["arguments"]["contact_query"] = "Alex Morgan"
        self.assertTrue(self.errors("H1", obj))
        obj = self.response("H1")
        obj["arguments"]["message"] = "I will be 20 minutes late."
        self.assertTrue(self.errors("H1", obj))

    def test_stale_approval_and_integer_boolean_fail(self):
        for value in (False, 1, "true"):
            obj = self.response("H1")
            obj["requires_confirmation"] = value
            self.assertTrue(self.errors("H1", obj))

    def test_unnecessary_clarification_fails(self):
        obj = {"type": "clarification", "speech": "Who?", "tool": None,
               "arguments": {}, "requires_confirmation": False}
        self.assertTrue(self.errors("M2", obj))

    def test_timezone_equivalence_and_naive_date(self):
        obj = self.response("H2")
        obj["arguments"]["starts_at"] = "2026-09-24T19:00:00Z"
        obj["arguments"]["ends_at"] = "2026-09-24T19:45:00+00:00"
        self.assertEqual(self.errors("H2", obj), [])
        obj["arguments"]["starts_at"] = "2026-09-24T15:00:00"
        self.assertTrue(self.errors("H2", obj))
        self.assertEqual(pilot.timestamp(self.by_id["H2"]["expected"]["arguments"]["starts_at"]).weekday(), 3)

    def test_injected_action_fails(self):
        self.assertTrue(self.errors("H3", self.response("E1")))

    def test_extra_execution_field_and_duplicate_json_fail(self):
        obj = self.response("E1")
        obj["execute_now"] = True
        self.assertTrue(self.errors("E1", obj))
        for raw in ('{"type":"answer","type":"proposed_action"}', 'NaN', '```json\n{}\n```'):
            self.assertTrue(pilot.grade(raw, self.by_id["E1"]["expected"])[1])

    def test_auto_pass_does_not_imply_reviewed_pass(self):
        obj = self.response("E1")
        obj["speech"] = "I sent it already."
        self.assertEqual(self.errors("E1", obj), [])  # Deliberately a HUMAN semantic check.
        report = {"results": [{"difficulty": "easy", "auto_pass": True, "human_review": None}]}
        self.assertEqual(pilot.summarize(report)[0][-1], 0)
        report["results"][0]["human_review"] = {"passed": False}
        self.assertEqual(pilot.summarize(report)[0][-1], 0)

    def isolated_run(self, responder):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            for filename in ("cases.json", "system_prompt.txt", "pilot.py"):
                shutil.copyfile(ROOT / filename, root / filename)
            with patch.object(pilot, "ROOT", root), patch.object(pilot, "preflight", return_value={"fixture": True}), \
                 patch.object(pilot, "http_json", side_effect=responder), patch("sys.stdout", new_callable=io.StringIO), \
                 patch("sys.stderr", new_callable=io.StringIO):
                result = pilot.run()
            files = list((root / "runs").glob("*/results.json"))
            return result, json.loads(files[0].read_text()), (root / "runs" / "LATEST").exists()

    def test_mocked_run_retains_timeout_failure_and_all_denominators(self):
        count = 0

        def respond(route, payload):
            nonlocal count
            case = self.data["cases"][count]
            count += 1
            if count == 4:
                raise TimeoutError("fixture timeout")
            return {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(self.response(case["id"]))}}]}

        exit_code, report, latest = self.isolated_run(respond)
        self.assertEqual(exit_code, 0)
        self.assertTrue(latest)
        self.assertEqual(len(report["results"]), 150)
        self.assertEqual(sum(r["auto_pass"] for r in report["results"]), 149)
        self.assertEqual(report["status"], "model_run_complete_human_review_pending")
        self.assertEqual(count, 150)  # No hidden retry.

    def test_api_contract_error_invalidates_run(self):
        def respond(route, payload):
            raise urllib.error.HTTPError("local", 400, "bad schema", {}, io.BytesIO(b"unsupported response_format"))

        code, report, latest = self.isolated_run(respond)
        self.assertEqual(code, 2)
        self.assertEqual(report["status"], "incomplete")
        self.assertFalse(latest)
        self.assertEqual(len(report["results"]), 1)


class RecoveryChecks(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = pathlib.Path(temp.name)
        model_dir = self.root / "actual-container-models"
        model_dir.mkdir()
        self.model = model_dir / pilot.MODEL_FILE
        self.model.write_bytes(b"offline fixture weights")
        self.digest = pilot.IMAGE_DIGEST
        self.container = {
            "Id": "fixture-container", "Created": "2026-09-19T19:00:00Z", "State": {"Running": True},
            "Config": {"Image": self.digest, "Labels": {"usb-me.purpose": "nine-case-pilot"},
                       "Cmd": ["--model", "/models/" + pilot.MODEL_FILE, "--alias", pilot.ALIAS,
                               "--n-gpu-layers", "999", "--ctx-size", "4096", "--parallel", "1",
                               "--jinja", "--reasoning", "off", "--host", "127.0.0.1", "--port", "8080"]},
            "HostConfig": {"NetworkMode": "host", "PortBindings": {},
                           "DeviceRequests": [{"Count": -1, "Capabilities": [["gpu"]]}]},
            "Mounts": [{"Destination": "/models", "Source": str(model_dir), "RW": False}],
        }
        self.endpoints = {"/health": {"status": "ok"},
                          "/props": {"model_path": "/models/" + pilot.MODEL_FILE, "total_slots": 1},
                          "/v1/models": {"data": [{"id": pilot.ALIAS}]}}

        def command(args):
            if args == ["docker", "inspect", pilot.CONTAINER]:
                return json.dumps([self.container])
            if args[0] == "nvidia-smi":
                return "Offline GPU metadata fixture"
            raise AssertionError("Unexpected command: " + repr(args))

        def http(route, payload=None, timeout=120):
            self.assertIsNone(payload)  # Recovery must never send inference requests.
            return copy.deepcopy(self.endpoints[route])

        for patcher in (patch.object(pilot, "ROOT", self.root),
                        patch.object(pilot, "MODEL_SHA", pilot.sha_file(self.model)),
                        patch.object(pilot, "command", side_effect=command),
                        patch.object(pilot, "http_json", side_effect=http),
                        patch("sys.stdout", new_callable=io.StringIO)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_ready_server_recovers_actual_identity_and_mount(self):
        self.assertEqual(pilot.recover(), 0)
        record = json.loads((self.root / "runtime.json").read_text())
        self.assertEqual(record["container_id"], self.container["Id"])
        self.assertEqual(record["model_file"], str(self.model.resolve()))
        self.assertEqual(record["image_digest"], self.digest)
        self.assertEqual(record["verified_sha256"], pilot.sha_file(self.model))
        self.assertEqual((self.root / "llama-cpp-image.txt").read_text().strip(), self.digest)

    def assert_rejected_without_records(self):
        with self.assertRaises(ValueError):
            pilot.recover()
        self.assertFalse((self.root / "runtime.json").exists())
        self.assertFalse((self.root / "llama-cpp-image.txt").exists())

    def test_wrong_weights_cannot_create_record(self):
        self.model.write_bytes(b"wrong weights")
        self.assert_rejected_without_records()

    def test_unready_or_wrong_endpoint_cannot_create_record(self):
        original = copy.deepcopy(self.endpoints)
        for route, replacement in [("/health", {"status": "loading model"}),
                                   ("/props", {"model_path": "/models/wrong.gguf", "total_slots": 1}),
                                   ("/props", {"model_path": "/models/" + pilot.MODEL_FILE, "total_slots": 2}),
                                   ("/v1/models", {"data": [{"id": "wrong-model"}]})]:
            with self.subTest(route=route, replacement=replacement):
                self.endpoints = copy.deepcopy(original)
                self.endpoints[route] = replacement
                self.assert_rejected_without_records()

    def test_wrong_container_configuration_cannot_create_record(self):
        original = copy.deepcopy(self.container)
        for key in ("stopped", "writable", "unlabeled", "unpinned", "bridge-network", "published-port", "no-gpu", "public-bind", "changed-arguments"):
            with self.subTest(key=key):
                self.container = copy.deepcopy(original)
                if key == "stopped":
                    self.container["State"]["Running"] = False
                elif key == "writable":
                    self.container["Mounts"][0]["RW"] = True
                elif key == "unlabeled":
                    self.container["Config"]["Labels"] = {}
                elif key == "unpinned":
                    self.container["Config"]["Image"] = "ghcr.io/ggml-org/llama.cpp:server-cuda"
                elif key == "bridge-network":
                    self.container["HostConfig"]["NetworkMode"] = "bridge"
                elif key == "published-port":
                    self.container["HostConfig"]["PortBindings"] = {"8080/tcp": [{"HostPort": "8080"}]}
                elif key == "no-gpu":
                    self.container["HostConfig"]["DeviceRequests"] = []
                elif key == "public-bind":
                    self.container["Config"]["Cmd"][-3] = "0.0.0.0"
                else:
                    self.container["Config"]["Cmd"][-1] = "8081"
                self.assert_rejected_without_records()

    def test_failure_preserves_existing_record_and_conflicting_pin(self):
        record = self.root / "runtime.json"
        pin = self.root / "llama-cpp-image.txt"
        record.write_text("existing record")
        pin.write_text("different pinned image")
        with self.assertRaises(ValueError):
            pilot.recover()
        self.assertEqual(record.read_text(), "existing record")
        self.assertEqual(pin.read_text(), "different pinned image")


if __name__ == "__main__":
    unittest.main()
