// Distinct WRITE command, only under prepare_xref_copy.ps1. No document open or xref resolution.
// Offline candidate: real SDK compile and write/SaveAs acceptance are still required.
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Runtime;

public class RdPrepareXrefCopy {
    public class Mapping {
        public string handle { get; set; } public string name { get; set; }
        public string old_path { get; set; } public string new_path { get; set; }
        public string target { get; set; } public string target_sha256 { get; set; }
    }
    public class Request {
        public int schema_version { get; set; } public string source { get; set; }
        public string source_sha256 { get; set; } public string issue_root { get; set; }
        public string output { get; set; } public string report { get; set; }
        public string marker { get; set; } public Mapping[] mappings { get; set; }
    }
    class Record {
        public string Name, Path;
        public Record(string name, string path) { Name = name; Path = path; }
    }
    static void Require(bool ok, string error) { if (!ok) throw new InvalidOperationException(error); }
    static string Hash(string path) {
        using (var stream = File.OpenRead(path)) using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }
    static void NewText(string path, string text) {
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false))) writer.Write(text);
    }
    static void CheckFile(string path, string sha) {
        Require(File.Exists(path), "prepare_file_missing");
        for (string p = path; !String.IsNullOrEmpty(p); p = System.IO.Path.GetDirectoryName(p))
            Require((File.GetAttributes(p) & FileAttributes.ReparsePoint) == 0, "prepare_reparse");
        Require(Hash(path) == sha, "prepare_hash_changed");
    }
    static void Bindings(Request q) {
        CheckFile(q.source, q.source_sha256);
        string root = System.IO.Path.GetFullPath(q.issue_root).TrimEnd('\\') + "\\";
        string finalDir = System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(q.output));
        foreach (var m in q.mappings) {
            Require(!String.IsNullOrEmpty(m.new_path) && !System.IO.Path.IsPathRooted(m.new_path)
                && m.new_path.IndexOf(':') < 0 && m.new_path.IndexOf('/') < 0, "prepare_relative_required");
            string target = System.IO.Path.GetFullPath(System.IO.Path.Combine(finalDir, m.new_path));
            Require(target.StartsWith(root, StringComparison.OrdinalIgnoreCase)
                && String.Equals(target, m.target, StringComparison.OrdinalIgnoreCase), "prepare_target_outside_or_mismatch");
            CheckFile(target, m.target_sha256);
        }
    }
    static Dictionary<string, Record> Records(Database db, Transaction tr) {
        var result = new Dictionary<string, Record>(StringComparer.OrdinalIgnoreCase);
        var blocks = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
        foreach (ObjectId id in blocks) {
            var b = (BlockTableRecord)tr.GetObject(id, OpenMode.ForRead);
            if (b.IsFromExternalReference) result.Add(id.Handle.ToString(), new Record(b.Name, b.PathName));
        }
        return result;
    }
    static void Verify(Database db, Dictionary<string, Record> expected) {
        using (var tr = db.TransactionManager.StartOpenCloseTransaction()) {
            var actual = Records(db, tr);
            Require(actual.Count == expected.Count, "prepare_postflight_xref_count");
            foreach (var pair in expected) {
                Record row;
                Require(actual.TryGetValue(pair.Key, out row) && row.Name == pair.Value.Name
                    && row.Path == pair.Value.Path, "prepare_postflight_exact_table");
            }
        }
    }
    [CommandMethod("RDPREPAREXREFCOPY", CommandFlags.Session)]
    public void Run() {
        string requestPath = Environment.GetEnvironmentVariable("RDCI_PREPARE_REQUEST");
        // Independent of a possibly malformed request body; wrapper always supplies this private path.
        string failurePath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(
            System.IO.Path.GetFullPath(requestPath)), "native.failure.json");
        var json = new JavaScriptSerializer();
        string phase = "request_validation";
        try {
            Require(!File.Exists(failurePath), "prepare_previous_native_failure");
            Prepare(requestPath, json, ref phase);
        } catch (System.Exception error) {
            try {
                NewText(failurePath, json.Serialize(new { schema_version = 1, kind = "explicit_xref_copy_failure",
                    status = "failed", phase = phase, exception_type = error.GetType().FullName,
                    message = error.Message, execution_authorized = false }));
            } catch (System.Exception evidenceError) {
                // Preserve BOTH exceptions if evidence cannot be written; never overwrite earlier evidence.
                throw new AggregateException("prepare_native_failure_evidence_write_failed", error, evidenceError);
            }
            throw; // Do not swallow the API exception, retry, or emit a success marker.
        }
        // Only successful preparation reaches this distinct write-mode hold, never Lisp/QUIT.
        // All API work, DBs, report and marker are closed. Early root exit still fails in owner.
        while (true) System.Threading.Thread.Sleep(1000);
    }
    static void Prepare(string requestPath, JavaScriptSerializer json, ref string phase) {
        string requestSha = Hash(requestPath);
        var q = json.Deserialize<Request>(File.ReadAllText(requestPath, Encoding.UTF8));
        Require(q.schema_version == 1 && q.mappings != null && q.mappings.Length == 3, "prepare_exact_three");
        Require(!File.Exists(q.output) && !Directory.Exists(q.output), "prepare_output_exists");
        Require(System.IO.Path.GetFileName(q.source) == System.IO.Path.GetFileName(q.output), "prepare_filename_changed");
        var handles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var m in q.mappings) {
            Require(handles.Add(m.handle) && names.Add(m.name) && targets.Add(m.target)
                && !String.Equals(m.old_path, m.new_path, StringComparison.OrdinalIgnoreCase), "prepare_duplicate_or_noop");
        }
        phase = "binding_preflight";
        Bindings(q);
        Dictionary<string, Record> expected;
        int changed = 0;
        phase = "read_source";
        using (var db = new Database(false, true)) {
            // No DocumentManager.Open, WorkingDatabase assignment, FindFile or ResolveXrefs.
            db.ReadDwgFile(q.source, FileOpenMode.OpenForReadAndAllShare, true, "");
            db.CloseInput(true);
            using (var tr = db.TransactionManager.StartTransaction()) {
                phase = "validate_btr";
                expected = Records(db, tr);
                // Validate ALL identities before changing any BTR.
                foreach (var m in q.mappings) {
                    Record row;
                    Require(expected.TryGetValue(m.handle, out row) && row.Name == m.name
                        && row.Path == m.old_path, "prepare_stale_btr_identity");
                    ObjectId id = db.GetObjectId(false, new Handle(Convert.ToInt64(m.handle, 16)), 0);
                    var b = (BlockTableRecord)tr.GetObject(id, OpenMode.ForRead);
                    Require(b.IsFromExternalReference && !b.IsDependent, "prepare_not_direct_xref");
                }
                phase = "update_btr";
                foreach (var m in q.mappings) {
                    ObjectId id = db.GetObjectId(false, new Handle(Convert.ToInt64(m.handle, 16)), 0);
                    var b = (BlockTableRecord)tr.GetObject(id, OpenMode.ForWrite);
                    b.PathName = m.new_path;
                    expected[m.handle].Path = m.new_path;
                    changed++;
                }
                tr.Commit();
            }
            phase = "verify_commit";
            Require(changed == 3, "prepare_changed_count");
            Verify(db, expected);
            Bindings(q);
            // Only a unique pending path in a freshly-created private output directory; never the source.
            Require(Directory.GetFileSystemEntries(System.IO.Path.GetDirectoryName(q.output)).Length == 0,
                "prepare_pending_collision");
            phase = "save_as";
            db.SaveAs(q.output, DwgVersion.Current);
        }
        // Reopen WITHOUT resolution. Verify every direct xref handle/name/path, including untouched rows.
        phase = "reopen_output";
        using (var saved = new Database(false, true)) {
            saved.ReadDwgFile(q.output, FileOpenMode.OpenForReadAndAllShare, true, "");
            saved.CloseInput(true);
            Verify(saved, expected);
        }
        phase = "binding_postflight";
        Bindings(q);
        Require(requestSha == Hash(requestPath), "prepare_request_changed");
        string outputSha = Hash(q.output);
        phase = "write_report";
        NewText(q.report, json.Serialize(new { schema_version = 1, kind = "explicit_xref_copy",
            status = "prepared_candidate", completion_hold = "inside_managed_prepare_command",
            request_sha256 = requestSha, source_sha256 = q.source_sha256, output = q.output,
            output_sha256 = outputSha, changed_count = changed, mappings = q.mappings,
            verified_direct_xref_count = expected.Count, dependency_complete = false,
            semantic_identity_proven = false, execution_authorized = false }));
        phase = "write_marker";
        NewText(q.marker + ".pending", "ALLDONE\n");
        // A marker write/close failure leaves only partial evidence, not a consumable success marker.
        File.Move(q.marker + ".pending", q.marker); // Atomic no-overwrite publish, then return to Run's managed hold.
    }
}
