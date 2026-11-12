using System;
using System.Collections.Generic;
using SpdsText;

class RowDeletionCases
{
    sealed class Table : IRowTable
    {
        public List<string[]> Rows = new List<string[]>();
        public List<int> Deleted = new List<int>();
        public bool Began, Updated, RefuseModify, RefuseDelete, RefuseUpdate, WrongRow;
        public Table(params string[] text) { foreach (string s in text) Rows.Add(new [] { s }); }
        public int RowCount { get { return Rows.Count; } }
        public string[] ReadRow(int row) { return Rows[row]; }
        public bool BeginModify() { Began = true; return !RefuseModify; }
        public bool Delete(int row)
        {
            Deleted.Add(row);
            if (RefuseDelete) return false;
            Rows.RemoveAt(WrongRow ? 0 : row); return true;
        }
        public bool Update() { Updated = true; return !RefuseUpdate; }
    }
    static int checks;
    static void Assert(bool value) { checks++; if (!value) throw new Exception("assertion " + checks); }
    static int Run(string spec, Dictionary<string, Table> tables, bool dry)
    {
        return RowDeletion.Execute(RowDeletion.Parse(spec), h => tables.ContainsKey(h) ? tables[h] : null, dry, s => {});
    }
    static void Refuses(Action action)
    {
        try { action(); } catch (ArgumentException) { checks++; return; }
        catch (InvalidOperationException) { checks++; return; }
        throw new Exception("invalid plan accepted");
    }
    static int Main()
    {
        foreach (string spec in new [] { "", "A:1=", "A:1= ", "A:-1=x", "ZZ:1=x", "00:1=x", "A:1=x;", "A:1=x;a:1=x", "A:x=x", "A:2147483648=x" })
            Refuses(() => RowDeletion.Parse(spec));
        Assert(RowDeletion.Parse("a:0=кириллица=значение")[0].Expected == "кириллица=значение");
        var table = new Table("header", "delete one", "keep", "delete three");
        var tables = new Dictionary<string, Table> { { "A", table } };
        Assert(Run("A:1=ONE;A:3=three",tables,true)==0);
        Assert(!table.Began && !table.Updated && table.Rows.Count==4 && table.Deleted.Count==0);
        Assert(Run("A:1=ONE;A:3=three",tables,false)==2);
        Assert(table.Deleted[0]==3 && table.Deleted[1]==1 && table.Rows.Count==2 && table.Rows[1][0]=="keep" && table.Updated);
        table = new Table("header","remove"); tables["A"] = table;
        Refuses(() => Run("A:1=remove;B:1=other",tables,false));
        Assert(!table.Began && table.Deleted.Count==0);
        tables["B"] = new Table("header","wrong");
        Refuses(() => Run("A:1=remove;B:1=expected",tables,false));
        Assert(!table.Began && table.Deleted.Count==0);
        Refuses(() => Run("A:3=remove",tables,true));
        Refuses(() => Run("A:1=absent",tables,true));
        table.RefuseModify = true; Refuses(() => Run("A:1=remove",tables,false));
        table.RefuseModify = false; table.RefuseDelete = true; Refuses(() => Run("A:1=remove",tables,false));
        table.RefuseDelete = false; table.RefuseUpdate = true; Refuses(() => Run("A:1=remove",tables,false));
        table = new Table("header","target","keep"); table.WrongRow=true; tables["A"]=table;
        Refuses(() => Run("A:1=target",tables,false));
        // Multi-cell/multiline row, substring guard, case-insensitive Cyrillic.
        table = new Table("header","unused"); table.Rows[1]=new [] { "Заголовок", "Первая\nВТОРАЯ" }; tables["A"]=table;
        Assert(Run("A:1=вторая",tables,true)==0 && table.Rows.Count==2);
        Assert(Run("A:0=header",tables,false)==1 && table.Rows.Count==1);
        Console.WriteLine("OK: " + checks + " inert row deletion assertions; no vendor/CAD");
        return 0;
    }
}
