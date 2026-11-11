"""Offline cover contract/path preflight. Never imports COM or opens DOC contents.

A passing plan is NOT permission to execute Word or publish a document.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


class PreflightError(ValueError):
    pass


def _path(value: object) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise PreflightError("path_required")
    # Local stable filesystem only; exclude devices, UNC, ADS and wildcard expansion.
    if value.startswith(("\\\\", "//")) or any(c in value for c in "*?\x00"):
        raise PreflightError("local_literal_path_required")
    # Check original spelling BEFORE abspath can erase aliases such as 'bad.\\..'.
    spelling = value.replace("\\", "/")
    if re.match(r"^[A-Za-z]:($|[^/])", spelling):
        raise PreflightError("drive_relative_forbidden")
    for component in spelling.split("/"):
        if component in ("", ".", "..") or re.fullmatch(r"[A-Za-z]:", component):
            continue
        if component.endswith((".", " ")):
            raise PreflightError("windows_component_alias_forbidden")
        stem = component.split(".", 1)[0].rstrip(" .").upper()
        if re.fullmatch(r"CON|PRN|AUX|NUL|CLOCK\$|CONIN\$|CONOUT\$|COM[0-9¹²³]+|LPT[0-9¹²³]+", stem):
            raise PreflightError("windows_device_name_forbidden")
        if any(c in component for c in '<>"|:') or any(ord(c) < 32 for c in component):
            raise PreflightError("windows_component_forbidden")
    path = Path(os.path.abspath(value))
    if os.name == "nt" and ":" in str(path)[2:]:
        raise PreflightError("alternate_stream_forbidden")
    return path


def _ordinary_chain(path: Path) -> None:
    # lstat before traversing each child; never resolve a link to an allowed target.
    for part in [*reversed(path.parents), path]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            raise PreflightError("path_missing") from None
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise PreflightError("link_or_reparse_forbidden")
        if part != path and not stat.S_ISDIR(info.st_mode):
            raise PreflightError("parent_not_directory")
        if stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
            raise PreflightError("hardlink_forbidden")


def _fingerprint(info: os.stat_result) -> tuple:
    # Windows pathname stat and handle fstat may expose different ctime semantics.
    # Compare ctime only within the same acquisition method below.
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_nlink)


def source_hash(path: Path) -> str:
    _ordinary_chain(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size == 0:
        raise PreflightError("nonempty_regular_source_required")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        opened = os.fstat(source.fileno())
        if _fingerprint(before) != _fingerprint(opened):
            raise PreflightError("source_changed")
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
        after = os.fstat(source.fileno())
    _ordinary_chain(path)
    end = path.lstat()
    if (_fingerprint(before) != _fingerprint(after)
            or _fingerprint(after) != _fingerprint(end)
            or before.st_ctime_ns != end.st_ctime_ns
            or opened.st_ctime_ns != after.st_ctime_ns):
        raise PreflightError("source_changed")
    return digest.hexdigest()


def preflight(request: dict) -> dict:
    if not isinstance(request, dict):
        raise PreflightError("object_required")
    if request.get("force"):
        raise PreflightError("force_overwrite_removed")
    expected_sha = request.get("template_sha256", "")
    if not isinstance(expected_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha):
        raise PreflightError("explicit_template_sha256_required")
    template = _path(request.get("template"))
    out = _path(request.get("out"))
    pdf = _path(request["pdf"]) if request.get("pdf") else None
    if template.suffix.lower() not in (".doc", ".docx") or out.suffix.lower() != template.suffix.lower():
        raise PreflightError("matching_doc_or_docx_extension_required")
    if pdf and pdf.suffix.lower() != ".pdf":
        raise PreflightError("pdf_extension_required")
    outputs = [out] + ([pdf] if pdf else [])
    names = [os.path.normcase(str(p)) for p in [template, *outputs]]
    if len(set(names)) != len(names):
        raise PreflightError("source_output_alias")
    _ordinary_chain(template)
    for output in outputs:
        _ordinary_chain(output.parent)
        if not output.parent.is_dir():
            raise PreflightError("output_parent_not_directory")
        # lexists includes dangling links; no filesystem writes even for empty parents.
        if os.path.lexists(output):
            raise PreflightError("output_exists")
    replacements = request.get("replace", {})
    counts = request.get("expected_counts", {})
    if not isinstance(replacements, dict) or not isinstance(counts, dict):
        raise PreflightError("replacement_maps_required")
    if set(replacements) != set(counts):
        raise PreflightError("exact_expected_count_keys_required")
    passthrough = request.get("passthrough_draft", False)
    if type(passthrough) is not bool:
        raise PreflightError("passthrough_must_be_boolean")
    if bool(replacements) == passthrough:
        raise PreflightError("choose_replacements_or_explicit_passthrough_draft")
    for old, new in replacements.items():
        if not isinstance(old, str) or not old or not isinstance(new, str) or old == new:
            raise PreflightError("nonempty_literal_change_required")
        if type(counts[old]) is not int or counts[old] < 1:
            raise PreflightError("positive_expected_count_required")
    actual_sha = source_hash(template)
    if actual_sha.lower() != expected_sha.lower():
        raise PreflightError("source_hash_mismatch")
    return {
        "status": "preflight_only", "execution_authorized": False,
        "native_generation_available": False, "engineering_approved": False,
        "draft": True, "template": str(template), "template_sha256": actual_sha,
        "out": str(out), "pdf": str(pdf) if pdf else None,
        "mode": "passthrough_draft" if passthrough else "explicit_replacements",
        "replacements": [{"old": old, "new": new, "expected": counts[old],
                          "observed": None, "postflight": None}
                         for old, new in replacements.items()],
        "coverage": "not_read_no_word_stories_checked",
        "blocker": "legacy_cover_native_disabled_explicit_draft_candidate_required",
    }


def _unique_object(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise PreflightError("duplicate_json_key")
        result[key] = value
    return result


def main() -> int:
    try:
        result = preflight(json.load(sys.stdin, object_pairs_hook=_unique_object))
    except (ValueError, OSError) as error:
        print(json.dumps({"status": "failed", "error": str(error)}, ensure_ascii=True))
        return 1
    print(json.dumps(result, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
