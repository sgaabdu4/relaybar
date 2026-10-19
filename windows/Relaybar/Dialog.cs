using System;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Relaybar
{
    static class Dialog
    {
        public static Icon AppIcon;

        public static int Show(string title, string text, Control extra, params string[] buttons)
        {
            using (var form = new Form())
            {
                form.Text = "Relaybar";
                form.Font = SystemFonts.MessageBoxFont;
                form.FormBorderStyle = FormBorderStyle.FixedDialog;
                form.MaximizeBox = false;
                form.MinimizeBox = false;
                form.StartPosition = FormStartPosition.CenterScreen;
                form.TopMost = true;
                form.AutoSize = true;
                form.AutoSizeMode = AutoSizeMode.GrowAndShrink;
                form.Padding = new Padding(Ui.S(16));
                if (AppIcon != null) form.Icon = AppIcon;
                else form.ShowIcon = false;

                var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
                var heading = new Label
                {
                    Text = title, AutoSize = true, MaximumSize = new Size(Ui.S(380), 0), UseMnemonic = false,
                    Font = new Font(form.Font.FontFamily, form.Font.Size * 1.15f, FontStyle.Bold), Margin = new Padding(0, 0, 0, Ui.S(8)),
                };
                layout.Controls.Add(heading);
                if (!string.IsNullOrEmpty(text))
                {
                    layout.Controls.Add(new Label
                    {
                        Text = text, AutoSize = true, MaximumSize = new Size(Ui.S(380), 0), UseMnemonic = false, Margin = new Padding(0, 0, 0, Ui.S(12)),
                    });
                }
                if (extra != null)
                {
                    extra.Margin = new Padding(0, 0, 0, Ui.S(14));
                    layout.Controls.Add(extra);
                }

                var chosen = -1;
                var row = new FlowLayoutPanel
                {
                    FlowDirection = FlowDirection.RightToLeft, AutoSize = true, WrapContents = false, Anchor = AnchorStyles.Right, Margin = Padding.Empty,
                };
                for (int n = buttons.Length - 1; n >= 0; n--)
                {
                    var index = n;
                    var button = new Button { Text = buttons[n], AutoSize = true, MinimumSize = new Size(Ui.S(84), 0), UseMnemonic = false };
                    button.Click += delegate
                    {
                        chosen = index;
                        form.Close();
                    };
                    if (n == 0) form.AcceptButton = button;
                    if (n == buttons.Length - 1) form.CancelButton = button;
                    row.Controls.Add(button);
                }
                layout.Controls.Add(row);
                form.Controls.Add(layout);
                form.Shown += delegate
                {
                    form.Activate();
                    var input = FirstInput(extra);
                    if (input != null) input.Focus();
                    else ((Button)form.AcceptButton).Focus();
                };
                form.ShowDialog();
                return buttons.Length > 1 && chosen == buttons.Length - 1 ? -1 : chosen;
            }
        }

        public static bool Ask(string title, string text, Control extra)
        {
            return Show(title, text, extra, "OK", "Cancel") == 0;
        }

        public static void Tell(string title, string text)
        {
            Show(title, text, null, "OK");
        }

        public static TextBox Field(string value, string placeholder, int width)
        {
            var field = new TextBox { Text = value, Width = Ui.S(width) };
            if (placeholder != null) field.HandleCreated += delegate { SendMessage(field.Handle, 0x1501, (IntPtr)1, placeholder); };
            return field;
        }

        public static FlowLayoutPanel Stack(params Control[] controls)
        {
            var stack = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
            foreach (var control in controls)
            {
                control.Margin = new Padding(0, 0, 0, Ui.S(8));
                stack.Controls.Add(control);
            }
            return stack;
        }

        public static ComboBox ColorPicker(Tint selected)
        {
            var picker = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, DrawMode = DrawMode.OwnerDrawFixed, Width = Ui.S(170) };
            picker.ItemHeight = Math.Max(picker.ItemHeight, Ui.S(18));
            foreach (var tint in Tints.All.Where(tint => tint != Tint.Plain)) picker.Items.Add(tint);
            picker.SelectedItem = selected;
            picker.DrawItem += (sender, e) =>
            {
                e.DrawBackground();
                if (e.Index < 0) return;
                var tint = (Tint)picker.Items[e.Index];
                var dot = e.Bounds.Height - Ui.S(8);
                e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var brush = new SolidBrush(tint.Rgb(false))) e.Graphics.FillEllipse(brush, e.Bounds.X + Ui.S(4), e.Bounds.Y + Ui.S(4), dot, dot);
                TextRenderer.DrawText(
                    e.Graphics, tint.Title(), e.Font, new Rectangle(e.Bounds.X + dot + Ui.S(10), e.Bounds.Y, e.Bounds.Width, e.Bounds.Height),
                    e.ForeColor, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            };
            return picker;
        }

        static Control FirstInput(Control control)
        {
            if (control == null) return null;
            if (control is TextBox) return control;
            foreach (Control child in control.Controls)
            {
                var found = FirstInput(child);
                if (found != null) return found;
            }
            return null;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, string lParam);
    }
}
