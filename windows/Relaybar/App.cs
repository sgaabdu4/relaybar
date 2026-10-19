using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.VisualBasic.FileIO;
using Microsoft.Win32;
using Timer = System.Windows.Forms.Timer;

namespace Relaybar
{
    sealed class App : ApplicationContext
    {
        const double ActiveGap = 60;
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        readonly Control invoker = new Control();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly List<NotifyIcon> icons = new List<NotifyIcon>();
        readonly List<AccountCard> cards = new List<AccountCard>();
        readonly List<FileSystemWatcher> watchers = new List<FileSystemWatcher>();
        readonly HashSet<string> pending = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, Bitmap> swatches = new Dictionary<string, Bitmap>();
        readonly Timer timer = new Timer { Interval = 300000 };
        readonly Timer debounce = new Timer { Interval = 5000 };
        readonly Icon appIcon;
        Timer waitingForLogin;
        List<Account> accounts = new List<Account>();

        public App()
        {
            invoker.CreateControl();
            if (invoker.Handle == IntPtr.Zero) throw new InvalidOperationException("No window handle.");
            using (var large = Icon.ExtractAssociatedIcon(Application.ExecutablePath)) appIcon = new Icon(large, SystemInformation.SmallIconSize);
            Dialog.AppIcon = appIcon;
            menu.Items.Add("Relaybar");
            menu.Opening += (sender, e) =>
            {
                BuildMenu();
                e.Cancel = false;
            };
            timer.Tick += delegate { Tick(); };
            timer.Start();
            debounce.Tick += delegate
            {
                debounce.Stop();
                var paths = pending.ToList();
                pending.Clear();
                FilesChanged(paths);
            };
            SystemEvents.UserPreferenceChanged += ThemeChanged;
            Reload();
        }

        void ThemeChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (invoker.IsHandleCreated) invoker.BeginInvoke((Action)Redraw);
        }

        void Tick()
        {
            var known = new HashSet<string>(accounts.Select(account => account.Id), StringComparer.OrdinalIgnoreCase);
            if (!known.SetEquals(VisibleAccounts().Select(account => account.Id))) Reload();
            else foreach (var account in accounts) Refresh(account);
        }

        void Reload()
        {
            accounts = VisibleAccounts();
            StopWatching();
            foreach (var account in accounts) Watch(account);
            var wanted = Math.Max(1, accounts.Count);
            while (icons.Count > wanted)
            {
                var icon = icons[icons.Count - 1];
                icons.RemoveAt(icons.Count - 1);
                icon.Visible = false;
                icon.Dispose();
            }
            while (icons.Count < wanted)
            {
                var icon = new NotifyIcon { ContextMenuStrip = menu };
                icon.MouseUp += (sender, e) =>
                {
                    if (e.Button == MouseButtons.Left) ShowMenu(icon);
                };
                icons.Add(icon);
            }
            Redraw();
            foreach (var account in accounts) Refresh(account);
        }

        void Watch(Account account)
        {
            try
            {
                var watcher = new FileSystemWatcher(account.WatchPath)
                {
                    IncludeSubdirectories = true, SynchronizingObject = invoker,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
                };
                watcher.Changed += (sender, e) => Queue(e.FullPath);
                watcher.Created += (sender, e) => Queue(e.FullPath);
                watcher.Renamed += (sender, e) => Queue(e.FullPath);
                watcher.EnableRaisingEvents = true;
                watchers.Add(watcher);
            }
            catch (ArgumentException) { }
            catch (IOException) { }
        }

        void StopWatching()
        {
            foreach (var watcher in watchers) watcher.Dispose();
            watchers.Clear();
        }

        void Queue(string path)
        {
            pending.Add(path);
            if (!debounce.Enabled) debounce.Start();
        }

        void FilesChanged(List<string> paths)
        {
            foreach (var account in accounts.ToList())
            {
                var touched = paths.Where(path => path.StartsWith(account.Id + "\\", StringComparison.OrdinalIgnoreCase)).ToList();
                if (touched.Count == 0) continue;
                if (account.IsClaude)
                {
                    RefreshSoon(account);
                    continue;
                }
                var log = touched.Where(path => path.EndsWith(".jsonl", StringComparison.OrdinalIgnoreCase) && File.Exists(path))
                    .OrderBy(File.GetLastWriteTimeUtc).LastOrDefault();
                var result = log == null ? null : Fetch.NewestCodexLog(Path.GetDirectoryName(log));
                if (result == null) continue;
                account.Apply(result);
                Redraw();
            }
        }

