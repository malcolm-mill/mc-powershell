using System;
using System.Text;

namespace Mc.Native
{
    /// <summary>One character cell: glyph plus 256-colour attributes.</summary>
    public struct Cell : IEquatable<Cell>
    {
        public char Ch;
        public byte Fg;
        public byte Bg;
        public byte Attr;           // bit0 bold, bit1 reverse, bit2 underline

        public bool Equals(Cell o)
        {
            return Ch == o.Ch && Fg == o.Fg && Bg == o.Bg && Attr == o.Attr;
        }
    }

    /// <summary>
    /// Double-buffered character grid. All drawing goes into the back buffer;
    /// Flush() diffs against the front buffer and emits one ANSI string.
    /// This is the only place in the project that talks to stdout.
    /// </summary>
    public sealed class Screen
    {
        const byte AttrBold = 1;
        const byte AttrReverse = 2;
        const byte AttrUnderline = 4;
        static readonly string Esc = ((char)27).ToString();

        Cell[] _back;
        Cell[] _front;
        int _w, _h;
        bool _full = true;

        readonly StringBuilder _sb = new StringBuilder(1 << 16);

        public int Width { get { return _w; } }
        public int Height { get { return _h; } }

        public Screen(int width, int height) { Resize(width, height); }

        public void Resize(int width, int height)
        {
            if (width < 1) width = 1;
            if (height < 1) height = 1;
            if (width == _w && height == _h) return;
            _w = width; _h = height;
            _back = new Cell[_w * _h];
            _front = new Cell[_w * _h];
            _full = true;
            Clear(7, 0);
        }

        /// <summary>Force a complete repaint on the next Flush.</summary>
        public void Invalidate() { _full = true; }

        public void Clear(byte fg, byte bg)
        {
            for (int i = 0; i < _back.Length; i++)
            {
                _back[i].Ch = ' ';
                _back[i].Fg = fg;
                _back[i].Bg = bg;
                _back[i].Attr = 0;
            }
        }

        public void Set(int x, int y, char ch, byte fg, byte bg, byte attr)
        {
            if (x < 0 || y < 0 || x >= _w || y >= _h) return;
            int i = y * _w + x;
            _back[i].Ch = ch < ' ' ? ' ' : ch;
            _back[i].Fg = fg;
            _back[i].Bg = bg;
            _back[i].Attr = attr;
        }

        /// <summary>Draw text, clipped to the screen. Returns cells written.</summary>
        public int Write(int x, int y, string s, byte fg, byte bg, byte attr)
        {
            if (s == null || y < 0 || y >= _h) return 0;
            int n = 0;
            for (int k = 0; k < s.Length; k++)
            {
                int cx = x + k;
                if (cx < 0) continue;
                if (cx >= _w) break;
                Set(cx, y, s[k], fg, bg, attr);
                n++;
            }
            return n;
        }

        /// <summary>Draw text padded or truncated to exactly <paramref name="width"/> cells.</summary>
        public void WriteFixed(int x, int y, string s, int width, byte fg, byte bg, byte attr)
        {
            if (width <= 0) return;
            if (s == null) s = string.Empty;
            if (s.Length > width) s = width > 1 ? s.Substring(0, width - 1) + "~" : "~";
            Write(x, y, s, fg, bg, attr);
            for (int k = s.Length; k < width; k++) Set(x + k, y, ' ', fg, bg, attr);
        }

        /// <summary>Draw text right-aligned in a fixed field (sizes, dates).</summary>
        public void WriteRight(int x, int y, string s, int width, byte fg, byte bg, byte attr)
        {
            if (width <= 0) return;
            if (s == null) s = string.Empty;
            if (s.Length > width) s = s.Substring(s.Length - width);
            int pad = width - s.Length;
            for (int k = 0; k < pad; k++) Set(x + k, y, ' ', fg, bg, attr);
            Write(x + pad, y, s, fg, bg, attr);
        }

