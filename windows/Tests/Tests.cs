using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Relaybar;

static class Tests
{
    static int failures;
    static string current;

    static int Main()
    {
        Run("finds signed-in Claude and Codex accounts", FindsSignedInClaudeAndCodexAccounts);
        Run("new Claude account without login is waiting, not expired", NewClaudeAccountWithoutLoginIsWaiting);
        Run("Claude login past its expiry shows as expired", ExpiredClaudeLoginIsExpired);
        Run("Codex without token is waiting, not expired", CodexWithoutTokenIsWaiting);
        Run("reads the newest Codex session in a folder", ReadsTheNewestCodexSessionInAFolder);
        Run("long Codex log reads the newest limits", LongCodexLogReadsTheNewestLimits);
        Run("Claude limits give session and weekly", ClaudeLimitsGiveSessionAndWeekly);
        Run("Claude falls back to older fields", ClaudeFallsBackToOlderFields);
        Run("Codex weekly-only plan", CodexWeeklyOnlyPlan);
        Run("Codex splits five-hour and weekly", CodexSplitsFiveHourAndWeekly);
        Run("Codex log uses the latest Codex limits", CodexLogUsesTheLatestCodexLimits);
        Run("status codes", StatusCodes);
        Run("passed reset means full", PassedResetMeansFull);
        Run("T3 Code: adds a new account", AddsANewAccount);
        Run("T3 Code: re-adding switches an old entry back on", ReaddingSwitchesAnOldEntryBackOn);
        Run("T3 Code: removing cleans every reference", RemovingCleansEveryReference);
        Run("T3 Code: removing an unknown account changes nothing", RemovingAnUnknownAccountChangesNothing);
        Run("T3 Code: unreadable settings are left as they are", UnreadableSettingsAreLeftAlone);
        Run("finds the desktop shortcut for an account", FindsTheShortcutForAnAccount);
        Console.WriteLine(failures == 0 ? "All tests passed." : failures + " check(s) failed.");
        return failures == 0 ? 0 : 1;
    }

    static void FindsSignedInClaudeAndCodexAccounts()
    {
        var home = new Fixture();
        home.Folder(".claude");
        home.Write(".claude.json", "{\"oauthAccount\": {\"emailAddress\": \"sam@example.com\", \"organizationName\": \"sam@example.com's Organization\"}}");
        home.Write(".claude-work/.claude.json", "{\"oauthAccount\": {\"emailAddress\": \"sam@example.org\", \"organizationName\": \"Acme Studio\"}}");
        home.Write(".claude-empty/settings.json", "{}");
        home.Write(".claude-notes", "not a folder");
        var claims = Convert.ToBase64String(Encoding.UTF8.GetBytes("{\"email\": \"sam@example.net\"}")).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        home.Write(".codex/auth.json", "{\"tokens\": {\"id_token\": \"header." + claims + ".signature\"}}");
        home.Write(".codex-client/auth.json", "{}");
        home.Folder(".codex-old");

        var accounts = AccountScanner.Scan(home.Root);

        Same(accounts.Select(a => a.Label), new[] { "sam@example.com", "sam@example.org", "sam@example.net", ".codex-client" });
        Same(accounts.Select(a => a.DefaultTag), new[] { "SA", "AS", "", "CL" });
        Same(accounts.Select(a => a.IsClaude), new[] { true, true, false, false });
        Expect(accounts[0].Credentials == home.Path(".claude/.credentials.json"), "default Claude login file");
        Expect(accounts[1].Credentials == home.Path(".claude-work/.credentials.json"), "second Claude login file");
        Expect(accounts[2].Credentials == home.Path(".codex/auth.json"), "Codex login file");
    }

    static void NewClaudeAccountWithoutLoginIsWaiting()
    {
        var home = new Fixture();
        Expect(Fetch.Claude(home.Path(".credentials.json")).Equals(FetchResult.Failed), "missing file");
        home.Write(".credentials.json", "{\"claudeAiOauth\": {}}");
        Expect(Fetch.Claude(home.Path(".credentials.json")).Equals(FetchResult.Failed), "no token");
    }

    static void ExpiredClaudeLoginIsExpired()
    {
        var home = new Fixture();
        var past = (DateTime.UtcNow.AddMinutes(-5) - Fetch.Epoch).TotalMilliseconds;
        home.Write(".credentials.json", "{\"claudeAiOauth\": {\"accessToken\": \"t\", \"expiresAt\": " + (long)past + "}}");
        Expect(Fetch.Claude(home.Path(".credentials.json")).Equals(FetchResult.Expired), "expired");
    }

