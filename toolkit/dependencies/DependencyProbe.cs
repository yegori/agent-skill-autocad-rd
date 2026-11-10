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
    // Bounded definition scan, NOT insertion expansion or a visibility/plot-use test.
    const int MaxUsageBlocks = 2048, MaxUsageEntities = 20000;
    static string Handle(ObjectId id) { return id.IsNull ? null : id.Handle.ToString(); }
    static object Observe(Entity entity, string container, string insert) {
        string kind = "unsupported_entity", target = null;
        var type = entity.GetType();
        if (type == typeof(DBText) || type == typeof(AttributeDefinition) || type == typeof(AttributeReference)) {
            kind = "text_style_reference"; target = Handle(((DBText)entity).TextStyleId);
        } else if (type == typeof(MText)) {
            kind = "text_style_reference"; target = Handle(((MText)entity).TextStyleId);
        } else if (type == typeof(BlockReference)) {
            kind = "block_reference"; target = Handle(((BlockReference)entity).BlockTableRecord);
        }
        return new { kind = kind, entity_handle = Handle(entity.ObjectId), class_name = entity.GetRXClass().Name,
            container_handle = container, owner_handle = Handle(entity.OwnerId), parent_insert_handle = insert,
            target_handle = target };
    }
    static object ReadUsage(Transaction tr, BlockTable blocks) {
        var containers = new List<object>(); var observations = new List<object>();
        int blockCount = 0, entityCount = 0; bool truncated = false;
        foreach (ObjectId id in blocks) {
            if (blockCount >= MaxUsageBlocks || entityCount >= MaxUsageEntities) { truncated = true; break; }
            blockCount++;
            var block = (BlockTableRecord)tr.GetObject(id, OpenMode.ForRead);
            string space = "block_definition", layoutName = null;
            if (block.IsLayout) {
                var layout = (Layout)tr.GetObject(block.LayoutId, OpenMode.ForRead);
                space = layout.ModelType ? "model" : "paper"; layoutName = layout.LayoutName;
            }
            bool external = block.IsFromExternalReference || block.IsFromOverlayReference || block.IsDependent;
            containers.Add(new { handle = Handle(id), name = block.Name, space = space, layout = layoutName,
                scan = external ? "external_skipped" : "local_definition", external = external });
            if (external) continue; // No xref entity access, resolution or recursive traversal.
            foreach (ObjectId entityId in block) {
                if (entityCount >= MaxUsageEntities) { truncated = true; break; }
                entityCount++;
                var entity = (Entity)tr.GetObject(entityId, OpenMode.ForRead);
                observations.Add(Observe(entity, Handle(id), null));
                // Attribute references are owned by the insert, not enumerated directly in the BTR.
                if (entity.GetType() != typeof(BlockReference)) continue;
                foreach (ObjectId attrId in ((BlockReference)entity).AttributeCollection) {
                    if (entityCount >= MaxUsageEntities) { truncated = true; break; }
                    entityCount++;
                    var attr = (Entity)tr.GetObject(attrId, OpenMode.ForRead);
                    observations.Add(Observe(attr, Handle(id), Handle(entityId)));
                }
            }
        }
        return new { schema_version = 1, coverage = "bounded_local_definition_references", complete = false,
            traversal = "definitions_once_no_recursion", truncated = truncated,
            max_blocks = MaxUsageBlocks, max_entities = MaxUsageEntities,
            containers = containers, observations = observations,
            omissions = new [] { "insertion_paths_and_cycles_not_expanded", "block_reachability_and_dynamic_evaluation",
                "visibility_layers_clipping_and_plot_use", "model_to_paper_viewports", "xref_contents_not_read",
                "mtext_inline_fonts_and_attribute_mtext", "dimensions_shapes_and_other_entity_resources",
                "proxy_spds_custom_resources", "actual_font_resolution_and_substitution" } };
    }
    [CommandMethod("RDDEPENDENCIES", CommandFlags.Session)]
    public void Run() {
        var json = new JavaScriptSerializer(); json.MaxJsonLength = 16 * 1024 * 1024;
        var request = json.Deserialize<Dictionary<string, string>>(File.ReadAllText(Environment.GetEnvironmentVariable("RDCI_DEP_REQUEST"), Encoding.UTF8));
        var source = request["source"]; var before = Hash(source);
        var xrefs = new List<object>(); var fonts = new List<object>(); var layouts = new List<object>(); var assets = new List<object>();
        object usage;
        // Host is a separate known-safe drawing. Source is NEVER made a document/current database.
        using (var db = new Database(false, true)) {
            db.ReadDwgFile(source, FileOpenMode.OpenForReadAndAllShare, true, "");
            db.CloseInput(true);
            using (var tr = db.TransactionManager.StartOpenCloseTransaction()) {
                var blocks = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
                foreach (ObjectId id in blocks) {
                    var b = (BlockTableRecord)tr.GetObject(id, OpenMode.ForRead);
                    if (b.IsFromExternalReference) xrefs.Add(new { record_handle = Handle(id), name = b.Name, path = b.PathName, overlay = b.IsFromOverlayReference, status = b.XrefStatus.ToString() });
                }
                var styles = (TextStyleTable)tr.GetObject(db.TextStyleTableId, OpenMode.ForRead);
                foreach (ObjectId id in styles) {
                    var style = (TextStyleTableRecord)tr.GetObject(id, OpenMode.ForRead);
                    fonts.Add(new { record_handle = Handle(id), name = style.Name, file = style.FileName, big_font = style.BigFontFileName, typeface = style.Font.TypeFace });
                }
                var layoutDict = (DBDictionary)tr.GetObject(db.LayoutDictionaryId, OpenMode.ForRead);
                foreach (DBDictionaryEntry e in layoutDict) {
                    var layout = (Layout)tr.GetObject(e.Value, OpenMode.ForRead);
                    if (!layout.ModelType) layouts.Add(new { name = layout.LayoutName, tab_order = layout.TabOrder, paper = layout.CanonicalMediaName, device = layout.PlotConfigurationName, style_sheet = layout.CurrentStyleSheet });
                }
                usage = ReadUsage(tr, blocks);
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
            coverage = "direct_tables_and_asset_dictionaries", execution_authorized = false, completion_hold = "inside_managed_command",
            xrefs = xrefs, fonts = fonts, layouts = layouts, assets = assets, usage = usage,
            omissions = new [] { "nested_xref_contents", "actual_font_resolution_and_substitution", "material_textures", "proxy_custom_resources", "plot_device_pmp_closure" },
            host_fontalt = Convert.ToString(AcApplication.GetSystemVariable("FONTALT")), host_fontmap = Convert.ToString(AcApplication.GetSystemVariable("FONTMAP")) };
        WriteNew(request["report"], json.Serialize(report));
        WriteNew(request["marker"], "ALLDONE\n"); // Only native command success after closed source/report, never Lisp fallthrough.
        // Do not return into command-ended Lisp/DELAY reactors in Core Console. The source DB and report
        // are already closed; the bounded wrapper stops this private Job after verifying the marker.
        // Not for interactive use, plotting or SaveAs. A marker followed by early exit still fails.
        while (true) System.Threading.Thread.Sleep(1000);
    }
}
