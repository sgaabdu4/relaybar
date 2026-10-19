using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace Relaybar
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length == 2 && args[0] == "--open")
            {
                var error = DesktopApp.Open(args[1]);
                if (error == null) return 0;
                Dialog.Tell("Could not open the desktop app", error);
                return 1;
            }
            if (args.Length == 1 && args[0] == "--uninstall")
            {
                Installer.Uninstall();
                return 0;
            }
            if (!Installer.IsInstalledCopy)
            {
                Dialog.AppIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                Application.Run(new SetupForm());
                return 0;
            }
            bool created;
            using (new Mutex(true, "Local\\Relaybar", out created))
            {
                if (!created) return 0;
                Application.Run(new App());
            }
            return 0;
        }

        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();
    }
}
