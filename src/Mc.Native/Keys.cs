using System;
using System.Threading;

namespace Mc.Native
{
    /// <summary>
    /// Turns host key events into canonical names so the PowerShell side never
    /// sees a ConsoleKeyInfo. Names look like: "up", "enter", "f5", "C-o",
    /// "M-f", "S-f3", "C-M-r", "a". Keymaps are written against these.
    /// </summary>
    public static class Keys
    {
        public static bool Available
        {
            get { try { return Console.KeyAvailable; } catch { return false; } }
        }

        /// <summary>Block until a key arrives.</summary>
        public static string Read()
        {
            return Describe(Console.ReadKey(true));
        }

        /// <summary>Wait up to <paramref name="ms"/> for a key; null on timeout.</summary>
        public static string ReadTimeout(int ms)
        {
            int waited = 0;
            const int tick = 15;
            while (waited < ms)
            {
                if (Available) return Read();
                Thread.Sleep(tick);
                waited += tick;
            }
            return Available ? Read() : null;
        }

        public static string Describe(ConsoleKeyInfo k)
        {
            bool ctrl = (k.Modifiers & ConsoleModifiers.Control) != 0;
            bool alt = (k.Modifiers & ConsoleModifiers.Alt) != 0;
            bool shift = (k.Modifiers & ConsoleModifiers.Shift) != 0;

            string name = BaseName(k, ref shift);
            if (name == null) return null;

            string prefix = string.Empty;
            if (ctrl) prefix += "C-";
            if (alt) prefix += "M-";
            if (shift) prefix += "S-";
            return prefix + name;
        }

        /// <summary>
        /// The unmodified key name. Shift is folded into the character itself for
        /// printable keys (so Shift+a is "A", not "S-a") and kept as a modifier
        /// for named keys (Shift+F3 is "S-f3").
        /// </summary>
        static string BaseName(ConsoleKeyInfo k, ref bool shift)
        {
            switch (k.Key)
            {
                case ConsoleKey.UpArrow: return "up";
                case ConsoleKey.DownArrow: return "down";
                case ConsoleKey.LeftArrow: return "left";
                case ConsoleKey.RightArrow: return "right";
                case ConsoleKey.Home: return "home";
                case ConsoleKey.End: return "end";
                case ConsoleKey.PageUp: return "pgup";
                case ConsoleKey.PageDown: return "pgdn";
                case ConsoleKey.Insert: return "ins";
                case ConsoleKey.Delete: return "del";
                case ConsoleKey.Backspace: return "backspace";
                case ConsoleKey.Tab: return "tab";
                case ConsoleKey.Enter: return "enter";
                case ConsoleKey.Escape: return "esc";
                case ConsoleKey.Spacebar: return "space";
            }

            if (k.Key >= ConsoleKey.F1 && k.Key <= ConsoleKey.F24)
            {
                int n = (int)k.Key - (int)ConsoleKey.F1 + 1;
                return "f" + n;
            }

            char c = k.KeyChar;
            if (c >= ' ' && c != (char)127)
            {
                shift = false;                       // already encoded in the glyph
                return c.ToString();
            }

            // Control characters: recover the letter from the key code.
            if (k.Key >= ConsoleKey.A && k.Key <= ConsoleKey.Z)
            {
                shift = false;
                return ((char)('a' + (k.Key - ConsoleKey.A))).ToString();
            }
            if (k.Key >= ConsoleKey.D0 && k.Key <= ConsoleKey.D9)
            {
                return ((char)('0' + (k.Key - ConsoleKey.D0))).ToString();
            }

            return null;
        }
    }
}
