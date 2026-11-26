import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../../../reusables"
import "../../../"

/**
 * TodoFace — Seamless Serpantinum v2.5+ To-Do & Todoist Cloud Sync Widget
 * Features:
 *  - Native Todoist API v1 bidirectional sync (auto-sync + instant push + offline queue)
 *  - Seamless WallpaperBlur + GlassFill surface harmonized with Matugen / ThemeBackend
 *  - Animated segmented filter pills, sleek progress bar, collapsible sections, notes
 *  - Full Todoist CSV import/export + safe 2-step cleanup inside unified Settings sheet
 */
Item {
    id: root
    anchors.fill: parent
    clip: true

    property bool previewMode: false

    property real minWidth: 260
    property real minHeight: 220
    property real maxWidth: 740
    property real maxHeight: 800
    property bool isRound: false

    readonly property string nerdFont: ThemeBackend.iconFont

    readonly property string scriptPath: {
        if (typeof Caching !== "undefined" && Caching.serpantinumDir && Caching.serpantinumDir.length > 0) {
            return Caching.serpantinumDir + "/scripts/todo_sync.py";
        }
        return (Quickshell.env("HOME") || "") + "/.local/share/serpantinum/src/scripts/todo_sync.py";
    }

    readonly property string todosConfigPath: {
        let xdg = Quickshell.env("XDG_CONFIG_HOME");
        let base = (xdg && xdg !== "") ? xdg : ((Quickshell.env("HOME") || "") + "/.config");
        return base + "/serpantinum/todos.json";
    }

    // Core State
    property var todosList: []
    property var todoistMeta: ({
        connected: false,
        user_name: "",
        user_email: "",
        project_id: "",
        project_name: "",
        projects: [],
        last_sync: 0,
        pending_count: 0,
        sync_error: ""
    })
    property bool isSyncing: false
    property int filterMode: 1 // 0: all, 1: today+overdue, 2: upcoming, 3: done
    property bool isSettingsOpen: false
    property int settingsTab: 0 // 0: Todoist Cloud, 1: CSV & Pulizia
    property string importMode: "merge"
    property bool confirmClearAll: false
    property bool showAllDescriptions: false

    // Quick Add selectors
    property int selectedPriority: 4 // 1: P1, 2: P2, 3: P3, 4: P4
    property int selectedDateIndex: 1 // 0: none, 1: today, 2: tomorrow, 3: +7 days
    readonly property var dateOptions: ["", "today", "domani", "+7 days"]
    readonly property var dateOptionLabels: [
        typeof I18n !== "undefined" ? I18n.t("widgets.todo.date_none", "Senza data") : "Senza data",
        typeof I18n !== "undefined" ? I18n.t("widgets.todo.date_today", "Oggi") : "Oggi",
        typeof I18n !== "undefined" ? I18n.t("widgets.todo.date_tomorrow", "Domani") : "Domani",
        typeof I18n !== "undefined" ? I18n.t("widgets.todo.date_week", "+7 gg") : "+7 gg"
    ]

    property var expandedNotesMap: ({})
    property var collapsedSectionsMap: ({})
    property string statusText: ""
    property bool statusIsError: false

    // Keyboard focus integration for LayerShell desktop panel
    property bool isInputActive: false
    property bool isPathInputActive: false
    property bool isTokenInputActive: false
    property bool wantsKeyboardFocus: !previewMode && (isInputActive || isPathInputActive || isTokenInputActive)

    function priorityThemeColor(prio) {
        let p = Number(prio);
        if (p === 1) return ThemeBackend.red;
        if (p === 2) return ThemeBackend.peach;
        if (p === 3) return ThemeBackend.blue;
        return ThemeBackend.overlay1;
    }

    function setKeyboardFocus(enable) {
        if (root.previewMode) return;
        root.wantsKeyboardFocus = enable;
        try {
            let win = root.Window ? root.Window.window : null;
            let targets = [];
            if (win) targets.push(win);
            let cur = root;
            while (cur) {
                targets.push(cur);
                if (!cur.parent) break;
                cur = cur.parent;
            }
            for (let i = 0; i < targets.length; i++) {
                let t = targets[i];
                if (!t) continue;
                if (t.wantsKeyboardFocus !== undefined) t.wantsKeyboardFocus = enable;
                if (t.focusable !== undefined) t.focusable = enable;
                if (t.WlrLayershell !== undefined) {
                    let focusVal = enable ? 1 : 0;
                    if (typeof WlrKeyboardFocus !== "undefined") {
                        focusVal = enable ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None;
                    } else if (typeof WlrLayershell !== "undefined" && WlrLayershell.KeyboardFocus) {
                        focusVal = enable ? WlrLayershell.KeyboardFocus.OnDemand : WlrLayershell.KeyboardFocus.None;
                    }
                    t.WlrLayershell.keyboardFocus = focusVal;
                }
                if (enable && typeof t.requestActivate === "function") {
                    t.requestActivate();
                }
            }
        } catch (e) {}
    }

    // Derived Counts
    readonly property int totalCount: {
        let c = 0;
        for (let i = 0; i < todosList.length; i++) {
            let it = todosList[i];
            if (it && !it.uncompletable && it.item_type !== "separator") c++;
        }
        return c;
    }
    readonly property int completedCount: {
        let c = 0;
        for (let i = 0; i < todosList.length; i++) {
            let it = todosList[i];
            if (it && !it.uncompletable && it.item_type !== "separator" && it.completed) c++;
        }
        return c;
    }
    readonly property int activeCount: totalCount - completedCount
    readonly property real completionRatio: totalCount > 0 ? (completedCount / totalCount) : 0.0

    readonly property int todayCount: {
        let c = 0;
        for (let i = 0; i < todosList.length; i++) {
            let it = todosList[i];
            if (it && !it.uncompletable && it.item_type !== "separator" && !it.completed && (it.day_category === "today" || it.day_category === "overdue")) {
                c++;
            }
        }
        return c;
    }

    readonly property int upcomingCount: {
        let c = 0;
        for (let i = 0; i < todosList.length; i++) {
            let it = todosList[i];
            if (it && !it.uncompletable && it.item_type !== "separator" && !it.completed && (it.day_category === "tomorrow" || it.day_category === "upcoming" || it.day_category === "future")) {
                c++;
            }
        }
        return c;
    }

    readonly property string headerTitle: {
        if (todoistMeta && todoistMeta.connected && todoistMeta.project_id && todoistMeta.project_name) {
            return todoistMeta.project_name;
        }
        return typeof I18n !== "undefined" ? I18n.t("widgets.todo.title", "To-Do") : "To-Do";
    }

    readonly property string lastSyncLabel: {
        let ts = (todoistMeta && todoistMeta.last_sync) ? Number(todoistMeta.last_sync) : 0;
        if (!ts) return "";
        try {
            let d = new Date(ts * 1000);
            let hh = String(d.getHours()).padStart(2, "0");
            let mm = String(d.getMinutes()).padStart(2, "0");
            return hh + ":" + mm;
        } catch (e) {
            return "";
        }
    }

    readonly property var filteredList: {
        let res = [];
        for (let i = 0; i < todosList.length; i++) {
            let it = todosList[i];
            if (!it) continue;
            if (filterMode === 1) {
                if (it.completed) continue;
                if (it.day_category !== "today" && it.day_category !== "overdue") continue;
            } else if (filterMode === 2) {
                if (it.completed) continue;
                if (it.day_category !== "tomorrow" && it.day_category !== "upcoming" && it.day_category !== "future") continue;
            } else if (filterMode === 3) {
                if (!it.completed) continue;
            }
            res.push(it);
        }

        if (filterMode === 0) {
            res.sort(function(a, b) {
                let sa = (a.section_index !== undefined && a.section_index > 0) ? Number(a.section_index) : 9999;
                let sb = (b.section_index !== undefined && b.section_index > 0) ? Number(b.section_index) : 9999;
                if (sa !== sb) return sa - sb;
                let ca = String(a.category || "");
                let cb = String(b.category || "");
                if (ca !== cb) return ca.localeCompare(cb);
                if (a.csv_order !== undefined && b.csv_order !== undefined) {
                    return Number(a.csv_order) - Number(b.csv_order);
                }
                let da = (a.days_diff !== undefined) ? Number(a.days_diff) : 999;
                let db = (b.days_diff !== undefined) ? Number(b.days_diff) : 999;
                if (da !== db) return da - db;
                let pa = (a.priority !== undefined) ? Number(a.priority) : 4;
                let pb = (b.priority !== undefined) ? Number(b.priority) : 4;
                if (pa !== pb) return pa - pb;
                return (Number(a.created_at) || 0) - (Number(b.created_at) || 0);
            });
        } else {
            res.sort(function(a, b) {
                if (Boolean(a.completed) !== Boolean(b.completed)) {
                    return a.completed ? 1 : -1;
                }
                let da = (a.days_diff !== undefined) ? Number(a.days_diff) : 999;
                let db = (b.days_diff !== undefined) ? Number(b.days_diff) : 999;
                if (da !== db) return da - db;
                let pa = (a.priority !== undefined) ? Number(a.priority) : 4;
                let pb = (b.priority !== undefined) ? Number(b.priority) : 4;
                if (pa !== pb) return pa - pb;
                if (a.csv_order !== undefined && b.csv_order !== undefined) {
                    return Number(a.csv_order) - Number(b.csv_order);
                }
                return (Number(b.created_at) || 0) - (Number(a.created_at) || 0);
            });
        }

        let finalItems = [];
        let lastSection = "__NONE__";
        let secTotalMap = {};
        let secDoneMap = {};
        let secDescMap = {};

        for (let i = 0; i < res.length; i++) {
            let t = res[i];
            let secName = (t.category || "").trim();
            if (secName !== "") {
                if (secTotalMap[secName] === undefined) {
                    secTotalMap[secName] = 0;
                    secDoneMap[secName] = 0;
                }
                if (!t.uncompletable && t.item_type !== "separator") {
                    secTotalMap[secName]++;
                    if (t.completed) secDoneMap[secName]++;
                }
                if (t.section_description && !secDescMap[secName]) {
                    secDescMap[secName] = t.section_description;
                }
            }
        }

        for (let i = 0; i < res.length; i++) {
            let it = res[i];
            let secName = (it.category || "").trim();
            if (secName !== "" && secName !== lastSection) {
                lastSection = secName;
                finalItems.push({
                    id: "__section__" + secName,
                    is_section_header: true,
                    section_title: secName,
                    section_description: secDescMap[secName] || it.section_description || "",
                    section_total: secTotalMap[secName] || 0,
                    section_done: secDoneMap[secName] || 0
                });
            } else if (secName === "" && lastSection !== "" && lastSection !== "__NONE__") {
                lastSection = "";
            }

            if (secName !== "" && Boolean(root.collapsedSectionsMap[secName])) {
                continue;
            }
            finalItems.push(it);
        }
        return finalItems;
    }

    function showStatus(msg, isErr) {
        statusText = msg;
        statusIsError = isErr === true;
        statusTimer.restart();
    }

    Timer {
        id: statusTimer
        interval: 3800
        onTriggered: root.statusText = ""
    }

    Timer {
        id: confirmClearTimer
        interval: 3200
        onTriggered: root.confirmClearAll = false
    }

    // Periodic date-bucket refresh (every 60s)
    Timer {
        interval: 60000
        repeat: true
        running: !root.previewMode
        onTriggered: initProcess.running = true
    }

    // Automatic Todoist background sync (every 5 minutes when connected)
    Timer {
        id: todoistAutoSyncTimer
        interval: 300000
        repeat: true
        running: !root.previewMode && Boolean(root.todoistMeta && root.todoistMeta.connected)
        onTriggered: root.syncTodoist(true)
    }

    function parseTodos(rawText) {
        if (!rawText) return;
        let txt = typeof rawText === "function" ? rawText() : rawText;
        if (typeof txt !== "string") txt = String(txt || "");
        txt = txt.trim();
        if (txt === "") return;
        try {
            let parsed = JSON.parse(txt);
            if (parsed && Array.isArray(parsed.todos)) {
                root.todosList = parsed.todos;
            } else if (Array.isArray(parsed)) {
                root.todosList = parsed;
            }
            if (parsed && parsed.todoist && typeof parsed.todoist === "object") {
                root.todoistMeta = parsed.todoist;
            }
        } catch (e) {}
    }

    function toggleNoteExpanded(id) {
        let map = Object.assign({}, root.expandedNotesMap);
        map[id] = !Boolean(map[id]);
        root.expandedNotesMap = map;
    }

    function toggleSectionCollapsed(secTitle) {
        if (!secTitle) return;
        let map = Object.assign({}, root.collapsedSectionsMap);
        map[secTitle] = !Boolean(map[secTitle]);
        root.collapsedSectionsMap = map;
    }

    function addTodo(title) {
        let clean = (title || "").trim();
        if (clean === "") return;

        let prio = String(root.selectedPriority);
        let due = root.dateOptions[root.selectedDateIndex] || "";
        let nowMs = Date.now();
        let isSep = clean.indexOf("* ") === 0 || clean === "---" || clean === "___";
        let dispTitle = clean.indexOf("* ") === 0 ? clean.slice(2).trim() : clean;

        let optimisticItem = {
            id: "todo_" + nowMs + "_" + root.todosList.length,
            source: (root.todoistMeta && root.todoistMeta.connected) ? "todoist" : "local",
            item_type: isSep ? "separator" : "task",
            uncompletable: isSep,
            title: dispTitle,
            raw_title: clean,
            description: "",
            completed: false,
            priority: root.selectedPriority,
            priority_label: "P" + root.selectedPriority,
            category: "",
            section_description: "",
            section_index: 0,
            labels: [],
            due_date: "",
            due_time: "",
            due_raw: due,
            day_category: due === "today" ? "today" : (due === "domani" ? "tomorrow" : (due ? "upcoming" : "nodate")),
            relative_label: due === "today" ? "Oggi" : (due === "domani" ? "Domani" : due),
            days_diff: due === "today" ? 0 : (due === "domani" ? 1 : 999),
            created_at: Math.floor(nowMs / 1000)
        };
        root.todosList = [optimisticItem].concat(root.todosList);

        addProcess.cmdTitle = clean;
        addProcess.cmdPriority = prio;
        addProcess.cmdDueDate = due;
        addProcess.running = false;
        addProcess.running = true;
    }

    function toggleTodo(todoId) {
        if (!todoId) return;
        let updated = [];
        for (let i = 0; i < root.todosList.length; i++) {
            let item = Object.assign({}, root.todosList[i]);
            if (item.id === todoId) {
                if (item.uncompletable || item.item_type === "separator") return;
                item.completed = !Boolean(item.completed);
            }
            updated.push(item);
        }
        root.todosList = updated;

        toggleProcess.cmdId = String(todoId);
        toggleProcess.running = false;
        toggleProcess.running = true;
    }

    function deleteTodo(todoId) {
        if (!todoId) return;
        let updated = [];
        for (let i = 0; i < root.todosList.length; i++) {
            if (root.todosList[i].id !== todoId) updated.push(root.todosList[i]);
        }
        root.todosList = updated;

        deleteProcess.cmdId = String(todoId);
        deleteProcess.running = false;
        deleteProcess.running = true;
    }

    function clearCompleted() {
        let updated = [];
        for (let i = 0; i < root.todosList.length; i++) {
            if (!root.todosList[i].completed) updated.push(root.todosList[i]);
        }
        root.todosList = updated;

        clearCompletedProcess.running = false;
        clearCompletedProcess.running = true;
    }

    function clearAll() {
        root.todosList = [];
        root.confirmClearAll = false;
        confirmClearTimer.stop();

        clearAllProcess.running = false;
        clearAllProcess.running = true;
    }

    function requestClearAll() {
        if (root.todosList.length === 0) return;
        if (!root.confirmClearAll) {
            root.confirmClearAll = true;
            confirmClearTimer.restart();
            root.showStatus(typeof I18n !== "undefined" ? I18n.t("widgets.todo.confirm_clear_prompt", "Premi di nuovo per svuotare tutta la lista") : "Premi di nuovo per svuotare tutta la lista", true);
        } else {
            root.clearAll();
        }
    }

    // Todoist Cloud actions
    function connectTodoist(token) {
        let t = (token || "").trim();
        if (t === "") {
            root.showStatus("Inserisci un Personal API Token Todoist valido", true);
            return;
        }
        root.isSyncing = true;
        todoistConnectProcess.cmdToken = t;
        todoistConnectProcess.running = false;
        todoistConnectProcess.running = true;
    }

    function syncTodoist(silent) {
        if (root.isSyncing || !root.todoistMeta || !root.todoistMeta.connected) return;
        root.isSyncing = true;
        todoistSyncProcess.silentMode = silent === true;
        todoistSyncProcess.running = false;
        todoistSyncProcess.running = true;
    }

    function setTodoistProject(projectId) {
        if (root.isSyncing) return;
        root.isSyncing = true;
        todoistProjectProcess.cmdProjectId = String(projectId || "");
        todoistProjectProcess.running = false;
        todoistProjectProcess.running = true;
    }

    function disconnectTodoist(removeTasks) {
        todoistDisconnectProcess.cmdRemove = removeTasks ? "--remove-tasks" : "";
        todoistDisconnectProcess.running = false;
        todoistDisconnectProcess.running = true;
    }

    function pickAndImportCsv(mode) {
        pickCsvProcess.cmdMode = mode || root.importMode;
        pickCsvProcess.running = false;
        pickCsvProcess.running = true;
    }

    function importCsvPath(filePath, mode) {
        let p = (filePath || "").trim();
        if (p === "") return;
        importPathProcess.cmdPath = p;
        importPathProcess.cmdMode = mode || root.importMode;
        importPathProcess.running = false;
        importPathProcess.running = true;
    }

    function pickAndExportCsv() {
        pickExportProcess.running = false;
        pickExportProcess.running = true;
    }

    // File watcher
    FileView {
        id: todosFileWatcher
        path: root.todosConfigPath
        watchChanges: !root.previewMode
        onFileChanged: reload()
        onLoaded: root.parseTodos(typeof text === "function" ? text() : text)
    }

    // Background Process runners
    Process {
        id: addProcess
        property string cmdTitle: ""
        property string cmdPriority: "4"
        property string cmdDueDate: ""
        command: ["python3", root.scriptPath, "--add", cmdTitle, cmdPriority, "", cmdDueDate]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") todosFileWatcher.reload();
                } catch (e) {}
            }
        }
    }

    Process {
        id: toggleProcess
        property string cmdId: ""
        command: ["python3", root.scriptPath, "--toggle", cmdId]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") todosFileWatcher.reload();
                } catch (e) {}
            }
        }
    }

    Process {
        id: deleteProcess
        property string cmdId: ""
        command: ["python3", root.scriptPath, "--delete", cmdId]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") todosFileWatcher.reload();
                } catch (e) {}
            }
        }
    }

    Process {
        id: clearCompletedProcess
        command: ["python3", root.scriptPath, "--clear-completed"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        root.showStatus(typeof I18n !== "undefined" ? I18n.t("widgets.todo.cleared", "Completate rimosse") : "Completate rimosse", false);
                        todosFileWatcher.reload();
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: clearAllProcess
        command: ["python3", root.scriptPath, "--clear-all"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        root.showStatus(typeof I18n !== "undefined" ? I18n.t("widgets.todo.cleared_all", "Lista svuotata") : "Lista svuotata", false);
                        todosFileWatcher.reload();
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: todoistConnectProcess
        property string cmdToken: ""
        command: ["python3", root.scriptPath, "--todoist-connect", cmdToken]
        stdout: StdioCollector {
            onStreamFinished: {
                root.isSyncing = false;
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        if (res.todoist) root.todoistMeta = res.todoist;
                        if (res.todos) root.todosList = res.todos;
                        tokenInput.text = "";
                        root.isTokenInputActive = false;
                        root.setKeyboardFocus(false);
                        root.showStatus("Todoist connesso (" + (res.synced_count || 0) + " attività)", false);
                        todosFileWatcher.reload();
                    } else {
                        root.showStatus(res.message || "Errore connessione Todoist", true);
                    }
                } catch (e) {
                    root.showStatus("Errore risposta Todoist", true);
                }
            }
        }
    }

    Process {
        id: todoistSyncProcess
        property bool silentMode: false
        command: ["python3", root.scriptPath, "--todoist-sync"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.isSyncing = false;
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        if (res.todoist) root.todoistMeta = res.todoist;
                        if (res.todos) root.todosList = res.todos;
                        if (!todoistSyncProcess.silentMode) {
                            root.showStatus("Sincronizzato con Todoist (" + (res.synced_count || 0) + ")", false);
                        }
                        todosFileWatcher.reload();
                    } else if (!todoistSyncProcess.silentMode) {
                        root.showStatus(res.message || "Errore sync Todoist", true);
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: todoistProjectProcess
        property string cmdProjectId: ""
        command: ["python3", root.scriptPath, "--todoist-set-project", cmdProjectId]
        stdout: StdioCollector {
            onStreamFinished: {
                root.isSyncing = false;
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        if (res.todoist) root.todoistMeta = res.todoist;
                        if (res.todos) root.todosList = res.todos;
                        root.showStatus("Progetto: " + (res.todoist ? res.todoist.project_name : ""), false);
                        todosFileWatcher.reload();
                    } else {
                        root.showStatus(res.message || "Errore cambio progetto", true);
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: todoistDisconnectProcess
        property string cmdRemove: ""
        command: cmdRemove !== ""
            ? ["python3", root.scriptPath, "--todoist-disconnect", cmdRemove]
            : ["python3", root.scriptPath, "--todoist-disconnect"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        if (res.todoist) root.todoistMeta = res.todoist;
                        if (res.todos) root.todosList = res.todos;
                        root.showStatus("Account Todoist scollegato", false);
                        todosFileWatcher.reload();
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: pickCsvProcess
        property string cmdMode: "merge"
        command: ["python3", root.scriptPath, "--pick-csv", "--mode=" + cmdMode]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        let count = res.imported_count !== undefined ? res.imported_count : 0;
                        root.showStatus((typeof I18n !== "undefined" ? I18n.t("widgets.todo.imported_count", "Importate %1 attività").arg(count) : ("Importate " + count + " attività")), false);
                        if (res.todos) root.todosList = res.todos;
                        todosFileWatcher.reload();
                    } else if (res.status === "error") {
                        root.showStatus(res.message || "Errore importazione CSV", true);
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: importPathProcess
        property string cmdPath: ""
        property string cmdMode: "merge"
        command: ["python3", root.scriptPath, "--import-csv", cmdPath, "--mode=" + cmdMode]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        let count = res.imported_count !== undefined ? res.imported_count : 0;
                        root.showStatus((typeof I18n !== "undefined" ? I18n.t("widgets.todo.imported_count", "Importate %1 attività").arg(count) : ("Importate " + count + " attività")), false);
                        if (res.todos) root.todosList = res.todos;
                        root.isSettingsOpen = false;
                        todosFileWatcher.reload();
                    } else {
                        root.showStatus(res.message || "Errore importazione CSV", true);
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: pickExportProcess
        command: ["python3", root.scriptPath, "--pick-export-csv"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let res = JSON.parse(this.text);
                    if (res.status === "ok") {
                        root.showStatus(typeof I18n !== "undefined" ? I18n.t("widgets.todo.exported_ok", "Attività esportate in CSV") : "Attività esportate in CSV", false);
                    } else if (res.status === "error") {
                        root.showStatus(res.message || "Errore esportazione", true);
                    }
                } catch (e) {}
            }
        }
    }

    Process {
        id: initProcess
        command: ["python3", root.scriptPath, "--get"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.parseTodos(this.text);
                // Perform a quiet startup sync if Todoist is connected and stale (>3 min)
                if (!root.previewMode && root.todoistMeta && root.todoistMeta.connected) {
                    let age = Math.floor(Date.now() / 1000) - (Number(root.todoistMeta.last_sync) || 0);
                    if (age > 180) {
                        root.syncTodoist(true);
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        if (!root.previewMode) {
            initProcess.running = true;
        }
    }

    // Seamless Serpantinum v2.5+ Surface
    Rectangle {
        id: bgCard
        anchors.fill: parent
        color: bgGlass.active ? "transparent" : Qt.alpha(ThemeBackend.surface0, ThemeBackend.elementOpacity)
        radius: ThemeBackend.clampedBorderRadius !== undefined ? ThemeBackend.clampedBorderRadius : ThemeBackend.borderRadius
        border.width: 1
        border.color: Qt.alpha(ThemeBackend.text, bgGlass.active ? 0.08 : 0.05)
        clip: true

        WallpaperBlur {
            z: -2
            anchors.fill: parent
            radius: parent.radius
        }

        GlassFill {
            id: bgGlass
            z: -1
            anchors.fill: parent
            radius: parent.radius
            tintColor: ThemeBackend.surface0
            tintAmount: 0.22
        }

        // ==================== MAIN VIEW ====================
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(13)
            spacing: Scaler.s(8)
            visible: !root.isSettingsOpen

            // Sleek Decluttered Header
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(28)
                spacing: Scaler.s(6)

                // Title + Todoist live connection dot
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Scaler.s(6)

                    // Live Todoist Cloud status indicator dot
                    Rectangle {
                        visible: Boolean(root.todoistMeta && root.todoistMeta.connected)
                        width: Scaler.s(7)
                        height: Scaler.s(7)
                        radius: width / 2
                        color: (root.todoistMeta && root.todoistMeta.sync_error)
                            ? ThemeBackend.peach
                            : (root.isSyncing ? ThemeBackend.mauve : ThemeBackend.green)
                        Behavior on color { ColorAnimation { duration: 220 } }
                    }

                    Text {
                        text: root.headerTitle
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(13.5)
                        font.weight: Font.Black
                        color: ThemeBackend.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }

                // Compact Progress Pill (e.g. "3/5")
                Rectangle {
                    visible: root.totalCount > 0
                    Layout.preferredHeight: Scaler.s(22)
                    Layout.preferredWidth: countLabel.implicitWidth + Scaler.s(12)
                    radius: Scaler.s(11)
                    color: root.activeCount === 0
                        ? Qt.alpha(ThemeBackend.green, 0.18)
                        : Qt.alpha(ThemeBackend.surface1, 0.72)

                    Text {
                        id: countLabel
                        anchors.centerIn: parent
                        text: root.completedCount + "/" + root.totalCount
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9.5)
                        font.bold: true
                        color: root.activeCount === 0 ? ThemeBackend.green : ThemeBackend.subtext0
                    }
                }

                // Todoist Cloud Sync button (visible when connected, rotates smoothly when syncing)
                Item {
                    visible: Boolean(root.todoistMeta && root.todoistMeta.connected)
                    Layout.preferredWidth: Scaler.s(26)
                    Layout.preferredHeight: Scaler.s(26)

                    Rectangle {
                        anchors.fill: parent
                        radius: Scaler.s(8)
                        color: syncMa.containsMouse ? Qt.alpha(ThemeBackend.mauve, 0.22) : Qt.alpha(ThemeBackend.surface1, 0.65)
                        Behavior on color { ColorAnimation { duration: 130 } }

                        Text {
                            id: syncIcon
                            anchors.centerIn: parent
                            text: "󰑐"
                            font.family: root.nerdFont
                            font.pixelSize: Scaler.s(13)
                            color: root.isSyncing ? ThemeBackend.mauve : ThemeBackend.subtext0

                            RotationAnimation on rotation {
                                from: 0; to: 360
                                duration: 900
                                loops: Animation.Infinite
                                running: root.isSyncing
                                onRunningChanged: if (!running) syncIcon.rotation = 0
                            }
                        }

                        MouseArea {
                            id: syncMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.syncTodoist(false)
                        }
                    }
                }

                // Toggle Expand All Notes (only visible if there are tasks with descriptions)
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: root.showAllDescriptions ? "󰘖" : "󰦨"
                    iconFontSize: Scaler.s(12.5)
                    accentColor: root.showAllDescriptions ? Qt.alpha(ThemeBackend.mauve, 0.24) : ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: root.showAllDescriptions ? ThemeBackend.mauve : ThemeBackend.subtext0
                    onClicked: root.showAllDescriptions = !root.showAllDescriptions
                }

                // Unified Settings / Todoist Cloud / CSV Button
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰒓"
                    iconFontSize: Scaler.s(12.5)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: (root.todoistMeta && root.todoistMeta.connected) ? ThemeBackend.mauve : ThemeBackend.subtext0
                    onClicked: {
                        root.confirmClearAll = false;
                        root.isSettingsOpen = true;
                    }
                }
            }

            // Minimal Progress Hairline
            Rectangle {
                visible: root.totalCount > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(3)
                radius: Scaler.s(1.5)
                color: Qt.alpha(ThemeBackend.surface2, 0.28)
                clip: true

                Rectangle {
                    width: parent.width * root.completionRatio
                    height: parent.height
                    radius: parent.radius
                    color: root.activeCount === 0 ? ThemeBackend.green : ThemeBackend.mauve
                    Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 220 } }
                }
            }

            // Floating Status Banner
            Rectangle {
                visible: root.statusText !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(24)
                radius: Scaler.s(8)
                color: Qt.alpha(root.statusIsError ? ThemeBackend.red : ThemeBackend.mauve, 0.16)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Scaler.s(9)
                    anchors.rightMargin: Scaler.s(9)
                    spacing: Scaler.s(6)

                    Text {
                        text: root.statusIsError ? "󰅖" : "󰄲"
                        font.family: root.nerdFont
                        font.pixelSize: Scaler.s(11.5)
                        color: root.statusIsError ? ThemeBackend.red : ThemeBackend.mauve
                    }

                    Text {
                        text: root.statusText
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(10)
                        font.bold: true
                        color: ThemeBackend.text
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }
            }

            // Quick Add Input Pill + Inline Priority / Date Chips
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(36)
                radius: Scaler.s(10)
                color: Qt.alpha(ThemeBackend.surface1, taskInput.activeFocus ? 0.82 : 0.56)
                border.width: 1
                border.color: taskInput.activeFocus ? Qt.alpha(ThemeBackend.mauve, 0.75) : Qt.alpha(ThemeBackend.text, 0.06)

                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on border.color { ColorAnimation { duration: 150 } }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Scaler.s(10)
                    anchors.rightMargin: Scaler.s(5)
                    spacing: Scaler.s(5)

                    TextInput {
                        id: taskInput
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        verticalAlignment: TextInput.AlignVCenter
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(11.5)
                        color: ThemeBackend.text
                        selectByMouse: true
                        enabled: !root.previewMode

                        onActiveFocusChanged: {
                            root.isInputActive = activeFocus;
                            root.setKeyboardFocus(activeFocus || root.isPathInputActive || root.isTokenInputActive);
                        }

                        Keys.onEscapePressed: {
                            taskInput.focus = false;
                            root.setKeyboardFocus(false);
                        }

                        onAccepted: {
                            let val = taskInput.text.trim();
                            if (val !== "") {
                                root.addTodo(val);
                                taskInput.text = "";
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.IBeamCursor
                            onPressed: function(mouse) {
                                root.setKeyboardFocus(true);
                                taskInput.forceActiveFocus();
                                mouse.accepted = false;
                            }
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: !taskInput.text && !taskInput.activeFocus
                            text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.new_placeholder", "Aggiungi attività...") : "Aggiungi attività..."
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10.5)
                            color: ThemeBackend.overlay1
                            elide: Text.ElideRight
                        }
                    }

                    // Inline Priority Pill (Cycles P4 -> P1 -> P2 -> P3 -> P4)
                    Rectangle {
                        Layout.preferredHeight: Scaler.s(22)
                        Layout.preferredWidth: prioText.implicitWidth + Scaler.s(10)
                        radius: Scaler.s(6)
                        color: root.selectedPriority < 4
                            ? Qt.alpha(root.priorityThemeColor(root.selectedPriority), 0.2)
                            : Qt.alpha(ThemeBackend.surface2, 0.35)

                        Text {
                            id: prioText
                            anchors.centerIn: parent
                            text: "P" + root.selectedPriority
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(9)
                            font.bold: true
                            color: root.priorityThemeColor(root.selectedPriority)
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.selectedPriority === 4) root.selectedPriority = 1;
                                else if (root.selectedPriority === 1) root.selectedPriority = 2;
                                else if (root.selectedPriority === 2) root.selectedPriority = 3;
                                else root.selectedPriority = 4;
                            }
                        }
                    }

                    // Inline Due Date Pill (Cycles Nessuna -> Oggi -> Domani -> +7 gg)
                    Rectangle {
                        Layout.preferredHeight: Scaler.s(22)
                        Layout.preferredWidth: dateChipText.implicitWidth + Scaler.s(12)
                        radius: Scaler.s(6)
                        color: root.selectedDateIndex > 0
                            ? Qt.alpha(ThemeBackend.mauve, 0.18)
                            : Qt.alpha(ThemeBackend.surface2, 0.35)

                        Text {
                            id: dateChipText
                            anchors.centerIn: parent
                            text: root.dateOptionLabels[root.selectedDateIndex]
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(9)
                            font.bold: root.selectedDateIndex > 0
                            color: root.selectedDateIndex > 0 ? ThemeBackend.mauve : ThemeBackend.subtext0
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectedDateIndex = (root.selectedDateIndex + 1) % root.dateOptions.length
                        }
                    }

                    // Add Submit Button
                    IconButton {
                        size: Scaler.s(26)
                        cornerRadius: Scaler.s(7)
                        buttonIcon: "󰐕"
                        iconFontSize: Scaler.s(14)
                        accentColor: ThemeBackend.mauve
                        textColor: ThemeBackend.crust
                        onClicked: {
                            let val = taskInput.text.trim();
                            if (val !== "") {
                                root.addTodo(val);
                                taskInput.text = "";
                            }
                        }
                    }
                }
            }

            // Modern Animated Segmented Filter Bar
            Rectangle {
                id: filterTrack
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(28)
                radius: Scaler.s(9)
                color: Qt.alpha(ThemeBackend.surface1, 0.45)

                // Sliding active pill
                Rectangle {
                    id: filterSlider
                    readonly property Item activeTab: filterRepeater.count > root.filterMode ? filterRepeater.itemAt(root.filterMode) : null
                    x: activeTab ? (activeTab.x + Scaler.s(3)) : Scaler.s(3)
                    y: Scaler.s(3)
                    width: activeTab ? Math.max(0, activeTab.width - Scaler.s(6)) : 0
                    height: parent.height - Scaler.s(6)
                    radius: Scaler.s(6.5)
                    color: Qt.alpha(ThemeBackend.mauve, 0.24)
                    border.width: 1
                    border.color: Qt.alpha(ThemeBackend.mauve, 0.38)

                    Behavior on x { NumberAnimation { duration: 210; easing.type: Easing.OutCubic } }
                    Behavior on width { NumberAnimation { duration: 210; easing.type: Easing.OutCubic } }
                }

                RowLayout {
                    anchors.fill: parent
                    spacing: 0

                    Repeater {
                        id: filterRepeater
                        model: [
                            { mode: 0, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_all", "Tutte") : "Tutte", count: root.totalCount },
                            { mode: 1, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_today", "Oggi") : "Oggi", count: root.todayCount },
                            { mode: 2, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_upcoming", "Prossime") : "Prossime", count: root.upcomingCount },
                            { mode: 3, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_done", "Fatte") : "Fatte", count: root.completedCount }
                        ]

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: Scaler.s(3)

                                Text {
                                    text: modelData.label
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9.5)
                                    font.bold: root.filterMode === modelData.mode
                                    color: root.filterMode === modelData.mode ? ThemeBackend.mauve : (tabMa.containsMouse ? ThemeBackend.text : ThemeBackend.subtext0)
                                    Behavior on color { ColorAnimation { duration: 140 } }
                                }

                                Text {
                                    visible: modelData.count > 0
                                    text: String(modelData.count)
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(8.5)
                                    font.bold: true
                                    color: root.filterMode === modelData.mode ? ThemeBackend.mauve : ThemeBackend.overlay1
                                }
                            }

                            MouseArea {
                                id: tabMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.filterMode = modelData.mode
                            }
                        }
                    }
                }
            }

            // Task List Area
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: todoListView
                    anchors.fill: parent
                    spacing: Scaler.s(5)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.filteredList

                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                        width: Scaler.s(4)
                    }

                    delegate: Item {
                        id: rowWrapper
                        width: todoListView.width
                        readonly property bool isSectionHeader: Boolean(modelData.is_section_header)
                        readonly property bool isSeparatorTask: !isSectionHeader && (Boolean(modelData.uncompletable) || modelData.item_type === "separator")
                        readonly property bool isSubtask: !isSectionHeader && (Number(modelData.indent || 1) > 1)
                        readonly property bool hasDesc: !isSectionHeader && Boolean(modelData.description && modelData.description.trim() !== "")
                        readonly property bool isNoteExpanded: root.showAllDescriptions || Boolean(root.expandedNotesMap[modelData.id])
                        readonly property bool isSectionCollapsed: isSectionHeader && Boolean(root.collapsedSectionsMap[modelData.section_title])

                        height: isSectionHeader
                            ? sectionCard.implicitHeight
                            : (isSeparatorTask ? sepTaskCard.implicitHeight : taskCard.implicitHeight)

                        // === A. COLLAPSIBLE SECTION HEADER ===
                        Item {
                            id: sectionCard
                            visible: rowWrapper.isSectionHeader
                            anchors.left: parent.left
                            anchors.right: parent.right
                            implicitHeight: secCol.implicitHeight + Scaler.s(8)

                            ColumnLayout {
                                id: secCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Scaler.s(2)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Scaler.s(6)

                                    Text {
                                        text: rowWrapper.isSectionCollapsed ? "󰅂" : "󰅀"
                                        font.family: root.nerdFont
                                        font.pixelSize: Scaler.s(11)
                                        color: ThemeBackend.mauve
                                    }

                                    Text {
                                        text: (modelData.section_title || "").toUpperCase()
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(9.5)
                                        font.weight: Font.Black
                                        color: ThemeBackend.subtext0
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }

                                    Text {
                                        visible: (modelData.section_total || 0) > 0
                                        text: (modelData.section_done || 0) + "/" + (modelData.section_total || 0)
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(8.5)
                                        font.bold: true
                                        color: ThemeBackend.overlay1
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: Qt.alpha(ThemeBackend.text, 0.07)
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleSectionCollapsed(modelData.section_title)
                            }
                        }

                        // === B. UNCOMPLETABLE SEPARATOR ITEM (* Title) ===
                        Rectangle {
                            id: sepTaskCard
                            visible: rowWrapper.isSeparatorTask
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: rowWrapper.isSubtask ? Scaler.s(14) : 0
                            implicitHeight: sepRow.implicitHeight + Scaler.s(10)
                            radius: Scaler.s(8)
                            color: Qt.alpha(ThemeBackend.surface1, 0.35)

                            RowLayout {
                                id: sepRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Scaler.s(10)
                                anchors.rightMargin: Scaler.s(10)
                                spacing: Scaler.s(6)

                                Rectangle {
                                    width: Scaler.s(3)
                                    height: Scaler.s(14)
                                    radius: Scaler.s(1.5)
                                    color: ThemeBackend.mauve
                                }

                                Text {
                                    text: modelData.title || ""
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(10.5)
                                    font.bold: true
                                    color: ThemeBackend.subtext1
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }

                        // === C. STANDARD TASK CARD ===
                        Rectangle {
                            id: taskCard
                            visible: !rowWrapper.isSectionHeader && !rowWrapper.isSeparatorTask
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: rowWrapper.isSubtask ? Scaler.s(16) : 0
                            implicitHeight: taskContentCol.implicitHeight + Scaler.s(14)
                            radius: Scaler.s(10)
                            color: taskRowMa.containsMouse
                                ? Qt.alpha(ThemeBackend.surface1, 0.82)
                                : Qt.alpha(ThemeBackend.surface1, modelData.completed ? 0.28 : 0.50)
                            border.width: 1
                            border.color: taskRowMa.containsMouse
                                ? Qt.alpha(ThemeBackend.mauve, 0.28)
                                : Qt.alpha(ThemeBackend.text, 0.04)

                            Behavior on color { ColorAnimation { duration: 140 } }
                            Behavior on border.color { ColorAnimation { duration: 140 } }

                            MouseArea {
                                id: taskRowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                            }

                            ColumnLayout {
                                id: taskContentCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Scaler.s(10)
                                anchors.rightMargin: Scaler.s(8)
                                spacing: Scaler.s(4)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Scaler.s(8)

                                    // Modern Circular Checkbox with Priority Ring
                                    Rectangle {
                                        id: checkCircle
                                        Layout.preferredWidth: Scaler.s(18)
                                        Layout.preferredHeight: Scaler.s(18)
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: Scaler.s(1)
                                        radius: width / 2
                                        color: modelData.completed
                                            ? ThemeBackend.green
                                            : (checkMa.containsMouse ? Qt.alpha(root.priorityThemeColor(modelData.priority), 0.25) : "transparent")
                                        border.width: modelData.completed ? 0 : 1.8
                                        border.color: root.priorityThemeColor(modelData.priority)
                                        scale: checkMa.pressed ? 0.84 : (checkMa.containsMouse ? 1.08 : 1.0)

                                        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutBack } }
                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: Boolean(modelData.completed) || checkMa.containsMouse
                                            text: "󰄬"
                                            font.family: root.nerdFont
                                            font.pixelSize: Scaler.s(11)
                                            color: modelData.completed ? ThemeBackend.crust : root.priorityThemeColor(modelData.priority)
                                            opacity: modelData.completed ? 1.0 : 0.65
                                        }

                                        MouseArea {
                                            id: checkMa
                                            anchors.fill: parent
                                            anchors.margins: -Scaler.s(4)
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleTodo(modelData.id)
                                        }
                                    }

                                    // Task Title + inline click to expand note
                                    Text {
                                        text: modelData.title || ""
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(11.5)
                                        font.weight: modelData.priority === 1 && !modelData.completed ? Font.Bold : Font.Medium
                                        font.strikeout: Boolean(modelData.completed)
                                        color: modelData.completed ? ThemeBackend.overlay1 : ThemeBackend.text
                                        Layout.fillWidth: true
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 3
                                        elide: Text.ElideRight

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: rowWrapper.hasDesc ? Qt.PointingHandCursor : Qt.ArrowCursor
                                            onClicked: {
                                                if (rowWrapper.hasDesc) root.toggleNoteExpanded(modelData.id);
                                            }
                                        }
                                    }

                                    // Note indicator button
                                    Item {
                                        visible: rowWrapper.hasDesc
                                        Layout.preferredWidth: Scaler.s(20)
                                        Layout.preferredHeight: Scaler.s(20)
                                        Layout.alignment: Qt.AlignTop

                                        Text {
                                            anchors.centerIn: parent
                                            text: rowWrapper.isNoteExpanded ? "󰘖" : "󰦨"
                                            font.family: root.nerdFont
                                            font.pixelSize: Scaler.s(11.5)
                                            color: rowWrapper.isNoteExpanded ? ThemeBackend.mauve : ThemeBackend.overlay1
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleNoteExpanded(modelData.id)
                                        }
                                    }

                                    // Hover-revealed delete button
                                    Item {
                                        Layout.preferredWidth: Scaler.s(20)
                                        Layout.preferredHeight: Scaler.s(20)
                                        Layout.alignment: Qt.AlignTop
                                        opacity: (taskRowMa.containsMouse || delMa.containsMouse) ? 1.0 : 0.0
                                        Behavior on opacity { NumberAnimation { duration: 120 } }

                                        Text {
                                            anchors.centerIn: parent
                                            text: "󰅖"
                                            font.family: root.nerdFont
                                            font.pixelSize: Scaler.s(12)
                                            color: delMa.containsMouse ? ThemeBackend.red : ThemeBackend.overlay1
                                        }

                                        MouseArea {
                                            id: delMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.deleteTodo(modelData.id)
                                        }
                                    }
                                }

                                // Expandable Description Note
                                Text {
                                    visible: rowWrapper.hasDesc && rowWrapper.isNoteExpanded
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Scaler.s(26)
                                    text: modelData.description || ""
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9.5)
                                    color: ThemeBackend.subtext0
                                    wrapMode: Text.WordWrap
                                }

                                // Metadata Chips Row (Due Date + Priority + Labels)
                                RowLayout {
                                    visible: Boolean(modelData.relative_label) || (modelData.priority && modelData.priority < 4) || (modelData.labels && modelData.labels.length > 0)
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Scaler.s(26)
                                    spacing: Scaler.s(5)

                                    // Due date pill
                                    Rectangle {
                                        visible: Boolean(modelData.relative_label)
                                        Layout.preferredHeight: Scaler.s(17)
                                        Layout.preferredWidth: dueRow.implicitWidth + Scaler.s(8)
                                        radius: Scaler.s(5)
                                        color: {
                                            if (modelData.day_category === "overdue") return Qt.alpha(ThemeBackend.red, 0.18);
                                            if (modelData.day_category === "today") return Qt.alpha(ThemeBackend.mauve, 0.18);
                                            if (modelData.day_category === "tomorrow") return Qt.alpha(ThemeBackend.blue, 0.16);
                                            return Qt.alpha(ThemeBackend.surface2, 0.32);
                                        }

                                        RowLayout {
                                            id: dueRow
                                            anchors.centerIn: parent
                                            spacing: Scaler.s(3)

                                            Text {
                                                text: modelData.day_category === "overdue" ? "󰀦" : "󰔛"
                                                font.family: root.nerdFont
                                                font.pixelSize: Scaler.s(8.5)
                                                color: {
                                                    if (modelData.day_category === "overdue") return ThemeBackend.red;
                                                    if (modelData.day_category === "today") return ThemeBackend.mauve;
                                                    if (modelData.day_category === "tomorrow") return ThemeBackend.blue;
                                                    return ThemeBackend.subtext0;
                                                }
                                            }

                                            Text {
                                                text: modelData.relative_label || ""
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: Scaler.s(8.5)
                                                font.bold: modelData.day_category === "overdue" || modelData.day_category === "today"
                                                color: {
                                                    if (modelData.day_category === "overdue") return ThemeBackend.red;
                                                    if (modelData.day_category === "today") return ThemeBackend.mauve;
                                                    if (modelData.day_category === "tomorrow") return ThemeBackend.blue;
                                                    return ThemeBackend.subtext0;
                                                }
                                            }
                                        }
                                    }

                                    // Labels
                                    Repeater {
                                        model: modelData.labels || []

                                        Rectangle {
                                            Layout.preferredHeight: Scaler.s(17)
                                            Layout.preferredWidth: lblText.implicitWidth + Scaler.s(8)
                                            radius: Scaler.s(5)
                                            color: Qt.alpha(ThemeBackend.surface2, 0.30)

                                            Text {
                                                id: lblText
                                                anchors.centerIn: parent
                                                text: "@" + modelData
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: Scaler.s(8.5)
                                                color: ThemeBackend.subtext0
                                            }
                                        }
                                    }

                                    Item { Layout.fillWidth: true }
                                }
                            }
                        }
                    }

                    // Clean Empty State
                    Item {
                        anchors.fill: parent
                        visible: root.filteredList.length === 0

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: Scaler.s(7)

                            Text {
                                text: root.filterMode === 1 ? "󰔛" : (root.filterMode === 2 ? "󰃮" : (root.filterMode === 3 ? "󰄲" : "󰄳"))
                                font.family: root.nerdFont
                                font.pixelSize: Scaler.s(26)
                                color: ThemeBackend.overlay0
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: {
                                    if (root.filterMode === 1) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_today", "Nessuna attività per oggi") : "Nessuna attività per oggi";
                                    if (root.filterMode === 2) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_upcoming", "Nessuna attività programmata") : "Nessuna attività programmata";
                                    if (root.filterMode === 3) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_completed", "Nessuna attività completata") : "Nessuna attività completata";
                                    return typeof I18n !== "undefined" ? I18n.t("widgets.todo.empty", "Collega Todoist o aggiungi un'attività") : "Collega Todoist o aggiungi un'attività";
                                }
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(10.5)
                                color: ThemeBackend.subtext0
                                Layout.alignment: Qt.AlignHCenter
                                horizontalAlignment: Text.AlignHCenter
                            }

                            ClickButton {
                                visible: root.totalCount === 0 && !(root.todoistMeta && root.todoistMeta.connected)
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredHeight: Scaler.s(28)
                                cornerRadius: Scaler.s(8)
                                buttonIcon: "󰅟"
                                buttonText: "Collega Todoist"
                                accentColor: Qt.alpha(ThemeBackend.mauve, 0.22)
                                textColor: ThemeBackend.mauve
                                onClicked: {
                                    root.settingsTab = 0;
                                    root.isSettingsOpen = true;
                                }
                            }
                        }
                    }
                }
            }
        }

        // ==================== SETTINGS / TODOIST / CSV SHEET ====================
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(13)
            spacing: Scaler.s(9)
            visible: root.isSettingsOpen

            // Sheet Header
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Text {
                    text: "Impostazioni To-Do"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(13)
                    font.weight: Font.Black
                    color: ThemeBackend.text
                    Layout.fillWidth: true
                }

                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰅖"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    textColor: ThemeBackend.subtext0
                    onClicked: {
                        root.isSettingsOpen = false;
                        root.isPathInputActive = false;
                        root.isTokenInputActive = false;
                        root.setKeyboardFocus(false);
                    }
                }
            }

            // Two-Tab Switcher: Todoist Cloud | CSV & Pulizia
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(28)
                radius: Scaler.s(9)
                color: Qt.alpha(ThemeBackend.surface1, 0.5)

                Rectangle {
                    x: root.settingsTab === 0 ? Scaler.s(3) : (parent.width / 2 + Scaler.s(1.5))
                    y: Scaler.s(3)
                    width: parent.width / 2 - Scaler.s(4.5)
                    height: parent.height - Scaler.s(6)
                    radius: Scaler.s(6.5)
                    color: Qt.alpha(ThemeBackend.mauve, 0.24)
                    border.width: 1
                    border.color: Qt.alpha(ThemeBackend.mauve, 0.38)
                    Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                }

                RowLayout {
                    anchors.fill: parent
                    spacing: 0

                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        RowLayout {
                            anchors.centerIn: parent; spacing: Scaler.s(4)
                            Text { text: "󰅟"; font.family: root.nerdFont; font.pixelSize: Scaler.s(11); color: root.settingsTab === 0 ? ThemeBackend.mauve : ThemeBackend.subtext0 }
                            Text { text: "Todoist Cloud"; font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(10); font.bold: root.settingsTab === 0; color: root.settingsTab === 0 ? ThemeBackend.mauve : ThemeBackend.subtext0 }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsTab = 0 }
                    }

                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        RowLayout {
                            anchors.centerIn: parent; spacing: Scaler.s(4)
                            Text { text: "󰈔"; font.family: root.nerdFont; font.pixelSize: Scaler.s(11); color: root.settingsTab === 1 ? ThemeBackend.mauve : ThemeBackend.subtext0 }
                            Text { text: "CSV & Pulizia"; font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(10); font.bold: root.settingsTab === 1; color: root.settingsTab === 1 ? ThemeBackend.mauve : ThemeBackend.subtext0 }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsTab = 1 }
                    }
                }
            }

            // -------- TAB 0: TODOIST API v1 CLOUD SYNC --------
            ColumnLayout {
                visible: root.settingsTab === 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Scaler.s(8)

                // Connection Status Card (when connected)
                Rectangle {
                    visible: Boolean(root.todoistMeta && root.todoistMeta.connected)
                    Layout.fillWidth: true
                    implicitHeight: connCol.implicitHeight + Scaler.s(16)
                    radius: Scaler.s(10)
                    color: Qt.alpha(ThemeBackend.green, 0.10)
                    border.width: 1
                    border.color: Qt.alpha(ThemeBackend.green, 0.28)

                    ColumnLayout {
                        id: connCol
                        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Scaler.s(10)
                        spacing: Scaler.s(4)

                        RowLayout {
                            Layout.fillWidth: true; spacing: Scaler.s(6)
                            Text { text: "󰄬"; font.family: root.nerdFont; font.pixelSize: Scaler.s(13); color: ThemeBackend.green }
                            Text {
                                text: (root.todoistMeta && root.todoistMeta.user_name) ? root.todoistMeta.user_name : "Account Todoist"
                                font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(11.5); font.bold: true; color: ThemeBackend.text
                                Layout.fillWidth: true; elide: Text.ElideRight
                            }
                            Text {
                                visible: root.lastSyncLabel !== ""
                                text: "Sync " + root.lastSyncLabel
                                font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9); color: ThemeBackend.subtext0
                            }
                        }

                        Text {
                            visible: Boolean(root.todoistMeta && root.todoistMeta.user_email)
                            text: root.todoistMeta ? root.todoistMeta.user_email : ""
                            font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); color: ThemeBackend.subtext0
                        }

                        Text {
                            visible: Boolean(root.todoistMeta && root.todoistMeta.sync_error)
                            text: root.todoistMeta ? root.todoistMeta.sync_error : ""
                            font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9); color: ThemeBackend.red
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                        }
                    }
                }

                // Project Filter Selector (when connected)
                ColumnLayout {
                    visible: Boolean(root.todoistMeta && root.todoistMeta.connected)
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Scaler.s(5)

                    Text {
                        text: "Progetto sincronizzato:"
                        font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); font.bold: true; color: ThemeBackend.subtext0
                    }

                    Flickable {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        contentHeight: projFlow.implicitHeight
                        clip: true

                        Flow {
                            id: projFlow
                            width: parent.width
                            spacing: Scaler.s(5)

                            // "Tutti i progetti" chip
                            Rectangle {
                                height: Scaler.s(24)
                                width: allProjTxt.implicitWidth + Scaler.s(14)
                                radius: Scaler.s(7)
                                readonly property bool selected: !(root.todoistMeta && root.todoistMeta.project_id)
                                color: selected ? Qt.alpha(ThemeBackend.mauve, 0.24) : Qt.alpha(ThemeBackend.surface1, 0.65)
                                border.width: 1
                                border.color: selected ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.06)

                                Text {
                                    id: allProjTxt
                                    anchors.centerIn: parent
                                    text: "Tutti i progetti"
                                    font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); font.bold: parent.selected
                                    color: parent.selected ? ThemeBackend.mauve : ThemeBackend.subtext0
                                }

                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.setTodoistProject("")
                                }
                            }

                            Repeater {
                                model: (root.todoistMeta && root.todoistMeta.projects) ? root.todoistMeta.projects : []

                                Rectangle {
                                    height: Scaler.s(24)
                                    width: projItemTxt.implicitWidth + Scaler.s(14)
                                    radius: Scaler.s(7)
                                    readonly property bool selected: root.todoistMeta && root.todoistMeta.project_id === modelData.id
                                    color: selected ? Qt.alpha(ThemeBackend.mauve, 0.24) : Qt.alpha(ThemeBackend.surface1, 0.65)
                                    border.width: 1
                                    border.color: selected ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.06)

                                    Text {
                                        id: projItemTxt
                                        anchors.centerIn: parent
                                        text: modelData.name || ""
                                        font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); font.bold: parent.selected
                                        color: parent.selected ? ThemeBackend.mauve : ThemeBackend.subtext0
                                    }

                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.setTodoistProject(modelData.id)
                                    }
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Scaler.s(6)

                        ClickButton {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Scaler.s(30)
                            cornerRadius: Scaler.s(8)
                            buttonIcon: "󰑐"
                            buttonText: root.isSyncing ? "Sincronizzazione..." : "Sincronizza ora"
                            accentColor: ThemeBackend.mauve
                            textColor: ThemeBackend.crust
                            onClicked: root.syncTodoist(false)
                        }

                        ClickButton {
                            Layout.preferredHeight: Scaler.s(30)
                            cornerRadius: Scaler.s(8)
                            buttonIcon: "󰍃"
                            buttonText: "Scollega"
                            accentColor: Qt.alpha(ThemeBackend.red, 0.18)
                            textColor: ThemeBackend.red
                            onClicked: root.disconnectTodoist(false)
                        }
                    }
                }

                // Token Setup Card (when NOT connected)
                ColumnLayout {
                    visible: !(root.todoistMeta && root.todoistMeta.connected)
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: Scaler.s(8)

                    Text {
                        text: "Incolla il tuo Personal API Token Todoist (Impostazioni → Integrazioni → Sviluppatore). Viene salvato localmente con permessi 0600 ed escluso dal backup Git."
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9.5)
                        color: ThemeBackend.subtext0
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Scaler.s(34)
                        radius: Scaler.s(9)
                        color: Qt.alpha(ThemeBackend.surface1, 0.78)
                        border.width: 1
                        border.color: tokenInput.activeFocus ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.08)
                        clip: true

                        TextInput {
                            id: tokenInput
                            anchors.fill: parent
                            anchors.margins: Scaler.s(8)
                            verticalAlignment: TextInput.AlignVCenter
                            echoMode: TextInput.Password
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10.5)
                            color: ThemeBackend.text
                            selectByMouse: true

                            onActiveFocusChanged: {
                                root.isTokenInputActive = activeFocus;
                                root.setKeyboardFocus(activeFocus || root.isInputActive || root.isPathInputActive);
                            }

                            Keys.onEscapePressed: {
                                tokenInput.focus = false;
                                root.setKeyboardFocus(false);
                            }

                            onAccepted: root.connectTodoist(tokenInput.text)

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.IBeamCursor
                                onPressed: function(mouse) {
                                    root.setKeyboardFocus(true);
                                    tokenInput.forceActiveFocus();
                                    mouse.accepted = false;
                                }
                            }

                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                visible: !tokenInput.text && !tokenInput.activeFocus
                                text: "Incolla API Token Todoist..."
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(10)
                                color: ThemeBackend.overlay0
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Scaler.s(6)

                        ClickButton {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Scaler.s(32)
                            cornerRadius: Scaler.s(8)
                            buttonIcon: "󰅟"
                            buttonText: root.isSyncing ? "Connessione..." : "Collega & Sincronizza"
                            accentColor: ThemeBackend.mauve
                            textColor: ThemeBackend.crust
                            onClicked: root.connectTodoist(tokenInput.text)
                        }

                        ClickButton {
                            Layout.preferredHeight: Scaler.s(32)
                            cornerRadius: Scaler.s(8)
                            buttonIcon: "󰏌"
                            buttonText: "Apri Token"
                            accentColor: Qt.alpha(ThemeBackend.surface1, 0.78)
                            textColor: ThemeBackend.subtext0
                            onClicked: Quickshell.execDetached(["xdg-open", "https://app.todoist.com/app/settings/integrations/developer"])
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }

            // -------- TAB 1: CSV IMPORT/EXPORT & PULIZIA --------
            ColumnLayout {
                visible: root.settingsTab === 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Scaler.s(8)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Scaler.s(6)

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: Scaler.s(26); radius: Scaler.s(7)
                        color: root.importMode === "merge" ? Qt.alpha(ThemeBackend.mauve, 0.22) : Qt.alpha(ThemeBackend.surface1, 0.55)
                        border.width: 1; border.color: root.importMode === "merge" ? ThemeBackend.mauve : "transparent"
                        Text { anchors.centerIn: parent; text: "Unisci (Merge)"; font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); font.bold: true; color: root.importMode === "merge" ? ThemeBackend.mauve : ThemeBackend.subtext0 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.importMode = "merge" }
                    }

                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: Scaler.s(26); radius: Scaler.s(7)
                        color: root.importMode === "replace" ? Qt.alpha(ThemeBackend.peach, 0.22) : Qt.alpha(ThemeBackend.surface1, 0.55)
                        border.width: 1; border.color: root.importMode === "replace" ? ThemeBackend.peach : "transparent"
                        Text { anchors.centerIn: parent; text: "Sostituisci"; font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); font.bold: true; color: root.importMode === "replace" ? ThemeBackend.peach : ThemeBackend.subtext0 }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.importMode = "replace" }
                    }
                }

                ClickButton {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(32)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰈔"
                    buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.browse_file", "Sfoglia file CSV...") : "Sfoglia file CSV..."
                    accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.crust
                    onClicked: root.pickAndImportCsv(root.importMode)
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Scaler.s(6)

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Scaler.s(30)
                        color: Qt.alpha(ThemeBackend.surface1, 0.72)
                        radius: Scaler.s(8)
                        border.width: 1
                        border.color: pathInput.activeFocus ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.text, 0.08)
                        clip: true

                        TextInput {
                            id: pathInput
                            anchors.fill: parent; anchors.margins: Scaler.s(6)
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); color: ThemeBackend.text
                            selectByMouse: true
                            onActiveFocusChanged: {
                                root.isPathInputActive = activeFocus;
                                root.setKeyboardFocus(activeFocus || root.isInputActive || root.isTokenInputActive);
                            }
                            Keys.onEscapePressed: { pathInput.focus = false; root.setKeyboardFocus(false); }
                            onAccepted: if (pathInput.text.trim() !== "") root.importCsvPath(pathInput.text.trim(), root.importMode)
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.IBeamCursor
                                onPressed: function(mouse) { root.setKeyboardFocus(true); pathInput.forceActiveFocus(); mouse.accepted = false; }
                            }
                            Text {
                                anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                                visible: !pathInput.text && !pathInput.activeFocus
                                text: "~/Documenti/todoist.csv"
                                font.family: ThemeBackend.fontFamily; font.pixelSize: Scaler.s(9.5); color: ThemeBackend.overlay0
                            }
                        }
                    }

                    ClickButton {
                        Layout.preferredWidth: Scaler.s(72)
                        Layout.preferredHeight: Scaler.s(30)
                        cornerRadius: Scaler.s(8)
                        buttonText: "Importa"
                        accentColor: ThemeBackend.surface2
                        textColor: ThemeBackend.text
                        onClicked: if (pathInput.text.trim() !== "") root.importCsvPath(pathInput.text.trim(), root.importMode)
                    }
                }

                Item { Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Scaler.s(6)

                    ClickButton {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Scaler.s(30)
                        cornerRadius: Scaler.s(8)
                        buttonIcon: "󰁆"
                        buttonText: "Esporta CSV"
                        accentColor: Qt.alpha(ThemeBackend.surface1, 0.75)
                        textColor: ThemeBackend.subtext0
                        onClicked: root.pickAndExportCsv()
                    }

                    ClickButton {
                        visible: root.completedCount > 0
                        Layout.preferredHeight: Scaler.s(30)
                        cornerRadius: Scaler.s(8)
                        buttonIcon: "󰃢"
                        buttonText: "Pulisci fatte"
                        accentColor: Qt.alpha(ThemeBackend.peach, 0.18)
                        textColor: ThemeBackend.peach
                        onClicked: {
                            root.clearCompleted();
                            root.isSettingsOpen = false;
                        }
                    }

                    ClickButton {
                        visible: root.totalCount > 0
                        Layout.preferredHeight: Scaler.s(30)
                        cornerRadius: Scaler.s(8)
                        buttonIcon: root.confirmClearAll ? "󰀦" : "󰆴"
                        buttonText: root.confirmClearAll ? "Conferma?" : "Svuota"
                        accentColor: root.confirmClearAll ? ThemeBackend.red : Qt.alpha(ThemeBackend.red, 0.18)
                        textColor: root.confirmClearAll ? ThemeBackend.crust : ThemeBackend.red
                        onClicked: {
                            if (root.confirmClearAll) {
                                root.clearAll();
                                root.isSettingsOpen = false;
                            } else {
                                root.requestClearAll();
                            }
                        }
                    }
                }
            }
        }
    }
}