        async void RefreshSoon(Account account)
        {
            var wait = account.LastFetch.AddSeconds(ActiveGap) - DateTime.UtcNow;
            if (wait <= TimeSpan.Zero)
            {
                Refresh(account);
                return;
            }
            if (account.RefreshQueued) return;
            account.RefreshQueued = true;
            await Task.Delay(wait);
            account.RefreshQueued = false;
            if (accounts.Contains(account)) Refresh(account);
        }

        async void Refresh(Account account)
        {
            await account.Refresh();
            Redraw();
            if (account.Session != null || account.Weekly != null) return;
            await Task.Delay(15000);
            if (accounts.Contains(account)) Refresh(account);
        }

        void Redraw()
        {
            var dark = Theme.DarkTaskbar;
            var size = SystemInformation.SmallIconSize.Width;
            if (accounts.Count == 0) SetIcon(icons[0], null, "Relaybar: add an account");
            for (int n = 0; n < accounts.Count; n++) SetIcon(icons[n], Render.Tray(accounts[n], size, dark), Tooltip(accounts[n]));
            foreach (var card in cards) card.Invalidate();
        }

        void SetIcon(NotifyIcon notifyIcon, Icon icon, string text)
        {
            var old = notifyIcon.Icon;
            notifyIcon.Icon = icon ?? appIcon;
            notifyIcon.Text = text.Length > 63 ? text.Substring(0, 63) : text;
            notifyIcon.Visible = true;
            if (old != null && old != appIcon) old.Dispose();
        }

        static string Tooltip(Account account)
        {
            var name = account.Tag.Length == 0 ? account.Tool : account.Tag + " " + account.Tool;
            if (account.Stale) return name + ": login expired";
            var parts = new List<string>();
            if (account.Session != null) parts.Add("5h " + account.Session.Left + "%");
            if (account.Weekly != null) parts.Add("7d " + account.Weekly.Left + "%");
            return parts.Count == 0 ? name + ": waiting" : name + ": " + string.Join(", ", parts) + " left";
        }

        void ShowMenu(NotifyIcon icon)
        {
            var show = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
            if (show != null) show.Invoke(icon, null);
        }

        void BuildMenu()
        {
            var colors = Colors.Get(Theme.DarkApps);
            var renderer = new MenuRenderer(colors);
            ToolStripManager.Renderer = renderer;
            menu.Renderer = renderer;
            menu.BackColor = colors.Background;
            menu.ForeColor = colors.Label;
            menu.Font = SystemFonts.MenuFont;
            var old = menu.Items.Cast<ToolStripItem>().ToList();
            menu.Items.Clear();
            foreach (var item in old) item.Dispose();
            cards.Clear();

            foreach (var account in accounts)
            {
                if ((DateTime.UtcNow - account.LastFetch).TotalSeconds > ActiveGap) Refresh(account);
                var card = new AccountCard(account, AppToOpen(account), colors);
                cards.Add(card);
                menu.Items.Add(card);
            }
            if (accounts.Count > 0) menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(CustomizeItem(colors));
            var add = Item("Add account", null, colors);
            add.DropDownItems.Add(Item("Claude…", () => AddAccount(Kind.Claude), colors));
            add.DropDownItems.Add(Item("Codex…", () => AddAccount(Kind.Codex), colors));
            menu.Items.Add(add);
            var login = Item("Open at login", ToggleLogin, colors);
            login.Checked = StartsAtLogin;
            menu.Items.Add(login);
            menu.Items.Add(Item("Quit Relaybar", Quit, colors));
        }

