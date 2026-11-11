"""Guarded draft candidate. Native availability/layout acceptance is coordinator-only.
No COM factory: the private native host owns direct Word and accesses only its HWND.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

# -I excludes the script directory; import the adjacent package-owned module explicitly.
import importlib.util
_spec = importlib.util.spec_from_file_location("cover_preflight", Path(__file__).with_name("cover_preflight.py"))
pre = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pre)


def validate(request):
    plan = pre.preflight(request)
    if not plan["pdf"]:
        raise pre.PreflightError("draft_requires_doc_and_pdf")
    exe = pre._path(request.get("word_exe"))
    if exe.name.upper() != "WINWORD.EXE":
        raise pre.PreflightError("explicit_winword_exe_required")
    digest = request.get("word_sha256")
    if not isinstance(digest, str) or pre.source_hash(exe).lower() != digest.lower():
        raise pre.PreflightError("word_binary_hash_mismatch")
    work = pre._path(request.get("work_parent"))
    pre._ordinary_chain(work)
    if not work.is_dir():
        raise pre.PreflightError("work_parent_not_directory")
    for key, limit in (("expected_pages", 1000), ("timeout_sec", 3600), ("pane_timeout_sec", 120)):
        value = request.get(key)
        if type(value) is not int or not 1 <= value <= limit:
            raise pre.PreflightError("explicit_positive_" + key + "_required")
    if request["pane_timeout_sec"] > request["timeout_sec"]:
        raise pre.PreflightError("pane_timeout_exceeds_total")
    olds = list(request.get("replace", {}))
    for old, new in request.get("replace", {}).items():
        # No Find caret syntax/control characters, field/table/paragraph boundary edits.
        if any(c in old + new for c in "^\r\n\t\x00\x07\x0b\x0c\x13\x14\x15") or not new:
            raise pre.PreflightError("unsupported_literal_token")
        if any(other in new for other in olds):
            raise pre.PreflightError("cascading_map_forbidden")
        if any(other != old and (old in other or other in old) for other in olds):
            raise pre.PreflightError("overlapping_map_forbidden")
    return plan, exe, work


def write_json_new(path, data):
    with Path(path).open("x", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=True, indent=2)


def copy_new(source, destination):
    pre._ordinary_chain(Path(source))
    pre._ordinary_chain(Path(destination).parent)
    with Path(source).open("rb") as incoming, Path(destination).open("xb") as outgoing:
        shutil.copyfileobj(incoming, outgoing)
        outgoing.flush()
        os.fsync(outgoing.fileno())


def run_native(config, config_path):
    if os.name != "nt":
        raise RuntimeError("interactive_windows_sta_required")
    host = Path(__file__).with_name("cover_native_host.ps1")
    log = Path(config_path).parent / "host.log"
    with log.open("xb") as output:
        process = subprocess.Popen(["pwsh", "-NoProfile", "-STA", "-File", str(host),
                                    "-ConfigPath", str(config_path)], stdout=output, stderr=output)
        try:
            code = process.wait(timeout=config["timeout_sec"] + 90)
        except subprocess.TimeoutExpired:
            # Never infer cleanup from a host timeout or kill Word by PID/name.
            # Own native watchdog may stop its Job; without returned evidence it is uncertain.
            raise RuntimeError("native_host_timeout_cleanup_uncertain_no_publication") from None
    if not Path(config["native_result"]).is_file():
        raise RuntimeError("native_result_missing_cleanup_uncertain")
    result = json.loads(Path(config["native_result"]).read_text(encoding="utf-8-sig"))
    if code != 0:
        raise RuntimeError("native_failed: " + json.dumps(result, ensure_ascii=True))
    return result


def generate(request, *, backend=None, pdf_validator=None, publisher=copy_new):
    """Injected inert backend/validator are for unit tests, never selectable by CLI."""
    plan, exe, work = validate(request)
    if backend is None:
        if os.name != "nt":
            raise RuntimeError("interactive_windows_sta_required")
        backend = run_native
    if pdf_validator is None:
        import fitz  # Required installed module. No fallback/install/availability waiver.
        def pdf_validator(path, pages):
            with fitz.open(path) as document:
                if document.needs_pass or document.page_count != pages or pages < 1:
                    raise RuntimeError("pdf_page_or_password_mismatch")
                for page in document:
                    if page.rect.is_empty or page.rect.is_infinite:
                        raise RuntimeError("pdf_invalid_page")
    run = Path(tempfile.mkdtemp(prefix="cover-draft-", dir=work))
    result = {"status": "failed", "draft": True, "engineering_approved": False,
              "native_accepted": False, "run_dir": str(run), "published": [],
              "coverage": "pending", "template_sha256": plan["template_sha256"]}
    try:
        (run / "snapshot").mkdir(); (run / "generated").mkdir()
        snapshot = run / "snapshot" / Path(plan["template"]).name
        doc = run / "generated" / Path(plan["out"]).name
        pdf = run / "generated" / Path(plan["pdf"]).name
        if doc == pdf:
            raise RuntimeError("private_output_alias")
        copy_new(plan["template"], snapshot)
        if pre.source_hash(snapshot) != plan["template_sha256"]:
            raise RuntimeError("snapshot_hash_mismatch")
        # Recheck both outputs/source and approved binary AFTER snapshot, before direct launch.
        validate(request)
        config = dict(request, template=plan["template"], word_exe=str(exe),
                      replace=request.get("replace", {}), expected_counts=request.get("expected_counts", {}),
                      template_sha256=plan["template_sha256"], snapshot=str(snapshot), doc=str(doc), pdf=str(pdf),
                      native_result=str(run / "native-result.json"), audit=str(run / "phase.log"))
        config_path = run / "native-config.json"
        write_json_new(config_path, config)
        native = backend(config, config_path)
        result["native"] = native
        if (native.get("status") != "controlled_draft_closed_and_stopped"
                or native.get("cleanup_verified") is not True
                or native.get("root_live_before_stop") is not True
                or native.get("timed_out") is not False
                or native.get("document", {}).get("document_closed") is not True
                or native.get("ownership", {}).get("identity_verified") is not True):
            raise RuntimeError("native_completion_or_cleanup_unproven")
        # Never accept a passthrough claim as actual observed replacement evidence.
        if request.get("replace"):
            counts = native["document"].get("replacement_counts", [])
            observed = {item["old"]: item for item in counts}
            if len(observed) != len(counts) or set(observed) != set(request["replace"]):
                raise RuntimeError("replacement_evidence_missing")
            for old in request["replace"]:
                if (observed[old].get("observed") != request["expected_counts"][old]
                        or observed[old].get("postflight") != "exact_main_text_transform_verified"):
                    raise RuntimeError("replacement_evidence_mismatch")
        for unchanged in (Path(plan["template"]), snapshot):
            if pre.source_hash(unchanged) != plan["template_sha256"]:
                raise RuntimeError("source_or_snapshot_changed")
        if pre.source_hash(exe).lower() != request["word_sha256"].lower():
            raise RuntimeError("word_binary_changed")
        artifacts = {"doc": pre.source_hash(doc), "pdf": pre.source_hash(pdf)}
        if native.get("closed_artifact_sha256") != artifacts:
            raise RuntimeError("closed_output_hash_binding_mismatch")
        pdf_validator(pdf, request["expected_pages"])
        validate(request)  # Both destinations absent and all paths still ordinary.
        result.update(artifact_sha256=artifacts, expected_pages=request["expected_pages"],
                      coverage=native["document"].get("coverage"))
        for kind, source, target in (("doc", doc, Path(plan["out"])), ("pdf", pdf, Path(plan["pdf"]))):
            pre._ordinary_chain(target.parent)
            result["publication_attempt"] = str(target)
            if os.path.lexists(target):
                raise RuntimeError("publication_collision_" + kind)
            publisher(source, target)  # exclusive create, never replaces; pair is NOT atomic.
            result["published"].append(str(target))
            if pre.source_hash(target) != artifacts[kind]:
                raise RuntimeError("published_hash_mismatch_" + kind)
        result.pop("publication_attempt", None)
        result["status"] = "draft_generated_pending_coordinator_qa"
    except Exception as error:
        result["error"] = str(error)
    write_json_new(run / "result.json", result)
    return result


def main():
    try:
        request = json.load(sys.stdin, object_pairs_hook=pre._unique_object)
        result = generate(request)
    except (ValueError, OSError, RuntimeError, ImportError) as error:
        result = {"status": "failed", "error": str(error), "native_accepted": False}
    print(json.dumps(result, ensure_ascii=True, indent=2))
    return 0 if result["status"] == "draft_generated_pending_coordinator_qa" else 1


if __name__ == "__main__":
    raise SystemExit(main())
