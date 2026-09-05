using System;
using System.Collections.Generic;
using System.IO;

namespace Mc.Native
{
    /// <summary>
    /// One row in a panel. Deliberately provider-agnostic: a file, a registry
    /// key, an environment variable and a certificate all arrive as this.
    /// <see cref="Item"/> carries the real underlying object so PowerShell-side
    /// commands and plugins can work with it directly.
    /// </summary>
    public sealed class PanelEntry
    {
        public string Name;             // display name
        public string Key;              // identity used to descend (path, etc.)
        public bool IsContainer;        // can Enter descend into it?
        public bool IsUp;               // the ".." row
        public long Size = -1;          // -1 = not applicable
        public DateTime Modified = DateTime.MinValue;
        public string Tag = "";         // short marker: DIR, LNK, extension, provider type
        public bool Marked;             // tagged with Insert / +
        public object Item;             // underlying object (FileSystemInfo, PSObject, ...)

        public override string ToString() { return Name; }
    }

    /// <summary>Sort fields shared by every panel source.</summary>
    public enum SortField { Name = 0, Extension = 1, Size = 2, Modified = 3, Unsorted = 4 }

    /// <summary>
    /// Fast filesystem enumeration. This is the hot path that a script
    /// implementation would lose on, so it lives in C#; every other provider
    /// is enumerated on the PowerShell side and mapped onto PanelEntry.
    /// </summary>
    public static class Fs
    {
        public static PanelEntry[] List(string path, bool showHidden)
        {
            var result = new List<PanelEntry>(256);

            DirectoryInfo dir;
            try { dir = new DirectoryInfo(path); }
            catch { return result.ToArray(); }

            if (dir.Parent != null || HasRootParent(dir))
            {
                result.Add(new PanelEntry
                {
                    Name = "..",
                    Key = dir.Parent != null ? dir.Parent.FullName : null,
                    IsContainer = true,
                    IsUp = true,
                    Tag = "UP"
                });
            }

            IEnumerable<FileSystemInfo> items;
            try { items = dir.EnumerateFileSystemInfos(); }
            catch (UnauthorizedAccessException) { return result.ToArray(); }
            catch (IOException) { return result.ToArray(); }

            var it = items.GetEnumerator();
            while (true)
            {
                // A single unreadable entry must not abort the whole listing.
                FileSystemInfo fsi;
                try { if (!it.MoveNext()) break; fsi = it.Current; }
                catch (UnauthorizedAccessException) { continue; }
                catch (IOException) { break; }

                FileAttributes attr;
                try { attr = fsi.Attributes; } catch { continue; }

                bool hidden = (attr & FileAttributes.Hidden) != 0
                           || (attr & FileAttributes.System) != 0;
                if (hidden && !showHidden) continue;

                bool isDir = (attr & FileAttributes.Directory) != 0;
                bool isLink = (attr & FileAttributes.ReparsePoint) != 0;

                var e = new PanelEntry
                {
                    Name = fsi.Name,
                    Key = fsi.FullName,
                    IsContainer = isDir,
                    Item = fsi
                };

                try { e.Modified = fsi.LastWriteTime; } catch { }

                if (isDir) e.Tag = isLink ? "LNK" : "DIR";
                else
                {
                    var fi = fsi as FileInfo;
                    if (fi != null) { try { e.Size = fi.Length; } catch { e.Size = -1; } }
                    string ext = fsi.Extension;
                    e.Tag = isLink ? "LNK" : (ext.Length > 1 ? ext.Substring(1).ToUpperInvariant() : "");
                }

                result.Add(e);
            }

            return result.ToArray();
        }

        static bool HasRootParent(DirectoryInfo dir)
        {
            // A drive root has no parent but should still offer ".." to reach the drive list.
            return false;
        }

        /// <summary>
        /// Stable sort with the mc convention: ".." first, then containers, then leaves.
        /// </summary>
        public static void Sort(PanelEntry[] entries, SortField field, bool descending, bool dirsFirst)
        {
            if (entries == null || entries.Length < 2) return;
            if (field == SortField.Unsorted) return;

            var cmp = Comparer<PanelEntry>.Create((a, b) =>
            {
                if (a.IsUp != b.IsUp) return a.IsUp ? -1 : 1;
                if (dirsFirst && a.IsContainer != b.IsContainer) return a.IsContainer ? -1 : 1;

                int r;
                switch (field)
                {
                    case SortField.Size:
                        r = a.Size.CompareTo(b.Size); break;
                    case SortField.Modified:
                        r = a.Modified.CompareTo(b.Modified); break;
                    case SortField.Extension:
                        r = string.Compare(a.Tag, b.Tag, StringComparison.OrdinalIgnoreCase);
                        if (r == 0) r = string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
                        break;
                    default:
                        r = string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); break;
                }
                if (r == 0) r = string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
                return descending ? -r : r;
            });

            Array.Sort(entries, cmp);
        }

        /// <summary>Human-readable size in the mc style (right-aligned, short).</summary>
        public static string FormatSize(long bytes)
        {
            if (bytes < 0) return "";
            if (bytes < 1024) return bytes.ToString();
            string[] units = { "K", "M", "G", "T", "P" };
            double v = bytes;
            int u = -1;
            while (v >= 1024 && u < units.Length - 1) { v /= 1024; u++; }
            return (v < 10 ? v.ToString("0.0") : v.ToString("0")) + units[u];
        }
    }
}