        ToolStripMenuItem CustomizeItem(Colors colors)
        {
            var customize = Item("Customize", null, colors);
            foreach (var account in accounts)
            {
                var item = Item((account.Tag.Length == 0 ? "" : account.Tag + "  ") + account.Label, null, colors);
                item.Image = Swatch(account.IsClaude ? "claude" : "codex", account.Tint, colors.Dark);
                item.DropDownItems.Add(Item("Rename…", () => Rename(account), colors));
                if (!account.IsMain && account.IsClaude && DesktopApp.Source(true) != null && !DesktopApp.Exists(account.Id))
                    item.DropDownItems.Add(Item("Make desktop app…", () => MakeDesktopApp(account), colors));
                if (!account.IsMain && T3Code.IsInstalled && !T3Code.Contains(account.Id))
                    item.DropDownItems.Add(Item("Add to T3 Code…", () => AddToT3(account), colors));
                item.DropDownItems.Add(Item("Remove…", () => Remove(account), colors));
                item.DropDownItems.Add(new ToolStripSeparator());
                foreach (var tint in Tints.All)
                {
                    var choice = Item(tint.Title(), () => SetTint(account, tint), colors);
                    choice.Image = Swatch("dot", tint, colors.Dark);
                    choice.Checked = account.Tint == tint;
                    item.DropDownItems.Add(choice);
                }
                customize.DropDownItems.Add(item);
            }
            if (Hidden.Count > 0)
            {
                customize.DropDownItems.Add(new ToolStripSeparator());
                customize.DropDownItems.Add(Item("Show hidden accounts", ShowHidden, colors));
            }
            return customize;
        }

        ToolStripMenuItem Item(string text, Action click, Colors colors)
        {
            var item = new ToolStripMenuItem(text) { ForeColor = colors.Label };
            item.DropDown.BackColor = colors.Background;
            if (click != null) item.Click += delegate { invoker.BeginInvoke(click); };
            return item;
        }

        Bitmap Swatch(string shape, Tint tint, bool dark)
        {
            var key = shape + tint + dark;
            Bitmap bitmap;
            if (swatches.TryGetValue(key, out bitmap)) return bitmap;
            var size = Ui.S(16);
            var color = tint.Rgb(dark);
            if (shape == "dot")
            {
                bitmap = new Bitmap(size, size);
                using (var graphics = Graphics.FromImage(bitmap))
                using (var brush = new SolidBrush(color))
                {
                    graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    graphics.FillEllipse(brush, Ui.S(3), Ui.S(3), size - Ui.S(6), size - Ui.S(6));
                }
            }
            else bitmap = Logo.Image(shape == "claude", color, size);
            swatches[key] = bitmap;
            return bitmap;
        }

        string AppToOpen(Account account)
        {
            var launcher = DesktopApp.Find(account.Id);
            if (launcher != null) return launcher.Shortcut;
            return account.IsMain ? DesktopApp.Source(account.IsClaude) : null;
        }

        List<string> Hidden
        {
            get { return Prefs.Strings("hidden"); }
            set { Prefs.Set("hidden", value.Cast<object>().ToList()); }
        }

        List<Account> VisibleAccounts()
        {
            var hidden = new HashSet<string>(Hidden, StringComparer.OrdinalIgnoreCase);
            return Account.Discover().Where(account => !hidden.Contains(account.Id)).ToList();
        }

        void ShowHidden()
        {
            Hidden = new List<string>();
            Reload();
        }

        void SetTint(Account account, Tint tint)
        {
            account.Tint = tint;
            DesktopApp.UpdateIcon(account.Id, account.Tag, account.Tint.Icon());
            Redraw();
        }

        void Rename(Account account)
        {
            var field = Dialog.Field(account.Tag, null, 140);
            if (!Dialog.Ask("Short name for " + account.Label, "Shown on the icon. Up to 3 letters. Leave empty for none.", field)) return;
            var tag = field.Text.Trim();
            account.Tag = tag.Length > 3 ? tag.Substring(0, 3) : tag;
            DesktopApp.UpdateIcon(account.Id, account.Tag, account.Tint.Icon());
            Redraw();
        }