        public void Fill(int x, int y, int w, int h, char ch, byte fg, byte bg, byte attr)
        {
            for (int yy = y; yy < y + h; yy++)
                for (int xx = x; xx < x + w; xx++)
                    Set(xx, yy, ch, fg, bg, attr);
        }

        /// <summary>Single- or double-line box in the classic mc style.</summary>
        public void Box(int x, int y, int w, int h, byte fg, byte bg, bool dbl)
        {
            if (w < 2 || h < 2) return;
            char tl = dbl ? '╔' : '┌';
            char tr = dbl ? '╗' : '┐';
            char bl = dbl ? '╚' : '└';
            char br = dbl ? '╝' : '┘';
            char hz = dbl ? '═' : '─';
            char vt = dbl ? '║' : '│';

            Set(x, y, tl, fg, bg, 0);
            Set(x + w - 1, y, tr, fg, bg, 0);
            Set(x, y + h - 1, bl, fg, bg, 0);
            Set(x + w - 1, y + h - 1, br, fg, bg, 0);
            for (int xx = x + 1; xx < x + w - 1; xx++)
            {
                Set(xx, y, hz, fg, bg, 0);
                Set(xx, y + h - 1, hz, fg, bg, 0);
            }
            for (int yy = y + 1; yy < y + h - 1; yy++)
            {
                Set(x, yy, vt, fg, bg, 0);
                Set(x + w - 1, yy, vt, fg, bg, 0);
            }
        }

        /// <summary>Horizontal rule with tee ends, for panel header separators.</summary>
        public void HLine(int x, int y, int w, byte fg, byte bg)
        {
            Set(x, y, '├', fg, bg, 0);
            for (int xx = x + 1; xx < x + w - 1; xx++) Set(xx, y, '─', fg, bg, 0);
            Set(x + w - 1, y, '┤', fg, bg, 0);
        }

        /// <summary>Diff the back buffer against the front buffer and paint the difference.</summary>
        public void Flush()
        {
            _sb.Length = 0;
            int lastFg = -1, lastBg = -1, lastAttr = -1;
            int curX = -1, curY = -1;

            for (int y = 0; y < _h; y++)
            {
                for (int x = 0; x < _w; x++)
                {
                    int i = y * _w + x;
                    if (!_full && _back[i].Equals(_front[i])) continue;

                    if (curY != y || curX != x)
                    {
                        _sb.Append(Esc).Append('[').Append(y + 1).Append(';').Append(x + 1).Append('H');
                        curX = x; curY = y;
                    }

                    Cell c = _back[i];
                    if (c.Fg != lastFg || c.Bg != lastBg || c.Attr != lastAttr)
                    {
                        _sb.Append(Esc).Append("[0");
                        if ((c.Attr & AttrBold) != 0) _sb.Append(";1");
                        if ((c.Attr & AttrUnderline) != 0) _sb.Append(";4");
                        if ((c.Attr & AttrReverse) != 0) _sb.Append(";7");
                        _sb.Append(";38;5;").Append(c.Fg);
                        _sb.Append(";48;5;").Append(c.Bg);
                        _sb.Append('m');
                        lastFg = c.Fg; lastBg = c.Bg; lastAttr = c.Attr;
                    }

                    _sb.Append(c.Ch);
                    curX++;
                    _front[i] = c;
                }
            }

            _full = false;
            if (_sb.Length == 0) return;
            _sb.Append(Esc).Append("[0m");
            Terminal.Write(_sb.ToString());
        }

        /// <summary>Render the back buffer as plain text. Used by golden-frame tests.</summary>
        public string Snapshot()
        {
            var sb = new StringBuilder((_w + 1) * _h);
            for (int y = 0; y < _h; y++)
            {
                for (int x = 0; x < _w; x++) sb.Append(_back[y * _w + x].Ch);
                sb.Append('\n');
            }
            return sb.ToString();
        }
    }
}