    static void CodexWithoutTokenIsWaiting()
    {
        var home = new Fixture();
        home.Write("auth.json", "{\"tokens\": {}}");
        Expect(Fetch.Codex(home.Path("auth.json")).Equals(FetchResult.Failed), "failed");
    }

    static void ReadsTheNewestCodexSessionInAFolder()
    {
        var home = new Fixture();
        Func<int, string> line = used => "{\"payload\": {\"rate_limits\": {\"primary\": {\"used_percent\": " + used + ", \"window_minutes\": 10080}}}}";
        home.Write("day/old.jsonl", line(10));
        home.Write("day/new.jsonl", line(42));
        home.Write("day/notes.txt", line(99));
        File.SetLastWriteTimeUtc(home.Path("day/old.jsonl"), DateTime.UtcNow.AddMinutes(-10));
        Expect(Fetch.NewestCodexLog(home.Path("day")).Equals(FetchResult.Ok(null, new Window(42, null))), "newest");
    }

    static void LongCodexLogReadsTheNewestLimits()
    {
        var home = new Fixture();
        var filler = string.Concat(Enumerable.Repeat("{\"payload\": {\"type\": \"message\", \"text\": \"" + new string('x', 200) + "\"}}\n", 500));
        var latest = "{\"payload\": {\"rate_limits\": {\"limit_id\": \"codex\", \"primary\": {\"used_percent\": 42, \"window_minutes\": 10080}}}}";
        home.Write("session.jsonl", filler + latest + "\r\n");
        Expect(Fetch.CodexLog(home.Path("session.jsonl")).Equals(FetchResult.Ok(null, new Window(42, null))), "latest");
        Expect(Fetch.CodexLog(home.Path("missing.jsonl")) == null, "missing");
    }

    static void ClaudeLimitsGiveSessionAndWeekly()
    {
        var result = UsageParser.Claude(Obj(
            "{\"limits\": [" +
            "{\"kind\": \"session\", \"percent\": 14, \"resets_at\": \"2030-01-01T10:00:00.002866+00:00\"}," +
            "{\"kind\": \"weekly_all\", \"percent\": 75, \"resets_at\": \"2030-01-05T09:00:00+00:00\"}," +
            "{\"kind\": \"weekly_scoped\", \"percent\": 3, \"resets_at\": \"2030-01-05T09:00:00+00:00\"}]}"));
        Expect(result.Kind == FetchKind.Ok, "ok");
        Expect(result.Session.Left == 86, "session left");
        Expect(result.Weekly.Left == 25, "weekly left");
        Expect(result.Session.ResetsAt == Fetch.Epoch.AddSeconds(1893492000), "session reset");
    }

    static void ClaudeFallsBackToOlderFields()
    {
        var result = UsageParser.Claude(Obj("{\"five_hour\": {\"utilization\": 40.4}, \"seven_day\": {\"utilization\": 99.6}}"));
        Expect(result.Session.Left == 60, "session left");
        Expect(result.Weekly.Left == 0, "weekly left");
        Expect(result.Session.ResetsAt == null, "no reset");
    }

    static void CodexWeeklyOnlyPlan()
    {
        var result = UsageParser.Codex(Obj(
            "{\"rate_limit\": {\"primary_window\": {\"used_percent\": 29, \"limit_window_seconds\": 604800, \"reset_at\": 1893492000}}}"));
        Expect(result.Equals(FetchResult.Ok(null, new Window(29, Fetch.Epoch.AddSeconds(1893492000)))), "weekly only");
    }

    static void CodexSplitsFiveHourAndWeekly()
    {
        var result = UsageParser.Codex(Obj(
            "{\"rate_limit\": {\"primary_window\": {\"used_percent\": 10, \"limit_window_seconds\": 18000}," +
            "\"secondary_window\": {\"used_percent\": 60, \"limit_window_seconds\": 604800}}}"));
        Expect(result.Equals(FetchResult.Ok(new Window(10, null), new Window(60, null))), "split");
    }

    static void CodexLogUsesTheLatestCodexLimits()
    {
        var lines = new[]
        {
            "{\"payload\": {\"type\": \"token_count\", \"rate_limits\": {\"limit_id\": \"codex\", \"primary\": {\"used_percent\": 20, \"window_minutes\": 10080}}}}",
            "{\"payload\": {\"type\": \"message\"}}",
            "{\"payload\": {\"type\": \"token_count\", \"rate_limits\": {\"limit_id\": \"codex\", \"primary\": {\"used_percent\": 28, \"window_minutes\": 10080, \"resets_at\": 1893492000}}}}",
            "{\"payload\": {\"type\": \"token_count\", \"rate_limits\": {\"limit_id\": \"review\", \"primary\": {\"used_percent\": 90, \"window_minutes\": 10080}}}}",
        };
        var result = UsageParser.CodexLog(string.Join("\n", lines));
        Expect(result.Equals(FetchResult.Ok(null, new Window(28, Fetch.Epoch.AddSeconds(1893492000)))), "latest codex");
    }

