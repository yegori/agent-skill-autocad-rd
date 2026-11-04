// Managed dependency probing and ordered preload inside TXTFIX/acad.exe only.
// External build/check scripts must never load the real MultiCAD assemblies.
using System;
using System.IO;
using System.Reflection;

namespace SpdsText
{
    internal static class SpdsDependencies
    {
        static ResolveEventHandler handler;
        static string installationDirectory;
        static Action<string> writeLog;

        internal static void Install(string directory, Action<string> log)
        {
            if (string.IsNullOrEmpty(directory))
                directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                    "CSoft", "СПДС GraphiCS 2023 x64", "mg142x64");
            if (!Path.IsPathRooted(directory))
                throw new ArgumentException("RDCI_SPDS_DIR must be an absolute installation path.");
            directory = Path.GetFullPath(directory);
            if (!Directory.Exists(directory))
                throw new DirectoryNotFoundException("SPDS installation directory not found: " + directory);
            installationDirectory = directory;
            writeLog = log;
            if (handler != null) AppDomain.CurrentDomain.AssemblyResolve -= handler;
            handler = delegate(object sender, ResolveEventArgs args)
            {
                AssemblyName requested = new AssemblyName(args.Name);
                if (!string.Equals(requested.Name, "mapimgd", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(requested.Name, "mapibasetypes", StringComparison.OrdinalIgnoreCase))
                    return null;
                string path = Path.Combine(directory, requested.Name + ".dll");
                try
                {
                    AssemblyName actual = AssemblyName.GetAssemblyName(path);
                    if (!Matches(requested, actual))
                    {
                        log("DEPENDENCY_ERROR|identity mismatch|requested=" + args.Name + "|found=" + actual.FullName);
                        return null;
                    }
                    Assembly assembly = Assembly.LoadFrom(path);
                    log("DEPENDENCY|" + assembly.FullName + "|" + path);
                    return assembly;
                }
                catch (Exception ex)
                {
                    log("DEPENDENCY_ERROR|" + requested.Name + "|" + ex.GetType().Name + "|" + ex.Message);
                    return null;
                }
            };
            AppDomain.CurrentDomain.AssemblyResolve += handler;
            log("SPDS_DIR|" + directory);
        }

        // Resolve both before JIT-compiling methods with MultiCAD types. Loading
        // mapimgd only in AssemblyResolve was too late on a clean AutoCAD profile.
        internal static void Preload()
        {
            if (handler == null) throw new InvalidOperationException("Install the SPDS resolver first.");
            foreach (string name in new[] { "mapibasetypes", "mapimgd" })
            {
                AssemblyName requested = null;
                foreach (AssemblyName reference in typeof(SpdsDependencies).Assembly.GetReferencedAssemblies())
                    if (string.Equals(reference.Name, name, StringComparison.OrdinalIgnoreCase))
                        requested = reference;
                if (requested == null)
                    requested = AssemblyName.GetAssemblyName(Path.Combine(installationDirectory, name + ".dll"));
                string path = Path.Combine(installationDirectory, name + ".dll");
                AssemblyName actual = AssemblyName.GetAssemblyName(path);
                if (!string.Equals(actual.Name, name, StringComparison.OrdinalIgnoreCase) || !Matches(requested, actual))
                    throw new FileLoadException("SPDS assembly identity mismatch: " + requested.FullName + " / " + actual.FullName);
                Assembly assembly = Assembly.LoadFrom(path);
                writeLog("DEPENDENCY|" + assembly.FullName + "|" + path);
            }
        }

        static bool Matches(AssemblyName requested, AssemblyName actual)
        {
            if (!string.Equals(requested.Name, actual.Name, StringComparison.OrdinalIgnoreCase)) return false;
            if (requested.Version != null && requested.Version != actual.Version) return false;
            if (!string.Equals(requested.CultureName ?? "", actual.CultureName ?? "", StringComparison.OrdinalIgnoreCase)) return false;
            byte[] a = requested.GetPublicKeyToken() ?? new byte[0];
            byte[] b = actual.GetPublicKeyToken() ?? new byte[0];
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
            return true;
        }
    }
}
