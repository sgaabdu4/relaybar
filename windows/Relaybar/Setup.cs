using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Relaybar
{
    static class Installer
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Relaybar";

        public static readonly string Folder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Relaybar");

        public static string Exe { get { return Path.Combine(Folder, "Relaybar.exe"); } }

        static string StartMenuLink { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Relaybar.lnk"); } }

        public static bool IsInstalledCopy
        {
            get { return string.Equals(Path.GetFullPath(Application.ExecutablePath), Exe, StringComparison.OrdinalIgnoreCase); }
        }

        public static void Install()
        {
            StopRunning();
            Directory.CreateDirectory(Folder);
            File.Copy(Application.ExecutablePath, Exe, true);
            Shortcuts.Save(StartMenuLink, Exe, "", Exe, "See how much of each Claude and Codex limit is left");
            using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                key.SetValue("DisplayName", "Relaybar");
                key.SetValue("DisplayIcon", Exe);
                key.SetValue("Publisher", "Relaybar");
                key.SetValue("InstallLocation", Folder);
                key.SetValue("UninstallString", "\"" + Exe + "\" --uninstall");
                key.SetValue("EstimatedSize", (int)(new FileInfo(Exe).Length / 1024), RegistryValueKind.DWord);
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }
        }

        public static void Start()
        {
            Process.Start(new ProcessStartInfo(Exe) { UseShellExecute = true, WorkingDirectory = Folder }).Dispose();
        }

        public static bool StartsAtLogin
        {
            get
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                    return key != null && string.Equals(key.GetValue("Relaybar") as string, RunCommand(Application.ExecutablePath), StringComparison.OrdinalIgnoreCase);
            }
        }

        public static void SetStartsAtLogin(bool enabled, string exe)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (enabled) key.SetValue("Relaybar", RunCommand(exe));
                else key.DeleteValue("Relaybar", false);
            }
        }

        static string RunCommand(string exe) { return "\"" + exe + "\""; }

        public static void Uninstall()
        {
            var choice = Dialog.Show(
                "Uninstall Relaybar?",
                "This removes Relaybar, its Start menu entries and its desktop app shortcuts.\n\n"
                    + "Your Claude and Codex accounts and their folders are not touched.",
                null, "Uninstall", "Cancel");
            if (choice != 0) return;
            StopRunning();
            using (var key = Registry.CurrentUser.OpenSubKey(RunKey, true))
                if (key != null) key.DeleteValue("Relaybar", false);
            var programs = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            foreach (var link in Directory.GetFiles(programs, "*.lnk"))
            {
                var name = Path.GetFileName(link);
                var target = name == "Relaybar.lnk" || name.StartsWith("Claude ", StringComparison.Ordinal) ? Shortcuts.Read(link) : null;
                if (target != null && string.Equals(target.Target, Exe, StringComparison.OrdinalIgnoreCase)) File.Delete(link);
            }
            Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
            var info = new ProcessStartInfo("cmd.exe", "/d /c ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"" + Folder + "\"")
            {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetTempPath(),
            };
            Dialog.Tell("Relaybar was uninstalled", "Thanks for trying it.");
            Process.Start(info).Dispose();
        }

        static void StopRunning()
        {
            var me = Process.GetCurrentProcess().Id;
            foreach (var process in Process.GetProcessesByName("Relaybar"))
            {
                try
                {
                    if (process.Id != me && string.Equals(process.MainModule.FileName, Exe, StringComparison.OrdinalIgnoreCase))
                    {
                        process.Kill();
                        process.WaitForExit(5000);
                    }
                }
                catch (Win32Exception) { }
                catch (InvalidOperationException) { }
                finally { process.Dispose(); }
            }
        }
    }

    static class NewAccount
    {
        public static string Slug(string name)
        {
            return string.Join("-", Regex.Split(name.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(word => word.Length > 0));
        }

        public static string Folder(Kind kind, string name)
        {
            return Path.Combine(Account.Home, "." + kind.Tool.ToLowerInvariant() + "-" + Slug(name));
        }

        public static string Create(Kind kind, string name, string tag, Tint tint, bool desktopApp, string exe, List<string> warnings)
        {
            var title = name.Trim();
            if (Slug(title).Length == 0) throw new IOException("Please enter a name. It is used for the account's folder.");
            var dir = Folder(kind, title);
            if (Directory.Exists(dir) || File.Exists(dir)) throw new IOException("That account already exists: " + dir);
            Directory.CreateDirectory(dir);
            tag = tag.Trim();
            if (tag.Length > 0) Prefs.Set("tag:" + dir, tag.Length > 3 ? tag.Substring(0, 3) : tag);
            Prefs.Set("color:" + dir, tint.Raw());
            if (desktopApp && kind.IsClaude)
            {
                try { DesktopApp.Make(title, dir, Prefs.Str("tag:" + dir) ?? "", tint.Icon(), exe); }
                catch (IOException error) { warnings.Add("The desktop app was not made: " + error.Message); }
                catch (UnauthorizedAccessException error) { warnings.Add("The desktop app was not made: " + error.Message); }
            }
            try { T3Code.Add(kind.IsClaude, title, tint.Icon(), dir); }
            catch (IOException error) { warnings.Add("It was not added to T3 Code: " + error.Message); }
            catch (UnauthorizedAccessException error) { warnings.Add("It was not added to T3 Code: " + error.Message); }
            return dir;
        }

        public static Process SignIn(Kind kind, string dir)
        {
            var info = new ProcessStartInfo("cmd.exe", "/d /c " + kind.Login + " || pause") { UseShellExecute = false };
            info.EnvironmentVariables[kind.Variable] = dir;
            info.EnvironmentVariables["PATH"] = SearchPath();
            return Process.Start(info);
        }

        public static bool SignedIn(string dir)
        {
            return AccountScanner.Scan(Account.Home).Any(account => string.Equals(account.Id, dir, StringComparison.OrdinalIgnoreCase));
        }

        public static bool ToolInstalled(Kind kind)
        {
            var name = kind.IsClaude ? "claude" : "codex";
            var extensions = (Environment.GetEnvironmentVariable("PATHEXT") ?? ".EXE;.CMD").Split(';');
            foreach (var folder in SearchPath().Split(';').Select(folder => folder.Trim()).Where(folder => folder.Length > 0))
            {
                foreach (var extension in extensions)
                {
                    try
                    {
                        if (File.Exists(Path.Combine(folder, name + extension))) return true;
                    }
                    catch (ArgumentException) { }
                }
            }
            return false;
        }

        public static string InstallPage(Kind kind)
        {
            return kind.IsClaude ? "https://claude.com/claude-code" : "https://github.com/openai/codex";
        }

        static string SearchPath()
        {
            return string.Join(";", new[]
            {
                Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.Machine),
                Environment.GetEnvironmentVariable("PATH", EnvironmentVariableTarget.User),
                Environment.GetEnvironmentVariable("PATH"),
            }.Where(path => !string.IsNullOrEmpty(path)));
        }
    }

    sealed class SetupForm : Form
    {
        static readonly Color Ink = Color.FromArgb(26, 26, 26);
        static readonly Color Muted = Color.FromArgb(95, 95, 95);
        static readonly Color Accent = Color.FromArgb(0, 103, 192);
        static readonly Color Good = Color.FromArgb(15, 123, 15);
        static readonly Color Bad = Color.FromArgb(196, 43, 28);

        readonly FlowLayoutPanel rows = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
        readonly FlowLayoutPanel needed = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
        readonly CheckBox atLogin = new CheckBox { Text = "Start Relaybar when I sign in to Windows", AutoSize = true, Checked = true };
        readonly CheckBox desktopApps = new CheckBox { AutoSize = true };
        readonly Label status = new Label { AutoSize = true, ForeColor = Muted };
        readonly Button install = new Button { AutoSize = true };
        readonly Button close = new Button { Text = "Cancel", AutoSize = true };
        readonly FlowLayoutPanel adders;
        readonly List<Account> existing = Account.Discover();
        readonly bool hasDesktop = DesktopApp.Source(true) != null;
        bool finished;

        public SetupForm()
        {
            Text = "Relaybar setup";
            Font = new Font("Segoe UI", 9.5f);
            BackColor = Color.White;
            ForeColor = Ink;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            if (Dialog.AppIcon != null) Icon = Dialog.AppIcon;

            var page = new FlowLayoutPanel
            {
                FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Padding = new Padding(Ui.S(28), Ui.S(24), Ui.S(28), Ui.S(8)),
            };
            page.Controls.Add(Header());
            page.Controls.Add(Heading("Accounts on this PC"));
            page.Controls.Add(Existing());
            page.Controls.Add(Heading("Add accounts"));
            page.Controls.Add(Note("Give each account a name, a short tag for its icon and a colour. "
                + "When you click Install, you sign in to each one in your browser. Relaybar never sees your password."));
            page.Controls.Add(rows);
            adders = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, Ui.S(4), 0, Ui.S(4)) };
            adders.Controls.Add(LinkButton("+ Claude account", () => AddRow(Kind.Claude)));
            adders.Controls.Add(LinkButton("+ Codex account", () => AddRow(Kind.Codex)));
            page.Controls.Add(adders);
            page.Controls.Add(needed);
            page.Controls.Add(Heading("Options"));
            desktopApps.Text = hasDesktop
                ? "Make a Claude desktop app for each new Claude account"
                : "Make Claude desktop apps (install the Claude desktop app first)";
            desktopApps.Checked = hasDesktop;
            desktopApps.Enabled = hasDesktop;
            page.Controls.Add(atLogin);
            page.Controls.Add(desktopApps);

            var footer = new TableLayoutPanel
            {
                Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, BackColor = Color.FromArgb(243, 243, 243), Margin = Padding.Empty,
                Padding = new Padding(Ui.S(28), Ui.S(14), Ui.S(20), Ui.S(14)),
            };
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            status.Anchor = AnchorStyles.Left;
            status.MaximumSize = new Size(Ui.S(300), 0);
            footer.Controls.Add(status, 0, 0);
            var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Anchor = AnchorStyles.Right, Margin = Padding.Empty };
            install.Text = Installer.IsInstalledCopy ? "Add accounts" : "Install";
            install.MinimumSize = new Size(Ui.S(110), Ui.S(32));
            install.BackColor = Accent;
            install.ForeColor = Color.White;
            install.FlatStyle = FlatStyle.Flat;
            install.FlatAppearance.BorderSize = 0;
            install.Font = new Font(Font, FontStyle.Bold);
            install.Click += delegate { Run(); };
            close.MinimumSize = new Size(Ui.S(90), Ui.S(32));
            close.Click += delegate { Close(); };
            buttons.Controls.Add(close);
            buttons.Controls.Add(install);
            footer.Controls.Add(buttons, 1, 0);

            var root = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Margin = Padding.Empty };
            page.Margin = Padding.Empty;
            root.Controls.Add(page, 0, 0);
            root.Controls.Add(footer, 0, 1);
            Controls.Add(root);
            AcceptButton = install;

            if (existing.Count == 0) AddRow(Kind.Claude);
            Refresh(null);
            Shown += delegate
            {
                var first = Rows.FirstOrDefault();
                if (first != null) first.Focus();
                else install.Select();
            };
        }

        Control Header()
        {
            var header = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, Margin = new Padding(0, 0, 0, Ui.S(8)) };
            var icon = new PictureBox { Size = new Size(Ui.S(56), Ui.S(56)), SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 0, Ui.S(14), 0) };
            using (var large = Icon.ExtractAssociatedIcon(Application.ExecutablePath)) icon.Image = large.ToBitmap();
            header.Controls.Add(icon, 0, 0);
            var words = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Anchor = AnchorStyles.Left };
            words.Controls.Add(new Label { Text = "Welcome to Relaybar", AutoSize = true, Font = new Font("Segoe UI Semibold", 17f), Margin = Padding.Empty });
            words.Controls.Add(new Label
            {
                Text = "See how much of each Claude and Codex limit is left, right by the clock.", AutoSize = true, ForeColor = Muted,
                MaximumSize = new Size(Ui.S(440), 0), Margin = Padding.Empty,
            });
            header.Controls.Add(words, 1, 0);
            return header;
        }

        Control Existing()
        {
            var list = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
            if (existing.Count == 0)
            {
                list.Controls.Add(Note("None yet. Relaybar finds accounts you have already signed in to with Claude Code or Codex."));
                return list;
            }
            foreach (var account in existing)
            {
                var line = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 0, 0, Ui.S(4)) };
                line.Controls.Add(new PictureBox
                {
                    Image = Logo.Image(account.IsClaude, account.Tint.Rgb(false), Ui.S(16)), Size = new Size(Ui.S(16), Ui.S(16)),
                    Margin = new Padding(0, Ui.S(3), Ui.S(8), 0),
                });
                var name = account.Tag.Length == 0 ? account.Tool : account.Tag;
                line.Controls.Add(new Label { Text = name, AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 0, Ui.S(6), 0), UseMnemonic = false });
                line.Controls.Add(new Label { Text = account.Label, AutoSize = true, ForeColor = Muted, Margin = Padding.Empty, UseMnemonic = false });
                list.Controls.Add(line);
            }
            return list;
        }

        Label Heading(string text)
        {
            return new Label
            {
                Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 11f), Margin = new Padding(0, Ui.S(16), 0, Ui.S(6)),
            };
        }

        Label Note(string text)
        {
            return new Label { Text = text, AutoSize = true, ForeColor = Muted, MaximumSize = new Size(Ui.S(520), 0), Margin = new Padding(0, 0, 0, Ui.S(8)), UseMnemonic = false };
        }

        Control LinkButton(string text, Action click)
        {
            var link = new LinkLabel { Text = text, AutoSize = true, LinkColor = Accent, ActiveLinkColor = Accent, LinkBehavior = LinkBehavior.HoverUnderline, Margin = new Padding(0, 0, Ui.S(18), 0) };
            link.LinkClicked += delegate { click(); };
            return link;
        }

        IEnumerable<Row> Rows { get { return rows.Controls.OfType<Row>(); } }

        void AddRow(Kind kind)
        {
            var used = new HashSet<Tint>(existing.Select(account => account.Tint).Concat(Rows.Select(other => other.Tint)));
            var tint = Tints.Palette.Where(free => !used.Contains(free)).DefaultIfEmpty(Tint.Orange).First();
            var added = new Row(kind, tint, Refresh);
            rows.Controls.Add(added);
            added.Focus();
            Refresh(null);
        }

        void Refresh(Row removed)
        {
            if (removed != null)
            {
                rows.Controls.Remove(removed);
                removed.Dispose();
            }
            needed.Controls.Clear();
            foreach (var kind in new[] { Kind.Claude, Kind.Codex })
            {
                if (!Rows.Any(row => row.Kind == kind) || NewAccount.ToolInstalled(kind)) continue;
                var tool = kind.IsClaude ? "Claude Code" : "the Codex CLI";
                var link = new LinkLabel
                {
                    Text = "To sign in to " + kind.Tool + " accounts, install " + tool + " first, then come back here.",
                    AutoSize = true, MaximumSize = new Size(Ui.S(520), 0), ForeColor = Bad, LinkColor = Accent, Margin = new Padding(0, Ui.S(2), 0, Ui.S(2)),
                };
                link.LinkArea = new LinkArea(link.Text.IndexOf(tool, StringComparison.Ordinal), tool.Length);
                link.LinkClicked += delegate { Ui.Open(NewAccount.InstallPage(kind)); };
                needed.Controls.Add(link);
            }
            if (needed.Controls.Count > 0) needed.Controls.Add(LinkButton("Check again", () => Refresh(null)));
            if (!finished) status.Text = Rows.Any() ? "" : Installer.IsInstalledCopy ? "Add an account to continue." : "You can also add accounts later from the Relaybar menu.";
        }

        async void Run()
        {
            if (finished)
            {
                Close();
                return;
            }
            foreach (var blank in Rows.Where(row => row.Folder == null && row.AccountName.Trim().Length == 0).ToList()) Refresh(blank);
            var pending = Rows.Where(row => !row.Done).ToList();
            var problem = Problem(pending);
            if (problem != null)
            {
                Show(problem, Bad);
                return;
            }
            Lock(true);
            try
            {
                if (!Installer.IsInstalledCopy)
                {
                    Show("Installing Relaybarâ€¦", Muted);
                    Installer.Install();
                }
                Installer.SetStartsAtLogin(atLogin.Checked, Installer.Exe);
                foreach (var row in pending.Where(row => row.Folder == null))
                {
                    var warnings = new List<string>();
                    row.Folder = NewAccount.Create(row.Kind, row.AccountName, row.TagText, row.Tint, desktopApps.Checked, Installer.Exe, warnings);
                    row.Say(warnings.Count == 0 ? "Waiting to sign in" : string.Join(" ", warnings), Muted);
                }
                foreach (var row in pending)
                {
                    if (!NewAccount.ToolInstalled(row.Kind))
                    {
                        row.Say("Install " + (row.Kind.IsClaude ? "Claude Code" : "the Codex CLI") + ", then try again", Bad);
                        continue;
                    }
                    row.Say("Signing inâ€¦ finish in your browser and the terminal window", Accent);
                    Show("Signing in to " + row.AccountName + "â€¦", Muted);
                    using (var process = NewAccount.SignIn(row.Kind, row.Folder)) await Task.Run(() => process.WaitForExit());
                    row.Done = NewAccount.SignedIn(row.Folder);
                    row.Say(row.Done ? "âœ“ Signed in" : "Not signed in yet", row.Done ? Good : Bad);
                }
            }
            catch (Exception error)
            {
                if (!(error is IOException || error is UnauthorizedAccessException || error is Win32Exception)) throw;
                Show(error.Message, Bad);
                Lock(false);
                return;
            }

            Installer.Start();
            var left = Rows.Count(row => !row.Done);
            if (left > 0)
            {
                Show("Relaybar is running. " + left + " account(s) are not signed in yet. Click Try again to sign in.", Bad);
                install.Text = "Try again";
                Lock(false);
                install.Select();
                return;
            }
            finished = true;
            Show("All set. Relaybar is running by the clock. If you can't see it, click the ^ arrow on the taskbar.", Good);
            install.Text = "Finish";
            close.Visible = false;
            install.Enabled = true;
            install.Select();
        }

        string Problem(List<Row> pending)
        {
            if (pending.Count == 0 && Installer.IsInstalledCopy) return "Add an account first.";
            var folders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in pending.Where(row => row.Folder == null))
            {
                if (NewAccount.Slug(row.AccountName).Length == 0) return "Please give every account a name.";
                var folder = NewAccount.Folder(row.Kind, row.AccountName);
                if (!folders.Add(folder)) return "Two accounts have the same name: " + row.AccountName.Trim();
                if (Directory.Exists(folder)) return "An account called " + row.AccountName.Trim() + " already exists.";
                if (row.Kind.IsClaude && desktopApps.Checked && row.AccountName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                    return "Names can't contain \\ / : * ? \" < > or |.";
            }
            return null;
        }

        void Lock(bool busy)
        {
            install.Enabled = !busy;
            adders.Enabled = !busy;
            atLogin.Enabled = !busy;
            desktopApps.Enabled = !busy && hasDesktop;
            foreach (var row in Rows) row.Lock(busy || row.Folder != null);
        }

        void Show(string text, Color color)
        {
            status.Text = text;
            status.ForeColor = color;
        }

        sealed class Row : FlowLayoutPanel
        {
            readonly ComboBox kind = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
            readonly TextBox name;
            readonly TextBox tag;
            readonly ComboBox colors;
            readonly Button remove = new Button { Text = "âœ•", FlatStyle = FlatStyle.Flat, TabStop = false };
            readonly Label state = new Label { AutoSize = true, Visible = false, UseMnemonic = false };
            public string Folder;
            public bool Done;

            public Row(Kind startKind, Tint tint, Action<Row> changed)
            {
                FlowDirection = FlowDirection.LeftToRight;
                AutoSize = true;
                WrapContents = true;
                MaximumSize = new Size(Ui.S(560), 0);
                Margin = new Padding(0, 0, 0, Ui.S(6));
                kind.Items.AddRange(new object[] { "Claude", "Codex" });
                kind.SelectedIndex = startKind.IsClaude ? 0 : 1;
                kind.Width = Ui.S(86);
                kind.SelectedIndexChanged += delegate { changed(null); };
                name = Dialog.Field("", "Name, for example Work", 190);
                tag = Dialog.Field("", "Tag", 56);
                tag.MaxLength = 3;
                tag.CharacterCasing = CharacterCasing.Upper;
                name.TextChanged += delegate
                {
                    if (!tag.Modified) tag.Text = Initials(name.Text);
                };
                colors = Dialog.ColorPicker(tint);
                colors.Width = Ui.S(120);
                remove.FlatAppearance.BorderSize = 0;
                remove.Size = new Size(Ui.S(28), Ui.S(26));
                remove.ForeColor = Muted;
                remove.Click += delegate { changed(this); };
                foreach (var control in new Control[] { kind, name, tag, colors, remove }) control.Margin = new Padding(0, 0, Ui.S(6), 0);
                Controls.AddRange(new Control[] { kind, name, tag, colors, remove });
                state.Margin = new Padding(Ui.S(2), Ui.S(4), 0, Ui.S(2));
                state.MaximumSize = new Size(Ui.S(540), 0);
                Controls.Add(state);
                SetFlowBreak(remove, true);
            }

            public Kind Kind { get { return kind.SelectedIndex == 1 ? Kind.Codex : Kind.Claude; } }

            public string AccountName { get { return name.Text; } }

            public string TagText { get { return tag.Text; } }

            public Tint Tint { get { return colors.SelectedItem is Tint ? (Tint)colors.SelectedItem : Tint.Orange; } }

            public new void Focus() { name.Select(); }

            public void Lock(bool locked)
            {
                foreach (var control in new Control[] { kind, name, tag, colors }) control.Enabled = !locked;
                remove.Visible = !locked;
            }

            public void Say(string text, Color color)
            {
                state.Text = text;
                state.ForeColor = color;
                state.Visible = true;
            }

            static string Initials(string text)
            {
                var words = Regex.Split(text, @"[^\p{L}\p{N}]+").Where(word => word.Length > 0).ToList();
                if (words.Count == 0) return "";
                var initials = words.Count == 1 ? words[0].Substring(0, Math.Min(2, words[0].Length)) : new string(words.Take(2).Select(word => word[0]).ToArray());
                return initials.ToUpperInvariant();
            }
        }
    }
}
