import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("stage_plan", Path(__file__).resolve().parents[1] / "toolkit/plan_stages.py")
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


def item(path, seconds=200, starts=1, sheets=1):
    return {"path": path, "sha256": "a" * 64, "estimated_seconds": seconds,
            "cad_starts": starts, "sheet_count": sheets, "estimate_basis": "measured"}


class StagePlanTests(unittest.TestCase):
    def inventory(self, *files):
        return {"schema_version": 1, "operation": "pdf", "files": list(files)}

    def test_order_and_limits_with_reserve(self):
        data = self.inventory(item("003 c.dwg", 500), item("001 a.dwg", 500), item("002 b.dwg", 500))
        plan = p.build_plan(data)
        self.assertEqual([len(s["files"]) for s in plan["steps"]], [2, 1])
        self.assertEqual([f["path"] for s in plan["steps"] for f in s["files"]], [f["path"] for f in data["files"]])
        self.assertEqual(plan["steps"][0]["estimated_seconds"], 1180)
        self.assertTrue(all(s["estimated_seconds"] <= 1200 and s["cad_starts"] <= 3 for s in plan["steps"]))
        self.assertEqual(plan["status"], "draft")
        self.assertFalse(plan["execution_authorized"])

    def test_start_count_not_bytes_limits_group(self):
        data = self.inventory(item("001.dwg", 10, 2), item("002.dwg", 10, 2))
        before = copy.deepcopy(data)
        first = p.build_plan(data)
        self.assertEqual(len(first["steps"]), 2)
        self.assertEqual(data, before)
        data["files"][0]["size_bytes"] = 99999999999
        self.assertEqual(p.build_plan(data), first)

    def test_stable_ids_and_changed_content_policy_or_estimates(self):
        data = self.inventory(item("001.dwg"))
        first = p.build_plan(data)
        self.assertEqual(first, p.build_plan(copy.deepcopy(data)))
        for field, value in (("sha256", "b" * 64), ("sheet_count", 2), ("estimated_seconds", 201)):
            changed = copy.deepcopy(data);changed["files"][0][field] = value
            self.assertNotEqual(first["plan_id"], p.build_plan(changed)["plan_id"])
        self.assertNotEqual(first["plan_id"], p.build_plan(data, reserve_seconds=181)["plan_id"])

    def test_unknown_estimates_no_guess_or_partial_steps(self):
        for key in ("estimated_seconds", "sheet_count", "cad_starts", "estimate_basis"):
            data = self.inventory(item("001.dwg"), item("002.dwg"));data["files"][1].pop(key)
            plan = p.build_plan(data)
            self.assertEqual(plan["status"], "needs_input");self.assertEqual(plan["steps"], [])
            self.assertEqual(plan["questions"][0]["file_index"], 1)

    def test_oversized_file_requests_package_split_not_larger_timeout(self):
        for seconds, starts in ((1021, 1), (10, 4)):
            plan = p.build_plan(self.inventory(item("001.dwg", seconds, starts)))
            self.assertEqual(plan["status"], "needs_input")
            self.assertEqual(plan["steps"], [])
            self.assertEqual(plan["questions"][0]["reason"], "single_file_needs_package_split_or_review")

    def test_boolean_nonfinite_negative_and_huge_costs_are_not_estimates(self):
        for cost in (True, 0, -1, float("inf"), float("nan"), 10 ** 1000):
            self.assertEqual(p.build_plan(self.inventory(item("001.dwg", cost)))["status"], "needs_input")

    def test_invalid_paths_hashes_duplicates_and_policy(self):
        for path in ("/a.dwg", "../a.dwg", "x/../a.dwg", "C:/a.dwg", "x\\a.dwg", "x//a.dwg", "x /a.dwg", "a.txt"):
            with self.subTest(path=path), self.assertRaises(p.PlanError):p.build_plan(self.inventory(item(path)))
        with self.assertRaises(p.PlanError):p.build_plan(self.inventory(item("A.dwg"), item("a.dwg")))
        for sha in (None, "abc", "A" * 64):
            data = self.inventory(item("001.dwg"));data["files"][0]["sha256"] = sha
            with self.assertRaises(p.PlanError):p.build_plan(data)
        for policy in ({"budget_seconds": 1201}, {"max_cad_starts": 4}, {"reserve_seconds": 1200}, {"budget_seconds": True}):
            with self.assertRaises(p.PlanError):p.build_plan(self.inventory(item("001.dwg")), **policy)

    def test_cli_new_output_only(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root);source = root / "inventory.json";out = root / "plan.json"
            source.write_text(json.dumps(self.inventory(item("001.dwg"))), encoding="utf-8")
            self.assertEqual(p.main([str(source), "--output", str(out)]), 0)
            before = out.read_bytes();self.assertEqual(p.main([str(source), "--output", str(out)]), 2)
            self.assertEqual(out.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
