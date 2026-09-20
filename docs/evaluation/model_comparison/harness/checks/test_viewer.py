"""Offline artifact checks; no model requests or remote environment access."""
import copy
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("viewer", ROOT / "viewer.py")
viewer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(viewer)


class ViewerChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.data = json.loads((ROOT / "cases.json").read_text())

    def item(self):
        result = copy.deepcopy(self.data["cases"][0])
        result.update(auto_pass=True, human_review=None, errors=[],
                      actual=dict(result["expected"], speech="Please confirm."),
                      raw_content='{"speech": "Please confirm."}')
        return result

    def render(self, items, **metadata):
        report = dict(planned_cases=150, results=items, status="incomplete")
        report.update(metadata)
        return viewer.render_report(self.root, report).read_text()

    def test_user_model_and_review_html_are_escaped(self):
        attack = '<script>alert("bad")</script><img src=x onerror="bad()"> &'
        item = self.item()
        item["title"] = attack
        item["input"]["user_request"] = attack
        item["actual"]["speech"] = attack
        item["raw_content"] = attack
        item["raw_response"] = {"danger": attack}
        item["errors"] = [attack]
        item["assistant_review"] = {"note": attack}
        rendered = self.render([item], error=attack)
        self.assertNotIn("<script>", rendered)
        self.assertNotIn("<img", rendered)
        self.assertIn("&lt;script&gt;", rendered)
        self.assertIn("Content-Security-Policy", rendered)

    def test_incomplete_run_preserves_denominators_and_pending_review(self):
        (self.root / "dataset.json").write_text(json.dumps(self.data))
        item = self.item()
        item["assistant_review"] = {"passed": True, "reviewer": "Assistant"}
        rendered = self.render([item])
        self.assertIn("1 of 150 planned cases attempted; 149 not attempted", rendered)
        self.assertIn("<td>1 / 50</td><td>1</td><td>0</td><td>1</td><td>0</td>", rendered)
        self.assertIn("Human review pending", rendered)
        self.assertIn("Assistant review (does not replace human review)", rendered)
        self.assertEqual(rendered.count('class="badge pending">Not attempted'), 149)

    def test_no_requests_yet_has_honest_empty_state(self):
        rendered = self.render([], error="Model not ready")
        self.assertIn("0 of 150 planned cases attempted; 150 not attempted", rendered)
        self.assertIn("No model requests have been recorded", rendered)
        self.assertIn("Model not ready", rendered)

    def test_human_pass_requires_automatic_pass(self):
        item = self.item()
        item["auto_pass"] = False
        item["human_review"] = {"passed": True, "reviewer": "Person"}
        rendered = self.render([item])
        self.assertIn("<td>1 / 50</td><td>0</td><td>1</td><td>0</td><td>0</td>", rendered)

    def test_catalog_contains_all_150_cases_and_full_prompt(self):
        self.data["cases"][0]["input"]["user_request"] = '<script>unsafe</script>\n```'
        (self.root / "cases.json").write_text(json.dumps(self.data))
        (self.root / "system_prompt.txt").write_text("Prompt <unsafe>")
        markdown, webpage = viewer.generate_cases(self.root)
        rendered = webpage.read_text()
        self.assertEqual(rendered.count('<details class="case">'), 150)
        for case in self.data["cases"]:
            self.assertIn(case["id"] + " · " + case["title"], rendered)
        self.assertIn("Prompt &lt;unsafe&gt;", rendered)
        self.assertNotIn("<script>", rendered)
        self.assertIn("````text", markdown.read_text())

    def test_report_cli_uses_latest_or_explicit_run(self):
        run_dir = self.root / "runs" / "sample"
        run_dir.mkdir(parents=True)
        (run_dir / "results.json").write_text(json.dumps({"planned_cases": 150, "results": [], "status": "incomplete"}))
        (self.root / "runs" / "LATEST").write_text("sample\n")
        with patch.object(viewer, "ROOT", self.root), patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(viewer.main(["report"]), 0)
            self.assertTrue((run_dir / "report.html").exists())
            self.assertEqual(viewer.main(["report", "--run", "sample"]), 0)
        with patch.object(viewer, "ROOT", self.root), patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(viewer.main(["report", "--run", "../outside"]), 2)


if __name__ == "__main__":
    unittest.main()
