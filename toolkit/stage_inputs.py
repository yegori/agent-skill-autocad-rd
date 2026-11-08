"""Explicit snapshot/working-copy staging. No dependency discovery, CAD execution, approval or reuse."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import uuid

_spec = importlib.util.spec_from_file_location("rd_resource", Path(__file__).with_name("resource_inventory.py"))
r = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r)


class StageError(Exception):
    pass


def relative(value):
    if (not isinstance(value, str) or not value or value.startswith("/") or ":" in value or "\\" in value
            or any(ord(c) < 32 for c in value)
            or any(p in ("", ".", "..") or p.endswith((" ", ".")) for p in value.split("/"))):
        raise StageError("invalid_stage_relative_path")
    return value


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise StageError("invalid_stage_hash")
    return value


def validate_spec(spec):
    if (not isinstance(spec, dict) or type(spec.get("schema_version")) is not int or spec["schema_version"] != 1
            or spec.get("coverage") != "explicit_not_discovered" or not isinstance(spec.get("files"), list)
            or not spec["files"] or not isinstance(spec.get("environment"), list)
            or not isinstance(spec.get("plot_options"), dict)):
        raise StageError("invalid_explicit_stage_spec")
    sha(spec.get("plan_id"))
    try:
        if str(uuid.UUID(spec["step_id"])) != spec["step_id"]:
            raise ValueError()
    except (KeyError, ValueError, TypeError, AttributeError):
        raise StageError("invalid_stage_step_id") from None
    seen, drawings = set(), 0
    for item in spec["files"]:
        if not isinstance(item, dict) or item.get("role") not in ("drawing", "project_dependency"):
            raise StageError("invalid_stage_file_role")
        path = relative(item.get("path"));sha(item.get("sha256"))
        if path.casefold() in seen:
            raise StageError("duplicate_stage_path")
        seen.add(path.casefold())
        if item["role"] == "drawing":
            drawings += 1
            if not path.casefold().endswith(".dwg"):
                raise StageError("stage_drawing_requires_dwg")
    if not 1 <= drawings <= 3:
        raise StageError("stage_drawing_limit")
    seen = set()
    for item in spec["environment"]:
        if (not isinstance(item, dict) or not isinstance(item.get("root"), str)
                or not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", item["root"])):
            raise StageError("invalid_environment_binding")
        path = relative(item.get("path"));sha(item.get("sha256"))
        key = (item["root"], path.casefold())
        if key in seen:
            raise StageError("duplicate_environment_binding")
        seen.add(key)
    # Reject non-JSON values/NaN; options are a fingerprint, not interpreted executable arguments.
    json.dumps(spec, ensure_ascii=False, allow_nan=False)


def manifest_id(body):
    return hashlib.sha256(json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")).hexdigest()


def check_originals(body):
    spec = body["spec"];source = Path(body["source_root"]).resolve(strict=True)
    for item in spec["files"]:
        if r.digest(r.checked_file(source, item["path"])) != item["sha256"]:
            raise StageError("stage_source_changed")
    roots = body["environment_roots"]
    if not isinstance(roots, dict):
        raise StageError("invalid_environment_roots")
    for item in spec["environment"]:
        if item["root"] not in roots or not isinstance(roots[item["root"]], str):
            raise StageError("environment_root_missing")
        root = Path(roots[item["root"]]).resolve(strict=True)
        if r.digest(r.checked_file(root, item["path"])) != item["sha256"]:
            raise StageError("environment_binding_changed")


def prepare(spec, source_root, environment_roots, destination):
    validate_spec(spec)
    source = Path(source_root).resolve(strict=True);dest = Path(destination).resolve()
    if (dest.is_relative_to(source) or source.is_relative_to(dest)
            or dest.is_relative_to(Path(__file__).resolve().parents[1])):
        raise StageError("stage_destination_overlap")
    roots = {name: str(Path(value).resolve(strict=True)) for name, value in environment_roots.items()}
    for value in roots.values():
        root = Path(value)
        if dest.is_relative_to(root) or root.is_relative_to(dest):
            raise StageError("stage_environment_overlap")
    body = {"schema_version": 1, "kind": "explicit_input_stage", "source_root": str(source),
            "environment_roots": roots, "spec": spec, "execution_authorized": False}
    check_originals(body)
    dest.mkdir(parents=True, exist_ok=False)  # No existing stage, retry, clean or overwrite.
    path = dest / "manifest.json"
    with path.open("x", encoding="utf-8") as stream:
        json.dump({"status": "preparing", **body}, stream, ensure_ascii=False, indent=2)
    for tree in ("snapshot", "working"):
        for item in spec["files"]:
            original = r.checked_file(source, item["path"])
            target = dest / tree / item["path"];target.parent.mkdir(parents=True, exist_ok=True)
            with original.open("rb") as src, target.open("xb") as out:
                shutil.copyfileobj(src, out)
            if r.digest(target) != item["sha256"]:
                raise StageError("stage_copy_hash_mismatch")
    check_originals(body)  # Catch input/environment changes during copying.
    result = {"status": "prepared", "stage_id": manifest_id(body), **body}
    temp = dest / "manifest.prepared.tmp"
    with temp.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2, allow_nan=False);stream.write("\n")
    os.replace(temp, path)  # Only our newly-created metadata, never a user document.
    verify(dest, expected_stage_id=result["stage_id"])
    return result


def tree_files(root):
    pending, actual = [root], set()
    while pending:
        path = pending.pop();info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise StageError("stage_reparse_point")
        if stat.S_ISDIR(info.st_mode):
            pending.extend(path.iterdir())  # Inspect each entry BEFORE descending into it.
        elif stat.S_ISREG(info.st_mode):
            actual.add(path.relative_to(root).as_posix())
        else:
            raise StageError("stage_non_regular_file")
    return actual


def verify(destination, *, expected_stage_id=None, allow_work_changes=False):
    dest = Path(destination).resolve(strict=True)
    path = r.checked_file(dest, "manifest.json")
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    if (not isinstance(data, dict) or data.get("status") != "prepared" or data.get("kind") != "explicit_input_stage"
            or type(data.get("schema_version")) is not int or data["schema_version"] != 1
            or data.get("execution_authorized") is not False):
        raise StageError("stage_not_prepared")
    validate_spec(data.get("spec"))
    body = {key: value for key, value in data.items() if key not in ("status", "stage_id")}
    if manifest_id(body) != data.get("stage_id") or (expected_stage_id is not None and data["stage_id"] != expected_stage_id):
        raise StageError("stage_manifest_identity_mismatch")
    check_originals(body)
    expected = {item["path"] for item in data["spec"]["files"]};changes = []
    for tree in ("snapshot", "working"):
        root = dest / tree
        actual = tree_files(root)
        if actual != expected:
            raise StageError("stage_file_set_changed")
        for item in data["spec"]["files"]:
            candidate = r.checked_file(root, item["path"])
            if r.digest(candidate) != item["sha256"]:
                if tree == "working" and allow_work_changes is True:
                    changes.append(item["path"])
                else:
                    raise StageError("stage_immutable_or_working_changed")
    return {"status": "verified", "stage_id": data["stage_id"], "working_changes": changes,
            "coverage": "explicit_not_discovered", "execution_authorized": False}


def main(argv=None):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("prepare");create.add_argument("spec", type=Path)
    create.add_argument("--source-root", type=Path, required=True)
    create.add_argument("--environment-roots", type=Path, required=True, help="Local JSON mapping of authorized roots")
    create.add_argument("--destination", type=Path, required=True)
    check = sub.add_parser("verify");check.add_argument("destination", type=Path)
    check.add_argument("--expected-stage-id");check.add_argument("--allow-work-changes", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            result = prepare(json.loads(args.spec.read_text(encoding="utf-8-sig")), args.source_root,
                             json.loads(args.environment_roots.read_text(encoding="utf-8-sig")), args.destination)
            result = {key: result[key] for key in ("status", "stage_id", "execution_authorized")}
        else:
            result = verify(args.destination, expected_stage_id=args.expected_stage_id, allow_work_changes=args.allow_work_changes)
    except (StageError, r.InventoryError, OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        print(json.dumps({"status": "failed", "error": str(exc) if isinstance(exc, (StageError, r.InventoryError)) else "stage_io_or_schema_error"}))
        return 2
    print(json.dumps(result, ensure_ascii=False));return 0


if __name__ == "__main__":
    raise SystemExit(main())