        void Remove(Account account)
        {
            var name = account.Tag.Length == 0 ? account.Label : account.Tag + " (" + account.Label + ")";
            var choice = Dialog.Show(
                "Remove " + name + "?",
                account.IsMain
                    ? "This is your main " + account.Tool + " folder, so Relaybar can only hide it. Nothing is deleted."
                    : "Hide it from Relaybar, or delete the account from this PC.",
                null, account.IsMain ? new[] { "Hide from Relaybar", "Cancel" } : new[] { "Hide from Relaybar", "Delete from this PC…", "Cancel" });
            if (choice == 0)
            {
                Hidden = Hidden.Concat(new[] { account.Id }).ToList();
                Reload();
                return;
            }
            if (account.IsMain || choice != 1) return;

            var targets = new[] { account.Id }.Concat(DesktopApp.Targets(account.Id)).Where(path => File.Exists(path) || Directory.Exists(path)).ToList();
            var details = "These move to the Recycle Bin:\n" + string.Join("\n", targets.Select(path => "  " + Tilde(path)));
            if (account.IsClaude) details += "\n\nThe saved login is in that folder, so you would need to log in again to use it.";
            if (T3Code.Contains(account.Id)) details += "\n\nIts T3 Code entry and favorites are removed too.";
            details += "\n\nClose any " + account.Tool + " windows or terminals using this account first.";
            if (Dialog.Show("Delete " + name + " from this PC?", details, null, "Continue", "Cancel") != 0) return;

            var word = account.Tag.Length == 0 ? Path.GetFileName(account.Id) : account.Tag;
            var field = Dialog.Field("", word, 220);
            if (Dialog.Show("Type " + word + " to delete this account", "This is the last step.", field, "Delete", "Cancel") != 0) return;
            if (field.Text.Trim() != word)
            {
                Dialog.Tell("Nothing was deleted", "The text didn't match " + word + ".");
                return;
            }

            StopWatching();
            var failed = new List<string>();
            foreach (var path in targets)
            {
                try
                {
                    if (Directory.Exists(path)) FileSystem.DeleteDirectory(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
                    else FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
                }
                catch (IOException) { failed.Add(Tilde(path)); }
                catch (UnauthorizedAccessException) { failed.Add(Tilde(path)); }
                catch (OperationCanceledException) { failed.Add(Tilde(path)); }
            }
            try { T3Code.Remove(account.Id); }
            catch (IOException) { failed.Add("T3 Code entry"); }
            catch (UnauthorizedAccessException) { failed.Add("T3 Code entry"); }
            foreach (var key in new[] { "tag:", "color:", "usage:" }) Prefs.Remove(key + account.Id);
            Reload();
            if (failed.Count > 0) Dialog.Tell("Some items could not be removed", string.Join("\n", failed));
        }

        void AddAccount(Kind kind)
        {
            var name = Dialog.Field("", "Account name, for example Work", 300);
            var tag = Dialog.Field("", "Short name on the icon, for example WK", 300);
            var used = new HashSet<Tint>(accounts.Select(account => account.Tint));
            var colors = Dialog.ColorPicker(Tints.Palette.Where(free => !used.Contains(free)).DefaultIfEmpty(Tint.Orange).First());
            var hasApp = DesktopApp.Source(kind.IsClaude) != null;
            var desktop = new CheckBox
            {
                Text = hasApp ? "Make a " + kind.Tool + " desktop app for this account" : "No " + kind.Tool + " desktop app found on this PC",
                AutoSize = true, Checked = hasApp, Enabled = hasApp,
            };
            if (!Dialog.Ask("Add a " + kind.Tool + " account", "A terminal window opens to sign in, and your browser opens the " + kind.Tool + " sign-in page.", Dialog.Stack(name, tag, colors, desktop)))
                return;
            var slug = Slug(name.Text);
            if (slug == null) return;
            var dir = Path.Combine(Account.Home, "." + kind.Tool.ToLowerInvariant() + "-" + slug);
            if (!Create(dir)) return;
            var shortName = tag.Text.Trim();
            if (shortName.Length > 0) Prefs.Set("tag:" + dir, shortName.Length > 3 ? shortName.Substring(0, 3) : shortName);
            var tint = colors.SelectedItem is Tint ? (Tint)colors.SelectedItem : Tint.Orange;
            Prefs.Set("color:" + dir, tint.Raw());
            var title = name.Text.Trim();
            if (desktop.Checked)
            {
                try { DesktopApp.Make(title, dir, Prefs.Str("tag:" + dir) ?? "", tint.Icon()); }
                catch (IOException error) { Dialog.Tell("The account was added, but the desktop app was not made", error.Message); }
                catch (UnauthorizedAccessException error) { Dialog.Tell("The account was added, but the desktop app was not made", error.Message); }
            }
            try { T3Code.Add(kind.IsClaude, title, tint.Icon(), dir); }
            catch (IOException error) { Dialog.Tell("The account was added, but not to T3 Code", error.Message); }
            catch (UnauthorizedAccessException error) { Dialog.Tell("The account was added, but not to T3 Code", error.Message); }
            SignIn(kind, dir);
            WaitForLogin();
        }

        static void SignIn(Kind kind, string dir)
        {
            var info = new ProcessStartInfo("cmd.exe", "/d /c " + kind.Login + " || pause") { UseShellExecute = false };
            info.EnvironmentVariables[kind.Variable] = dir;
            try { Process.Start(info).Dispose(); }
            catch (Win32Exception error) { Dialog.Tell("Could not open a terminal to sign in", error.Message); }
        }

        void WaitForLogin()
        {
            var known = new HashSet<string>(accounts.Select(account => account.Id), StringComparer.OrdinalIgnoreCase);
            var started = DateTime.UtcNow;
            if (waitingForLogin != null) waitingForLogin.Dispose();
            var poll = new Timer { Interval = 5000 };
            waitingForLogin = poll;
            poll.Tick += delegate
            {
                if (VisibleAccounts().Any(account => !known.Contains(account.Id)))
                {
                    poll.Dispose();
                    Reload();
                }
                else if ((DateTime.UtcNow - started).TotalSeconds > 900) poll.Dispose();
            };
            poll.Start();
        }

        void MakeDesktopApp(Account account)
        {
            var field = Dialog.Field(Suggested(account), null, 220);
            if (!Dialog.Ask("Make a Claude desktop app", "The app will be called Claude followed by this name.", field)) return;
            var title = field.Text.Trim();
            if (title.Length == 0)
            {
                Dialog.Tell("Please enter a name", "The name is used for the app.");
                return;
            }
            try
            {
                var shortcut = DesktopApp.Make(title, account.Id, account.Tag, account.Tint.Icon());
                Process.Start("explorer.exe", "/select,\"" + shortcut + "\"").Dispose();
            }
            catch (IOException error) { Dialog.Tell("Could not make the desktop app", error.Message); }
            catch (UnauthorizedAccessException error) { Dialog.Tell("Could not make the desktop app", error.Message); }
        }

        void AddToT3(Account account)
        {
            var field = Dialog.Field(Suggested(account), null, 220);
            if (!Dialog.Ask("Add " + account.Label + " to T3 Code", "The name T3 Code shows for this account.", field)) return;
            var title = field.Text.Trim();
            if (title.Length == 0)
            {
                Dialog.Tell("Please enter a name", "T3 Code shows this name.");
                return;
            }
            try { T3Code.Add(account.IsClaude, title, account.Tint.Icon(), account.Id); }
            catch (IOException error) { Dialog.Tell("Could not add it to T3 Code", error.Message); }
            catch (UnauthorizedAccessException error) { Dialog.Tell("Could not add it to T3 Code", error.Message); }
        }

        static string Suggested(Account account)
        {
            var words = Path.GetFileName(account.Id).Split('-').Skip(1).Where(word => word.Length > 0);
            return string.Join(" ", words.Select(word => char.ToUpperInvariant(word[0]) + word.Substring(1)));
        }

        static string Slug(string name)
        {
            var words = System.Text.RegularExpressions.Regex.Split(name.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(word => word.Length > 0);
            var slug = string.Join("-", words);
            if (slug.Length > 0) return slug;
            Dialog.Tell("Please enter a name", "The name is used for the account's folder.");
            return null;
        }

        static bool Create(string dir)
        {
            if (Directory.Exists(dir) || File.Exists(dir))
            {
                Dialog.Tell("That account already exists", dir);
                return false;
            }
            try
            {
                Directory.CreateDirectory(dir);
                return true;
            }
            catch (IOException error) { Dialog.Tell("Could not create the account folder", error.Message); }
            catch (UnauthorizedAccessException error) { Dialog.Tell("Could not create the account folder", error.Message); }
            return false;
        }

        static string RunCommand { get { return "\"" + Application.ExecutablePath + "\""; } }

        static bool StartsAtLogin
        {
            get
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                    return key != null && string.Equals(key.GetValue("Relaybar") as string, RunCommand, StringComparison.OrdinalIgnoreCase);
            }
        }

        static void ToggleLogin()
        {
            try
            {
                var enabled = StartsAtLogin;
                using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (enabled) key.DeleteValue("Relaybar", false);
                    else key.SetValue("Relaybar", RunCommand);
                }
            }
            catch (UnauthorizedAccessException error) { Dialog.Tell("Could not change the login setting", error.Message); }
        }

        static string Tilde(string path)
        {
            return path.StartsWith(Account.Home + "\\", StringComparison.OrdinalIgnoreCase) ? "~" + path.Substring(Account.Home.Length) : path;
        }

        void Quit()
        {
            SystemEvents.UserPreferenceChanged -= ThemeChanged;
            StopWatching();
            foreach (var icon in icons)
            {
                icon.Visible = false;
                icon.Dispose();
            }
            ExitThread();
        }
    }
}
