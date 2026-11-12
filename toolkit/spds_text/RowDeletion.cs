// Pure C# 5 guarded row-deletion plan. No Autodesk/MultiCAD loading in unit tests.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace SpdsText
{
    public interface IRowTable
    {
        int RowCount { get; }
        string[] ReadRow(int row);
        bool BeginModify();
        bool Delete(int row);
        bool Update();
    }

    public sealed class RowRequest
    {
        public string Handle;
        public int Row;
        public string Expected;
    }

    public static class RowDeletion
    {
        public static List<RowRequest> Parse(string specification)
        {
            if (string.IsNullOrWhiteSpace(specification) || specification.Length > 16384)
                throw new ArgumentException("rowdel_spec_required_or_too_large");
            var result = new List<RowRequest>();
            var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string part in specification.Split(';'))
            {
                int colon = part.IndexOf(':'), equal = part.IndexOf('=', colon + 1);
                if (colon < 1 || equal < colon + 2) throw new ArgumentException("rowdel_invalid_entry");
                string handle = part.Substring(0, colon).Trim().ToUpperInvariant();
                int row;
                if (!Regex.IsMatch(handle, "^[0-9A-F]{1,16}$") || handle[0] == '0' ||
                    !int.TryParse(part.Substring(colon + 1, equal - colon - 1), NumberStyles.None, CultureInfo.InvariantCulture, out row))
                    throw new ArgumentException("rowdel_invalid_handle_or_zero_based_row");
                string expected = part.Substring(equal + 1);
                if (string.IsNullOrWhiteSpace(expected)) throw new ArgumentException("rowdel_nonempty_guard_required");
                if (!keys.Add(handle + ":" + row)) throw new ArgumentException("rowdel_duplicate_target");
                result.Add(new RowRequest { Handle = handle, Row = row, Expected = expected });
            }
            if (result.Count > 100) throw new ArgumentException("rowdel_too_many_targets");
            return result;
        }

        sealed class Plan
        {
            internal string Handle;
            internal IRowTable Table;
            internal List<RowRequest> Requests = new List<RowRequest>();
            internal List<string[]> Before = new List<string[]>();
        }

        public static int Execute(List<RowRequest> requests, Func<string, IRowTable> resolve, bool dry, Action<string> log)
        {
            var plans = new Dictionary<string, Plan>(StringComparer.OrdinalIgnoreCase);
            // Resolve and capture ALL tables/guards before any TryModify or Delete.
            foreach (RowRequest request in requests)
            {
                Plan plan;
                if (!plans.TryGetValue(request.Handle, out plan))
                {
                    var table = resolve(request.Handle);
                    if (table == null) throw new InvalidOperationException("rowdel_table_not_found:" + request.Handle);
                    plan = new Plan { Handle = request.Handle, Table = table };
                    int count = table.RowCount;
                    if (count < 1 || count > 10000) throw new InvalidOperationException("rowdel_table_size_limit");
                    int cells = 0;
                    for (int i = 0; i < count; i++)
                    {
                        string[] row = table.ReadRow(i);
                        if (row == null) throw new InvalidOperationException("rowdel_unreadable_row");
                        cells += row.Length;
                        if (cells > 100000) throw new InvalidOperationException("rowdel_cell_limit");
                        plan.Before.Add((string[])row.Clone());
                    }
                    plans.Add(request.Handle, plan);
                }
                if (request.Row >= plan.Before.Count) throw new InvalidOperationException("rowdel_row_out_of_range");
                string text = string.Join("|", plan.Before[request.Row]);
                log("ROWDEL|" + request.Handle + "|row " + request.Row + "|before=" + text.Replace("\r", "\\r").Replace("\n", "\\n"));
                if (text.IndexOf(request.Expected, StringComparison.OrdinalIgnoreCase) < 0)
                    throw new InvalidOperationException("rowdel_guard_mismatch:" + request.Handle + ":" + request.Row);
                plan.Requests.Add(request);
            }
            int changed = 0;
            foreach (Plan plan in plans.Values)
            {
                plan.Requests.Sort((a, b) => b.Row.CompareTo(a.Row));
                if (dry)
                {
                    foreach (RowRequest request in plan.Requests)
                        log("ROWDEL|" + plan.Handle + "|row " + request.Row + "|dry=True|would_delete=True");
                    continue;
                }
                if (!plan.Table.BeginModify()) throw new InvalidOperationException("rowdel_modify_refused");
                var expectedRows = new List<string[]>(plan.Before);
                foreach (RowRequest request in plan.Requests)
                {
                    int beforeCount = plan.Table.RowCount;
                    bool deleted = plan.Table.Delete(request.Row);
                    log("ROWDEL|" + plan.Handle + "|row " + request.Row + "|deleted=" + deleted);
                    if (!deleted || plan.Table.RowCount != beforeCount - 1)
                        throw new InvalidOperationException("rowdel_delete_failed");
                    expectedRows.RemoveAt(request.Row);
                    changed++;
                }
                if (!plan.Table.Update()) throw new InvalidOperationException("rowdel_update_failed");
                if (plan.Table.RowCount != expectedRows.Count) throw new InvalidOperationException("rowdel_count_mismatch");
                for (int row = 0; row < expectedRows.Count; row++)
                {
                    string[] actual = plan.Table.ReadRow(row), expected = expectedRows[row];
                    if (actual == null || actual.Length != expected.Length) throw new InvalidOperationException("rowdel_remaining_rows_mismatch");
                    for (int c = 0; c < actual.Length; c++)
                        if (!string.Equals(actual[c], expected[c], StringComparison.Ordinal))
                            throw new InvalidOperationException("rowdel_remaining_rows_mismatch");
                }
            }
            return changed;
        }
    }
}
