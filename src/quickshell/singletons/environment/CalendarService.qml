pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

Item {
    id: root

    readonly property string syncScriptPath: {
        if (typeof Caching !== "undefined" && Caching.serpantinumDir && Caching.serpantinumDir.length > 0) {
            return Caching.serpantinumDir + "/scripts/calendar_sync.py";
        }
        return Qt.resolvedUrl("../../../scripts/calendar_sync.py").toString().replace(/^file:\/\//, "");
    }

    readonly property string cacheFilePath: {
        if (typeof Caching !== "undefined" && typeof Caching.getCacheDir === "function") {
            return Caching.getCacheDir("calendar") + "/events.json";
        }
        return (Quickshell.env("HOME") || "") + "/.cache/serpantinum/calendar/events.json";
    }

    readonly property string configFilePath: {
        let xdg = Quickshell.env("XDG_CONFIG_HOME");
        let base = (xdg && xdg !== "") ? xdg : ((Quickshell.env("HOME") || "") + "/.config");
        return base + "/serpantinum/calendars.json";
    }

    property bool isReady: false
    property bool isLoading: false
    property string lastSyncTime: ""
    property var rawData: ({})
    property var events: []
    property var calendars: []
    property var errors: []
    property var warnings: []
    property bool isCached: rawData && (rawData.status === "cached")
    property string lastError: (errors && errors.length > 0) ? (errors[0].calendar + ": " + errors[0].error) : ""
    property string lastWarning: (warnings && warnings.length > 0) ? (warnings[0].calendar + ": " + warnings[0].message) : ""
    property int eventsCount: events ? events.length : 0

    property int refreshInterval: 15 * 60 * 1000 // 15 mins

    signal calendarUpdated()

    function sync(showLoader, force) {
        if (showLoader !== false) {
            root.isLoading = true;
        }
        let shouldForce = (force === true) || (showLoader === true);
        if (shouldForce) {
            syncProcess.command = ["python3", root.syncScriptPath, "--force-sync"];
        } else {
            syncProcess.command = ["python3", root.syncScriptPath, "--sync"];
        }
        syncProcess.running = false;
        syncProcess.running = true;
    }

    function addCalendar(name, url, color) {
        root.isLoading = true;
        let cName = (name || "Calendar").trim();
        let cUrl = (url || "").trim();
        let cColor = (color || "#89b4fa").trim();
        addProcess.calName = cName;
        addProcess.calUrl = cUrl;
        addProcess.calColor = cColor;
        addProcess.running = false;
        addProcess.running = true;
    }

    function removeCalendar(idOrUrl) {
        root.isLoading = true;
        removeProcess.targetId = (idOrUrl || "").trim();
        removeProcess.running = false;
        removeProcess.running = true;
    }

    function toggleCalendar(idOrUrl) {
        root.isLoading = true;
        toggleProcess.targetId = (idOrUrl || "").trim();
        toggleProcess.running = false;
        toggleProcess.running = true;
    }

    function parseData(jsonText) {
        if (!jsonText) {
            root.isLoading = false;
            return;
        }
        let txt = typeof jsonText === "function" ? jsonText() : jsonText;
        if (typeof txt !== "string") txt = String(txt || "");
        txt = txt.trim();
        if (txt === "") {
            root.isLoading = false;
            return;
        }

        try {
            let parsed = JSON.parse(txt);
            root.rawData = parsed;
            root.events = parsed.events || [];
            root.calendars = parsed.calendars || [];
            root.errors = parsed.errors || [];
            root.warnings = parsed.warnings || [];
            root.lastSyncTime = parsed.last_sync || "";
            root.isReady = true;
            root.isLoading = false;
            root.calendarUpdated();
        } catch (e) {
            root.isLoading = false;
        }
    }

    function getEventsForDate(year, month, day) {
        if (!root.events || root.events.length === 0) return [];
        let y = Number(year);
        let m = Number(month);
        let d = Number(day);
        let res = [];
        for (let i = 0; i < root.events.length; i++) {
            let ev = root.events[i];
            if (ev.year === y && ev.month === m && ev.day === d) {
                res.push(ev);
            }
        }
        return res;
    }

    function hasEventsOnDate(year, month, day) {
        if (!root.events || root.events.length === 0) return false;
        let y = Number(year);
        let m = Number(month);
        let d = Number(day);
        for (let i = 0; i < root.events.length; i++) {
            let ev = root.events[i];
            if (ev.year === y && ev.month === m && ev.day === d) {
                return true;
            }
        }
        return false;
    }

    function getEventColorsForDate(year, month, day) {
        if (!root.events || root.events.length === 0) return [];
        let y = Number(year);
        let m = Number(month);
        let d = Number(day);
        let colors = [];
        for (let i = 0; i < root.events.length; i++) {
            let ev = root.events[i];
            if (ev.year === y && ev.month === m && ev.day === d) {
                let c = ev.calendar_color || "#89b4fa";
                if (!colors.includes(c)) {
                    colors.push(c);
                    if (colors.length >= 3) break;
                }
            }
        }
        return colors;
    }

    function getUpcomingEvents(limit) {
        if (!root.events || root.events.length === 0) return [];
        let max = limit || 10;
        let now = new Date();
        let todayStr = now.getFullYear() + "-"
            + String(now.getMonth() + 1).padStart(2, '0') + "-"
            + String(now.getDate()).padStart(2, '0');
        let currentTimeStr = todayStr + "T"
            + String(now.getHours()).padStart(2, '0') + ":"
            + String(now.getMinutes()).padStart(2, '0') + ":"
            + String(now.getSeconds()).padStart(2, '0');

        let res = [];
        for (let i = 0; i < root.events.length; i++) {
            let ev = root.events[i];
            // Include today's events or future events
            if (ev.is_all_day) {
                if (ev.date >= todayStr) {
                    res.push(ev);
                }
            } else {
                if (ev.end >= currentTimeStr || ev.start >= currentTimeStr) {
                    res.push(ev);
                }
            }
            if (res.length >= max) break;
        }
        return res;
    }

    Process {
        id: syncProcess
        command: ["python3", root.syncScriptPath, "--sync"]
        stdout: StdioCollector {
            onStreamFinished: root.parseData(this.text)
        }
        onExited: root.isLoading = false
    }

    Process {
        id: addProcess
        property string calName: ""
        property string calUrl: ""
        property string calColor: "#89b4fa"
        command: ["python3", root.syncScriptPath, "--add", calName, calUrl, calColor]
        stdout: StdioCollector {
            onStreamFinished: root.parseData(this.text)
        }
        onExited: root.isLoading = false
    }

    Process {
        id: removeProcess
        property string targetId: ""
        command: ["python3", root.syncScriptPath, "--remove", targetId]
        stdout: StdioCollector {
            onStreamFinished: root.parseData(this.text)
        }
        onExited: root.isLoading = false
    }

    Process {
        id: toggleProcess
        property string targetId: ""
        command: ["python3", root.syncScriptPath, "--toggle", targetId]
        stdout: StdioCollector {
            onStreamFinished: root.parseData(this.text)
        }
        onExited: root.isLoading = false
    }

    Process {
        id: initReadProcess
        command: ["python3", root.syncScriptPath, "--get"]
        stdout: StdioCollector {
            onStreamFinished: {
                let txt = this.text.trim();
                if (txt !== "" && txt !== '{"status": "empty"}') {
                    root.parseData(txt);
                }
            }
        }
    }

    FileView {
        id: eventsWatcher
        path: root.cacheFilePath
        watchChanges: true
        onLoaded: root.parseData(typeof eventsWatcher.text === "function" ? eventsWatcher.text() : eventsWatcher.text)
        onFileChanged: root.parseData(typeof eventsWatcher.text === "function" ? eventsWatcher.text() : eventsWatcher.text)
    }

    Timer {
        id: refreshTimer
        interval: root.refreshInterval
        running: true
        repeat: true
        onTriggered: root.sync(false)
    }

    Component.onCompleted: {
        initReadProcess.running = true;
    }
}
