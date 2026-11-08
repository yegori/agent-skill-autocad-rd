"""Draft PDF stage producer for an explicit package-owned inventory. Never opens DWG or starts CAD."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import uuid


class PlanError(Exception):
    """Fixed diagnostic; never contains document text or paths."""


def positive_number(value):
    try:
        return type(value) in (int, float) and math.isfinite(value) and value > 0
    except (OverflowError, ValueError):
        return False


def build_plan(inventory, *, budget_seconds=1200, reserve_seconds=180, max_cad_starts=3):
    # Initial bounded pilot policy, not an unrestricted scheduler configuration.
    if (type(budget_seconds) is not int or not 1 <= budget_seconds <= 1200
            or type(reserve_seconds) is not int or not 0 <= reserve_seconds < budget_seconds
            or type(max_cad_starts) is not int or not 1 <= max_cad_starts <= 3):
        raise PlanError("invalid_stage_policy")
    if (not isinstance(inventory, dict) or type(inventory.get("schema_version")) is not int
            or inventory["schema_version"] != 1 or inventory.get("operation") != "pdf"
            or not isinstance(inventory.get("files"), list) or not inventory["files"]):
        raise PlanError("invalid_stage_inventory")
    files, seen, questions = [], set(), []
    for index, item in enumerate(inventory["files"]):
        if not isinstance(item, dict):
            raise PlanError("invalid_stage_file")
        path, sha = item.get("path"), item.get("sha256")
        if (not isinstance(path, str) or not path or path.startswith("/") or "\\" in path or ":" in path
                or any(ord(c) < 32 for c in path) or not path.casefold().endswith(".dwg")
                or any(part in ("", ".", "..") or part.endswith((" ", ".")) for part in path.split("/"))):
            raise PlanError("invalid_relative_dwg_path")
        if (path.casefold() in seen or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha)):
            raise PlanError("duplicate_path_or_invalid_source_hash")
        seen.add(path.casefold())
        sheet_count, starts, seconds = (item.get(k) for k in ("sheet_count", "cad_starts", "estimated_seconds"))
        basis = item.get("estimate_basis")
        if (type(sheet_count) is not int or sheet_count < 1 or type(starts) is not int or starts < 1
                or not positive_number(seconds) or basis not in ("measured", "conservative")):
            questions.append({"file_index": index, "reason": "sheet_start_time_estimate_required"})
        elif seconds + reserve_seconds > budget_seconds or starts > max_cad_starts:
            questions.append({"file_index": index, "reason": "single_file_needs_package_split_or_review"})
        files.append({"path": path, "sha256": sha, "sheet_count": sheet_count, "cad_starts": starts,
                      "estimated_seconds": seconds, "estimate_basis": basis})
    policy = {"budget_seconds": budget_seconds, "reserve_seconds": reserve_seconds, "max_cad_starts": max_cad_starts}
    # Unknown metadata gets no executable plan and no fabricated fallback from file size.
    if questions:
        return {"schema_version": 1, "operation": "pdf", "status": "needs_input", "policy": policy,
                "steps": [], "questions": questions, "execution_authorized": False}
    canonical = {"schema_version": 1, "operation": "pdf", "policy": policy, "files": files}
    plan_id = hashlib.sha256(json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")).hexdigest()
    steps, batch, seconds, starts = [], [], reserve_seconds, 0

    def emit():
        steps.append({"step_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "autocad-rd/pdf/" + plan_id + "/" + str(len(steps)))),
                      "files": list(batch), "estimated_seconds": seconds, "cad_starts": starts,
                      "sheet_count": sum(f["sheet_count"] for f in batch), "timeout_seconds": budget_seconds})

    for item in files:
        if batch and (seconds + item["estimated_seconds"] > budget_seconds or starts + item["cad_starts"] > max_cad_starts):
            emit()
            batch, seconds, starts = [], reserve_seconds, 0
        batch.append(item)
        seconds += item["estimated_seconds"]
        starts += item["cad_starts"]
    emit()
    return {"schema_version": 1, "operation": "pdf", "status": "draft", "plan_id": plan_id,
            "policy": policy, "steps": steps, "questions": [], "execution_authorized": False}


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        inventory = json.loads(args.inventory.read_text(encoding="utf-8-sig"))
        plan = build_plan(inventory)
        # New output only, no source/old-plan replacement or executor state manipulation.
        with args.output.open("x", encoding="utf-8") as output:
            json.dump(plan, output, ensure_ascii=False, indent=2, allow_nan=False)
            output.write("\n")
    except (PlanError, OSError, ValueError) as exc:
        print(json.dumps({"status": "failed", "error": str(exc) if isinstance(exc, PlanError) else "plan_io_or_json_error"}))
        return 2
    print(json.dumps({"status": plan["status"], "steps": len(plan["steps"])}))
    return 3 if plan["status"] == "needs_input" else 0


if __name__ == "__main__":
    raise SystemExit(main())
