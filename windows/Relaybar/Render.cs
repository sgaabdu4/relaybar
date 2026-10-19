using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Relaybar
{
    enum Tint { Orange, Blue, Green, Purple, Pink, Teal, Yellow, Red, Plain }

    static class Tints
    {
        public static readonly Tint[] All = (Tint[])Enum.GetValues(typeof(Tint));
        public static readonly Tint[] Palette = { Tint.Orange, Tint.Blue, Tint.Green, Tint.Purple, Tint.Pink, Tint.Teal, Tint.Yellow };
        static readonly int[] Light = { 0xFF9500, 0x007AFF, 0x34C759, 0xAF52DE, 0xFF2D55, 0x30B0C7, 0xFFCC00, 0xFF3B30 };
        static readonly int[] Dark = { 0xFF9F0A, 0x0A84FF, 0x30D158, 0xBF5AF2, 0xFF375F, 0x40C8E0, 0xFFD60A, 0xFF453A };

        public static Color Rgb(this Tint tint, bool dark)
        {
            if (tint == Tint.Plain) return Colors.Get(dark).Label;
            return Color.FromArgb(255, Color.FromArgb((dark ? Dark : Light)[(int)tint]));
        }

        public static Color For(this Tint tint, Window window, bool dark)
        {
            return window.Left <= 10 ? Low(dark) : tint.Rgb(dark);
        }

        public static Color Low(bool dark)
        {
            return dark ? Color.FromArgb(255, 140, 140) : Color.FromArgb(224, 77, 77);
        }

        public static Color Icon(this Tint tint)
        {
            return tint == Tint.Plain ? Color.FromArgb(142, 142, 147) : tint.Rgb(false);
        }

        public static string Title(this Tint tint)
        {
            return tint == Tint.Plain ? "No color" : tint.ToString();
        }

        public static string Raw(this Tint tint)
        {
            return tint.ToString().ToLowerInvariant();
        }

        public static Tint? Parse(string raw)
        {
            foreach (var tint in All) if (tint.Raw() == raw) return tint;
            return null;
        }

        public static string Hex(Color color)
        {
            return string.Format("#{0:x2}{1:x2}{2:x2}", color.R, color.G, color.B);
        }
    }

    sealed class Colors
    {
        public Color Background, Hover, Label, Secondary, Tertiary, Track, Border;
        public bool Dark;

        static readonly Colors light = new Colors
        {
            Background = Color.FromArgb(249, 249, 249), Hover = Color.FromArgb(232, 232, 232), Label = Color.FromArgb(26, 26, 26),
            Secondary = Color.FromArgb(95, 95, 95), Tertiary = Color.FromArgb(138, 138, 138), Track = Color.FromArgb(225, 225, 225),
            Border = Color.FromArgb(208, 208, 208), Dark = false,
        };

        static readonly Colors dark = new Colors
        {
            Background = Color.FromArgb(43, 43, 43), Hover = Color.FromArgb(61, 61, 61), Label = Color.FromArgb(242, 242, 242),
            Secondary = Color.FromArgb(181, 181, 181), Tertiary = Color.FromArgb(140, 140, 140), Track = Color.FromArgb(71, 71, 71),
            Border = Color.FromArgb(69, 69, 69), Dark = true,
        };

        public static Colors Get(bool isDark) { return isDark ? dark : light; }
    }

    static class Theme
    {
        public static bool DarkTaskbar { get { return Read("SystemUsesLightTheme") == 0; } }

        public static bool DarkApps { get { return Read("AppsUseLightTheme") == 0; } }

        static int Read(string name)
        {
            using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            {
                var value = key == null ? null : key.GetValue(name);
                return value is int ? (int)value : 1;
            }
        }
    }

    static class Ui
    {
        public static readonly float Scale;

        static Ui()
        {
            using (var graphics = Graphics.FromHwnd(IntPtr.Zero)) Scale = graphics.DpiX / 96f;
        }

        public static int S(float value) { return (int)Math.Round(value * Scale); }

        public static void Open(string path)
        {
            try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
            catch (System.ComponentModel.Win32Exception error) { Dialog.Tell("Could not open " + Path.GetFileNameWithoutExtension(path), error.Message); }
        }
    }

    static class Logo
    {
        static readonly Dictionary<bool, GraphicsPath> paths = new Dictionary<bool, GraphicsPath>();

        public static void Draw(Graphics graphics, bool claude, RectangleF rect, Color color)
        {
            using (var path = (GraphicsPath)Get(claude).Clone())
            using (var matrix = new Matrix())
            using (var brush = new SolidBrush(color))
            {
                matrix.Translate(rect.X, rect.Y);
                matrix.Scale(rect.Width / 100f, rect.Height / 100f);
                path.Transform(matrix);
                var smoothing = graphics.SmoothingMode;
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.FillPath(brush, path);
                graphics.SmoothingMode = smoothing;
            }
        }

        public static Bitmap Image(bool claude, Color color, int size)
        {
            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(bitmap)) Draw(graphics, claude, new RectangleF(0, 0, size, size), color);
            return bitmap;
        }

        static GraphicsPath Get(bool claude)
        {
            GraphicsPath path;
            if (paths.TryGetValue(claude, out path)) return path;
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(claude ? "claude.svg" : "codex.svg"))
            using (var reader = new StreamReader(stream))
            {
                var svg = reader.ReadToEnd();
                path = new GraphicsPath(FillMode.Winding);
                foreach (Match match in Regex.Matches(svg, "\\sd=\"([^\"]+)\"")) Svg(match.Groups[1].Value, path);
            }
            paths[claude] = path;
            return path;
        }

        static void Svg(string data, GraphicsPath path)
        {
            var tokens = Regex.Matches(data, @"[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?").Cast<Match>().Select(m => m.Value).ToList();
            int i = 0;
            var command = 'M';
            PointF current = PointF.Empty, start = PointF.Empty;
            Func<float> number = () => float.Parse(tokens[i++], CultureInfo.InvariantCulture);
            while (i < tokens.Count)
            {
                if (char.IsLetter(tokens[i][0])) command = tokens[i++][0];
                var relative = char.IsLower(command);
                float x0 = relative ? current.X : 0, y0 = relative ? current.Y : 0;
                switch (char.ToUpperInvariant(command))
                {
                    case 'M':
                        path.StartFigure();
                        current = start = new PointF(x0 + number(), y0 + number());
                        command = relative ? 'l' : 'L';
                        break;
                    case 'L':
                        {
                            var point = new PointF(x0 + number(), y0 + number());
                            path.AddLine(current, point);
                            current = point;
                            break;
                        }
                    case 'H':
                        {
                            var point = new PointF(x0 + number(), current.Y);
                            path.AddLine(current, point);
                            current = point;
                            break;
                        }
                    case 'V':
                        {
                            var point = new PointF(current.X, y0 + number());
                            path.AddLine(current, point);
                            current = point;
                            break;
                        }
                    case 'C':
                        {
                            var first = new PointF(x0 + number(), y0 + number());
                            var second = new PointF(x0 + number(), y0 + number());
                            var end = new PointF(x0 + number(), y0 + number());
                            path.AddBezier(current, first, second, end);
                            current = end;
                            break;
                        }
                    case 'Z':
                        path.CloseFigure();
                        current = start;
                        if (i < tokens.Count && !char.IsLetter(tokens[i][0])) i++;
                        break;
                    default:
                        i++;
                        break;
                }
            }
        }
    }

    static class Render
    {
        public static Icon Tray(Account account, int size, bool dark)
        {
            using (var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                using (var graphics = Graphics.FromImage(bitmap))
                {
                    graphics.SmoothingMode = SmoothingMode.AntiAlias;
                    graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    var lines = new[] { account.Session, account.Weekly }.Where(window => window != null).ToList();
                    if (lines.Count == 0)
                    {
                        var pad = size * 0.12f;
                        Logo.Draw(graphics, account.IsClaude, new RectangleF(pad, pad, size - 2 * pad, size - 2 * pad), account.Tint.Rgb(dark));
                    }
                    else
                    {
                        Numbers(graphics, lines.Select(window => new KeyValuePair<string, Color>(
                            window.Left.ToString(CultureInfo.InvariantCulture), account.Tint.For(window, dark))).ToList(), size);
                    }
                }
                using (var stream = new MemoryStream(Ico(new[] { bitmap }, false))) return new Icon(stream, size, size);
            }
        }

        static void Numbers(Graphics graphics, List<KeyValuePair<string, Color>> lines, int size)
        {
            using (var family = new FontFamily("Segoe UI"))
            {
                var style = (int)FontStyle.Bold;
                RectangleF reference;
                using (var probe = new GraphicsPath())
                {
                    probe.AddString("100", family, style, 100, PointF.Empty, StringFormat.GenericTypographic);
                    reference = probe.GetBounds();
                }
                var gap = Math.Max(1f, size / 12f);
                var lineHeight = lines.Count > 1 ? (size - gap) / 2 : size * 0.62f;
                var scale = Math.Min(size / reference.Width, lineHeight / reference.Height);
                var height = reference.Height * scale;
                var top = (size - (height * lines.Count + gap * (lines.Count - 1))) / 2;
                for (int n = 0; n < lines.Count; n++)
                {
                    using (var path = new GraphicsPath())
                    using (var brush = new SolidBrush(lines[n].Value))
                    using (var matrix = new Matrix())
                    {
                        path.AddString(lines[n].Key, family, style, 100 * scale, PointF.Empty, StringFormat.GenericTypographic);
                        var bounds = path.GetBounds();
                        var y = top + n * (height + gap) - reference.Top * scale;
                        matrix.Translate((float)Math.Floor(size - bounds.Right), (float)Math.Round(y));
                        path.Transform(matrix);
                        graphics.FillPath(brush, path);
                    }
                }
            }
        }

        public static byte[] DesktopIcon(string tag, Color color)
        {
            using (var large = new Bitmap(256, 256, PixelFormat.Format32bppArgb))
            {
                using (var graphics = Graphics.FromImage(large))
                {
                    graphics.SmoothingMode = SmoothingMode.AntiAlias;
                    graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    var unit = 256f * 824 / 1024;
                    var tile = new RectangleF((256 - unit) / 2, (256 - unit) / 2, unit, unit);
                    var top = Blend(color, Color.White, 0.18f);
                    var bottom = Blend(color, Color.Black, 0.14f);
                    using (var shape = Rounded(tile, unit * 0.225f))
                    using (var fill = new LinearGradientBrush(tile, top, bottom, LinearGradientMode.Vertical))
                        graphics.FillPath(fill, shape);
                    var inset = unit * 0.21f;
                    Logo.Draw(graphics, true, RectangleF.Inflate(tile, -inset, -inset), Color.White);
                    if (tag.Length > 0)
                    {
                        using (var font = new Font("Segoe UI Black", unit * 0.16f, FontStyle.Regular, GraphicsUnit.Pixel))
                        using (var text = new SolidBrush(bottom))
                        {
                            var measured = graphics.MeasureString(tag, font, PointF.Empty, StringFormat.GenericTypographic);
                            var pillHeight = unit * 0.23f;
                            var pill = new RectangleF(
                                tile.Left + unit * 0.09f, tile.Bottom - unit * 0.09f - pillHeight,
                                Math.Max(pillHeight, measured.Width + unit * 0.1f), pillHeight);
                            using (var shape = Rounded(pill, pillHeight / 2)) graphics.FillPath(Brushes.White, shape);
                            graphics.DrawString(
                                tag, font, text, pill.X + (pill.Width - measured.Width) / 2, pill.Y + (pill.Height - measured.Height) / 2,
                                StringFormat.GenericTypographic);
                        }
                    }
                }
                var frames = new[] { 16, 24, 32, 48 }.Select(size => Resize(large, size)).ToList();
                frames.Add(large);
                try { return Ico(frames, true); }
                finally { foreach (var frame in frames.Where(frame => frame != large)) frame.Dispose(); }
            }
        }

        public static GraphicsPath Rounded(RectangleF rect, float radius)
        {
            var path = new GraphicsPath();
            var d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
            path.AddArc(rect.X, rect.Y, d, d, 180, 90);
            path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
            path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
            path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        static Color Blend(Color color, Color with, float fraction)
        {
            Func<int, int, int> mix = (a, b) => (int)Math.Round(a + (b - a) * fraction);
            return Color.FromArgb(mix(color.R, with.R), mix(color.G, with.G), mix(color.B, with.B));
        }

        static Bitmap Resize(Bitmap source, int size)
        {
            var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.DrawImage(source, 0, 0, size, size);
            }
            return bitmap;
        }

        static byte[] Ico(IList<Bitmap> frames, bool pngForLarge)
        {
            var images = frames.Select(frame => pngForLarge && frame.Width >= 256 ? Png(frame) : Dib(frame)).ToList();
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write((ushort)0);
                writer.Write((ushort)1);
                writer.Write((ushort)frames.Count);
                var offset = 6 + 16 * frames.Count;
                for (int n = 0; n < frames.Count; n++)
                {
                    writer.Write((byte)(frames[n].Width % 256));
                    writer.Write((byte)(frames[n].Height % 256));
                    writer.Write((byte)0);
                    writer.Write((byte)0);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write(images[n].Length);
                    writer.Write(offset);
                    offset += images[n].Length;
                }
                foreach (var image in images) writer.Write(image);
                writer.Flush();
                return stream.ToArray();
            }
        }

        static byte[] Png(Bitmap bitmap)
        {
            using (var stream = new MemoryStream())
            {
                bitmap.Save(stream, ImageFormat.Png);
                return stream.ToArray();
            }
        }

        static byte[] Dib(Bitmap bitmap)
        {
            int width = bitmap.Width, height = bitmap.Height;
            var maskStride = (width + 31) / 32 * 4;
            using (var stream = new MemoryStream())
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write(40);
                writer.Write(width);
                writer.Write(height * 2);
                writer.Write((ushort)1);
                writer.Write((ushort)32);
                writer.Write(0);
                writer.Write(width * height * 4 + maskStride * height);
                writer.Write(0);
                writer.Write(0);
                writer.Write(0);
                writer.Write(0);
                var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    var row = new byte[width * 4];
                    for (int y = height - 1; y >= 0; y--)
                    {
                        System.Runtime.InteropServices.Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                        writer.Write(row);
                    }
                }
                finally { bitmap.UnlockBits(data); }
                writer.Write(new byte[maskStride * height]);
                writer.Flush();
                return stream.ToArray();
            }
        }
    }

    sealed class AccountCard : ToolStripItem
    {
        readonly Account account;
        readonly string opens;
        readonly Colors colors;
        static readonly Font nameFont = new Font("Segoe UI Semibold", 13 * Ui.Scale, GraphicsUnit.Pixel);
        static readonly Font smallFont = new Font("Segoe UI", 11 * Ui.Scale, GraphicsUnit.Pixel);
        static readonly Font valueFont = new Font("Segoe UI Semibold", 12 * Ui.Scale, GraphicsUnit.Pixel);
        const TextFormatFlags Flags = TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;

        public AccountCard(Account account, string opens, Colors colors)
        {
            this.account = account;
            this.opens = opens;
            this.colors = colors;
            AutoSize = false;
            Size = GetPreferredSize(Size.Empty);
            if (opens != null) ToolTipText = "Open " + Path.GetFileNameWithoutExtension(opens);
        }

        public override Size GetPreferredSize(Size constrainingSize)
        {
            var rows = Math.Max(1, new[] { account.Session, account.Weekly }.Count(window => window != null) + (account.Stale ? 1 : 0));
            return new Size(Ui.S(250), Ui.S(32 + rows * 18));
        }

        protected override void OnClick(EventArgs e)
        {
            base.OnClick(e);
            if (opens != null) Ui.Open(opens);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var graphics = e.Graphics;
            var bounds = new Rectangle(Point.Empty, Size);
            using (var background = new SolidBrush(colors.Background)) graphics.FillRectangle(background, bounds);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            if (opens != null && Selected)
            {
                using (var hover = new SolidBrush(colors.Hover))
                using (var shape = Render.Rounded(new RectangleF(Ui.S(5), Ui.S(1), bounds.Width - Ui.S(10), bounds.Height - Ui.S(2)), Ui.S(6)))
                    graphics.FillPath(hover, shape);
            }
            float inset = Ui.S(14);
            Logo.Draw(graphics, account.IsClaude, new RectangleF(inset, Ui.S(7), Ui.S(14), Ui.S(14)), account.Tint.Rgb(colors.Dark));
            var name = account.Tag.Length == 0 ? (account.IsClaude ? "Claude" : "Codex") : account.Tag;
            Draw(graphics, name, nameFont, colors.Label, inset + Ui.S(21), Ui.S(4), Ui.S(160), TextFormatFlags.EndEllipsis);

            float y = Ui.S(28);
            foreach (var row in new[] { new KeyValuePair<string, Window>("5h", account.Session), new KeyValuePair<string, Window>("7d", account.Weekly) })
            {
                if (row.Value == null) continue;
                Row(graphics, row.Key, row.Value, y, bounds.Width);
                y += Ui.S(18);
            }
            if (account.Stale) Draw(graphics, "Login expired", smallFont, Tint.Orange.Rgb(colors.Dark), inset, y, Ui.S(200), 0);
            else if (account.Session == null && account.Weekly == null)
                Draw(graphics, "Waiting for " + (account.IsClaude ? "Claude" : "Codex"), smallFont, colors.Tertiary, inset, y, Ui.S(200), 0);
        }

        void Row(Graphics graphics, string label, Window window, float y, int width)
        {
            float inset = Ui.S(14);
            float right = width - inset;
            Draw(graphics, label, smallFont, colors.Secondary, inset, y, Ui.S(24), 0);

            var reset = Resets(window);
            var resetWidth = TextRenderer.MeasureText(graphics, reset, smallFont, Size.Empty, Flags).Width;
            Draw(graphics, reset, smallFont, colors.Tertiary, right - resetWidth, y, resetWidth + 1, 0);

            var valueRight = right - Ui.S(52);
            var value = window.Left + "%";
            var valueWidth = TextRenderer.MeasureText(graphics, value, valueFont, Size.Empty, Flags).Width;
            Draw(graphics, value, valueFont, account.Tint.For(window, colors.Dark), valueRight - valueWidth, y - Ui.S(1), valueWidth + 1, 0);

            var track = new RectangleF(inset + Ui.S(24), y + Ui.S(6), valueRight - Ui.S(40) - inset - Ui.S(24), Ui.S(4));
            using (var brush = new SolidBrush(colors.Track))
            using (var shape = Render.Rounded(track, track.Height / 2))
                graphics.FillPath(brush, shape);
            if (window.Left <= 0) return;
            var fill = new RectangleF(track.X, track.Y, Math.Max(track.Height, track.Width * window.Left / 100f), track.Height);
            var color = window.Left <= 10 ? Tints.Low(colors.Dark) : account.Tint == Tint.Plain ? colors.Secondary : account.Tint.Rgb(colors.Dark);
            using (var brush = new SolidBrush(color))
            using (var shape = Render.Rounded(fill, fill.Height / 2))
                graphics.FillPath(brush, shape);
        }

        static void Draw(Graphics graphics, string text, Font font, Color color, float x, float y, float width, TextFormatFlags extra)
        {
            var rect = new Rectangle((int)x, (int)y, (int)Math.Ceiling(width), font.Height + Ui.S(2));
            TextRenderer.DrawText(graphics, text, font, rect, color, Flags | extra);
        }

        public static string Resets(Window window)
        {
            if (!window.ResetsAt.HasValue) return "";
            var seconds = (window.ResetsAt.Value - DateTime.UtcNow).TotalSeconds;
            if (seconds < 86400)
            {
                var minutes = Math.Max(0, (int)(seconds / 60));
                return minutes >= 60 ? (minutes / 60) + "h " + (minutes % 60) + "m" : minutes + "m";
            }
            return window.ResetsAt.Value.ToLocalTime().ToString("ddd", CultureInfo.CurrentCulture);
        }
    }

    sealed class MenuRenderer : ToolStripProfessionalRenderer
    {
        readonly Colors colors;

        public MenuRenderer(Colors colors) : base(new MenuColors(colors))
        {
            this.colors = colors;
            RoundedEdges = false;
        }

        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
        {
            e.ArrowColor = e.Item.Enabled ? colors.Label : colors.Tertiary;
            base.OnRenderArrow(e);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = e.Item.Enabled ? colors.Label : colors.Tertiary;
            base.OnRenderItemText(e);
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
        {
            var rect = e.ImageRectangle;
            rect.Inflate(Ui.S(2), Ui.S(2));
            using (var brush = new SolidBrush(colors.Hover)) e.Graphics.FillRectangle(brush, rect);
            if (e.Image != null) e.Graphics.DrawImage(e.Image, e.ImageRectangle);
            else TextRenderer.DrawText(e.Graphics, "\u2713", e.Item.Font, rect, colors.Label, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }

        sealed class MenuColors : ProfessionalColorTable
        {
            readonly Colors c;

            public MenuColors(Colors colors)
            {
                c = colors;
                UseSystemColors = false;
            }

            public override Color ToolStripDropDownBackground { get { return c.Background; } }
            public override Color ImageMarginGradientBegin { get { return c.Background; } }
            public override Color ImageMarginGradientMiddle { get { return c.Background; } }
            public override Color ImageMarginGradientEnd { get { return c.Background; } }
            public override Color MenuBorder { get { return c.Border; } }
            public override Color MenuItemBorder { get { return c.Hover; } }
            public override Color MenuItemSelected { get { return c.Hover; } }
            public override Color MenuItemSelectedGradientBegin { get { return c.Hover; } }
            public override Color MenuItemSelectedGradientEnd { get { return c.Hover; } }
            public override Color MenuItemPressedGradientBegin { get { return c.Hover; } }
            public override Color MenuItemPressedGradientEnd { get { return c.Hover; } }
            public override Color SeparatorDark { get { return c.Border; } }
            public override Color SeparatorLight { get { return c.Background; } }
            public override Color CheckBackground { get { return c.Hover; } }
            public override Color CheckSelectedBackground { get { return c.Hover; } }
            public override Color CheckPressedBackground { get { return c.Hover; } }
        }
    }
}
