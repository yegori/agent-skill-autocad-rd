// Найти и заменить текст в DWG, ВКЛЮЧАЯ объекты СПДС GraphiCS (таблицы McTable, выноски McNote*), без взрыва.
// Плюс обычные TEXT / MTEXT / атрибуты блоков. Команда TXTFIX (AutoCAD 2024 + СПДС GraphiCS 2023, NETLOAD).
// Параметры — переменные окружения процесса acad.exe (их выставляет run_txtfix.ps1):
//   TXT_IN / TXT_OUT — пути DWG через «|» (файлы открываются по очереди, результат — SaveAs в TXT_OUT);
//   TXT_FIND — регулярное выражение .NET (без учёта регистра); TXT_REPL — замена ($1 и т.п. допустимы);
//   TXT_SEEN — подстрока-«маяк»: строки, где она есть, но шаблон не совпал, пишутся в журнал как SEEN (проверка на пропуски);
//   TXT_LOG — журнал UTF-8; TXT_DRY = "1" — только найти, ничего не менять и не сохранять.
// Журнал: FILE / HIT|где|было => стало / SEEN / UPDATED / SAVED / DONE|changed=… / ERROR / ALLDONE.
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

[assembly: CommandClass(typeof(SpdsText.Cmd))]

namespace SpdsText
{
    public class Cmd
    {
        static Regex Rx;
        static string Repl, Seen;
        static StreamWriter log;
        static bool dry;
        static int changed;

        static void L(string s) { if (log != null) { log.WriteLine(s); log.Flush(); } }

        static string Fix(string s, string where)
        {
            if (s == null) return null;
            if (!Rx.IsMatch(s))
            {
                if (!string.IsNullOrEmpty(Seen) && s.IndexOf(Seen, StringComparison.OrdinalIgnoreCase) >= 0)
                    L("SEEN|" + where + "|" + s.Replace("\n", "\\n"));
                return null;
            }
            string r = Rx.Replace(s, Repl);
            L("HIT|" + where + "|" + s.Replace("\n", "\\n") + " => " + r.Replace("\n", "\\n"));
            return r;
        }

        [CommandMethod("TXTFIX", CommandFlags.Session)]
        public void Run()
        {
            string logPath = Environment.GetEnvironmentVariable("TXT_LOG");
            string[] ins = (Environment.GetEnvironmentVariable("TXT_IN") ?? "").Split(new[] { '|' }, StringSplitOptions.RemoveEmptyEntries);
            string[] outs = (Environment.GetEnvironmentVariable("TXT_OUT") ?? "").Split(new[] { '|' }, StringSplitOptions.RemoveEmptyEntries);
            dry = Environment.GetEnvironmentVariable("TXT_DRY") == "1";
            Rx = new Regex(Environment.GetEnvironmentVariable("TXT_FIND") ?? "(?!)", RegexOptions.IgnoreCase);
            Repl = Environment.GetEnvironmentVariable("TXT_REPL") ?? "";
            Seen = Environment.GetEnvironmentVariable("TXT_SEEN");
            log = new StreamWriter(logPath ?? Path.Combine(Path.GetTempPath(), "txtfix.log"), false, new UTF8Encoding(false));
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
                    if (Environment.GetEnvironmentVariable("TXT_MODE") == "props")
                    { foreach (var kv in mcIds) PropsMc(kv.Value, kv.Key); }
                    else
                    { foreach (var kv in mcIds) FixMc(kv.Value, kv.Key); }
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

        // Режим TXT_MODE=props: свойства объектов СПДС «как в палитре Свойства» (ObjectProperties), в т.ч. числовые
        // (напр. значение отметки уровня mcsDbObjectLevelMark, которое не является строкой).
        //   TXT_CLASS — маска класса (wildcard, напр. "mcsDbObjectLevelMark"); TXT_PROP — имя свойства (пусто — только вывод всех);
        //   TXT_FROM / TXT_TO — значение «было» / «стало» (числа сравниваются с допуском 0,0005; запятая или точка).
        static bool Like(string s, string mask)
        { return Regex.IsMatch(s ?? "", "^" + Regex.Escape(mask ?? "*").Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase); }

        static bool SameValue(object v, string want)
        {
            if (v == null || want == null) return false;
            double a, b; var ci = System.Globalization.CultureInfo.InvariantCulture;
            if (double.TryParse(Convert.ToString(v, ci), System.Globalization.NumberStyles.Float, ci, out a) &&
                double.TryParse(want.Replace(',', '.'), System.Globalization.NumberStyles.Float, ci, out b))
                return Math.Abs(a - b) < 0.0005;
            return string.Equals(Convert.ToString(v, ci), want, StringComparison.OrdinalIgnoreCase);
        }

        static void PropsMc(ObjectId id, string w)
        {
            string cls = id.ObjectClass.Name;
            if (!Like(cls, Environment.GetEnvironmentVariable("TXT_CLASS") ?? "*")) return;
            string pname = Environment.GetEnvironmentVariable("TXT_PROP");
            string from = Environment.GetEnvironmentVariable("TXT_FROM"), to = Environment.GetEnvironmentVariable("TXT_TO");
            McObject o;
            try { o = McObjectManager.GetObject(McObjectId.FromOldIdPtr(id.OldIdPtr)); }
            catch (System.Exception ex) { L("NOOBJ|" + w + "|" + ex.Message); return; }
            var ent = o as McEntity;
            if (ent == null || ent.DbEntity == null) { L("NOENT|" + w); return; }
            McProperties props = ent.DbEntity.ObjectProperties;
            var ci = System.Globalization.CultureInfo.InvariantCulture;
            foreach (string n in props.GetNames())
            {
                object v; try { v = props[n]; } catch { continue; }
                L("PROP|" + w + "|" + n + "|" + (v == null ? "null" : v.GetType().Name) + "|" + Convert.ToString(v, ci));
                if (string.IsNullOrEmpty(pname) || !string.Equals(n, pname, StringComparison.OrdinalIgnoreCase) || !SameValue(v, from)) continue;
                if (dry) { L("HIT|" + w + "|" + n + "|" + Convert.ToString(v, ci) + " => " + to); continue; }
                try
                {
                    Type t = props.GetPropertyType(n) ?? (v != null ? v.GetType() : typeof(string));
                    object nv = t == typeof(string) ? (object)to : Convert.ChangeType(to.Replace(',', '.'), t, ci);
                    if (ent.TryModify()) { props[n] = nv; ent.DbEntity.Update(); changed++; L("HIT|" + w + "|" + n + "|" + Convert.ToString(v, ci) + " => " + Convert.ToString(props[n], ci)); }
                    else L("FAILMOD|" + w);
                }
                catch (System.Exception ex) { L("ERROR|" + w + "|" + n + "|" + ex.Message); }
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
