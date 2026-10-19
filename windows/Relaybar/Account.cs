using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace Relaybar
{
    sealed class Account
    {
        public static readonly string Home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        public readonly string Id;
        public readonly bool IsClaude;
        public readonly string Credentials;
        public readonly string Label;
        readonly string defaultTag;
        readonly Tint defaultTint;

        public Window Session { get; private set; }
        public Window Weekly { get; private set; }
        public bool Stale { get; private set; }
        public DateTime LastFetch { get; private set; }
        public bool RefreshQueued;
        DateTime retryAt = DateTime.MinValue;
        double backoff = 120;

        Account(AccountInfo info, Tint defaultTint)
        {
            Id = info.Id;
            IsClaude = info.IsClaude;
            Credentials = info.Credentials;
            Label = info.Label;
            defaultTag = info.DefaultTag;
            this.defaultTint = defaultTint;
            LastFetch = DateTime.MinValue;
            var saved = Json.List(Prefs.Get("usage:" + Id));
            if (saved != null && saved.Count == 4 && saved.All(value => value is double))
            {
                var numbers = saved.Cast<double>().ToArray();
                Session = Saved(numbers, 0);
                Weekly = Saved(numbers, 2);
            }
        }

        static Window Saved(double[] saved, int index)
        {
            if (saved[index] < 0) return null;
            return new Window(saved[index], saved[index + 1] > 0 ? (DateTime?)Fetch.Epoch.AddSeconds(saved[index + 1]) : null);
        }

        public bool IsMain
        {
            get
            {
                return string.Equals(Id, Path.Combine(Home, ".claude"), StringComparison.OrdinalIgnoreCase)
                    || string.Equals(Id, Path.Combine(Home, ".codex"), StringComparison.OrdinalIgnoreCase);
            }
        }

        public string Tool { get { return IsClaude ? "Claude" : "Codex"; } }

        public string WatchPath
        {
            get
            {
                var path = Path.Combine(Id, IsClaude ? "projects" : "sessions");
                return Directory.Exists(path) ? path : Id;
            }
        }

        public string Tag
        {
            get { return Prefs.Str("tag:" + Id) ?? defaultTag; }
            set { Prefs.Set("tag:" + Id, value); }
        }

        public Tint Tint
        {
            get { return Tints.Parse(Prefs.Str("color:" + Id)) ?? defaultTint; }
            set { Prefs.Set("color:" + Id, value.Raw()); }
        }

        public async Task Refresh()
        {
            if (DateTime.UtcNow < retryAt) return;
            LastFetch = DateTime.UtcNow;
            var credentials = Credentials;
            var claude = IsClaude;
            Apply(await Task.Run(() => claude ? Fetch.Claude(credentials) : Fetch.Codex(credentials)));
        }

        public void Apply(FetchResult result)
        {
            switch (result.Kind)
            {
                case FetchKind.Ok:
                    Session = result.Session;
                    Weekly = result.Weekly;
                    var saved = new List<object>();
                    foreach (var window in new[] { Session, Weekly })
                    {
                        saved.Add(window == null ? -1.0 : window.Used);
                        saved.Add(window == null || !window.ResetsAt.HasValue ? 0.0 : (window.ResetsAt.Value - Fetch.Epoch).TotalSeconds);
                    }
                    Prefs.Set("usage:" + Id, saved);
                    Stale = false;
                    backoff = 120;
                    break;
                case FetchKind.Expired:
                    Stale = true;
                    break;
                case FetchKind.RateLimited:
                    retryAt = DateTime.UtcNow.AddSeconds(result.RetryAfter ?? backoff);
                    backoff = Math.Min(backoff * 2, 900);
                    break;
            }
        }

        public static List<Account> Discover()
        {
            var claudeCount = 0;
            return AccountScanner.Scan(Home)
                .Select(info => info.IsClaude ? new Account(info, Tints.Palette[claudeCount++ % Tints.Palette.Length]) : new Account(info, Tint.Plain))
                .ToList();
        }
    }

    static class Prefs
    {
        static readonly string file = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Relaybar", "settings.json");
        static Dictionary<string, object> data;

        static Dictionary<string, object> Data
        {
            get
            {
                if (data == null) data = Json.Obj(Json.ReadFile(file)) ?? new Dictionary<string, object>();
                return data;
            }
        }

        public static object Get(string key)
        {
            object value;
            return Data.TryGetValue(key, out value) ? value : null;
        }

        public static string Str(string key) { return Get(key) as string; }

        public static List<string> Strings(string key)
        {
            var list = Json.List(Get(key));
            return list == null ? new List<string>() : list.OfType<string>().ToList();
        }

        public static void Set(string key, object value)
        {
            Data[key] = value;
            Save();
        }

        public static void Remove(string key)
        {
            if (Data.Remove(key)) Save();
        }

        static void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(file));
                Json.WriteFile(file, Data);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
