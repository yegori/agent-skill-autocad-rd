import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("resource_inventory", Path(__file__).resolve().parents[1] / "toolkit/resource_inventory.py")
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


class ResourceInventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve();self.inputs = self.root / "input";self.inputs.mkdir()
        self.evidence = self.root / "evidence";self.evidence.mkdir()
        self.report = {"schema_version": 1, "kind": "paper_resource_probe", "status": "observed", "error": None,
                       "requested_files": 2, "files": []}
        for n in (1, 2):
            path = f"00{n}.dwg";(self.inputs / path).write_bytes(b"non-DWG fixture only")
            raw = self.evidence / f"{n}.txt";raw.write_text("Layout1|ISO_A4|DWG To PDF.pc3\n", encoding="utf-8")
            log = self.evidence / f"{n}.log";log.write_text("normal exit", encoding="utf-8")
            h = lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
            self.report["files"].append({"path": path, "sha256": h(self.inputs/path), "status": "observed", "exit_code": 0,
                "cad_starts": 1, "elapsed_seconds": 10.0*n, "layout_count": 1,
                "layouts": [{"name": "Layout1", "paper": "ISO_A4", "device": "DWG To PDF.pc3", "paper_status": "standard_unverified"}],
                "raw_metadata": str(raw), "raw_metadata_sha256": h(raw), "raw_log": str(log), "raw_log_sha256": h(log)})

    def build(self, **kwargs):return p.build_inventory(self.report, self.inputs, self.evidence, **kwargs)

    def test_real_hash_evidence_order_and_conservative_cost(self):
        before = copy.deepcopy(self.report);data = self.build()
        self.assertEqual([f["path"] for f in data["files"]], ["001.dwg", "002.dwg"])
        self.assertEqual([f["estimated_seconds"] for f in data["files"]], [80.0, 100.0])
        self.assertEqual([f["cad_starts"] for f in data["files"]], [2, 2])
        self.assertFalse(data["execution_authorized"]);self.assertFalse(data["cost_policy"]["print_time_measured"])
        self.assertEqual(self.report, before)
        plan = p.planner.build_plan(data)
        self.assertEqual(len(plan["steps"]), 2);self.assertEqual(plan["status"], "draft")

    def test_controlled_read_requires_explicit_live_root_marker_and_verified_cleanup(self):
        record = self.report['files'][0]
        record.update(completion_mode='owned_job_after_metadata', exit_code=None,
                      controlled_cleanup_verified=True, root_alive_before_stop=True)
        log = self.evidence/'1.log';log.write_text('ALLDONE\n', encoding='utf-8')
        record['raw_log_sha256'] = hashlib.sha256(log.read_bytes()).hexdigest()
        self.assertEqual(self.build()['status'], 'draft_inventory')
        for key, value in (('controlled_cleanup_verified', False), ('root_alive_before_stop', 1), ('exit_code', -1073741819)):
            old = record[key];record[key] = value
            with self.assertRaises(p.InventoryError):self.build()
            record[key] = old
        log.write_text('incomplete', encoding='utf-8');record['raw_log_sha256'] = hashlib.sha256(log.read_bytes()).hexdigest()
        with self.assertRaisesRegex(p.InventoryError, 'completion_marker_invalid'):self.build()

    def test_sizes_do_not_replace_measurement_or_change_estimate(self):
        before = self.build();self.report["files"][0]["size_bytes"] = 999999999
        self.assertEqual(before, self.build())
        self.report["files"][0]["elapsed_seconds"] = None
        with self.assertRaisesRegex(p.InventoryError, "execution_unproven"):self.build()

    def test_changed_source_or_raw_evidence_refused(self):
        for path in (self.inputs/"001.dwg", self.evidence/"1.txt", self.evidence/"1.log"):
            before = path.read_bytes();path.write_bytes(b"changed")
            with self.assertRaises(p.InventoryError):self.build()
            path.write_bytes(before)

    def test_device_and_unknown_custom_formats_block_all_not_silent_skip(self):
        layout = self.report["files"][1]["layouts"][0];layout["paper_status"] = "unknown"
        data = self.build();self.assertEqual(data["status"], "needs_input");self.assertEqual(data["files"], [])
        selected = self.build(selected_paths=["001.dwg"])
        self.assertEqual([f["path"] for f in selected["files"]], ["001.dwg"])
        layout["paper_status"] = "standard_unverified";layout["device"] = "other.pc3"
        raw = self.evidence/"2.txt";raw.write_text("Layout1|ISO_A4|other.pc3\n", encoding="utf-8")
        self.report["files"][1]["raw_metadata_sha256"] = hashlib.sha256(raw.read_bytes()).hexdigest()
        self.assertEqual(self.build()["status"], "needs_input")

    def test_metadata_count_and_rows_must_match_not_human_console(self):
        self.report["files"][0]["layout_count"] = 2
        with self.assertRaisesRegex(p.InventoryError, "count_invalid"):self.build()
        self.report["files"][0]["layout_count"] = 1
        self.report["files"][0]["layouts"][0]["name"] = "invented"
        with self.assertRaisesRegex(p.InventoryError, "metadata_invalid"):self.build()

    def test_incomplete_nonzero_exit_bool_and_duplicates_refuse(self):
        for change in ({"status": "failed"}, {"requested_files": 3}, {"schema_version": True}):
            before = copy.deepcopy(self.report);self.report.update(change)
            with self.assertRaises(p.InventoryError):self.build()
            self.report = before
        for key, value in (("exit_code", 1), ("exit_code", False), ("cad_starts", True), ("elapsed_seconds", float("inf"))):
            before = copy.deepcopy(self.report);self.report["files"][0][key] = value
            with self.assertRaises(p.InventoryError):self.build()
            self.report = before
        self.report["files"][1]["path"] = "001.dwg"
        with self.assertRaises(p.InventoryError):self.build()

    def test_paths_cannot_escape_inputs_or_evidence(self):
        for key, value in (("path", "../001.dwg"), ("path", "C:/001.dwg"), ("raw_log", str(self.inputs/"001.dwg"))):
            before = copy.deepcopy(self.report);self.report["files"][0][key] = value
            with self.assertRaises(p.InventoryError):self.build()
            self.report = before

    def test_explicit_selection_and_policy(self):
        data = self.build(selected_paths=["002.dwg", "001.dwg"])
        self.assertEqual([f["path"] for f in data["files"]], ["002.dwg", "001.dwg"])
        for selection in ([], ["missing.dwg"], ["001.dwg", "001.dwg"]):
            with self.assertRaises(p.InventoryError):self.build(selected_paths=selection)
        for kwargs in ({"load_factor": True}, {"seconds_per_sheet": float("nan")}, {"seconds_per_sheet": 0}):
            with self.assertRaises(p.InventoryError):self.build(**kwargs)

    def test_cli_keeps_existing_output_and_refuses_input_output(self):
        report = self.root/"probe.json";report.write_text(json.dumps(self.report), encoding="utf-8")
        output, plan = self.root/"inventory.json", self.root/"plan.json"
        args = [str(report), "--input-root", str(self.inputs), "--evidence-root", str(self.evidence),
                "--output", str(output), "--plan-output", str(plan)]
        self.assertEqual(p.main(args), 0);before = output.read_bytes(), plan.read_bytes()
        self.assertEqual(p.main(args), 2);self.assertEqual(before, (output.read_bytes(), plan.read_bytes()))
        args[args.index("--output")+1] = str(self.inputs/"new.json")
        self.assertEqual(p.main(args), 2);self.assertFalse((self.inputs/"new.json").exists())


if __name__ == "__main__":unittest.main()
