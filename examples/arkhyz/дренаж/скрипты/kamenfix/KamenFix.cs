// Замена текста внутри объектов СПДС GraphiCS (таблицы, выноски) и обычных TEXT/MTEXT/атрибутов.
// Команда KAMENFIX (AutoCAD 2024 + СПДС GraphiCS 2023, загрузка через NETLOAD).
// Параметры — переменные окружения процесса acad.exe:
//   KAMEN_LOG  — файл журнала (UTF-8);  KAMEN_OUT — куда сохранить DWG (SaveAs), пусто — не сохранять;
//   KAMEN_DRY  — "1": только найти, не менять.
// Замена: «фр. 120-150» / «фр.120-150» / «фракции 120-150» -> «ср. размер 150».
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using Autodesk.AutoCAD.ApplicationServices;
using Autodesk.AutoCAD.DatabaseServices;
using Autodesk.AutoCAD.Runtime;
using Multicad;
using Multicad.DatabaseServices;
using Multicad.Symbols;
using Multicad.Symbols.Tables;
using AcApp = Autodesk.AutoCAD.ApplicationServices.Application;

[assembly: CommandClass(typeof(KamenFix.Cmd))]

namespace KamenFix
{
    public class Cmd
    {
        static readonly Regex Rx = new Regex(@"фр(акции|\.)?\s*120\s*[-–]\s*150", RegexOptions.IgnoreCase);
        const string Repl = "ср. размер 150";
        static StreamWriter log;
        static bool dry;
        static int changed;

        static void L(string s) { if (log != null) { log.WriteLine(s); log.Flush(); } }

        static string Fix(string s, string where)
        {
            if (s == null) return null;
            if (s.IndexOf("120", StringComparison.Ordinal) < 0) return null;
            if (!Rx.IsMatch(s)) { L("SEEN|" + where + "|" + s.Replace("\n", "\\n")); return null; }
            string r = Rx.Replace(s, Repl);
            L("HIT|" + where + "|" + s.Replace("\n", "\\n") + " => " + r.Replace("\n", "\\n"));
            return r;
        }

        // KAMEN_IN / KAMEN_OUT — списки путей через «|» (файлы открываются по очереди в этом же сеансе).
        [CommandMethod("KAMENFIX", CommandFlags.Session)]
        public void Run()
        {
            string logPath = Environment.GetEnvironmentVariable("KAMEN_LOG");
            string[] ins = (Environment.GetEnvironmentVariable("KAMEN_IN") ?? "").Split(new[] { '|' }, StringSplitOptions.RemoveEmptyEntries);
            string[] outs = (Environment.GetEnvironmentVariable("KAMEN_OUT") ?? "").Split(new[] { '|' }, StringSplitOptions.RemoveEmptyEntries);
            dry = Environment.GetEnvironmentVariable("KAMEN_DRY") == "1";
            log = new StreamWriter(logPath ?? Path.Combine(Path.GetTempPath(), "kamenfix.log"), false, new UTF8Encoding(false));
            object pn = AcApp.GetSystemVariable("PROXYNOTICE");
            try
            {
                AcApp.SetSystemVariable("PROXYNOTICE", (short)0);   // окно «Информация о прокси-объектах» блокирует пакетный режим
                for (int i = 0; i < ins.Length; i++)
                {
                    Document d = null;
                    try
                    {
                        d = AcApp.DocumentManager.Open(ins[i], false);
                        AcApp.DocumentManager.MdiActiveDocument = d;
                        One(d, i < outs.Length ? outs[i] : null);
                    }
                    catch (System.Exception ex) { L("ERROR|" + ins[i] + "|" + ex); }
                    finally { if (d != null) try { d.CloseAndDiscard(); } catch { } }
                }
            }
            catch (System.Exception ex) { L("ERROR|" + ex); }
            finally
            {
                try { AcApp.SetSystemVariable("PROXYNOTICE", pn); } catch { }
                L("ALLDONE");
                log.Close(); log = null;
            }
        }

