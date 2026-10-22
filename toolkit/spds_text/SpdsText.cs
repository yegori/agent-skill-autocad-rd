// Найти и заменить текст в DWG, ВКЛЮЧАЯ объекты СПДС GraphiCS (таблицы McTable, выноски McNote*), без взрыва.
// Плюс обычные TEXT / MTEXT / атрибуты блоков. Команда TXTFIX (AutoCAD 2024 + СПДС GraphiCS 2023, NETLOAD).
// Параметры — переменные окружения процесса acad.exe (их выставляет run_txtfix.ps1):
//   TXT_IN / TXT_OUT — пути DWG через «|» (файлы открываются по очереди, результат — SaveAs в TXT_OUT);
//   TXT_FIND — регулярное выражение .NET (без учёта регистра); TXT_REPL — замена ($1 и т.п. допустимы);
//   TXT_PAIRS — вместо FIND/REPL: файл UTF-8, строки «regex<TAB>замена» (# — комментарий), применяются по очереди за один проход;
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
        static List<KeyValuePair<Regex, string>> Pairs;   // TXT_FIND/TXT_REPL или список из TXT_PAIRS — применяются по очереди
        static string Seen;
        static StreamWriter log;
        static bool dry, abort;
        static int changed;

        static void L(string s) { if (log != null) { log.WriteLine(s); log.Flush(); } }

        static string Fix(string s, string where)
        {
            if (s == null) return null;
            string r = s; bool hit = false;
            foreach (var p in Pairs)
                if (p.Key.IsMatch(r)) { r = p.Key.Replace(r, p.Value); hit = true; }
            if (!hit)
            {
                if (!string.IsNullOrEmpty(Seen) && s.IndexOf(Seen, StringComparison.OrdinalIgnoreCase) >= 0)
                    L("SEEN|" + where + "|" + s.Replace("\n", "\\n"));
                return null;
            }
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
            Pairs = new List<KeyValuePair<Regex, string>>();
            string pairsPath = Environment.GetEnvironmentVariable("TXT_PAIRS");
            if (!string.IsNullOrEmpty(pairsPath))
            {
                foreach (string line in File.ReadAllLines(pairsPath, Encoding.UTF8))
                {
                    if (line.Trim().Length == 0 || line.StartsWith("#")) continue;
                    int tab = line.IndexOf('\t');
                    if (tab < 0) continue;
                    Pairs.Add(new KeyValuePair<Regex, string>(new Regex(line.Substring(0, tab), RegexOptions.IgnoreCase), line.Substring(tab + 1)));
                }
            }
            else
                Pairs.Add(new KeyValuePair<Regex, string>(new Regex(Environment.GetEnvironmentVariable("TXT_FIND") ?? "(?!)", RegexOptions.IgnoreCase),
                                                          Environment.GetEnvironmentVariable("TXT_REPL") ?? ""));
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
            changed = 0; abort = false;
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
                    string mode = Environment.GetEnvironmentVariable("TXT_MODE");
                    if (mode == "props")
                    { foreach (var kv in mcIds) PropsMc(kv.Value, kv.Key); }
                    else if (mode == "leader")
                    { foreach (var kv in mcIds) LeaderMc(kv.Value, kv.Key); }
                    else
                    { foreach (var kv in mcIds) FixMc(kv.Value, kv.Key); }
                    if (abort) L("NOTSAVED|" + outPath);
                    else if (!dry && !string.IsNullOrEmpty(outPath))
                    {
                        // 22.10: без регенерации псевдоштриховка СПДС (mcsPseudoHatch) сохранялась с пустой прокси-графикой —
                        // в консольной печати и без СПДС штриховка бетона пропадала. Регенерируем перед сохранением.
                        try { doc.Editor.Regen(); L("REGEN|ok"); } catch (System.Exception ex) { L("REGEN|" + ex.Message); }
                        foreach (var kv in mcIds)
                            if (kv.Value.ObjectClass.Name.Equals("mcsPseudoHatch", StringComparison.OrdinalIgnoreCase))
                                try
                                {
                                    var pe = McObjectManager.GetObject(McObjectId.FromOldIdPtr(kv.Value.OldIdPtr)) as McEntity;
                                    if (pe != null && pe.DbEntity != null) L("PSEUDOHATCH|" + kv.Key + "|modify=" + pe.TryModify() + "|update=" + pe.DbEntity.Update());
                                }
                                catch (System.Exception ex) { L("PSEUDOHATCH|" + kv.Key + "|" + ex.Message); }
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
            if (!HandleOk(id)) return;
            var ent = tr.GetObject(id, OpenMode.ForRead);
            string w = lay + "|" + cls + "|" + id.Handle;
            if (ent is DBText)
            {
                var t = (DBText)ent; string r = Fix(t.TextString, w);
                if (r != null && !dry)
                {
                    t.UpgradeOpen(); changed++;
                    if (r.Trim().Length == 0) { t.Erase(); L("ERASED|" + w); }   // замена на пустую строку — удалить однострочный текст
                    else t.TextString = r;
                }
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

        // Режим TXT_MODE=leader: сегменты выносок СПДС (свойство Leader: McBaseLeader → дерево McBLSegment) и их стрелки.
        //   TXT_CLASS — маска класса; TXT_HANDLE — handle объекта (пусто — все); вывод LEADER|где|путь|начало|конец|стрелка.
        //   TXT_PT = "x,y" и TXT_ARROW = None/Oblique/… — у сегмента, чей конец ближе всего к точке (не дальше TXT_TOL, по умолч. 1), сменить стрелку.
        static void LeaderMc(ObjectId id, string w)
        {
            if (!Like(id.ObjectClass.Name, Environment.GetEnvironmentVariable("TXT_CLASS") ?? "*")) return;
            string h = Environment.GetEnvironmentVariable("TXT_HANDLE");
            if (!string.IsNullOrEmpty(h) && !string.Equals(id.Handle.ToString(), h, StringComparison.OrdinalIgnoreCase)) return;
            McObject o;
            try { o = McObjectManager.GetObject(McObjectId.FromOldIdPtr(id.OldIdPtr)); }
            catch (System.Exception ex) { L("NOOBJ|" + w + "|" + ex.Message); return; }
            var lp = o == null ? null : o.GetType().GetProperty("Leader");
            var leader = lp == null ? null : lp.GetValue(o, null) as McBaseLeader;
            if (leader == null) { L("NOLEADER|" + w); return; }
            var ci = System.Globalization.CultureInfo.InvariantCulture;
            var all = new List<KeyValuePair<string, McBLSegment>>();
            Action<McBLSegmentList, string> walk = null;
            walk = (list, path) =>
            {
                if (list == null) return;
                for (int i = 0; i < list.Count; i++)
                {
                    var s = list[i]; string p = path + "/" + i;
                    all.Add(new KeyValuePair<string, McBLSegment>(p, s));
                    L("LEADER|" + w + "|" + p + "|" + s.Start.X.ToString("F1", ci) + "," + s.Start.Y.ToString("F1", ci) + "|" +
                      s.End.X.ToString("F1", ci) + "," + s.End.Y.ToString("F1", ci) + "|" + s.Arrow);
                    walk(s.Childs, p);
                }
            };
            walk(leader.Childs, "");
            string pt = Environment.GetEnvironmentVariable("TXT_PT"), arr = Environment.GetEnvironmentVariable("TXT_ARROW");
            if (string.IsNullOrEmpty(pt) || string.IsNullOrEmpty(arr)) return;
            string[] xy = pt.Split(',');
            double x = double.Parse(xy[0], ci), y = double.Parse(xy[1], ci), tol;
            if (!double.TryParse(Environment.GetEnvironmentVariable("TXT_TOL") ?? "1", System.Globalization.NumberStyles.Float, ci, out tol)) tol = 1;
            KeyValuePair<string, McBLSegment> best = default(KeyValuePair<string, McBLSegment>); double bd = double.MaxValue;
            foreach (var kv in all)   // засечка рисуется у начала сегмента (ветки к полке) — ищем по началу и по концу
            {
                double d = Math.Min(Math.Sqrt(Math.Pow(kv.Value.Start.X - x, 2) + Math.Pow(kv.Value.Start.Y - y, 2)),
                                    Math.Sqrt(Math.Pow(kv.Value.End.X - x, 2) + Math.Pow(kv.Value.End.Y - y, 2)));
                if (d < bd) { bd = d; best = kv; }
            }
            if (best.Value == null || bd > tol) { L("NOSEG|" + w + "|" + pt + "|nearest=" + bd.ToString("F2", ci)); return; }
            bool del = string.Equals(arr, "DELETE", StringComparison.OrdinalIgnoreCase);   // DELETE — удалить ветку верхнего уровня целиком
            int top = int.Parse(best.Key.Split('/')[1]);
            if (del && best.Key.Split('/').Length != 2) { L("NOTTOP|" + w + "|" + best.Key); return; }
            var na = del ? Multicad.Geometry.Arrows.None : (Multicad.Geometry.Arrows)Enum.Parse(typeof(Multicad.Geometry.Arrows), arr, true);
            string what = del ? "DELETE" : na.ToString();
            if (dry) { L("HIT|" + w + "|" + best.Key + "|" + best.Value.Arrow + " => " + what); return; }
            var ent = o as McEntity;
            if (ent != null && !ent.TryModify()) { L("FAILMOD|" + w); return; }
            var old = best.Value.Arrow;
            if (del)
            {
                // ВНИМАНИЕ: индекс DelSegment не совпадает с порядком Childs (22.10: DelSegment(2) удалил ветку /4).
                // Поэтому после удаления проверяем, что пропала именно нужная ветка; иначе файл не сохраняется.
                double sx = best.Value.Start.X, sy = best.Value.Start.Y;
                int di = top; string dis = Environment.GetEnvironmentVariable("TXT_DELIDX");   // подбор индекса DelSegment
                if (!string.IsNullOrEmpty(dis)) di = int.Parse(dis);
                bool ok = leader.DelSegment(di); L("DELSEG|" + w + "|" + di + "|" + ok);
                for (int i = 0; i < leader.Childs.Count; i++)
                    L("AFTER|" + w + "|/" + i + "|" + leader.Childs[i].Start.X.ToString("F1", ci) + "," + leader.Childs[i].Start.Y.ToString("F1", ci));
                bool still = false;
                for (int i = 0; i < leader.Childs.Count; i++)
                    if (Math.Abs(leader.Childs[i].Start.X - sx) < 1e-6 && Math.Abs(leader.Childs[i].Start.Y - sy) < 1e-6) still = true;
                if (!ok || still) { L("WRONGDEL|" + w + "|удалена не та ветка — файл не сохраняется"); abort = true; return; }
            }
            else best.Value.Arrow = na;   // ВНИМАНИЕ: у McNotePosition стрелка общая — меняется у всех веток (22.10)
            changed++;
            if (ent != null) ent.DbEntity.Update();
            L("HIT|" + w + "|" + best.Key + "|" + old + " => " + what + "|segments=" + leader.Childs.Count);
        }

        // TXT_HANDLES — список handle через запятую: в текстовом режиме обрабатываются только эти объекты (пусто — все).
        static bool HandleOk(ObjectId id)
        {
            string hs = Environment.GetEnvironmentVariable("TXT_HANDLES");
            if (string.IsNullOrEmpty(hs)) return true;
            foreach (string h in hs.Split(','))
                if (string.Equals(h.Trim(), id.Handle.ToString(), StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        static void FixMc(ObjectId id, string w)
        {
            if (!HandleOk(id)) { L("MC|" + w + "|skip"); return; }
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
                        if (v != null && open())
                        {
                            cell.Value = v; changed++;
                            // TXT_CELLFIT = None/Shrink/Wrap — режим вписывания текста в изменённых ячейках (длинный текст не вылезает за графу)
                            string fit = Environment.GetEnvironmentVariable("TXT_CELLFIT");
                            if (!string.IsNullOrEmpty(fit))
                            {
                                var hf = cell.HorzFits;
                                cell.HorzFits = (HorizontalFitsEnum)Enum.Parse(typeof(HorizontalFitsEnum), fit, true);
                                L("CELLFIT|" + w + "|cell " + r + "," + c + "|" + hf + " => " + cell.HorzFits);
                            }
                            // TXT_CELLXSCALE = 0.85 — сжатие текста (коэффициент ширины) в изменённых ячейках; Shrink в пакетном режиме не отрисовывается
                            string xs = Environment.GetEnvironmentVariable("TXT_CELLXSCALE");
                            if (!string.IsNullOrEmpty(xs))
                            {
                                double ox = cell.TextXScale;
                                cell.TextXScale = double.Parse(xs, System.Globalization.CultureInfo.InvariantCulture);
                                L("CELLXSCALE|" + w + "|cell " + r + "," + c + "|" + ox + " => " + cell.TextXScale);
                            }
                        }
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
