// Read a side database, never Document.Open/ResolveXrefs/SaveAs. Loaded only inside AutoCAD.
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using AcApplication = Autodesk.AutoCAD.ApplicationServices.Core.Application;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Runtime;

public class RdDependencyProbe {
    static string Hash(string path) {
        using (var stream = File.OpenRead(path)) using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }
    static void WriteNew(string path, string text) {
        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false))) writer.Write(text);
    }
    [CommandMethod("RDDEPENDENCIES", CommandFlags.Session)]
    public void Run() {
        var json = new JavaScriptSerializer(); json.MaxJsonLength = 16 * 1024 * 1024;
        var request = json.Deserialize<Dictionary<string, string>>(File.ReadAllText(Environment.GetEnvironmentVariable("RDCI_DEP_REQUEST"), Encoding.UTF8));
        var source = request["source"]; var before = Hash(source);
        var xrefs = new List<object>(); var fonts = new List<object>(); var layouts = new List<object>(); var assets = new List<object>();
        // Host is a separate known-safe drawing. Source is NEVER made a document/current database.
        using (var db = new Database(false, true)) {
            db.ReadDwgFile(source, FileOpenMode.OpenForReadAndAllShare, true, "");
            db.CloseInput(true);
            using (var tr = db.TransactionManager.StartOpenCloseTransaction()) {
                var blocks = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
                foreach (ObjectId id in blocks) {
                    var b = (BlockTableRecord)tr.GetObject(id, OpenMode.ForRead);
                    if (b.IsFromExternalReference) xrefs.Add(new { name = b.Name, path = b.PathName, overlay = b.IsFromOverlayReference, status = b.XrefStatus.ToString() });
                }
                var styles = (TextStyleTable)tr.GetObject(db.TextStyleTableId, OpenMode.ForRead);
                foreach (ObjectId id in styles) {
                    var style = (TextStyleTableRecord)tr.GetObject(id, OpenMode.ForRead);
                    fonts.Add(new { name = style.Name, file = style.FileName, big_font = style.BigFontFileName, typeface = style.Font.TypeFace });
                }
                var layoutDict = (DBDictionary)tr.GetObject(db.LayoutDictionaryId, OpenMode.ForRead);
                foreach (DBDictionaryEntry e in layoutDict) {
                    var layout = (Layout)tr.GetObject(e.Value, OpenMode.ForRead);
                    if (!layout.ModelType) layouts.Add(new { name = layout.LayoutName, tab_order = layout.TabOrder, paper = layout.CanonicalMediaName, device = layout.PlotConfigurationName, style_sheet = layout.CurrentStyleSheet });
                }
                var nod = (DBDictionary)tr.GetObject(db.NamedObjectsDictionaryId, OpenMode.ForRead);
                foreach (var key in new [] { "ACAD_IMAGE_DICT", "ACAD_PDFDEFINITIONS", "ACAD_DWFDEFINITIONS", "ACAD_DGNDEFINITIONS" }) {
                    if (!nod.Contains(key)) continue;
                    var dict = (DBDictionary)tr.GetObject(nod.GetAt(key), OpenMode.ForRead);
                    foreach (DBDictionaryEntry e in dict) {
                        var obj = tr.GetObject(e.Value, OpenMode.ForRead); string path = null;
                        var image = obj as RasterImageDef; if (image != null) path = image.SourceFileName;
                        var underlay = obj as UnderlayDefinition; if (underlay != null) path = underlay.SourceFileName;
                        assets.Add(new { dictionary = key, name = e.Key, path = path, class_name = obj.GetRXClass().Name });
                    }
                }
            }
        }
        if (before != Hash(source)) throw new InvalidOperationException("dependency_source_changed");
        var report = new { schema_version = 1, kind = "side_database_dependencies", status = "observed_partial", source_sha256 = before,
            coverage = "direct_tables_and_asset_dictionaries", execution_authorized = false, xrefs = xrefs, fonts = fonts, layouts = layouts, assets = assets,
            omissions = new [] { "nested_xref_contents", "actual_font_resolution_and_substitution", "material_textures", "proxy_custom_resources", "plot_device_pmp_closure" },
            host_fontalt = Convert.ToString(AcApplication.GetSystemVariable("FONTALT")), host_fontmap = Convert.ToString(AcApplication.GetSystemVariable("FONTMAP")) };
        WriteNew(request["report"], json.Serialize(report));
        WriteNew(request["marker"], "ALLDONE\n"); // Only native command success after closed source/report, never Lisp fallthrough.
    }
}