        static void One(Document doc, string outPath)
        {
            changed = 0;
            try
            {
                Database db = doc.Database;
                L("FILE|" + db.Filename + "|dry=" + dry);
                var mcIds = new List<KeyValuePair<string, ObjectId>>();
                using (doc.LockDocument())
                {
                    using (Transaction tr = db.TransactionManager.StartTransaction())
                    {
                        var bt = (BlockTable)tr.GetObject(db.BlockTableId, OpenMode.ForRead);
                        foreach (ObjectId bid in bt)
                        {
                            var btr = (BlockTableRecord)tr.GetObject(bid, OpenMode.ForRead);
                            if (!btr.IsLayout) continue;
                            string lay = ((Layout)tr.GetObject(btr.LayoutId, OpenMode.ForRead)).LayoutName;
                            foreach (ObjectId id in btr)
                            {
                                string cls = id.ObjectClass.Name;
                                if (cls.StartsWith("mcs", StringComparison.OrdinalIgnoreCase))
                                { mcIds.Add(new KeyValuePair<string, ObjectId>(lay + "|" + cls + "|" + id.Handle, id)); continue; }
                                FixAcad(tr, id, lay);
                            }
                        }
                        tr.Commit();
                    }
                    foreach (var kv in mcIds) FixMc(kv.Value, kv.Key);
                    if (!dry && !string.IsNullOrEmpty(outPath))
                    {
                        db.SaveAs(outPath, DwgVersion.Current);
                        L("SAVED|" + outPath);
                    }
                }
                L("DONE|changed=" + changed + "|mcs=" + mcIds.Count);
            }
            catch (System.Exception ex) { L("ERROR|" + ex); }
        }

        static void FixAcad(Transaction tr, ObjectId id, string lay)
        {
            string cls = id.ObjectClass.DxfName;
            if (cls != "TEXT" && cls != "MTEXT" && cls != "INSERT") return;
            var ent = tr.GetObject(id, OpenMode.ForRead);
            string w = lay + "|" + cls + "|" + id.Handle;
            if (ent is DBText)
            {
                var t = (DBText)ent; string r = Fix(t.TextString, w);
                if (r != null && !dry) { t.UpgradeOpen(); t.TextString = r; changed++; }
            }
            else if (ent is MText)
            {
                var t = (MText)ent; string r = Fix(t.Contents, w);
                if (r != null && !dry) { t.UpgradeOpen(); t.Contents = r; changed++; }
            }
            else if (ent is BlockReference)
            {
                foreach (ObjectId aid in ((BlockReference)ent).AttributeCollection)
                {
                    var a = (AttributeReference)tr.GetObject(aid, OpenMode.ForRead);
                    string r = Fix(a.TextString, w + "|ATT " + a.Tag);
                    if (r != null && !dry) { a.UpgradeOpen(); a.TextString = r; changed++; }
                }
            }
        }

        static void FixMc(ObjectId id, string w)
        {
            McObject o;
            try { o = McObjectManager.GetObject(McObjectId.FromOldIdPtr(id.OldIdPtr)); }
            catch (System.Exception ex) { L("NOOBJ|" + w + "|" + ex.Message); return; }
            if (o == null) { L("NOOBJ|" + w); return; }
            string tn = o.GetType().Name;
            var ent = o as McEntity;
            int before = changed;
            bool opened = false;
            Func<bool> open = () => { if (dry) return false; if (!opened && ent != null) opened = ent.TryModify(); return opened || ent == null; };

            var tbl = o as McTable;
            if (tbl != null)
            {
                int nr = tbl.Rows.Count, nc = tbl.Columns.Count;
                for (int r = 0; r < nr; r++)
                    for (int c = 0; c < nc; c++)
                    {
                        Multicad.Symbols.Tables.Cell cell;
                        try { cell = tbl[r, c]; } catch { continue; }
                        if (cell == null) continue;
                        string v = Fix(cell.Value, w + "|" + tn + "|cell " + r + "," + c);
                        if (v != null && open()) { cell.Value = v; changed++; }
                    }
            }
            else
            {
                foreach (PropertyInfo p in o.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
                {
                    if (p.GetIndexParameters().Length > 0 || !p.CanRead) continue;
                    object val;
                    try { val = p.GetValue(o, null); } catch { continue; }
                    if (val is string)
                    {
                        string v = Fix((string)val, w + "|" + tn + "." + p.Name);
                        if (v != null && p.CanWrite && open()) { p.SetValue(o, v, null); changed++; }
                    }
                    else if (val is McNoteUnit.McNoteUnitCollection)
                    {
                        var col = (McNoteUnit.McNoteUnitCollection)val;
                        bool any = false;
                        for (int i = 0; i < col.Count; i++)
                        {
                            string v = Fix(col[i].Text, w + "|" + tn + "." + p.Name + "[" + i + "]");
                            if (v != null && open()) { col[i] = new McNoteUnit(v, col[i].HorizontalAligment); any = true; changed++; }
                        }
                        if (any && p.CanWrite) p.SetValue(o, col, null);
                    }
                }
            }
            if (changed > before && ent != null)
            {
                bool ok = ent.DbEntity.Update();
                L("UPDATED|" + w + "|" + ok);
            }
            else L("MC|" + w + "|" + tn);
        }
    }
}
