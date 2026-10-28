import AppKit

/// Reads and controls web browsers through their own AppleScript support: list tabs, read the current page,
/// open, switch and close tabs. Works with Chrome, Brave, Edge, Arc, Vivaldi (Chromium family) and Safari.
@MainActor
enum BrowserControl {
    private static let chromium = ["Google Chrome", "Brave Browser", "Microsoft Edge", "Arc", "Vivaldi", "Chromium"]
    private static let all = chromium + ["Safari"]

    /// The browser to use: the one named, else the frontmost browser, else any running one, else Chrome.
    static func resolve(_ name: String?) -> String {
        if let name, !name.isEmpty, name.lowercased() != "any" {
            let wanted = name.lowercased()
            if let match = all.first(where: { $0.lowercased() == wanted || $0.lowercased().contains(wanted) }) { return match }
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName
        if let frontmost, all.contains(frontmost) { return frontmost }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        return all.first(where: running.contains) ?? "Google Chrome"
    }

    private static func isSafari(_ browser: String) -> Bool { browser == "Safari" }

    // MARK: - Tabs

    static func tabs(_ name: String?) -> (String, Bool) {
        let browser = resolve(name)
        let titleKey = isSafari(browser) ? "name" : "title"
        let activeIndex = isSafari(browser) ? "index of current tab of win" : "active tab index of win"
        let script = """
        tell application "\(browser)"
            if (count of windows) = 0 then return "No windows open."
            set out to ""
            set w to 0
            repeat with win in windows
                set w to w + 1
                set active to \(activeIndex)
                set t to 0
                repeat with tb in tabs of win
                    set t to t + 1
                    set marker to ""
                    if t = active then set marker to " (active)"
                    set out to out & "window " & w & ", tab " & t & marker & ": " & (\(titleKey) of tb) & " — " & (URL of tb) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        let (output, failed) = MacTools.appleScript(script, success: "")
        return failed ? (explain(output, browser: browser), true) : ("\(browser) tabs:\n\(output)", false)
    }

    static func open(_ url: String, in name: String?, newTab: Bool) -> (String, Bool) {
        let browser = resolve(name)
        let link = escape(url.contains("://") ? url : "https://\(url)")
        let script: String
        if isSafari(browser) {
            script = newTab ? """
            tell application "Safari"
                activate
                if (count of windows) = 0 then make new document
                tell front window to set current tab to (make new tab with properties {URL:"\(link)"})
            end tell
            """ : """
            tell application "Safari"
                activate
                if (count of windows) = 0 then make new document
                set URL of current tab of front window to "\(link)"
            end tell
            """
        } else {
            script = newTab ? """
            tell application "\(browser)"
                activate
                if (count of windows) = 0 then make new window
                tell front window to make new tab with properties {URL:"\(link)"}
            end tell
            """ : """
            tell application "\(browser)"
                activate
                if (count of windows) = 0 then make new window
                set URL of active tab of front window to "\(link)"
            end tell
            """
        }
        let (output, failed) = MacTools.appleScript(script, success: "")
        return failed ? (explain(output, browser: browser), true) : ("Opened \(url) in \(browser).", false)
    }

    static func switchTab(window: Int, tab: Int, in name: String?) -> (String, Bool) {
        let browser = resolve(name)
        let select = isSafari(browser) ? "set current tab of window \(window) to tab \(tab) of window \(window)"
                                       : "set active tab index of window \(window) to \(tab)"
        let script = """
        tell application "\(browser)"
            activate
            \(select)
            set index of window \(window) to 1
        end tell
        """
        let (output, failed) = MacTools.appleScript(script, success: "")
        return failed ? (explain(output, browser: browser), true) : ("Switched to tab \(tab).", false)
    }

    static func closeTab(window: Int, tab: Int, in name: String?) -> (String, Bool) {
        let browser = resolve(name)
        let (output, failed) = MacTools.appleScript("tell application \"\(browser)\" to close tab \(tab) of window \(window)", success: "")
        return failed ? (explain(output, browser: browser), true) : ("Closed tab \(tab).", false)
    }

    // MARK: - Reading the page

    /// The current tab's title, address and text. Uses the browser's JavaScript bridge when it's allowed,
    /// otherwise reads the page through Accessibility, otherwise downloads the page.
    static func readPage(_ name: String?) async -> (String, Bool) {
        let browser = resolve(name)
        let info = isSafari(browser)
            ? "tell application \"Safari\" to return (name of current tab of front window) & linefeed & (URL of current tab of front window)"
            : "tell application \"\(browser)\" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"
        let (header, failed) = MacTools.appleScript(info, success: "")
        if failed { return (explain(header, browser: browser), true) }
        let lines = header.components(separatedBy: "\n")
        let title = lines.first ?? ""
        let url = lines.count > 1 ? lines[1] : ""

        let javascript = "document.body ? document.body.innerText.slice(0, 20000) : ''"
        let run = isSafari(browser)
            ? "tell application \"Safari\" to do JavaScript \"\(javascript)\" in current tab of front window"
            : "tell application \"\(browser)\" to execute active tab of front window javascript \"\(javascript)\""
        var (text, jsFailed) = MacTools.appleScript(run, success: "")
        if jsFailed || text.isEmpty {
            text = await UIControl.windowText(appName: browser) ?? ""
        }
        if text.isEmpty, let pageURL = URL(string: url), pageURL.scheme?.hasPrefix("http") == true {
            text = await download(pageURL)
        }
        guard !text.isEmpty else {
            return ("\(title) — \(url)\nI couldn't read the page text. In \(browser), turn on View → Developer → Allow JavaScript from Apple Events, then ask again.", false)
        }
        return ("Page: \(title)\nAddress: \(url)\n\n\(text.prefix(20000))", false)
    }

    private static func download(_ url: URL) async -> String {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return "" }
        return html
            .replacingOccurrences(of: #"(?is)<(script|style|noscript)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"&nbsp;|&#160;"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func explain(_ error: String, browser: String) -> String {
        if error.contains("-1743") || error.lowercased().contains("not allowed") {
            return "Saturday isn't allowed to control \(browser) yet. Allow it in System Settings → Privacy & Security → Automation → Saturday."
        }
        if error.contains("-600") || error.contains("isn't running") { return "\(browser) isn't running." }
        return "\(browser) said: \(error)"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
