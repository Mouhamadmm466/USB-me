"""Exercise startup recovery with fake local commands; never access Docker or a GPU."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
FAKE_TOOL = r'''
import json, os, pathlib, sys
root = pathlib.Path.cwd()
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = root / "fixture-state.json"
state = json.loads(state_path.read_text())
with (root / "fixture-calls.jsonl").open("a") as out:
    out.write(json.dumps([name] + args) + "\n")
def save():
    state_path.write_text(json.dumps(state))
if name == "uname":
    print("Linux")
    sys.exit(0)
if name in ("nvidia-smi", "sleep", "flock"):
    sys.exit(1 if name == "flock" and state["scenario"] == "locked" else 0)
if name == "sha256sum":
    state["checksum_checked"] = True
    save()
    sys.exit(1 if state["scenario"] == "checksum-failure" else 0)
if name == "docker":
    image = "ghcr.io/ggml-org/llama.cpp@sha256:131a7be5d90d6df75f32ffad405d71e354e9bdba806264b6a905339283925b85"
    server_args = ["--model", "/models/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf",
        "--alias", "usb-me-phi4-mini-q4km", "--n-gpu-layers", "999", "--ctx-size", "4096",
        "--parallel", "1", "--jinja", "--reasoning", "off", "--host", "127.0.0.1", "--port", "8081"]
    if args[:2] == ["image", "inspect"]:
        assert args[2] == image
        sys.exit(1 if state["scenario"] == "image-missing" else 0)
    if args[0] == "pull":
        assert args[1] == image
        sys.exit(0)
    if args[0] == "run":
        assert state.get("checksum_checked"), "Must verify weights before launching"
        assert "-p" not in args and "--publish" not in args
        assert args[args.index("--network") + 1] == "host"
        assert args[args.index(image) + 1:] == server_args
        state["status"] = "running"
        save()
        sys.exit(0)
    if args[0] == "info":
        sys.exit(0)
    if args[0] == "inspect":
        if state["status"] == "missing":
            sys.exit(1)
        if "--format" not in args:
            print(json.dumps([{"Config": {"Image": image, "Cmd": server_args,
                "Labels": {"usb-me.purpose": "phi4-mini-150-pilot"}},
                "HostConfig": {"NetworkMode": "bridge" if state["scenario"] == "wrong-network" else "host",
                               "PortBindings": {}}}]))
        else:
            fmt = args[args.index("--format") + 1]
            if fmt == '{{index .Config.Labels "usb-me.purpose"}}':
                print("phi4-mini-150-pilot")
            elif fmt == '{{.State.Status}}':
                print(state["status"])
            elif fmt == '{{.State.Running}}':
                print("true" if state["status"] == "running" else "false")
            elif fmt.startswith("Status="):
                print("Status=" + state["status"] + " Error=fixture error")
            else:
                sys.exit(91)
        sys.exit(0)
    if args[0] == "start":
        if state["scenario"] == "port-conflict":
            print("Bind for 127.0.0.1:8081 failed: port is already allocated", file=sys.stderr)
            sys.exit(125)
        state["status"] = "running"
        save()
        sys.exit(0)
    if args[0] == "logs":
        print("fixture startup log")
        sys.exit(0)
if name == "curl":
    state["polls"] += 1
    if state["scenario"] == "crashed":
        state["status"] = "exited"
    save()
    if state["polls"] < 3 or state["status"] != "running":
        sys.exit(7)  # Simulate connection refusal while loading.
    print('{"status":"ok"}')
    sys.exit(0)
if name == "python3":
    if args[0] == "-c":
        os.execv(sys.executable, [sys.executable] + args)
    if args == ["pilot.py", "validate"]:
        sys.exit(0)
    if args == ["pilot.py", "recover"]:
        if state["scenario"] == "verification-failure":
            print("fixture model checksum mismatch", file=sys.stderr)
            sys.exit(2)
        assert state["polls"] >= 3 and state["status"] == "running"
        (root / "runtime.json").write_text('{"fixture": true}')
        print("Model server ready. Setup record recovered. Next: python3 pilot.py run")
        sys.exit(0)
    if args == ["pilot.py", "run"]:
        assert (root / "runtime.json").exists(), "Evaluation must follow successful setup"
        sys.exit(0)
    if args[:1] == ["viewer.py"]:
        sys.exit(0)
print("Unexpected fixture command: " + repr([name] + args), file=sys.stderr)
sys.exit(91)
'''


class StartupChecks(unittest.TestCase):
    def simulate(self, scenario, workflow=False, action=None):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            shutil.copyfile(ROOT / "start_model.sh", root / "start_model.sh")
            shutil.copyfile(ROOT / "workflow.sh", root / "workflow.sh")
            model_dir = root / "models"
            model_dir.mkdir()
            (model_dir / "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf").write_bytes(b"offline fixture weights")
            fake_bin = root / "bin"
            fake_bin.mkdir()
            for name in ("docker", "nvidia-smi", "curl", "python3", "sha256sum", "sleep", "uname", "flock"):
                path = fake_bin / name
                path.write_text("#!" + sys.executable + "\n" + FAKE_TOOL)
                path.chmod(0o755)
            missing = scenario in ("fresh", "image-missing", "checksum-failure")
            (root / "fixture-state.json").write_text(json.dumps({"scenario": scenario, "polls": 0,
                "status": "missing" if missing else "running" if scenario == "already-running" else "created"}))
            command = ["bash", str(root / ("workflow.sh" if workflow else "start_model.sh"))]
            if action:
                command.append(action)
            result = subprocess.run(command, cwd=root.parent,
                env=dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
                         USB_ME_WORKFLOW_LOCK=str(root / "workflow.lock"), USB_ME_LOCK_HELD="0"),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
            calls = [json.loads(line) for line in (root / "fixture-calls.jsonl").read_text().splitlines()]
            return result, (root / "runtime.json").exists(), calls

    def test_created_container_waits_through_refusals_before_recovery(self):
        result, recorded, calls = self.simulate("loading")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(recorded)
        self.assertIn(["docker", "start", "usb-me-phi4-mini-server"], calls)
        self.assertEqual(sum(call[0] == "curl" for call in calls), 3)

    def test_running_container_is_reused_without_restart(self):
        result, recorded, calls = self.simulate("already-running")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(recorded)
        self.assertFalse(any(call[:2] == ["docker", "start"] for call in calls))

    def test_port_conflict_prints_diagnostics_and_creates_no_record(self):
        result, recorded, calls = self.simulate("port-conflict")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)
        self.assertIn("port is already allocated", result.stdout)
        self.assertIn("fixture startup log", result.stdout)
        self.assertFalse(any(call[0] == "curl" for call in calls))

    def test_crash_during_loading_prints_logs_and_creates_no_record(self):
        result, recorded, calls = self.simulate("crashed")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)
        self.assertIn("fixture startup log", result.stdout)
        self.assertNotIn(["python3", "pilot.py", "recover"], calls)

    def test_ready_endpoint_with_failed_verification_is_not_success(self):
        result, recorded, _ = self.simulate("verification-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)
        self.assertIn("fixture model checksum mismatch", result.stdout)

    def test_fresh_container_uses_exact_image_host_network_and_loopback(self):
        result, recorded, calls = self.simulate("fresh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(recorded)
        run = next(c for c in calls if c[:2] == ["docker", "run"])
        self.assertEqual(run[run.index("--network") + 1], "host")
        self.assertEqual(run[run.index("--host") + 1], "127.0.0.1")
        self.assertNotIn("-p", run)
        self.assertFalse(any(c[:2] == ["docker", "pull"] for c in calls))

    def test_missing_image_pulls_only_the_pinned_digest(self):
        result, recorded, calls = self.simulate("image-missing")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(recorded)
        pulls = [c for c in calls if c[:2] == ["docker", "pull"]]
        self.assertEqual(len(pulls), 1)
        self.assertEqual(pulls[0][2], "ghcr.io/ggml-org/llama.cpp@sha256:131a7be5d90d6df75f32ffad405d71e354e9bdba806264b6a905339283925b85")

    def test_wrong_network_does_not_start_existing_container(self):
        result, recorded, calls = self.simulate("wrong-network")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)
        self.assertFalse(any(c[:2] == ["docker", "start"] for c in calls))
        self.assertIn("different settings", result.stdout)

    def test_bad_weights_prevent_container_launch(self):
        result, recorded, calls = self.simulate("checksum-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(recorded)
        self.assertFalse(any(c[:2] == ["docker", "run"] for c in calls))

    def test_default_workflow_runs_setup_then_evaluation_and_report_from_other_directory(self):
        result, _, calls = self.simulate("loading", workflow=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        setup = calls.index(["python3", "pilot.py", "recover"])
        run = calls.index(["python3", "pilot.py", "run"])
        report = calls.index(["python3", "viewer.py", "report"])
        self.assertLess(setup, run)
        self.assertLess(run, report)

    def test_setup_failure_prevents_model_evaluation(self):
        result, _, calls = self.simulate("verification-failure", workflow=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(["python3", "pilot.py", "run"], calls)

    def test_workflow_lock_prevents_concurrent_setup_and_evaluation(self):
        result, _, calls = self.simulate("locked", workflow=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another workflow run is active", result.stdout)
        self.assertFalse(any(c[0] == "docker" for c in calls))
        self.assertNotIn(["python3", "pilot.py", "run"], calls)

    def test_cases_view_does_not_start_model(self):
        result, _, calls = self.simulate("loading", workflow=True, action="cases")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(calls, [["python3", "viewer.py", "cases"]])

    def test_setup_verifies_server_without_running_evaluation(self):
        result, recorded, calls = self.simulate("loading", workflow=True, action="setup")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(recorded)
        self.assertIn(["python3", "pilot.py", "recover"], calls)
        self.assertNotIn(["python3", "pilot.py", "run"], calls)

    def test_setup_respects_shared_workflow_lock(self):
        result, _, calls = self.simulate("locked", workflow=True, action="setup")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "docker" for c in calls))


if __name__ == "__main__":
    unittest.main()
