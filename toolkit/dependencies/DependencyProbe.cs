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
    // Opt-in exact edge only. Handles are meaningful solely in this source SHA / side DB.
    class TargetOptions { public string reference, block, sha; }
    static TargetOptions ParseTargetRequest(Dictionary<string, string> request, string sha) {
        string[] keys = { "target_reference", "target_block", "expected_source_sha256" };
        bool any = false; foreach (string key in keys) if (request.ContainsKey(key)) any = true;
        if (!any) return null;
        foreach (string key in keys) if (!request.ContainsKey(key)) throw new InvalidOperationException("target_request_incomplete");
        string reference = CanonicalHandle(request[keys[0]]), block = CanonicalHandle(request[keys[1]]);
        string expected = request[keys[2]];
        if (expected == null || !System.Text.RegularExpressions.Regex.IsMatch(expected, "\\A[0-9a-fA-F]{64}\\z"))
            throw new InvalidOperationException("target_source_sha_required");
        if (!String.Equals(expected, sha, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("target_source_sha_mismatch");
        return new TargetOptions { reference = reference, block = block, sha = expected.ToLowerInvariant() };
    }
    static string CanonicalHandle(string value) {
        long number;
        if (value == null || !System.Text.RegularExpressions.Regex.IsMatch(value, "\\A[1-9a-fA-F][0-9a-fA-F]{0,15}\\z") ||
            !Int64.TryParse(value, System.Globalization.NumberStyles.AllowHexSpecifier, System.Globalization.CultureInfo.InvariantCulture, out number) || number <= 0)
            throw new InvalidOperationException("target_positive_hex_handle_required");
        return number.ToString("X");
    }
    static DBObject ResolveTarget(Database db, Transaction tr, string requested, out object evidence) {
        ObjectId id;
        if (requested == null) { evidence = new { requested_handle = requested, state = "null_owner" }; return null; }
        try {
            id = db.GetObjectId(false, new Autodesk.AutoCAD.DatabaseServices.Handle(Convert.ToInt64(requested, 16)), 0);
            if (id.IsNull || id.IsErased) {
                evidence = new { requested_handle = requested, state = id.IsNull ? "missing" : "erased" }; return null;
            }
            var obj = tr.GetObject(id, OpenMode.ForRead);
            evidence = new { requested_handle = requested, state = "resolved", actual_handle = Handle(obj.ObjectId),
                runtime_type = obj.GetType().FullName, class_name = obj.GetRXClass().Name, owner_handle = Handle(obj.OwnerId) };
            return obj;
        } catch (Autodesk.AutoCAD.Runtime.Exception error) {
            evidence = new { requested_handle = requested, state = "lookup_or_open_failed", api_status = error.ErrorStatus.ToString() }; return null;
        }
    }
    static object TargetContainer(Transaction tr, BlockTableRecord block) {
        string space = "block_definition", layoutName = null;
        if (block.IsLayout) {
            var layout = (Layout)tr.GetObject(block.LayoutId, OpenMode.ForRead);
            space = layout.ModelType ? "model" : "paper"; layoutName = layout.LayoutName;
        }
        bool external = block.IsFromExternalReference || block.IsFromOverlayReference || block.IsDependent;
        return new { handle = Handle(block.ObjectId), name = block.Name, space = space, layout = layoutName,
            external = external, capture = "metadata_only" };
    }
    static object TargetObservation(Entity entity, string container, string insert) {
        return new { reference = Observe(entity, container, insert), layer_handle = Handle(entity.LayerId),
            layer_name = entity.Layer, entity_visible = entity.Visible, plot_visibility = "UNKNOWN" };
    }
    static Dictionary<string, object> ReadTargeted(Database db, Transaction tr, TargetOptions options) {
        var rows = new List<object>();
        var result = new Dictionary<string, object> {
            { "schema_version", 1 }, { "status", "needs_input" }, { "complete", false }, { "truncated", false },
            { "coverage", "exact_edge_and_target_local_definition" }, { "traversal", "target_only_no_recursion" },
            { "source_sha256", options.sha }, { "requested_reference", options.reference }, { "requested_block", options.block },
            { "link_verified", false }, { "max_blocks", MaxUsageBlocks }, { "max_entities", MaxUsageEntities },
            { "opened_btr_count", 0 }, { "entity_count", 0 }, { "observations", rows }, { "definition_scan", "not_started" },
            { "paper_reachability", "UNKNOWN" }, { "plot_visibility", "UNKNOWN" },
            { "omissions", new [] { "dependent_definitions_not_followed", "external_contents_not_read", "no_fonts_or_resource_resolution",
                "no_geometry_text_or_extents", "dynamic_evaluation_clipping_layer_viewport_visibility_unknown", "unsupported_entity_resources" } }
        };
        object referenceInfo, blockInfo;
        var referring = ResolveTarget(db, tr, options.reference, out referenceInfo);
        var target = ResolveTarget(db, tr, options.block, out blockInfo);
        result["reference_resolution"] = referenceInfo; result["target_resolution"] = blockInfo;
        var openedBlocks = new HashSet<ObjectId>();
        if (referring is BlockTableRecord) openedBlocks.Add(referring.ObjectId);
        if (target is BlockTableRecord) openedBlocks.Add(target.ObjectId);
        result["opened_btr_count"] = openedBlocks.Count;
        result["entity_count"] = (referring is Entity ? 1 : 0) + (target is Entity && (referring == null || target.ObjectId != referring.ObjectId) ? 1 : 0);
        if (referring == null || target == null) { result["reason"] = "requested_object_unresolved"; return result; }
        if (Handle(referring.ObjectId) != options.reference || Handle(target.ObjectId) != options.block) {
            result["reason"] = "resolved_handle_mismatch"; return result;
        }
        if (referring.GetType() != typeof(BlockReference) || target.GetType() != typeof(BlockTableRecord)) {
            result["reason"] = "requested_object_type_unsupported"; return result;
        }
        var insert = (BlockReference)referring; var block = (BlockTableRecord)target;
        result["entity_count"] = 1; result["actual_target_handle"] = Handle(insert.BlockTableRecord);
        if (insert.BlockTableRecord != block.ObjectId) { result["reason"] = "block_link_mismatch"; return result; }
        result["link_verified"] = true;
        result["referring_entity"] = TargetObservation(insert, Handle(insert.OwnerId), null);
        result["target_container"] = TargetContainer(tr, block);
        object ownerInfo;
        var owner = ResolveTarget(db, tr, Handle(insert.OwnerId), out ownerInfo);
        result["owner_resolution"] = ownerInfo;
        if (owner == null || owner.GetType() != typeof(BlockTableRecord) || owner.ObjectId != insert.OwnerId) { result["reason"] = "owner_context_unknown"; return result; }
        result["owner_container"] = TargetContainer(tr, (BlockTableRecord)owner);
        openedBlocks.Add(owner.ObjectId); result["opened_btr_count"] = openedBlocks.Count;
        var ownerBlock = (BlockTableRecord)owner;
        if (ownerBlock.IsFromExternalReference || ownerBlock.IsFromOverlayReference || ownerBlock.IsDependent) {
            result["definition_scan"] = "external_skipped"; result["reason"] = "external_owner_skipped"; return result;
        }
        if (block.IsFromExternalReference || block.IsFromOverlayReference || block.IsDependent) {
            result["definition_scan"] = "external_skipped"; result["reason"] = "external_target_skipped"; return result;
        }
        int count = 1; result["definition_scan"] = "bounded_target_only";
        foreach (ObjectId id in block) {
            if (count >= MaxUsageEntities) { result["truncated"] = true; break; }
            count++;
            var entity = tr.GetObject(id, OpenMode.ForRead) as Entity;
            if (entity == null || entity.OwnerId != block.ObjectId) {
                result["entity_count"] = count; result["reason"] = "entity_type_or_owner_mismatch"; return result;
            }
            rows.Add(TargetObservation(entity, Handle(block.ObjectId), null));
            if (entity.GetType() != typeof(BlockReference)) continue;
            foreach (ObjectId attrId in ((BlockReference)entity).AttributeCollection) {
                if (count >= MaxUsageEntities) { result["truncated"] = true; break; }
                count++;
                var attr = tr.GetObject(attrId, OpenMode.ForRead) as Entity;
                if (attr == null || attr.GetType() != typeof(AttributeReference) || attr.OwnerId != entity.ObjectId) {
                    result["entity_count"] = count; result["reason"] = "attribute_type_or_owner_mismatch"; return result;
                }
                rows.Add(TargetObservation(attr, Handle(block.ObjectId), Handle(id)));
            }
            if ((bool)result["truncated"]) break;
        }
        result["entity_count"] = count;
        result["definition_scan"] = (bool)result["truncated"] ? "capped_target_only" : "enumerated_target_only";
        result["status"] = (bool)result["truncated"] ? "needs_input" : "observed_partial";
        result["reason"] = (bool)result["truncated"] ? "entity_cap_reached" : "target_definition_observed_not_closure";
        return result;
    }
    [CommandMethod("RDDEPENDENCIES", CommandFlags.Session)]
    public void Run() {
        var json = new JavaScriptSerializer(); json.MaxJsonLength = 16 * 1024 * 1024;
        var request = json.Deserialize<Dictionary<string, string>>(File.ReadAllText(Environment.GetEnvironmentVariable("RDCI_DEP_REQUEST"), Encoding.UTF8));
        var source = request["source"]; var before = Hash(source);
        var xrefs = new List<object>(); var fonts = new List<object>(); var layouts = new List<object>(); var assets = new List<object>();
        object usage = null;
        var targetOptions = ParseTargetRequest(request, before);
        Dictionary<string, object> targeted = null;
        // Host is a separate known-safe drawing. Source is NEVER made a document/current database.
        using (var db = new Database(false, true)) {
            db.ReadDwgFile(source, FileOpenMode.OpenForReadAndAllShare, true, "");
            db.CloseInput(true);
            using (var tr = db.TransactionManager.StartOpenCloseTransaction()) {
                if (targetOptions != null) targeted = ReadTargeted(db, tr, targetOptions);
                else {
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
        }
        if (before != Hash(source)) throw new InvalidOperationException("dependency_source_changed");
        object report;
        if (targetOptions != null) report = new { schema_version = 1, kind = "side_database_targeted_block", status = targeted["status"],
            source_sha256 = before, coverage = "exact_edge_and_target_local_definition", execution_authorized = false,
            completion_hold = "inside_managed_command", targeted_block = targeted };
        else report = new { schema_version = 1, kind = "side_database_dependencies", status = "observed_partial", source_sha256 = before,
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
