using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Relaybar
{
    public static class Json
    {
        public static object Parse(string text)
        {
            if (text == null) return null;
            try { return new Reader(text).Document(); }
            catch (FormatException) { return null; }
        }

        public static object ReadFile(string path)
        {
            return Parse(ReadText(path));
        }

        public static string ReadText(string path)
        {
            try
            {
                using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(file, Encoding.UTF8))
                    return reader.ReadToEnd();
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        public static void WriteFile(string path, object value)
        {
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, Write(value), new UTF8Encoding(false));
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }

        public static Dictionary<string, object> Obj(object value) { return value as Dictionary<string, object>; }

        public static List<object> List(object value) { return value as List<object>; }

        public static string Str(object value) { return value as string; }

        public static double? Num(object value) { return value is double ? (double?)(double)value : null; }

        public static object At(object value, params string[] keys)
        {
            foreach (var key in keys)
            {
                var obj = Obj(value);
                if (obj == null || !obj.TryGetValue(key, out value)) return null;
            }
            return value;
        }

        public static string Write(object value)
        {
            var builder = new StringBuilder();
            Write(builder, value, "");
            return builder.Append('\n').ToString();
        }

        static void Write(StringBuilder b, object value, string indent)
        {
            var obj = value as IDictionary<string, object>;
            var list = value as IList<object>;
            var inner = indent + "  ";
            if (value == null) b.Append("null");
            else if (value is bool) b.Append((bool)value ? "true" : "false");
            else if (value is string) Quote(b, (string)value);
            else if (obj != null)
            {
                if (obj.Count == 0) { b.Append("{}"); return; }
                b.Append("{\n");
                var first = true;
                foreach (var pair in obj)
                {
                    if (!first) b.Append(",\n");
                    first = false;
                    b.Append(inner);
                    Quote(b, pair.Key);
                    b.Append(": ");
                    Write(b, pair.Value, inner);
                }
                b.Append('\n').Append(indent).Append('}');
            }
            else if (list != null)
            {
                if (list.Count == 0) { b.Append("[]"); return; }
                b.Append("[\n");
                for (int n = 0; n < list.Count; n++)
                {
                    if (n > 0) b.Append(",\n");
                    b.Append(inner);
                    Write(b, list[n], inner);
                }
                b.Append('\n').Append(indent).Append(']');
            }
            else b.Append(Convert.ToDouble(value, CultureInfo.InvariantCulture).ToString("R", CultureInfo.InvariantCulture));
        }

        static void Quote(StringBuilder b, string text)
        {
            b.Append('"');
            foreach (var c in text)
            {
                switch (c)
                {
                    case '"': b.Append("\\\""); break;
                    case '\\': b.Append("\\\\"); break;
                    case '\n': b.Append("\\n"); break;
                    case '\r': b.Append("\\r"); break;
                    case '\t': b.Append("\\t"); break;
                    default:
                        if (c < ' ') b.Append("\\u").Append(((int)c).ToString("x4"));
                        else b.Append(c);
                        break;
                }
            }
            b.Append('"');
        }

        sealed class Reader
        {
            readonly string s;
            int i;

            public Reader(string s) { this.s = s; }

            public object Document()
            {
                var value = Value();
                Space();
                if (i != s.Length) throw new FormatException();
                return value;
            }

            void Space()
            {
                while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '﻿')) i++;
            }

            char Next()
            {
                Space();
                if (i >= s.Length) throw new FormatException();
                return s[i];
            }

            object Value()
            {
                var c = Next();
                if (c == '{') return Object();
                if (c == '[') return Array();
                if (c == '"') return String();
                if (Word("true")) return true;
                if (Word("false")) return false;
                if (Word("null")) return null;
                return Number();
            }

            bool Word(string word)
            {
                if (i + word.Length > s.Length || string.CompareOrdinal(s, i, word, 0, word.Length) != 0) return false;
                i += word.Length;
                return true;
            }

            Dictionary<string, object> Object()
            {
                var obj = new Dictionary<string, object>();
                i++;
                if (Next() == '}') { i++; return obj; }
                while (true)
                {
                    if (Next() != '"') throw new FormatException();
                    var key = String();
                    if (Next() != ':') throw new FormatException();
                    i++;
                    obj[key] = Value();
                    var c = Next();
                    i++;
                    if (c == '}') return obj;
                    if (c != ',') throw new FormatException();
                }
            }

            List<object> Array()
            {
                var list = new List<object>();
                i++;
                if (Next() == ']') { i++; return list; }
                while (true)
                {
                    list.Add(Value());
                    var c = Next();
                    i++;
                    if (c == ']') return list;
                    if (c != ',') throw new FormatException();
                }
            }

            string String()
            {
                i++;
                var b = new StringBuilder();
                while (true)
                {
                    if (i >= s.Length) throw new FormatException();
                    var c = s[i++];
                    if (c == '"') return b.ToString();
                    if (c != '\\') { b.Append(c); continue; }
                    if (i >= s.Length) throw new FormatException();
                    var escape = s[i++];
                    switch (escape)
                    {
                        case 'b': b.Append('\b'); break;
                        case 'f': b.Append('\f'); break;
                        case 'n': b.Append('\n'); break;
                        case 'r': b.Append('\r'); break;
                        case 't': b.Append('\t'); break;
                        case 'u':
                            int code;
                            if (i + 4 > s.Length || !int.TryParse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code))
                                throw new FormatException();
                            b.Append((char)code);
                            i += 4;
                            break;
                        default: b.Append(escape); break;
                    }
                }
            }

            double Number()
            {
                var start = i;
                while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
                double value;
                if (i == start || !double.TryParse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out value))
                    throw new FormatException();
                return value;
            }
        }
    }

    public sealed class Window
    {
        public readonly double Used;
        public readonly DateTime? ResetsAt;

        public Window(double used, DateTime? resetsAt)
        {
            Used = used;
            ResetsAt = resetsAt;
        }

        public int Left
        {
            get
            {
                if (ResetsAt.HasValue && ResetsAt.Value < DateTime.UtcNow) return 100;
                return Math.Max(0, 100 - (int)Math.Round(Used, MidpointRounding.AwayFromZero));
            }
        }

        public override bool Equals(object other)
        {
            var window = other as Window;
            return window != null && window.Used == Used && window.ResetsAt == ResetsAt;
        }

        public override int GetHashCode() { return Used.GetHashCode(); }

        public override string ToString() { return "Window(" + Used + ", " + ResetsAt + ")"; }
    }

    public enum FetchKind { Ok, Expired, RateLimited, Failed }

    public sealed class FetchResult
    {
        public readonly FetchKind Kind;
        public readonly Window Session;
        public readonly Window Weekly;
        public readonly double? RetryAfter;

        FetchResult(FetchKind kind, Window session, Window weekly, double? retryAfter)
        {
            Kind = kind;
            Session = session;
            Weekly = weekly;
            RetryAfter = retryAfter;
        }

        public static FetchResult Ok(Window session, Window weekly) { return new FetchResult(FetchKind.Ok, session, weekly, null); }

        public static FetchResult RateLimited(double? retryAfter) { return new FetchResult(FetchKind.RateLimited, null, null, retryAfter); }

        public static readonly FetchResult Expired = new FetchResult(FetchKind.Expired, null, null, null);
        public static readonly FetchResult Failed = new FetchResult(FetchKind.Failed, null, null, null);

        public override bool Equals(object other)
        {
            var result = other as FetchResult;
            return result != null && result.Kind == Kind && Equals(result.Session, Session) && Equals(result.Weekly, Weekly)
                && result.RetryAfter == RetryAfter;
        }

        public override int GetHashCode() { return (int)Kind; }

        public override string ToString() { return Kind + "(" + Session + ", " + Weekly + ", " + RetryAfter + ")"; }
    }

    public static class Fetch
    {
        public static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        static Fetch()
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288;
        }

        public static FetchResult Claude(string credentials)
        {
            var oauth = Json.At(Json.ReadFile(credentials), "claudeAiOauth");
            var token = Json.Str(Json.At(oauth, "accessToken"));
            if (token == null) return FetchResult.Failed;
            var expiresAt = Json.Num(Json.At(oauth, "expiresAt"));
            if (expiresAt.HasValue && Epoch.AddMilliseconds(expiresAt.Value) <= DateTime.UtcNow) return FetchResult.Expired;
            return Get(
                "https://api.anthropic.com/api/oauth/usage", token,
                new Dictionary<string, string> { { "anthropic-beta", "oauth-2025-04-20" } }, UsageParser.Claude);
        }

        public static FetchResult Codex(string authFile)
        {
            var tokens = Json.At(Json.ReadFile(authFile), "tokens");
            var token = Json.Str(Json.At(tokens, "access_token"));
            if (token == null) return FetchResult.Failed;
            var headers = new Dictionary<string, string>();
            var accountId = Json.Str(Json.At(tokens, "account_id"));
            if (accountId != null) headers["ChatGPT-Account-Id"] = accountId;
            return Get("https://chatgpt.com/backend-api/wham/usage", token, headers, UsageParser.Codex);
        }

        public static FetchResult NewestCodexLog(string folder)
        {
            string[] files;
            try { files = Directory.GetFiles(folder); }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
            var newest = files
                .Where(file => string.Equals(Path.GetExtension(file), ".jsonl", StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
            return newest == null ? null : CodexLog(newest);
        }

        public static FetchResult CodexLog(string file)
        {
            try
            {
                using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var start = Math.Max(0, stream.Length - 65536);
                    stream.Seek(start, SeekOrigin.Begin);
                    var bytes = new byte[stream.Length - start];
                    int read = 0, count;
                    while (read < bytes.Length && (count = stream.Read(bytes, read, bytes.Length - read)) > 0) read += count;
                    return UsageParser.CodexLog(Encoding.UTF8.GetString(bytes, 0, read));
                }
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }

        static FetchResult Get(
            string url, string token, Dictionary<string, string> headers, Func<Dictionary<string, object>, FetchResult> parse)
        {
            try
            {
                var request = (HttpWebRequest)WebRequest.Create(url);
                request.Timeout = 20000;
                request.ReadWriteTimeout = 20000;
                request.UserAgent = "Relaybar/1.0";
                request.Headers["Authorization"] = "Bearer " + token;
                foreach (var header in headers) request.Headers[header.Key] = header.Value;
                HttpWebResponse response;
                try { response = (HttpWebResponse)request.GetResponse(); }
                catch (WebException error)
                {
                    response = error.Response as HttpWebResponse;
                    if (response == null) return FetchResult.Failed;
                }
                using (response)
                using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                    return UsageParser.Response((int)response.StatusCode, reader.ReadToEnd(), response.Headers["Retry-After"], parse);
            }
            catch (WebException) { return FetchResult.Failed; }
            catch (IOException) { return FetchResult.Failed; }
        }
    }

    public static class UsageParser
    {
        public static FetchResult Response(
            int status, string body, string retryAfter, Func<Dictionary<string, object>, FetchResult> parse)
        {
            switch (status)
            {
                case 200:
                    {
                        var json = Json.Obj(Json.Parse(body));
                        return json == null ? FetchResult.Failed : parse(json);
                    }
                case 401:
                case 403:
                    return FetchResult.Expired;
                case 429:
                    {
                        double seconds;
                        var valid = double.TryParse(retryAfter, NumberStyles.Float, CultureInfo.InvariantCulture, out seconds) && seconds > 0;
                        return FetchResult.RateLimited(valid ? (double?)seconds : null);
                    }
                default:
                    return FetchResult.Failed;
            }
        }

        public static FetchResult Claude(Dictionary<string, object> json)
        {
            var limits = Json.List(Json.At(json, "limits")) ?? new List<object>();
            Func<string, string, Window> window = (kind, legacy) =>
            {
                var limit = limits.Select(Json.Obj).FirstOrDefault(entry => entry != null && Json.Str(Json.At(entry, "kind")) == kind);
                var percent = limit == null ? null : Json.Num(Json.At(limit, "percent"));
                if (percent.HasValue) return new Window(percent.Value, IsoDate(Json.At(limit, "resets_at")));
                var old = Json.Obj(Json.At(json, legacy));
                percent = old == null ? null : Json.Num(Json.At(old, "utilization"));
                return percent.HasValue ? new Window(percent.Value, IsoDate(Json.At(old, "resets_at"))) : null;
            };
            return FetchResult.Ok(window("session", "five_hour"), window("weekly_all", "seven_day"));
        }

        public static FetchResult Codex(Dictionary<string, object> json)
        {
            var limits = Json.At(json, "rate_limit");
            return Split(
                new[] { "primary_window", "secondary_window" }.Select(key => Json.Obj(Json.At(limits, key))),
                "used_percent", "reset_at", entry => Json.Num(Json.At(entry, "limit_window_seconds")) ?? 604800);
        }

        public static FetchResult CodexLog(string text)
        {
            var lines = text.Split('\n');
            for (int n = lines.Length - 1; n >= 0; n--)
            {
                if (lines[n].IndexOf("\"rate_limits\"", StringComparison.Ordinal) < 0) continue;
                var limits = Json.Obj(Json.At(Json.Parse(lines[n]), "payload", "rate_limits"));
                if (limits == null || (Json.Str(Json.At(limits, "limit_id")) ?? "codex") != "codex") continue;
                var result = Split(
                    new[] { "primary", "secondary" }.Select(key => Json.Obj(Json.At(limits, key))),
                    "used_percent", "resets_at", entry => (Json.Num(Json.At(entry, "window_minutes")) ?? 10080) * 60);
                if (!result.Equals(FetchResult.Ok(null, null))) return result;
            }
            return null;
        }

        static FetchResult Split(
            IEnumerable<Dictionary<string, object>> entries, string used, string reset, Func<Dictionary<string, object>, double> length)
        {
            var windows = new List<KeyValuePair<double, Window>>();
            foreach (var entry in entries.Where(entry => entry != null))
            {
                var percent = Json.Num(Json.At(entry, used));
                if (!percent.HasValue) continue;
                var at = Json.Num(Json.At(entry, reset));
                var resetsAt = at.HasValue ? (DateTime?)Fetch.Epoch.AddSeconds(at.Value) : null;
                windows.Add(new KeyValuePair<double, Window>(length(entry), new Window(percent.Value, resetsAt)));
            }
            return FetchResult.Ok(
                windows.Where(pair => pair.Key <= 6 * 3600).Select(pair => pair.Value).FirstOrDefault(),
                windows.Where(pair => pair.Key > 6 * 3600).Select(pair => pair.Value).FirstOrDefault());
        }

        public static DateTime? IsoDate(object value)
        {
            var text = value as string;
            if (text == null) return null;
            DateTimeOffset date;
            var trimmed = Regex.Replace(text, @"\.\d+", "");
            return DateTimeOffset.TryParse(trimmed, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out date)
                ? (DateTime?)date.UtcDateTime
                : null;
        }
    }

    public sealed class AccountInfo
    {
        public readonly string Id;
        public readonly bool IsClaude;
        public readonly string Credentials;
        public readonly string Label;
        public readonly string DefaultTag;

        public AccountInfo(string id, bool isClaude, string credentials, string label, string defaultTag)
        {
            Id = id;
            IsClaude = isClaude;
            Credentials = credentials;
            Label = label;
            DefaultTag = defaultTag;
        }
    }

    public static class AccountScanner
    {
        public static List<AccountInfo> Scan(string home)
        {
            string[] dirs;
            try { dirs = Directory.GetDirectories(home); }
            catch (IOException) { return new List<AccountInfo>(); }
            catch (UnauthorizedAccessException) { return new List<AccountInfo>(); }
            var claude = new List<AccountInfo>();
            var codex = new List<AccountInfo>();
            foreach (var dir in dirs.OrderBy(Path.GetFileName, StringComparer.Ordinal))
            {
                var name = Path.GetFileName(dir);
                if (name == ".claude" || name.StartsWith(".claude-", StringComparison.Ordinal))
                {
                    var isDefault = name == ".claude";
                    var config = isDefault ? Path.Combine(home, ".claude.json") : Path.Combine(dir, ".claude.json");
                    var oauth = Json.At(Json.ReadFile(config), "oauthAccount");
                    var email = Json.Str(Json.At(oauth, "emailAddress"));
                    if (email == null) continue;
                    var org = Json.Str(Json.At(oauth, "organizationName")) ?? "";
                    var tag = org.Length == 0 || org.EndsWith("'s Organization", StringComparison.Ordinal)
                        ? Prefix(email, 2).ToUpperInvariant()
                        : Initials(org);
                    claude.Add(new AccountInfo(dir, true, Path.Combine(dir, ".credentials.json"), email, tag));
                }
                else if (name == ".codex" || name.StartsWith(".codex-", StringComparison.Ordinal))
                {
                    var auth = Path.Combine(dir, "auth.json");
                    if (!File.Exists(auth)) continue;
                    var suffix = name.Substring(".codex".Length).TrimStart('-');
                    codex.Add(new AccountInfo(dir, false, auth, CodexEmail(auth) ?? name, Prefix(suffix, 2).ToUpperInvariant()));
                }
            }
            return claude.Concat(codex).ToList();
        }

        static string Prefix(string text, int count)
        {
            return text.Length <= count ? text : text.Substring(0, count);
        }

        static string Initials(string text)
        {
            var words = Regex.Split(text, @"[^\p{L}\p{N}]+").Where(word => word.Length > 0);
            return new string(words.Take(2).Select(word => word[0]).ToArray()).ToUpperInvariant();
        }

        static string CodexEmail(string auth)
        {
            var token = Json.Str(Json.At(Json.ReadFile(auth), "tokens", "id_token"));
            if (token == null) return null;
            var parts = token.Split('.');
            if (parts.Length < 2) return null;
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload += new string('=', (4 - payload.Length % 4) % 4);
            try { return Json.Str(Json.At(Json.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(payload))), "email")); }
            catch (FormatException) { return null; }
        }
    }

    public sealed class T3Settings
    {
        public readonly string SettingsFile;

        public T3Settings(string home)
        {
            SettingsFile = Path.Combine(home, ".t3", "userdata", "settings.json");
        }

        public bool Contains(string homePath)
        {
            var root = Read();
            return root != null && Instances(root).Any(pair => SameHome(pair.Value, homePath));
        }

        public void Add(bool claude, string name, string hex, string homePath)
        {
            var root = ReadForWriting();
            var instances = Instances(root);
            var existing = instances.FirstOrDefault(pair => SameHome(pair.Value, homePath));
            if (existing.Key != null)
            {
                var entry = Json.Obj(existing.Value) ?? new Dictionary<string, object>();
                if (!false.Equals(Json.At(entry, "enabled"))) return;
                entry["enabled"] = true;
                instances[existing.Key] = entry;
                root["providerInstances"] = instances;
                Write(root);
                return;
            }
            var driver = claude ? "claudeAgent" : "codex";
            var slug = string.Join("_", Regex.Split(name.ToLowerInvariant(), @"[^\p{L}\p{N}]+").Where(word => word.Length > 0));
            var key = driver + "_" + (slug.Length == 0 ? "account" : slug);
            for (int number = 2; instances.ContainsKey(key); number++) key = driver + "_" + slug + "_" + number;
            instances[key] = new Dictionary<string, object>
            {
                { "driver", driver }, { "displayName", name }, { "accentColor", hex }, { "enabled", true },
                { "config", new Dictionary<string, object> { { "homePath", homePath } } },
            };
            root["providerInstances"] = instances;
            Write(root);
        }

        public void Remove(string homePath)
        {
            var root = Read();
            if (root == null) return;
            var instances = Instances(root);
            var removed = instances.Where(pair => SameHome(pair.Value, homePath)).ToList();
            if (removed.Count == 0) return;
            foreach (var pair in removed)
            {
                instances.Remove(pair.Key);
                var driver = Json.Str(Json.At(pair.Value, "driver")) ?? "claudeAgent";
                var favorites = Json.List(Json.At(root, "favorites"));
                if (favorites != null) favorites.RemoveAll(favorite => Json.Str(Json.At(favorite, "provider")) == pair.Key);
                var preferences = Json.Obj(Json.At(root, "providerModelPreferences"));
                if (preferences != null) preferences.Remove(pair.Key);
                foreach (var setting in new[] { "defaultModelSelection", "textGenerationModelSelection" })
                {
                    var selection = Json.Obj(Json.At(root, setting));
                    if (selection != null && Json.Str(Json.At(selection, "instanceId")) == pair.Key) selection["instanceId"] = driver;
                }
            }
            root["providerInstances"] = instances;
            Write(root);
        }

        Dictionary<string, object> Read()
        {
            if (!File.Exists(SettingsFile)) return new Dictionary<string, object>();
            return Json.Obj(Json.ReadFile(SettingsFile));
        }

        Dictionary<string, object> ReadForWriting()
        {
            var root = Read();
            if (root == null) throw new IOException(SettingsFile + " could not be read, so it was left as it is.");
            return root;
        }

        static Dictionary<string, object> Instances(Dictionary<string, object> root)
        {
            return Json.Obj(Json.At(root, "providerInstances")) ?? new Dictionary<string, object>();
        }

        static bool SameHome(object instance, string homePath)
        {
            return string.Equals(Json.Str(Json.At(instance, "config", "homePath")), homePath, StringComparison.OrdinalIgnoreCase);
        }

        void Write(Dictionary<string, object> root)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsFile));
            if (File.Exists(SettingsFile)) File.Copy(SettingsFile, SettingsFile + ".relaybar-backup", true);
            Json.WriteFile(SettingsFile, root);
        }
    }

    public sealed class Launcher
    {
        public readonly string Shortcut;
        public readonly string Icon;

        Launcher(string shortcut, string icon)
        {
            Shortcut = shortcut;
            Icon = icon;
        }

        public string[] Targets { get { return new[] { Shortcut }; } }

        public static string OpenArguments(string configDir)
        {
            return "--open \"" + configDir + "\"";
        }

        public static Launcher Find(string configDir, string folder)
        {
            string[] files;
            try { files = Directory.GetFiles(folder, "*.lnk"); }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
            var wanted = OpenArguments(configDir);
            foreach (var file in files.OrderBy(file => file, StringComparer.Ordinal))
            {
                var name = Path.GetFileName(file);
                if (!name.StartsWith("Claude ", StringComparison.Ordinal) && !name.StartsWith("Codex ", StringComparison.Ordinal)) continue;
                var link = Shortcuts.Read(file);
                if (link != null && string.Equals(link.Arguments.Trim(), wanted, StringComparison.OrdinalIgnoreCase))
                    return new Launcher(file, link.Icon);
            }
            return null;
        }
    }

    public static class Shortcuts
    {
        public sealed class Link
        {
            public string Target;
            public string Arguments;
            public string Icon;
        }

        public static void Save(string path, string target, string arguments, string icon, string description)
        {
            try
            {
                Use(path, link =>
                {
                    Set(link, "TargetPath", target);
                    Set(link, "Arguments", arguments);
                    Set(link, "WorkingDirectory", Path.GetDirectoryName(target));
                    Set(link, "IconLocation", icon + ",0");
                    Set(link, "Description", description);
                    link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
                    return true;
                });
            }
            catch (TargetInvocationException error)
            {
                throw new IOException("Could not save " + path + ": " + error.InnerException.Message);
            }
        }

        public static Link Read(string path)
        {
            try
            {
                return Use(path, link =>
                {
                    var icon = (string)Get(link, "IconLocation") ?? "";
                    var comma = icon.LastIndexOf(',');
                    return new Link
                    {
                        Target = (string)Get(link, "TargetPath"),
                        Arguments = (string)Get(link, "Arguments") ?? "",
                        Icon = comma >= 0 ? icon.Substring(0, comma) : icon,
                    };
                });
            }
            catch (TargetInvocationException) { return null; }
            catch (COMException) { return null; }
        }

        static T Use<T>(string path, Func<object, T> body)
        {
            var type = Type.GetTypeFromProgID("WScript.Shell");
            object shell = null, link = null;
            try
            {
                shell = Activator.CreateInstance(type);
                link = type.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
                return body(link);
            }
            finally
            {
                if (link != null) Marshal.FinalReleaseComObject(link);
                if (shell != null) Marshal.FinalReleaseComObject(shell);
            }
        }

        static object Get(object target, string name)
        {
            return target.GetType().InvokeMember(name, BindingFlags.GetProperty, null, target, null);
        }

        static void Set(object target, string name, object value)
        {
            target.GetType().InvokeMember(name, BindingFlags.SetProperty, null, target, new[] { value });
        }
    }
}