    static void StatusCodes()
    {
        Func<int, string, FetchResult> response = (status, retry) => UsageParser.Response(status, "", retry, UsageParser.Claude);
        Expect(response(401, null).Equals(FetchResult.Expired), "401");
        Expect(response(403, null).Equals(FetchResult.Expired), "403");
        Expect(response(429, "0").Equals(FetchResult.RateLimited(null)), "429 zero");
        Expect(response(429, "30").Equals(FetchResult.RateLimited(30)), "429 thirty");
        Expect(response(500, null).Equals(FetchResult.Failed), "500");
        Expect(response(200, "not json").Equals(FetchResult.Failed), "200 bad body");
    }

    static void PassedResetMeansFull()
    {
        Expect(new Window(90, DateTime.UtcNow.AddMinutes(-1)).Left == 100, "passed");
        Expect(new Window(90, DateTime.UtcNow.AddMinutes(1)).Left == 10, "pending");
        Expect(new Window(130, null).Left == 0, "over");
    }

    const string SettingsPath = ".t3/userdata/settings.json";

    static T3Settings Seeded(Fixture home)
    {
        home.Write(SettingsPath,
            "{\n" +
            "  \"theme\": \"dark\",\n" +
            "  \"favorites\": [{\"provider\": \"claudeAgent\", \"model\": \"m1\"}, {\"provider\": \"claudeAgent_old\", \"model\": \"m1\"}],\n" +
            "  \"providerModelPreferences\": {\"claudeAgent_old\": {\"hiddenModels\": [\"m2\"]}, \"codex\": {\"hiddenModels\": []}},\n" +
            "  \"defaultModelSelection\": {\"instanceId\": \"claudeAgent_old\", \"model\": \"m1\"},\n" +
            "  \"textGenerationModelSelection\": {\"instanceId\": \"codex\", \"model\": \"m3\"},\n" +
            "  \"providerInstances\": {\n" +
            "    \"claudeAgent_old\": {\"driver\": \"claudeAgent\", \"displayName\": \"Old\", \"enabled\": false, \"config\": {\"homePath\": \"C:\\\\h\\\\.claude-old\"}},\n" +
            "    \"claudeAgent_keep\": {\"driver\": \"claudeAgent\", \"displayName\": \"Keep \\u00e9\", \"config\": {\"homePath\": \"C:\\\\h\\\\.claude-keep\"}}\n" +
            "  }\n" +
            "}");
        return new T3Settings(home.Root);
    }

    static void AddsANewAccount()
    {
        var home = new Fixture();
        var settings = Seeded(home);
        settings.Add(false, "Client Work", "#34c759", @"C:\h\.codex-client-work");
        var root = home.Json(SettingsPath);
        var entry = Json.Obj(Json.At(root, "providerInstances", "codex_client_work"));
        Expect(entry != null, "entry");
        Expect(Json.Str(Json.At(entry, "driver")) == "codex", "driver");
        Expect(Json.Str(Json.At(entry, "displayName")) == "Client Work", "name");
        Expect(Json.Str(Json.At(entry, "accentColor")) == "#34c759", "colour");
        Expect(true.Equals(Json.At(entry, "enabled")), "enabled");
        Expect(Json.Str(Json.At(entry, "config", "homePath")) == @"C:\h\.codex-client-work", "home");
        Expect(Json.Str(Json.At(root, "providerInstances", "claudeAgent_keep", "displayName")) == "Keep \u00e9", "other entries kept");
        Expect(settings.Contains(@"C:\h\.codex-client-work"), "contains");
        Expect(File.Exists(home.Path(SettingsPath + ".relaybar-backup")), "backup");
    }

    static void ReaddingSwitchesAnOldEntryBackOn()
    {
        var home = new Fixture();
        Seeded(home).Add(true, "Old", "#ffffff", @"C:\h\.claude-old");
        var instances = Json.Obj(Json.At(home.Json(SettingsPath), "providerInstances"));
        Expect(instances.Count == 2, "no new entry");
        Expect(true.Equals(Json.At(instances, "claudeAgent_old", "enabled")), "enabled");
    }

