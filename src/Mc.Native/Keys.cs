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

        /// <summary>
        /// Translate a raw Windows console key event into a canonical name.
        /// Returns null for anything that is not an event in its own right
        /// (a key release, a bare modifier).
        ///
        /// This is a pure function on purpose: it is the whole translation
        /// table, and keeping it free of console handles is what lets the
        /// tests cover it without a terminal.
        /// </summary>
        public static string DescribeConsoleKey(int virtualKeyCode, char unicodeChar,
                                                uint controlKeyState, bool keyDown)
        {
            const uint RIGHT_ALT_PRESSED = 0x0001;
            const uint LEFT_ALT_PRESSED = 0x0002;
            const uint RIGHT_CTRL_PRESSED = 0x0004;
            const uint LEFT_CTRL_PRESSED = 0x0008;
            const uint SHIFT_PRESSED = 0x0010;

            if (!keyDown) return null;

            bool ctrl = (controlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0;
            bool alt = (controlKeyState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0;
            bool shift = (controlKeyState & SHIFT_PRESSED) != 0;

            string name = VirtualKeyName(virtualKeyCode);
            if (name != null && name.Length == 0) return null;   // bare modifier or lock

            if (name == null)
            {
                if (unicodeChar >= ' ' && unicodeChar != (char)127)
                {
                    // A printable character. Shift is already in the glyph.
                    if (!ctrl && !alt) return unicodeChar.ToString();
                    name = char.ToLowerInvariant(unicodeChar).ToString();
                    shift = false;
                }
                else if (virtualKeyCode >= 'A' && virtualKeyCode <= 'Z')
                {
                    name = ((char)('a' + (virtualKeyCode - 'A'))).ToString();
                    shift = false;
                }
                else if (virtualKeyCode >= '0' && virtualKeyCode <= '9')
                {
                    name = ((char)virtualKeyCode).ToString();
                }
                else
                {
                    // Windows reports UnicodeChar as 0 for Alt combinations, so
                    // punctuation keys need naming from the virtual key code or
                    // bindings like Alt+. (toggle hidden files) never arrive.
                    name = OemKeyName(virtualKeyCode);
                    if (name == null) return null;
                    shift = false;
                }
            }

            string prefix = string.Empty;
            if (ctrl) prefix += "C-";
            if (alt) prefix += "M-";
            if (shift) prefix += "S-";
            return prefix + name;
        }

        /// <summary>Unshifted character for the OEM punctuation keys.</summary>
        public static string OemKeyName(int vk)
        {
            switch (vk)
            {
                case 0xBA: return ";";
                case 0xBB: return "=";
                case 0xBC: return ",";
                case 0xBD: return "-";
                case 0xBE: return ".";
                case 0xBF: return "/";
                case 0xC0: return "`";
                case 0xDB: return "[";
                case 0xDC: return "\\";
                case 0xDD: return "]";
                case 0xDE: return "'";
                default: return null;
            }
        }

        /// <summary>Named keys by Windows virtual key code. "" means "ignore".</summary>
        public static string VirtualKeyName(int vk)
        {
            switch (vk)
            {
                case 0x08: return "backspace";
                case 0x09: return "tab";
                case 0x0D: return "enter";
                case 0x1B: return "esc";
                case 0x20: return "space";
                case 0x21: return "pgup";
                case 0x22: return "pgdn";
                case 0x23: return "end";
                case 0x24: return "home";
                case 0x25: return "left";
                case 0x26: return "up";
                case 0x27: return "right";
                case 0x28: return "down";
                case 0x2D: return "ins";
                case 0x2E: return "del";

                // Bare modifiers and locks are not events on their own.
                case 0x10: case 0x11: case 0x12:
                case 0x14: case 0x90: case 0x91:
                case 0x5B: case 0x5C: case 0x5D:
                    return "";
            }

            if (vk >= 0x70 && vk <= 0x7B) return "f" + (vk - 0x70 + 1);
            return null;
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
