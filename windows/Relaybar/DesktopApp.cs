using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace Relaybar
{
    sealed class Kind
    {
        public readonly string Tool;
        public readonly string Variable;
        public readonly string Login;

        Kind(string tool, string variable, string login)
        {
            Tool = tool;
            Variable = variable;
            Login = login;
        }

        public bool IsClaude { get { return Tool == "Claude"; } }

        public static readonly Kind Claude = new Kind("Claude", "CLAUDE_CONFIG_DIR", "claude auth login --claudeai");
        public static readonly Kind Codex = new Kind("Codex", "CODEX_HOME", "codex login");
    }

    static class DesktopApp
    {
        const string IconName = "relaybar-desktop.ico";
        const string DataName = "relaybar-desktop";

        static string Folder { get { return Environment.GetFolderPath(Environment.SpecialFolder.Programs); } }

        public static string Source(bool claude)
        {
            if (!claude) return null;
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return new[] { Path.Combine(local, @"Microsoft\WindowsApps\claude-desktop.exe"), Path.Combine(local, @"AnthropicClaude\claude.exe") }
                .FirstOrDefault(File.Exists);
        }

        public static Launcher Find(string configDir) { return Launcher.Find(configDir, Folder); }

        public static bool Exists(string configDir) { return Find(configDir) != null; }

        public static string[] Targets(string configDir)
        {
            var launcher = Find(configDir);
            return launcher == null ? new string[0] : launcher.Targets;
        }

        public static string Make(string name, string configDir, string tag, Color color, string relaybar)
        {
            if (Source(true) == null) throw new IOException("The Claude desktop app was not found.");
            if (name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) throw new IOException("The name can't contain \\ / : * ? \" < > or |.");
            var shortcut = Path.Combine(Folder, "Claude " + name + ".lnk");
            if (File.Exists(shortcut)) throw new IOException(shortcut + " already exists. It was left as it is.");
            var icon = Path.Combine(configDir, IconName);
            File.WriteAllBytes(icon, Render.DesktopIcon(tag, color));
            Shortcuts.Save(shortcut, relaybar, Launcher.OpenArguments(configDir), icon, "Claude for " + name);
            return shortcut;
        }

        public static void UpdateIcon(string configDir, string tag, Color color)
        {
            var launcher = Find(configDir);
            if (launcher == null || string.IsNullOrEmpty(launcher.Icon)) return;
            try
            {
                File.WriteAllBytes(launcher.Icon, Render.DesktopIcon(tag, color));
                SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        public static string Open(string configDir)
        {
            var claude = Path.GetFileName(configDir.TrimEnd('\\')).StartsWith(".claude", StringComparison.Ordinal);
            var source = Source(claude);
            if (source == null) return (claude ? "The Claude" : "The Codex") + " desktop app was not found.";
            if (!Directory.Exists(configDir)) return configDir + " no longer exists.";
            var info = new ProcessStartInfo(source, "--user-data-dir=\"" + Path.Combine(configDir, DataName) + "\"") { UseShellExecute = false };
            info.EnvironmentVariables[claude ? Kind.Claude.Variable : Kind.Codex.Variable] = configDir;
            try
            {
                Process.Start(info).Dispose();
                return null;
            }
            catch (Win32Exception error) { return error.Message; }
        }

        [DllImport("shell32.dll")]
        static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
    }

    static class T3Code
    {
        static readonly T3Settings settings = new T3Settings(Account.Home);

        public static bool IsInstalled
        {
            get
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "t3code");
                return Directory.Exists(dir) && Directory.GetFiles(dir, "T3 Code*.exe").Length > 0;
            }
        }

        public static bool Contains(string homePath) { return settings.Contains(homePath); }

        public static void Add(bool claude, string name, Color color, string homePath)
        {
            if (!IsInstalled) return;
            settings.Add(claude, name, Tints.Hex(color), homePath);
        }

        public static void Remove(string homePath) { settings.Remove(homePath); }
    }
}