    static void RemovingCleansEveryReference()
    {
        var home = new Fixture();
        var settings = Seeded(home);
        settings.Remove(@"C:\h\.claude-old");
        var root = home.Json(SettingsPath);
        Same(Json.Obj(Json.At(root, "providerInstances")).Keys, new[] { "claudeAgent_keep" });
        Same(Json.List(Json.At(root, "favorites")).Select(f => Json.Str(Json.At(f, "provider"))), new[] { "claudeAgent" });
        Same(Json.Obj(Json.At(root, "providerModelPreferences")).Keys, new[] { "codex" });
        Expect(Json.Str(Json.At(root, "defaultModelSelection", "instanceId")) == "claudeAgent", "default selection");
        Expect(Json.Str(Json.At(root, "textGenerationModelSelection", "instanceId")) == "codex", "text selection");
        Expect(Json.Str(Json.At(root, "theme")) == "dark", "theme");
        Expect(!settings.Contains(@"C:\h\.claude-old"), "gone");
    }

    static void RemovingAnUnknownAccountChangesNothing()
    {
        var home = new Fixture();
        var settings = Seeded(home);
        var before = File.ReadAllBytes(home.Path(SettingsPath));
        settings.Remove(@"C:\h\.claude-missing");
        Expect(File.ReadAllBytes(home.Path(SettingsPath)).SequenceEqual(before), "unchanged");
    }

    static void UnreadableSettingsAreLeftAlone()
    {
        var home = new Fixture();
        home.Write(SettingsPath, "{ broken");
        var settings = new T3Settings(home.Root);
        var threw = false;
        try { settings.Add(true, "Work", "#ffffff", @"C:\h\.claude-work"); }
        catch (IOException) { threw = true; }
        settings.Remove(@"C:\h\.claude-work");
        Expect(threw, "add refuses");
        Expect(File.ReadAllText(home.Path(SettingsPath)) == "{ broken", "unchanged");
    }

    static void FindsTheShortcutForAnAccount()
    {
        var folder = new Fixture();
        var target = Path.Combine(Environment.SystemDirectory, "notepad.exe");
        Shortcuts.Save(folder.Path("Claude Work.lnk"), target, Launcher.OpenArguments(@"C:\h\.claude-work"), @"C:\h\.claude-work\icon.ico", "Claude Work");
        Shortcuts.Save(folder.Path("Claude Old.lnk"), target, Launcher.OpenArguments(@"C:\h\.claude-work-old"), @"C:\h\icon.ico", "Claude Old");
        Shortcuts.Save(folder.Path("Notes.lnk"), target, Launcher.OpenArguments(@"C:\h\.claude-notes"), @"C:\h\icon.ico", "Notes");

        var found = Launcher.Find(@"C:\h\.claude-work", folder.Root);
        Expect(found != null && found.Shortcut == folder.Path("Claude Work.lnk"), "shortcut");
        Expect(found != null && found.Icon == @"C:\h\.claude-work\icon.ico", "icon");
        Expect(Launcher.Find(@"C:\h\.claude", folder.Root) == null, "no prefix match");
        Expect(Launcher.Find(@"C:\h\.claude-notes", folder.Root) == null, "only Claude and Codex shortcuts");
    }

    static Dictionary<string, object> Obj(string text)
    {
        var obj = Json.Obj(Json.Parse(text));
        if (obj == null) throw new InvalidOperationException("bad test JSON: " + text);
        return obj;
    }

    static void Run(string name, Action test)
    {
        current = name;
        var before = failures;
        try { test(); }
        catch (Exception error)
        {
            failures++;
            Console.WriteLine("FAIL " + name + ": " + error);
        }
        if (failures == before) Console.WriteLine("ok   " + name);
    }

    static void Expect(bool condition, string what)
    {
        if (condition) return;
        failures++;
        Console.WriteLine("FAIL " + current + ": " + what);
    }

    static void Same<T>(IEnumerable<T> actual, IEnumerable<T> expected)
    {
        var a = actual.ToList();
        var e = expected.ToList();
        Expect(a.SequenceEqual(e), "expected [" + string.Join(", ", e) + "] but got [" + string.Join(", ", a) + "]");
    }

    sealed class Fixture
    {
        public readonly string Root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "relaybar-tests-" + Guid.NewGuid().ToString("N"));

        public Fixture() { Directory.CreateDirectory(Root); }

        public string Path(string relative) { return System.IO.Path.Combine(Root, relative.Replace('/', '\\')); }

        public void Write(string relative, string text)
        {
            var path = Path(relative);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path));
            File.WriteAllText(path, text, new UTF8Encoding(false));
        }

        public void Folder(string relative) { Directory.CreateDirectory(Path(relative)); }

        public Dictionary<string, object> Json(string relative) { return Relaybar.Json.Obj(Relaybar.Json.ReadFile(Path(relative))); }
    }
}
