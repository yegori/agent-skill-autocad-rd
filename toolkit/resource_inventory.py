"""Validate a bounded paper-resource probe and produce a conservative, unauthorized PDF inventory."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys

_spec = importlib.util.spec_from_file_location("rd_stage_plan", Path(__file__).with_name("plan_stages.py"))
planner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(planner)


class InventoryError(Exception):
    pass


def number(value):
    try:
        return type(value) in (int, float) and math.isfinite(value) and value > 0
    except (OverflowError, ValueError):
        return False


def checked_file(root, value):
    if not isinstance(value, str) or not value:
        raise InventoryError("invalid_probe_path")
    path = Path(value)
    if not path.is_absolute():
        path = root / path
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root) or resolved == root or not resolved.is_file():
        raise InventoryError("probe_path_outside_root")
    # Resolve containment alone does not reject links pointing back inside the authorized root.
    for item in (path, *path.parents):
        if item.is_symlink() or (getattr(item, "is_junction", lambda: False)()):
            raise InventoryError("probe_reparse_point")
        if item == root:
            break
    return resolved


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build_inventory(report, input_root, evidence_root, *, selected_paths=None, load_factor=2.0, seconds_per_sheet=60.0):
    root, evidence = Path(input_root).resolve(strict=True), Path(evidence_root).resolve(strict=True)
    if (not number(load_factor) or not 1 <= load_factor <= 10 or not number(seconds_per_sheet)
            or not 1 <= seconds_per_sheet <= 600):
        raise InventoryError("invalid_conservative_cost_policy")
    if (not isinstance(report, dict) or type(report.get("schema_version")) is not int or report["schema_version"] != 1
            or report.get("kind") != "paper_resource_probe" or report.get("status") != "observed"
            or report.get("error") is not None or not isinstance(report.get("files"), list)
            or not 1 <= len(report["files"]) <= 3 or type(report.get("requested_files")) is not int
            or report["requested_files"] != len(report["files"])):
        raise InventoryError("incomplete_resource_probe")
    records = {}
    for record in report["files"]:
        if not isinstance(record, dict):
            raise InventoryError("invalid_probe_record")
        rel = record.get("path")
        if (not isinstance(rel, str) or not rel or rel.startswith("/") or ":" in rel or "\\" in rel
                or any(part in ("", ".", "..") or part.endswith((" ", ".")) for part in rel.split("/"))
                or any(ord(c) < 32 for c in rel) or not rel.casefold().endswith(".dwg") or rel.casefold() in records):
            raise InventoryError("invalid_or_duplicate_probe_dwg")
        mode = record.get("completion_mode", "natural_exit")
        if mode not in ("natural_exit", "owned_job_after_metadata"):
            raise InventoryError("probe_completion_mode_invalid")
        controlled = mode == "owned_job_after_metadata"
        exit_proven = (record.get("exit_code") is None and record.get("controlled_cleanup_verified") is True
                       and record.get("root_alive_before_stop") is True) if controlled else (type(record.get("exit_code")) is int and record["exit_code"] == 0)
        if (record.get("status") != "observed" or not exit_proven
                or type(record.get("cad_starts")) is not int or record["cad_starts"] != 1 or not number(record.get("elapsed_seconds"))):
            raise InventoryError("probe_native_execution_unproven")
        source = checked_file(root, rel)
        if digest(source) != record.get("sha256"):
            raise InventoryError("probe_source_changed")
        raw = checked_file(evidence, record.get("raw_metadata"))
        log = checked_file(evidence, record.get("raw_log"))
        if digest(raw) != record.get("raw_metadata_sha256") or digest(log) != record.get("raw_log_sha256"):
            raise InventoryError("probe_evidence_changed")
        if controlled and log.read_text(encoding="utf-8-sig").strip() != "ALLDONE":
            raise InventoryError("probe_completion_marker_invalid")
        layouts = record.get("layouts")
        if (not isinstance(layouts, list) or not layouts or type(record.get("layout_count")) is not int
                or record["layout_count"] != len(layouts)):
            raise InventoryError("probe_layout_count_invalid")
        rows = [line.split("|") for line in raw.read_text(encoding="utf-8-sig").splitlines()]
        if any(len(row) != 3 for row in rows) or len(rows) != len(layouts):
            raise InventoryError("probe_layout_metadata_invalid")
        seen = set()
        for row, layout in zip(rows, layouts):
            if (not isinstance(layout, dict) or not row[0].strip() or row[0].casefold() in seen
                    or row != [layout.get("name"), layout.get("paper"), layout.get("device")]):
                raise InventoryError("probe_layout_metadata_invalid")
            seen.add(row[0].casefold())
        records[rel.casefold()] = record
    selection = list(records) if selected_paths is None else selected_paths
    if (not isinstance(selection, list) or not selection or any(not isinstance(x, str) for x in selection)
            or len({x.casefold() for x in selection}) != len(selection) or any(x.casefold() not in records for x in selection)):
        raise InventoryError("invalid_explicit_probe_selection")
    files, questions = [], []
    for index, key in enumerate(selection):
        record = records[key.casefold()]
        blockers = []
        for layout in record["layouts"]:
            paper, status = layout["paper"], layout.get("paper_status")
            if (not isinstance(paper, str) or not re.match(r"^(ISO|ANSI|ARCH)_", paper)
                    or status != "standard_unverified" or layout["device"].casefold() != "dwg to pdf.pc3"):
                blockers.append("paper_or_device_requires_review")
        if blockers:
            questions.append({"file_index": index, "reason": blockers[0]})
        count = record["layout_count"]
        files.append({"path": record["path"], "sha256": record["sha256"], "sheet_count": count, "cad_starts": 2,
                      "estimated_seconds": record["elapsed_seconds"] * load_factor + count * seconds_per_sheet,
                      "estimate_basis": "conservative", "measured_probe_seconds": record["elapsed_seconds"],
                      "sheet_count_basis": "all_paper_layouts_candidate_not_issue_selection"})
    return {"schema_version": 1, "operation": "pdf", "status": "needs_input" if questions else "draft_inventory",
            "files": [] if questions else files, "questions": questions, "execution_authorized": False,
            "cost_policy": {"load_factor": load_factor, "seconds_per_sheet": seconds_per_sheet,
                            "future_cad_starts_per_file": 2, "print_time_measured": False}}


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--plan-output", type=Path, required=True)
    parser.add_argument("--select", action="append")
    args = parser.parse_args(argv)
    try:
        for output in (args.output, args.plan_output):
            if output.resolve().is_relative_to(args.input_root.resolve()):
                raise InventoryError("inventory_output_inside_input")
            if output.exists():
                raise InventoryError("inventory_output_exists")
        if args.output.resolve() == args.plan_output.resolve():
            raise InventoryError("inventory_outputs_must_differ")
        inventory = build_inventory(json.loads(args.report.read_text(encoding="utf-8-sig")), args.input_root,
                                    args.evidence_root, selected_paths=args.select)
        plan = (planner.build_plan(inventory) if inventory["status"] == "draft_inventory" else
                {"schema_version": 1, "status": "needs_input", "steps": [], "questions": inventory["questions"], "execution_authorized": False})
        for path, value in ((args.output, inventory), (args.plan_output, plan)):
            with path.open("x", encoding="utf-8") as stream:
                json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
                stream.write("\n")
    except (InventoryError, planner.PlanError, OSError, ValueError) as exc:
        print(json.dumps({"status": "failed", "error": str(exc) if isinstance(exc, (InventoryError, planner.PlanError)) else "inventory_io_or_json_error"}))
        return 2
    print(json.dumps({"status": plan["status"], "steps": len(plan["steps"])}))
    return 3 if plan["status"] == "needs_input" else 0


if __name__ == "__main__":
    raise SystemExit(main())
