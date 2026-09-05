using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace Mc.Native
{
    public enum InputKind { Key = 0, Mouse = 1, Resize = 2 }

    /// <summary>
    /// One thing the user did. Key events carry a canonical name; mouse events
    /// carry a cell coordinate and a button.
    /// </summary>
    public sealed class InputEvent
    {
        public InputKind Kind;
        public string Key;              // canonical name, e.g. "up", "C-o", "f5"
        public int X;                   // 0-based column
        public int Y;                   // 0-based row
        public string Button;           // left | right | middle | wheelup | wheeldown
        public bool Pressed;            // true on press, false on release
        public bool Double;             // double-click

        // Raw values, for the key diagnostic in tools/keytest.ps1.
        public int RawKeyCode;
        public char RawChar;
        public uint RawControlState;
        public bool Ctrl, Alt, Shift;

        public override string ToString()
        {
            return Kind == InputKind.Key
                ? "key " + Key
                : "mouse " + Button + " " + X + "," + Y;
        }
    }

    /// <summary>
    /// Input source. Console.ReadKey discards mouse events entirely, so on
    /// Windows we read the console input queue directly, which also gives
    /// better key fidelity than ReadKey. Everywhere else we fall back to
    /// ReadKey and report no mouse; the shape of the API is the same either
    /// way, so the PowerShell side never branches on platform.
    /// </summary>
    public static class Input
    {
        const int STD_INPUT_HANDLE = -10;

        const uint ENABLE_PROCESSED_INPUT = 0x0001;
        const uint ENABLE_LINE_INPUT = 0x0002;
        const uint ENABLE_ECHO_INPUT = 0x0004;
        const uint ENABLE_WINDOW_INPUT = 0x0008;
        const uint ENABLE_MOUSE_INPUT = 0x0010;
        const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
        const uint ENABLE_EXTENDED_FLAGS = 0x0080;
        const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;

        const ushort KEY_EVENT = 0x0001;
        const ushort MOUSE_EVENT = 0x0002;
        const ushort WINDOW_BUFFER_SIZE_EVENT = 0x0004;

        const uint MOUSE_MOVED = 0x0001;
        const uint DOUBLE_CLICK = 0x0002;
        const uint MOUSE_WHEELED = 0x0004;
        const uint MOUSE_HWHEELED = 0x0008;

        const uint RIGHT_ALT_PRESSED = 0x0001;
        const uint LEFT_ALT_PRESSED = 0x0002;
        const uint RIGHT_CTRL_PRESSED = 0x0004;
        const uint LEFT_CTRL_PRESSED = 0x0008;
        const uint SHIFT_PRESSED = 0x0010;

        [StructLayout(LayoutKind.Sequential)]
        struct COORD { public short X; public short Y; }

        [StructLayout(LayoutKind.Sequential)]
        struct KEY_EVENT_RECORD
        {
            public int bKeyDown;          // Win32 BOOL: 4 bytes, not 1
            public ushort wRepeatCount;
            public ushort wVirtualKeyCode;
            public ushort wVirtualScanCode;
            public ushort UnicodeChar;    // WCHAR, kept as ushort to stay blittable
            public uint dwControlKeyState;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MOUSE_EVENT_RECORD
        {
            public COORD dwMousePosition;
            public uint dwButtonState;
            public uint dwControlKeyState;
            public uint dwEventFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WINDOW_BUFFER_SIZE_RECORD { public COORD dwSize; }

        [StructLayout(LayoutKind.Explicit)]
        struct INPUT_RECORD
        {
            [FieldOffset(0)] public ushort EventType;
            [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
            [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
            [FieldOffset(4)] public WINDOW_BUFFER_SIZE_RECORD WindowBufferSizeEvent;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetConsoleMode(IntPtr h, out uint mode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetConsoleMode(IntPtr h, uint mode);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool ReadConsoleInput(IntPtr h, out INPUT_RECORD buffer, uint length, out uint read);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool PeekConsoleInput(IntPtr h, out INPUT_RECORD buffer, uint length, out uint read);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        static IntPtr _inHandle = IntPtr.Zero;
        static uint _savedMode;
        static bool _native;              // true when the Windows backend is live
        static uint _lastButtons;

        /// <summary>True when mouse events can actually be delivered.</summary>
        public static bool MouseEnabled { get; private set; }

        static bool IsWindows
        {
            get { return RuntimeInformation.IsOSPlatform(OSPlatform.Windows); }
        }

        /// <summary>
        /// What the input layer actually managed to set up. Printed by
        /// tools/keytest.ps1 -- when keys or the mouse misbehave, this says
        /// whether the native backend is even in play.
        /// </summary>
        public static string Diagnostics()
        {
            uint current = 0;
            bool haveMode = false;
            try { haveMode = _inHandle != IntPtr.Zero && GetConsoleMode(_inHandle, out current); }
            catch { haveMode = false; }

            int recordSize = Marshal.SizeOf(typeof(INPUT_RECORD));

            return string.Join(Environment.NewLine, new[]
            {
                "platform         : " + (IsWindows ? "windows" : "other"),
                "native backend   : " + (_native ? "yes (ReadConsoleInput)" : "no (Console.ReadKey fallback)"),
                "mouse enabled    : " + MouseEnabled,
                "input handle     : 0x" + _inHandle.ToInt64().ToString("x"),
                "saved mode       : 0x" + _savedMode.ToString("x"),
                "current mode     : " + (haveMode ? "0x" + current.ToString("x") : "unavailable"),
                "INPUT_RECORD size: " + recordSize + " (expected 20)",
                "input redirected : " + Console.IsInputRedirected,
                "native failures  : " + NativeFailures
            });
        }

        public static void Start(bool enableMouse)
        {
            if (_native) return;
            MouseEnabled = false;
            if (!IsWindows) return;       // ReadKey fallback, no mouse

            try
            {
                _inHandle = GetStdHandle(STD_INPUT_HANDLE);
                if (_inHandle == IntPtr.Zero || _inHandle == new IntPtr(-1)) return;
                if (!GetConsoleMode(_inHandle, out _savedMode)) return;

                // Raw: no line editing, no echo, no Ctrl+C signal. QuickEdit
                // must go or the terminal eats clicks for text selection, and
                // it only takes effect alongside EXTENDED_FLAGS.
                uint mode = _savedMode;
                mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT
                          | ENABLE_QUICK_EDIT_MODE | ENABLE_VIRTUAL_TERMINAL_INPUT);
                mode |= ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS;
                if (enableMouse) mode |= ENABLE_MOUSE_INPUT;

                if (!SetConsoleMode(_inHandle, mode)) return;

                _native = true;
                _lastButtons = 0;
                MouseEnabled = enableMouse;
            }
            catch
            {
                _native = false;
                MouseEnabled = false;
            }
        }

        public static void Stop()
        {
            if (!_native) { MouseEnabled = false; return; }
            try { SetConsoleMode(_inHandle, _savedMode); } catch { }
            _native = false;
            MouseEnabled = false;
        }

        /// <summary>
        /// Wait up to <paramref name="timeoutMs"/> for an event; null on timeout.
        /// </summary>
        public static InputEvent Read(int timeoutMs)
        {
            if (!_native) return ReadFallback(timeoutMs);

            try
            {
                return ReadNative(timeoutMs);
            }
            catch
            {
                // Never let the native backend leave the app with a dead
                // keyboard: give up on it permanently and degrade to ReadKey.
                NativeFailures++;
                Stop();
                return ReadFallback(timeoutMs);
            }
        }

        /// <summary>Times the native backend failed and fell back. Should be 0.</summary>
        public static int NativeFailures { get; private set; }

        // --- ReadKey fallback (non-Windows, or if raw mode was refused) -----

        static InputEvent ReadFallback(int timeoutMs)
        {
            int waited = 0;
            const int tick = 15;
            while (true)
            {
                bool available;
                try { available = Console.KeyAvailable; } catch { available = false; }
                if (available)
                {
                    string name = Keys.Describe(Console.ReadKey(true));
                    if (name == null) continue;
                    return new InputEvent { Kind = InputKind.Key, Key = name };
                }
                if (waited >= timeoutMs) return null;
                Thread.Sleep(tick);
                waited += tick;
            }
        }

        // --- Windows console input queue ------------------------------------

        static InputEvent ReadNative(int timeoutMs)
        {
            var clock = System.Diagnostics.Stopwatch.StartNew();
            while (true)
            {
                int remaining = timeoutMs - (int)clock.ElapsedMilliseconds;
                if (remaining < 0) remaining = 0;

                uint wait = WaitForSingleObject(_inHandle, (uint)remaining);
                if (wait != 0) return null;                  // 0 == WAIT_OBJECT_0

                INPUT_RECORD record;
                uint read;
                if (!ReadConsoleInput(_inHandle, out record, 1, out read))
                    throw new InvalidOperationException(
                        "ReadConsoleInput failed, error " + Marshal.GetLastWin32Error());
                if (read == 0) return null;

                InputEvent ev = Translate(record);
                if (ev != null) return ev;

                // Key release, mouse move, modifier: keep waiting on the same
                // deadline rather than restarting the clock.
                if (clock.ElapsedMilliseconds >= timeoutMs) return null;
            }
        }

        static InputEvent Translate(INPUT_RECORD record)
        {
            switch (record.EventType)
            {
                case KEY_EVENT: return TranslateKey(record.KeyEvent);
                case MOUSE_EVENT: return TranslateMouse(record.MouseEvent);
                case WINDOW_BUFFER_SIZE_EVENT: return new InputEvent { Kind = InputKind.Resize };
                default: return null;
            }
        }

        static InputEvent TranslateKey(KEY_EVENT_RECORD k)
        {
            string name = Keys.DescribeConsoleKey(k.wVirtualKeyCode, (char)k.UnicodeChar,
                                                  k.dwControlKeyState, k.bKeyDown != 0);
            if (name == null) return null;

            return new InputEvent
            {
                Kind = InputKind.Key,
                Key = name,
                Ctrl = (k.dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0,
                Alt = (k.dwControlKeyState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0,
                Shift = (k.dwControlKeyState & SHIFT_PRESSED) != 0,
                RawKeyCode = k.wVirtualKeyCode,
                RawChar = (char)k.UnicodeChar,
                RawControlState = k.dwControlKeyState
            };
        }

        static InputEvent TranslateMouse(MOUSE_EVENT_RECORD m)
        {
            bool ctrl = (m.dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0;
            bool alt = (m.dwControlKeyState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED)) != 0;
            bool shift = (m.dwControlKeyState & SHIFT_PRESSED) != 0;

            if ((m.dwEventFlags & MOUSE_HWHEELED) != 0) return null;

            if ((m.dwEventFlags & MOUSE_WHEELED) != 0)
            {
                short delta = (short)((m.dwButtonState >> 16) & 0xFFFF);
                return new InputEvent
                {
                    Kind = InputKind.Mouse,
                    Button = delta > 0 ? "wheelup" : "wheeldown",
                    Pressed = true,
                    X = m.dwMousePosition.X,
                    Y = m.dwMousePosition.Y,
                    Ctrl = ctrl, Alt = alt, Shift = shift
                };
            }

            if ((m.dwEventFlags & MOUSE_MOVED) != 0) return null;

            uint buttons = m.dwButtonState & 0x7;
            uint changed = buttons ^ _lastButtons;
            bool doubleClick = (m.dwEventFlags & DOUBLE_CLICK) != 0;
            _lastButtons = buttons;

            // A double-click arrives with no state change, so treat it as a press.
            if (changed == 0 && !doubleClick) return null;

            uint which = changed != 0 ? changed : buttons;
            bool pressed = doubleClick || (buttons & which) != 0;

            string button;
            if ((which & 0x1) != 0) button = "left";
            else if ((which & 0x2) != 0) button = "right";
            else if ((which & 0x4) != 0) button = "middle";
            else return null;

            return new InputEvent
            {
                Kind = InputKind.Mouse,
                Button = button,
                Pressed = pressed,
                Double = doubleClick,
                X = m.dwMousePosition.X,
                Y = m.dwMousePosition.Y,
                Ctrl = ctrl, Alt = alt, Shift = shift
            };
        }
    }
}
