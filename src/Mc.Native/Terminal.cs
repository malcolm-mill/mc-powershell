using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Mc.Native
{
    /// <summary>
    /// Terminal lifecycle: raw-ish mode, alternate screen buffer, UTF-8 output,
    /// and guaranteed restore. Everything here is idempotent so a crashed app
    /// can still call Shutdown() from a finally block.
    /// </summary>
    public static class Terminal
    {
        static readonly string Esc = ((char)27).ToString();
        static TextWriter _out;
        static bool _initialised;
        static Encoding _savedOutputEncoding;
        static bool _savedCursorVisible = true;

        const int STD_OUTPUT_HANDLE = -11;
        const int STD_INPUT_HANDLE = -10;
        const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
        const uint DISABLE_NEWLINE_AUTO_RETURN = 0x0008;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        /// <summary>True when the host terminal accepted VT escape sequences.</summary>
        public static bool VtEnabled { get; private set; }

        static bool IsWindows
        {
            get { return RuntimeInformation.IsOSPlatform(OSPlatform.Windows); }
        }

        public static void Init()
        {
            if (_initialised) return;

            // A big buffered writer: the renderer emits one frame as one Write.
            var stdout = Console.OpenStandardOutput();
            _out = new StreamWriter(stdout, new UTF8Encoding(false), 1 << 16) { AutoFlush = false };

            _savedOutputEncoding = Console.OutputEncoding;
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }

            VtEnabled = true;
            if (IsWindows)
            {
                VtEnabled = TryEnableWindowsVt();
            }

            try { _savedCursorVisible = Console.CursorVisible; } catch { }
            try { Console.TreatControlCAsInput = true; } catch { }

            // Raw key + mouse input. Must come after TreatControlCAsInput,
            // whose setter rewrites the console mode we are about to save.
            Input.Start(true);

            Emit("[?1049h");   // alternate screen buffer
            Emit("[?7l");      // disable autowrap: no scroll on the bottom-right cell
            Emit("[?25l");     // hide cursor
            Emit("[2J");       // clear
            Flush();

            _initialised = true;
        }

        public static void Shutdown()
        {
            if (!_initialised) return;

            // Restore the console mode before anything else touches the
            // terminal, so a shell-out gets ordinary cooked input back.
            Input.Stop();

            try
            {
                Emit("[0m");
                Emit("[?7h");
                Emit("[?25h");
                Emit("[?1049l");   // back to the primary buffer, scrollback intact
                Flush();
            }
            catch { }

            try { Console.CursorVisible = _savedCursorVisible; } catch { }
            try { Console.TreatControlCAsInput = false; } catch { }
            try { if (_savedOutputEncoding != null) Console.OutputEncoding = _savedOutputEncoding; } catch { }

            _initialised = false;
        }

        static bool TryEnableWindowsVt()
        {
            try
            {
                IntPtr h = GetStdHandle(STD_OUTPUT_HANDLE);
                uint mode;
                if (!GetConsoleMode(h, out mode)) return false;
                uint want = mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
                if (want == mode) return true;
                return SetConsoleMode(h, want);
            }
            catch { return false; }
        }

        /// <summary>Append an escape sequence (without the leading ESC) to the output buffer.</summary>
        static void Emit(string seq)
        {
            if (_out == null) return;
            _out.Write(Esc);
            _out.Write(seq);
        }

        public static void Write(string s)
        {
            if (_out == null) { Console.Write(s); return; }
            _out.Write(s);
            _out.Flush();
        }

        public static void Flush()
        {
            if (_out != null) _out.Flush();
        }

        public static bool TryGetSize(out int width, out int height)
        {
            try
            {
                width = Console.WindowWidth;
                height = Console.WindowHeight;
                if (width < 1) width = 80;
                if (height < 1) height = 25;
                return true;
            }
            catch
            {
                width = 80; height = 25;
                return false;
            }
        }
    }
}
