import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../../../reusables"
import "../../../"

Item {
    id: root
    anchors.fill: parent
    clip: true

    property real minWidth: 260
    property real minHeight: 220
    property real maxWidth: 700
    property real maxHeight: 700
    property bool isRound: false

    readonly property string nerdFont: ThemeBackend.iconFont

    // Script & data paths
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

    // State
    property var todosList: []
    property int filterMode: 1 // 0: all, 1: today + overdue, 2: upcoming, 3: completed
    property bool showAddRow: true
    property bool isImportSheetOpen: false
    property string importMode: "merge" // "merge" | "replace"
    property bool confirmClearAll: false

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
    property bool showAllDescriptions: false
    property string statusText: ""
    property bool statusIsError: false

    // Keyboard focus integration for LayerShell panel window
    property bool isInputActive: false
    property bool isPathInputActive: false
    property bool wantsKeyboardFocus: isInputActive || isPathInputActive

    function setKeyboardFocus(enable) {
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

    readonly property var filteredList: {
        let res = [];
        for (let i = 0; i < todosList.length; i++) {
            let it = todosList[i];
            if (!it) continue;
            if (filterMode === 1) {
                // Today + Overdue
                if (it.completed) continue;
                if (it.day_category !== "today" && it.day_category !== "overdue") continue;
            } else if (filterMode === 2) {
                // Upcoming
                if (it.completed) continue;
                if (it.day_category !== "tomorrow" && it.day_category !== "upcoming" && it.day_category !== "future") continue;
            } else if (filterMode === 3) {
                // Completed
                if (!it.completed) continue;
            }
            res.push(it);
        }

        if (filterMode === 0) {
            // In "Tutte" view: preserve Todoist section order, then sort tasks within each section by date/priority
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
            // Smart sort: uncompleted first -> overdue/today/upcoming -> priority P1..P4 -> csv_order
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

        // Inject Todoist section separator headers whenever section/category changes
        let finalItems = [];
        let lastSection = "__NONE__";

        // Precompute counts per section in the current filtered set
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

    // Midnight / periodic refresh timer to update relative day categories
    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: initProcess.running = true
    }

    // Local state management
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

        // Optimistic UI update
        let nowMs = Date.now();
        let pColor = "#a6adc8";
        let pLabel = "P4";
        if (root.selectedPriority === 1) { pColor = "#f38ba8"; pLabel = "P1"; }
        else if (root.selectedPriority === 2) { pColor = "#fab387"; pLabel = "P2"; }
        else if (root.selectedPriority === 3) { pColor = "#89b4fa"; pLabel = "P3"; }

        let isSep = clean.indexOf("* ") === 0 || clean === "---" || clean === "___";
        let dispTitle = clean.indexOf("* ") === 0 ? clean.slice(2).trim() : clean;

        let optimisticItem = {
            id: "todo_" + nowMs + "_" + root.todosList.length,
            item_type: isSep ? "separator" : "task",
            uncompletable: isSep,
            title: dispTitle,
            raw_title: clean,
            description: "",
            completed: false,
            priority: root.selectedPriority,
            priority_label: pLabel,
            priority_color: pColor,
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
        let updated = [optimisticItem].concat(root.todosList);
        root.todosList = updated;

        // Sync via process
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
                if (item.uncompletable || item.item_type === "separator") {
                    return;
                }
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
            if (root.todosList[i].id !== todoId) {
                updated.push(root.todosList[i]);
            }
        }
        root.todosList = updated;

        deleteProcess.cmdId = String(todoId);
        deleteProcess.running = false;
        deleteProcess.running = true;
    }

    function clearCompleted() {
        let updated = [];
        for (let i = 0; i < root.todosList.length; i++) {
            if (!root.todosList[i].completed) {
                updated.push(root.todosList[i]);
            }
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

    // File watcher for persistent todos.json
    FileView {
        id: todosFileWatcher
        path: root.todosConfigPath
        watchChanges: true
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
                        root.showStatus(typeof I18n !== "undefined" ? I18n.t("widgets.todo.cleared_all", "Lista svuotata completamente") : "Lista svuotata completamente", false);
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
                        root.showStatus(res.message || "Errore importazione CSV Todoist", true);
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
                        root.isImportSheetOpen = false;
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
                        root.showStatus(typeof I18n !== "undefined" ? I18n.t("widgets.todo.exported_ok", "Attività esportate in CSV Todoist") : "Attività esportate in CSV Todoist", false);
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
            onStreamFinished: root.parseTodos(this.text)
        }
    }

    Component.onCompleted: {
        initProcess.running = true;
    }

    // Glassmorphism card container
    Rectangle {
        id: bgCard
        anchors.fill: parent
        color: Qt.alpha(ThemeBackend.surface0, ThemeBackend.elementOpacity)
        radius: ThemeBackend.clampedBorderRadius !== undefined ? ThemeBackend.clampedBorderRadius : ThemeBackend.borderRadius
        border.width: 1
        border.color: Qt.alpha(ThemeBackend.surface2, 0.38)
        clip: true

        WallpaperBlur {
            z: -2
            anchors.fill: parent
            radius: parent.radius
        }

        GlassFill {
            z: -1
            anchors.fill: parent
            radius: parent.radius
            tintColor: ThemeBackend.surface0
            tintAmount: 0.22
        }

        // Main Widget View
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(12)
            spacing: Scaler.s(6)
            visible: !root.isImportSheetOpen

            // Header Bar
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(30)
                spacing: Scaler.s(5)

                // Checklist Icon
                Rectangle {
                    Layout.preferredWidth: Scaler.s(28)
                    Layout.preferredHeight: Scaler.s(28)
                    radius: Scaler.s(7)
                    color: Qt.alpha(ThemeBackend.mauve, 0.2)

                    Text {
                        anchors.centerIn: parent
                        text: "󰄲"
                        font.family: root.nerdFont
                        font.pixelSize: Scaler.s(15)
                        color: ThemeBackend.mauve
                    }
                }

                // Title
                Text {
                    text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.title", "To-Do") : "To-Do"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(13.5)
                    font.weight: Font.Black
                    color: ThemeBackend.text
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // Today badge count (if any)
                Rectangle {
                    visible: root.todayCount > 0
                    Layout.preferredHeight: Scaler.s(22)
                    Layout.preferredWidth: todayLabel.implicitWidth + Scaler.s(10)
                    radius: Scaler.s(11)
                    color: Qt.alpha(ThemeBackend.mauve, 0.22)
                    border.width: 1
                    border.color: Qt.alpha(ThemeBackend.mauve, 0.65)

                    Text {
                        id: todayLabel
                        anchors.centerIn: parent
                        text: root.todayCount + " oggi"
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9)
                        font.bold: true
                        color: ThemeBackend.mauve
                    }
                }

                // Total Progress Badge (e.g. "3/5")
                Rectangle {
                    visible: root.totalCount > 0
                    Layout.preferredHeight: Scaler.s(22)
                    Layout.preferredWidth: countLabel.implicitWidth + Scaler.s(10)
                    radius: Scaler.s(11)
                    color: Qt.alpha(ThemeBackend.surface1, 0.8)
                    border.width: 1
                    border.color: Qt.alpha(root.activeCount === 0 ? ThemeBackend.green : ThemeBackend.surface2, 0.5)

                    Text {
                        id: countLabel
                        anchors.centerIn: parent
                        text: root.completedCount + "/" + root.totalCount
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9)
                        font.bold: true
                        color: root.activeCount === 0 ? ThemeBackend.green : ThemeBackend.subtext0
                    }
                }

                // Toggle Expand All Descriptions button
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: root.showAllDescriptions ? "󰘖" : "󰦨"
                    iconFontSize: Scaler.s(13)
                    accentColor: root.showAllDescriptions ? Qt.alpha(ThemeBackend.mauve, 0.28) : ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: root.showAllDescriptions ? ThemeBackend.mauve : ThemeBackend.subtext0
                    onClicked: root.showAllDescriptions = !root.showAllDescriptions
                }

                // Quick Import Todoist CSV button (Zenity file picker dialog)
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰈔"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.blue
                    onClicked: root.pickAndImportCsv("merge")
                }

                // Quick Export Todoist CSV button
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰁆"
                    iconFontSize: Scaler.s(12.5)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.subtext0
                    onClicked: root.pickAndExportCsv()
                }

                // Clear completed tasks button (broom icon)
                IconButton {
                    visible: root.completedCount > 0
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰃢"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.peach
                    onClicked: root.clearCompleted()
                }

                // Empty / Clear ALL tasks button (with 2-step confirmation)
                Rectangle {
                    visible: root.todosList.length > 0
                    Layout.preferredHeight: Scaler.s(26)
                    Layout.preferredWidth: root.confirmClearAll ? (clearConfirmRow.implicitWidth + Scaler.s(12)) : Scaler.s(26)
                    radius: Scaler.s(7)
                    color: root.confirmClearAll
                        ? ThemeBackend.red
                        : (clearAllMa.containsMouse ? Qt.alpha(ThemeBackend.red, 0.22) : Qt.alpha(ThemeBackend.surface1, ThemeBackend.elementOpacity))
                    border.width: root.confirmClearAll ? 0 : 1
                    border.color: clearAllMa.containsMouse ? Qt.alpha(ThemeBackend.red, 0.5) : "transparent"

                    Behavior on Layout.preferredWidth { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 130 } }

                    RowLayout {
                        id: clearConfirmRow
                        anchors.centerIn: parent
                        spacing: Scaler.s(4)

                        Text {
                            text: root.confirmClearAll ? "󰀦" : "󰆴"
                            font.family: root.nerdFont
                            font.pixelSize: Scaler.s(12.5)
                            color: root.confirmClearAll ? ThemeBackend.crust : ThemeBackend.red
                        }

                        Text {
                            visible: root.confirmClearAll
                            text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.clear_all_confirm", "Svuota?") : "Svuota?"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(9.5)
                            font.bold: true
                            color: ThemeBackend.crust
                        }
                    }

                    MouseArea {
                        id: clearAllMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.requestClearAll()
                    }
                }

                // Toggle Import / Settings Sheet
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰒓"
                    iconFontSize: Scaler.s(12.5)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: root.isImportSheetOpen ? ThemeBackend.mauve : ThemeBackend.subtext0
                    onClicked: {
                        root.confirmClearAll = false;
                        root.isImportSheetOpen = true;
                    }
                }
            }

            // Sleek Completion Progress Bar
            Rectangle {
                visible: root.totalCount > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(4)
                radius: Scaler.s(2)
                color: Qt.alpha(ThemeBackend.surface2, 0.35)
                clip: true

                Rectangle {
                    width: parent.width * root.completionRatio
                    height: parent.height
                    radius: parent.radius
                    color: root.activeCount === 0 ? ThemeBackend.green : ThemeBackend.mauve
                    Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
            }

            // Status message toast banner (feedback for import/export)
            Rectangle {
                visible: root.statusText !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(24)
                radius: Scaler.s(6)
                color: Qt.alpha(root.statusIsError ? ThemeBackend.red : ThemeBackend.mauve, 0.18)
                border.width: 1
                border.color: Qt.alpha(root.statusIsError ? ThemeBackend.red : ThemeBackend.mauve, 0.45)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Scaler.s(8)
                    anchors.rightMargin: Scaler.s(8)
                    spacing: Scaler.s(6)

                    Text {
                        text: root.statusIsError ? "󰅖" : "󰄲"
                        font.family: root.nerdFont
                        font.pixelSize: Scaler.s(12)
                        color: root.statusIsError ? ThemeBackend.red : ThemeBackend.mauve
                    }

                    Text {
                        text: root.statusText
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(10.5)
                        font.bold: true
                        color: ThemeBackend.text
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }
            }

            // Smart Quick Add Task Row
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(4)

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(34)
                    radius: Scaler.s(8)
                    color: Qt.alpha(ThemeBackend.surface1, 0.75)
                    border.width: 1
                    border.color: taskInput.activeFocus ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.4)

                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Scaler.s(8)
                        anchors.rightMargin: Scaler.s(4)
                        spacing: Scaler.s(6)

                        TextInput {
                            id: taskInput
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(11.5)
                            color: ThemeBackend.text
                            selectByMouse: true

                            onActiveFocusChanged: {
                                root.isInputActive = activeFocus;
                                root.setKeyboardFocus(activeFocus || root.isPathInputActive);
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
                                text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.new_placeholder", "Nuova attività... (o '* Titolo' per separatore)") : "Nuova attività... (o '* Titolo' per separatore)"
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(10.5)
                                color: ThemeBackend.overlay1
                                elide: Text.ElideRight
                            }
                        }

                        // Add button
                        IconButton {
                            size: Scaler.s(26)
                            cornerRadius: Scaler.s(6)
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

                // Quick selector chips for Priority and Due Date
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Scaler.s(6)

                    // Priority Chip Selector (Cycles P4 -> P1 -> P2 -> P3 -> P4)
                    Rectangle {
                        Layout.preferredHeight: Scaler.s(22)
                        Layout.preferredWidth: prioChipText.implicitWidth + Scaler.s(14)
                        radius: Scaler.s(6)
                        color: {
                            if (root.selectedPriority === 1) return Qt.alpha("#f38ba8", 0.25);
                            if (root.selectedPriority === 2) return Qt.alpha("#fab387", 0.25);
                            if (root.selectedPriority === 3) return Qt.alpha("#89b4fa", 0.25);
                            return Qt.alpha(ThemeBackend.surface2, 0.4);
                        }
                        border.width: 1
                        border.color: {
                            if (root.selectedPriority === 1) return "#f38ba8";
                            if (root.selectedPriority === 2) return "#fab387";
                            if (root.selectedPriority === 3) return "#89b4fa";
                            return Qt.alpha(ThemeBackend.surface2, 0.4);
                        }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Scaler.s(3)

                            Text {
                                text: root.selectedPriority === 1 ? "󰀦" : "󰄲"
                                font.family: root.nerdFont
                                font.pixelSize: Scaler.s(10)
                                color: {
                                    if (root.selectedPriority === 1) return "#f38ba8";
                                    if (root.selectedPriority === 2) return "#fab387";
                                    if (root.selectedPriority === 3) return "#89b4fa";
                                    return ThemeBackend.subtext0;
                                }
                            }

                            Text {
                                id: prioChipText
                                text: "P" + root.selectedPriority
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(9.5)
                                font.bold: true
                                color: {
                                    if (root.selectedPriority === 1) return "#f38ba8";
                                    if (root.selectedPriority === 2) return "#fab387";
                                    if (root.selectedPriority === 3) return "#89b4fa";
                                    return ThemeBackend.subtext0;
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // Cycle: 4 -> 1 -> 2 -> 3 -> 4
                                if (root.selectedPriority === 4) root.selectedPriority = 1;
                                else if (root.selectedPriority === 1) root.selectedPriority = 2;
                                else if (root.selectedPriority === 2) root.selectedPriority = 3;
                                else root.selectedPriority = 4;
                            }
                        }
                    }

                    // Date Chip Selector (Cycles: Nessuna -> Oggi -> Domani -> +7 gg)
                    Rectangle {
                        Layout.preferredHeight: Scaler.s(22)
                        Layout.preferredWidth: dateChipText.implicitWidth + Scaler.s(18)
                        radius: Scaler.s(6)
                        color: root.selectedDateIndex > 0 ? Qt.alpha(ThemeBackend.mauve, 0.22) : Qt.alpha(ThemeBackend.surface2, 0.4)
                        border.width: 1
                        border.color: root.selectedDateIndex > 0 ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.4)

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Scaler.s(4)

                            Text {
                                text: "󰔛"
                                font.family: root.nerdFont
                                font.pixelSize: Scaler.s(10)
                                color: root.selectedDateIndex > 0 ? ThemeBackend.mauve : ThemeBackend.subtext0
                            }

                            Text {
                                id: dateChipText
                                text: root.dateOptionLabels[root.selectedDateIndex]
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(9.5)
                                font.bold: root.selectedDateIndex > 0
                                color: root.selectedDateIndex > 0 ? ThemeBackend.mauve : ThemeBackend.subtext0
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.selectedDateIndex = (root.selectedDateIndex + 1) % root.dateOptions.length;
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }
            }

            // Intelligent Date Filter Tabs
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(26)
                spacing: Scaler.s(4)

                Repeater {
                    model: [
                        { mode: 0, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_all", "Tutte") : "Tutte", count: root.totalCount, icon: "󰈔" },
                        { mode: 1, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_today", "Oggi") : "Oggi", count: root.todayCount, icon: "󰔛" },
                        { mode: 2, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_upcoming", "Prossime") : "Prossime", count: root.upcomingCount, icon: "󰃮" },
                        { mode: 3, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_done", "Completate") : "Completate", count: root.completedCount, icon: "󰄲" }
                    ]

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Scaler.s(24)
                        radius: Scaler.s(6)
                        color: root.filterMode === modelData.mode
                            ? Qt.alpha(ThemeBackend.mauve, 0.22)
                            : (filterMa.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.6) : "transparent")
                        border.width: 1
                        border.color: root.filterMode === modelData.mode ? Qt.alpha(ThemeBackend.mauve, 0.5) : Qt.alpha(ThemeBackend.surface2, 0.2)

                        Behavior on color { ColorAnimation { duration: 120 } }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Scaler.s(3)

                            Text {
                                text: modelData.icon
                                font.family: root.nerdFont
                                font.pixelSize: Scaler.s(10)
                                color: root.filterMode === modelData.mode ? ThemeBackend.mauve : ThemeBackend.subtext0
                            }

                            Text {
                                text: modelData.label
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(9.5)
                                font.bold: root.filterMode === modelData.mode
                                color: root.filterMode === modelData.mode ? ThemeBackend.mauve : ThemeBackend.subtext0
                            }

                            Text {
                                visible: modelData.count > 0
                                text: "(" + modelData.count + ")"
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(8.5)
                                color: root.filterMode === modelData.mode ? ThemeBackend.mauve : ThemeBackend.overlay1
                            }
                        }

                        MouseArea {
                            id: filterMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.filterMode = modelData.mode
                        }
                    }
                }
            }

            // Task List View
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: tasksView
                    anchors.fill: parent
                    clip: true
                    spacing: Scaler.s(6)
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.filteredList

                    delegate: Item {
                        id: delegateRoot
                        width: tasksView.width
                        readonly property bool isSecHeader: Boolean(modelData.is_section_header)
                        readonly property bool isSepItem: Boolean(!modelData.is_section_header && (modelData.uncompletable || modelData.item_type === "separator"))
                        readonly property bool hasDesc: Boolean(modelData.description && String(modelData.description).trim() !== "")
                        readonly property bool isNoteExpanded: Boolean(root.showAllDescriptions || root.expandedNotesMap[modelData.id])

                        implicitHeight: isSecHeader
                            ? (sectionHeaderBox.implicitHeight + Scaler.s(4))
                            : (isSepItem ? (separatorItemBox.implicitHeight + Scaler.s(2)) : (taskMainCol.implicitHeight + Scaler.s(12)))

                        // 1) TODOIST SECTION HEADER DELEGATE (TYPE=section)
                        Rectangle {
                            id: sectionHeaderBox
                            visible: delegateRoot.isSecHeader
                            width: parent.width
                            implicitHeight: secCol.implicitHeight + Scaler.s(12)
                            radius: Scaler.s(7)
                            color: secHeaderMa.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.65) : Qt.alpha(ThemeBackend.surface0, 0.45)
                            border.width: 1
                            border.color: Qt.alpha(ThemeBackend.mauve, 0.35)

                            ColumnLayout {
                                id: secCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Scaler.s(6)
                                spacing: Scaler.s(3)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Scaler.s(6)

                                    Text {
                                        text: Boolean(root.collapsedSectionsMap[modelData.section_title]) ? "󰅂" : "󰅃"
                                        font.family: root.nerdFont
                                        font.pixelSize: Scaler.s(11)
                                        color: ThemeBackend.mauve
                                    }

                                    Text {
                                        text: modelData.section_title || ""
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(11)
                                        font.weight: Font.Black
                                        color: ThemeBackend.mauve
                                        Layout.fillWidth: true
                                        wrapMode: Text.WordWrap
                                    }

                                    Rectangle {
                                        visible: (modelData.section_total || 0) > 0
                                        Layout.preferredHeight: Scaler.s(16)
                                        Layout.preferredWidth: secCountTxt.implicitWidth + Scaler.s(8)
                                        radius: Scaler.s(8)
                                        color: Qt.alpha(ThemeBackend.mauve, 0.18)

                                        Text {
                                            id: secCountTxt
                                            anchors.centerIn: parent
                                            text: (modelData.section_done || 0) + "/" + (modelData.section_total || 0)
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: Scaler.s(8.5)
                                            font.bold: true
                                            color: ThemeBackend.mauve
                                        }
                                    }
                                }

                                // Section Description (from Todoist section DESCRIPTION column)
                                Text {
                                    visible: !Boolean(root.collapsedSectionsMap[modelData.section_title]) && Boolean(modelData.section_description && String(modelData.section_description).trim() !== "")
                                    text: modelData.section_description || ""
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9.5)
                                    color: ThemeBackend.subtext0
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Scaler.s(16)
                                    wrapMode: Text.WordWrap
                                }

                                // Bottom Todoist-style divider line
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 1
                                    color: Qt.alpha(ThemeBackend.mauve, 0.28)
                                }
                            }

                            MouseArea {
                                id: secHeaderMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleSectionCollapsed(modelData.section_title)
                            }
                        }

                        // 2) TODOIST UNCOMPLETABLE SEPARATOR TASK DELEGATE ('* Title' or '---')
                        Rectangle {
                            id: separatorItemBox
                            visible: delegateRoot.isSepItem
                            width: parent.width
                            implicitHeight: sepRowCol.implicitHeight + Scaler.s(10)
                            radius: Scaler.s(6)
                            color: Qt.alpha(ThemeBackend.surface1, 0.35)
                            border.width: 1
                            border.color: Qt.alpha(ThemeBackend.surface2, 0.35)

                            ColumnLayout {
                                id: sepRowCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Scaler.s(5)
                                spacing: Scaler.s(3)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Scaler.s(6)

                                    Rectangle {
                                        width: Scaler.s(12)
                                        height: 2
                                        radius: 1
                                        color: ThemeBackend.mauve
                                    }

                                    Text {
                                        visible: modelData.title !== "---" && modelData.title !== "___" && modelData.title !== "***"
                                        text: modelData.title || ""
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(10.5)
                                        font.bold: true
                                        color: ThemeBackend.subtext1
                                        Layout.fillWidth: true
                                        wrapMode: Text.WordWrap
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 1
                                        color: Qt.alpha(ThemeBackend.surface2, 0.55)
                                    }

                                    IconButton {
                                        size: Scaler.s(20)
                                        cornerRadius: Scaler.s(4)
                                        buttonIcon: "󰅖"
                                        iconFontSize: Scaler.s(10)
                                        accentColor: "transparent"
                                        textColor: ThemeBackend.overlay1
                                        onClicked: root.deleteTodo(modelData.id)
                                    }
                                }

                                Text {
                                    visible: delegateRoot.hasDesc
                                    text: modelData.description || ""
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9.5)
                                    color: ThemeBackend.subtext0
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }

                        // 3) REGULAR TASK CARD DELEGATE
                        Rectangle {
                            id: taskCard
                            visible: !delegateRoot.isSecHeader && !delegateRoot.isSepItem
                            anchors.fill: parent
                            radius: Scaler.s(8)
                            color: Qt.alpha(ThemeBackend.surface1, taskCardHover.hovered ? 0.78 : 0.52)
                            border.width: 1
                            border.color: {
                                if (modelData.day_category === "overdue" && !modelData.completed) return Qt.alpha("#f38ba8", 0.5);
                                if (modelData.day_category === "today" && !modelData.completed) return Qt.alpha(ThemeBackend.mauve, 0.4);
                                return Qt.alpha(ThemeBackend.surface2, taskCardHover.hovered ? 0.5 : 0.25);
                            }
                            opacity: modelData.completed ? 0.58 : 1.0

                            Behavior on color { ColorAnimation { duration: 120 } }
                            Behavior on opacity { NumberAnimation { duration: 150 } }

                            HoverHandler {
                                id: taskCardHover
                            }

                            // Priority color indicator bar on left (P1: Red, P2: Orange, P3: Blue, P4: Subtle)
                            Rectangle {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: Scaler.s(3.5)
                                radius: Scaler.s(1.5)
                                color: modelData.priority_color || "#a6adc8"
                            }

                            // Click anywhere on card body to expand/collapse full description
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: delegateRoot.hasDesc ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: {
                                    if (delegateRoot.hasDesc) {
                                        root.toggleNoteExpanded(modelData.id);
                                    }
                                }
                            }

                            ColumnLayout {
                                id: taskMainCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Scaler.s(10)
                                anchors.rightMargin: Scaler.s(6)
                                anchors.topMargin: Scaler.s(6)
                                anchors.bottomMargin: Scaler.s(6)
                                spacing: Scaler.s(4)

                                // Main Row: Checkbox + Priority Pill + Title + Note Toggle + Delete
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Scaler.s(6)

                                    // Custom Checkbox Button
                                    Rectangle {
                                        id: checkBtn
                                        Layout.preferredWidth: Scaler.s(18)
                                        Layout.preferredHeight: Scaler.s(18)
                                        radius: Scaler.s(5)
                                        color: modelData.completed ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.4)
                                        border.width: 1.5
                                        border.color: modelData.completed ? ThemeBackend.mauve : (modelData.priority_color || ThemeBackend.subtext1)

                                        Behavior on color { ColorAnimation { duration: 120 } }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: Boolean(modelData.completed)
                                            text: "✓"
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: Scaler.s(10)
                                            font.bold: true
                                            color: ThemeBackend.crust
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleTodo(modelData.id)
                                        }
                                    }

                                    // Priority badge (only if P1, P2 or P3)
                                    Rectangle {
                                        visible: Boolean(modelData.priority && modelData.priority < 4)
                                        Layout.preferredHeight: Scaler.s(16)
                                        Layout.preferredWidth: prioBadgeText.implicitWidth + Scaler.s(8)
                                        radius: Scaler.s(4)
                                        color: Qt.alpha(modelData.priority_color || "#f38ba8", 0.22)
                                        border.width: 1
                                        border.color: modelData.priority_color || "#f38ba8"

                                        Text {
                                            id: prioBadgeText
                                            anchors.centerIn: parent
                                            text: modelData.priority_label || ("P" + modelData.priority)
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: Scaler.s(8.5)
                                            font.bold: true
                                            color: modelData.priority_color || "#f38ba8"
                                        }
                                    }

                                    // Title Text
                                    Text {
                                        text: modelData.title || ""
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(11.5)
                                        font.bold: !modelData.completed
                                        font.strikeout: Boolean(modelData.completed)
                                        color: modelData.completed ? ThemeBackend.subtext0 : ThemeBackend.text
                                        Layout.fillWidth: true
                                        wrapMode: Text.WordWrap
                                        elide: delegateRoot.isNoteExpanded ? Text.ElideNone : Text.ElideRight
                                        maximumLineCount: delegateRoot.isNoteExpanded ? 6 : 2
                                    }

                                    // Toggle Note Button (if task has description / note)
                                    IconButton {
                                        visible: delegateRoot.hasDesc
                                        size: Scaler.s(22)
                                        cornerRadius: Scaler.s(5)
                                        buttonIcon: delegateRoot.isNoteExpanded ? "󰅃" : "󰅂"
                                        iconFontSize: Scaler.s(11)
                                        accentColor: delegateRoot.isNoteExpanded ? Qt.alpha(ThemeBackend.mauve, 0.2) : "transparent"
                                        textColor: ThemeBackend.mauve
                                        onClicked: root.toggleNoteExpanded(modelData.id)
                                    }

                                    // Delete Task Button (appears on hover)
                                    IconButton {
                                        visible: taskCardHover.hovered
                                        size: Scaler.s(22)
                                        cornerRadius: Scaler.s(5)
                                        buttonIcon: "󰅖"
                                        iconFontSize: Scaler.s(11)
                                        accentColor: "transparent"
                                        textColor: ThemeBackend.red
                                        onClicked: root.deleteTodo(modelData.id)
                                    }
                                }

                                // Todoist-style Description Preview / Full Box (always readable!)
                                Rectangle {
                                    visible: delegateRoot.hasDesc
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Scaler.s(24)
                                    implicitHeight: descText.implicitHeight + (delegateRoot.isNoteExpanded ? Scaler.s(10) : Scaler.s(2))
                                    radius: Scaler.s(6)
                                    color: delegateRoot.isNoteExpanded ? Qt.alpha(ThemeBackend.surface0, 0.72) : "transparent"
                                    border.width: delegateRoot.isNoteExpanded ? 1 : 0
                                    border.color: Qt.alpha(ThemeBackend.mauve, 0.35)

                                    Text {
                                        id: descText
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: delegateRoot.isNoteExpanded ? Scaler.s(5) : 0
                                        text: modelData.description || ""
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(9.8)
                                        color: delegateRoot.isNoteExpanded ? ThemeBackend.text : ThemeBackend.subtext0
                                        wrapMode: Text.WordWrap
                                        elide: delegateRoot.isNoteExpanded ? Text.ElideNone : Text.ElideRight
                                        maximumLineCount: delegateRoot.isNoteExpanded ? 50 : 2
                                    }
                                }

                                // Sub-Row: Due Date Badge + Labels
                                RowLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Scaler.s(24)
                                    spacing: Scaler.s(5)
                                    visible: Boolean(modelData.relative_label || (modelData.labels && modelData.labels.length > 0))

                                    // Due Date Badge (Smart relative day display)
                                    Rectangle {
                                        visible: Boolean(modelData.relative_label && modelData.relative_label !== "")
                                        Layout.preferredHeight: Scaler.s(18)
                                        Layout.preferredWidth: dateBadgeContent.implicitWidth + Scaler.s(10)
                                        radius: Scaler.s(4)
                                        color: {
                                            if (modelData.day_category === "overdue") return Qt.alpha("#f38ba8", 0.22);
                                            if (modelData.day_category === "today") return Qt.alpha(ThemeBackend.mauve, 0.22);
                                            if (modelData.day_category === "tomorrow") return Qt.alpha("#89b4fa", 0.22);
                                            return Qt.alpha(ThemeBackend.surface2, 0.5);
                                        }
                                        border.width: 1
                                        border.color: {
                                            if (modelData.day_category === "overdue") return "#f38ba8";
                                            if (modelData.day_category === "today") return ThemeBackend.mauve;
                                            if (modelData.day_category === "tomorrow") return "#89b4fa";
                                            return Qt.alpha(ThemeBackend.surface2, 0.4);
                                        }

                                        RowLayout {
                                            id: dateBadgeContent
                                            anchors.centerIn: parent
                                            spacing: Scaler.s(3)

                                            Text {
                                                text: modelData.day_category === "overdue" ? "󰀦" : "󰔛"
                                                font.family: root.nerdFont
                                                font.pixelSize: Scaler.s(9)
                                                color: {
                                                    if (modelData.day_category === "overdue") return "#f38ba8";
                                                    if (modelData.day_category === "today") return ThemeBackend.mauve;
                                                    if (modelData.day_category === "tomorrow") return "#89b4fa";
                                                    return ThemeBackend.subtext1;
                                                }
                                            }

                                            Text {
                                                text: modelData.relative_label || ""
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: Scaler.s(9)
                                                font.bold: modelData.day_category === "overdue" || modelData.day_category === "today"
                                                color: {
                                                    if (modelData.day_category === "overdue") return "#f38ba8";
                                                    if (modelData.day_category === "today") return ThemeBackend.mauve;
                                                    if (modelData.day_category === "tomorrow") return "#89b4fa";
                                                    return ThemeBackend.subtext1;
                                                }
                                            }
                                        }
                                    }

                                    // Labels (from Todoist @labels)
                                    Repeater {
                                        model: modelData.labels || []

                                        Rectangle {
                                            Layout.preferredHeight: Scaler.s(18)
                                            Layout.preferredWidth: lblText.implicitWidth + Scaler.s(8)
                                            radius: Scaler.s(4)
                                            color: Qt.alpha(ThemeBackend.surface2, 0.4)

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

                    // Empty State Indicator
                    Item {
                        anchors.fill: parent
                        visible: root.filteredList.length === 0

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: Scaler.s(6)

                            Text {
                                text: {
                                    if (root.filterMode === 1) return "󰔛";
                                    if (root.filterMode === 2) return "󰃮";
                                    if (root.filterMode === 3) return "󰄲";
                                    return "󰈔";
                                }
                                font.family: root.nerdFont
                                font.pixelSize: Scaler.s(28)
                                color: ThemeBackend.overlay0
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: {
                                    if (root.filterMode === 1) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_today", "Nessuna attività per oggi!") : "Nessuna attività per oggi!";
                                    if (root.filterMode === 2) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_upcoming", "Nessuna attività programmata") : "Nessuna attività programmata";
                                    if (root.filterMode === 3) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_completed", "Nessuna attività completata") : "Nessuna attività completata";
                                    return typeof I18n !== "undefined" ? I18n.t("widgets.todo.empty", "Nessuna attività. Aggiungine una o importa un CSV Todoist.") : "Nessuna attività. Aggiungine una o importa un CSV Todoist.";
                                }
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(10.5)
                                color: ThemeBackend.subtext0
                                Layout.alignment: Qt.AlignHCenter
                                horizontalAlignment: Text.AlignHCenter
                            }

                            // Quick button to import CSV in empty state
                            ClickButton {
                                visible: root.totalCount === 0
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredHeight: Scaler.s(28)
                                cornerRadius: Scaler.s(6)
                                buttonIcon: "󰈔"
                                buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.btn_import_csv", "Importa CSV Todoist") : "Importa CSV Todoist"
                                accentColor: Qt.alpha(ThemeBackend.surface1, 0.8)
                                textColor: ThemeBackend.mauve
                                onClicked: root.pickAndImportCsv("merge")
                            }
                        }
                    }
                }
            }
        }

        // Inline Configuration & Todoist CSV Import/Export Sheet
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(12)
            spacing: Scaler.s(8)
            visible: root.isImportSheetOpen

            // Sheet Header
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Text {
                    text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.csv_manage_title", "Importa & Esporta CSV Todoist") : "Importa & Esporta CSV Todoist"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(13)
                    font.bold: true
                    color: ThemeBackend.text
                    Layout.fillWidth: true
                }

                IconButton {
                    size: Scaler.s(28)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰅖"
                    iconFontSize: Scaler.s(14)
                    accentColor: ThemeBackend.surface1
                    textColor: ThemeBackend.subtext0
                    onClicked: {
                        root.isImportSheetOpen = false;
                        root.isPathInputActive = false;
                    }
                }
            }

            Text {
                text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.csv_help", "Compatibile al 100% con i modelli e le esportazioni CSV di Todoist (sezioni, priorità P1-P4, scadenze naturali, note e tag).") : "Compatibile al 100% con i modelli e le esportazioni CSV di Todoist (sezioni, priorità P1-P4, scadenze naturali, note e tag)."
                font.family: ThemeBackend.fontFamily
                font.pixelSize: Scaler.s(9.5)
                color: ThemeBackend.overlay1
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }

            // Mode Selector: Unisci (Merge) vs Sostituisci (Replace)
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(28)
                    radius: Scaler.s(6)
                    color: root.importMode === "merge" ? Qt.alpha(ThemeBackend.mauve, 0.25) : Qt.alpha(ThemeBackend.surface1, 0.6)
                    border.width: 1
                    border.color: root.importMode === "merge" ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.3)

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Scaler.s(4)
                        Text {
                            text: "󰐕"
                            font.family: root.nerdFont
                            font.pixelSize: Scaler.s(11)
                            color: root.importMode === "merge" ? ThemeBackend.mauve : ThemeBackend.subtext0
                        }
                        Text {
                            text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.mode_merge", "Unisci (Merge)") : "Unisci (Merge)"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            font.bold: true
                            color: root.importMode === "merge" ? ThemeBackend.mauve : ThemeBackend.subtext0
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.importMode = "merge"
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(28)
                    radius: Scaler.s(6)
                    color: root.importMode === "replace" ? Qt.alpha(ThemeBackend.peach, 0.25) : Qt.alpha(ThemeBackend.surface1, 0.6)
                    border.width: 1
                    border.color: root.importMode === "replace" ? ThemeBackend.peach : Qt.alpha(ThemeBackend.surface2, 0.3)

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: Scaler.s(4)
                        Text {
                            text: "󰑐"
                            font.family: root.nerdFont
                            font.pixelSize: Scaler.s(11)
                            color: root.importMode === "replace" ? ThemeBackend.peach : ThemeBackend.subtext0
                        }
                        Text {
                            text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.mode_replace", "Sostituisci (Replace)") : "Sostituisci (Replace)"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            font.bold: true
                            color: root.importMode === "replace" ? ThemeBackend.peach : ThemeBackend.subtext0
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.importMode = "replace"
                    }
                }
            }

            // Quick Pick via Zenity file dialog button
            ClickButton {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(34)
                cornerRadius: Scaler.s(7)
                buttonIcon: "󰈔"
                buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.browse_file", "Sfoglia file CSV...") : "Sfoglia file CSV..."
                accentColor: ThemeBackend.mauve
                textColor: ThemeBackend.crust
                onClicked: root.pickAndImportCsv(root.importMode)
            }

            // Divider or OR label
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)
                Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(ThemeBackend.surface2, 0.4) }
                Text {
                    text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.or_manual_path", "oppure inserisci percorso") : "oppure inserisci percorso"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(9.5)
                    color: ThemeBackend.overlay0
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(ThemeBackend.surface2, 0.4) }
            }

            // Manual Path Input
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(32)
                    color: Qt.alpha(ThemeBackend.surface1, 0.8)
                    radius: Scaler.s(6)
                    border.width: 1
                    border.color: pathInput.activeFocus ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.4)
                    clip: true

                    TextInput {
                        id: pathInput
                        anchors.fill: parent
                        anchors.margins: Scaler.s(6)
                        verticalAlignment: TextInput.AlignVCenter
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(10)
                        color: ThemeBackend.text
                        selectByMouse: true

                        onActiveFocusChanged: {
                            root.isPathInputActive = activeFocus;
                            root.setKeyboardFocus(activeFocus || root.isInputActive);
                        }

                        Keys.onEscapePressed: {
                            pathInput.focus = false;
                            root.setKeyboardFocus(false);
                        }

                        onAccepted: {
                            if (pathInput.text.trim() !== "") {
                                root.importCsvPath(pathInput.text.trim(), root.importMode);
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.IBeamCursor
                            onPressed: function(mouse) {
                                root.setKeyboardFocus(true);
                                pathInput.forceActiveFocus();
                                mouse.accepted = false;
                            }
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: !pathInput.text && !pathInput.activeFocus
                            text: "~/Documenti/todoist_tasks.csv"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            color: ThemeBackend.overlay0
                        }
                    }
                }

                ClickButton {
                    Layout.preferredWidth: Scaler.s(80)
                    Layout.preferredHeight: Scaler.s(32)
                    cornerRadius: Scaler.s(6)
                    buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.import_btn", "Importa") : "Importa"
                    accentColor: ThemeBackend.surface2
                    textColor: ThemeBackend.text
                    onClicked: {
                        if (pathInput.text.trim() !== "") {
                            root.importCsvPath(pathInput.text.trim(), root.importMode);
                        }
                    }
                }
            }

            Item {
                Layout.fillHeight: true
            }

            // Bottom Action Row: Export CSV & Empty All List
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                // Export to Todoist CSV button
                ClickButton {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(32)
                    cornerRadius: Scaler.s(6)
                    buttonIcon: "󰁆"
                    buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.export_btn", "Esporta CSV Todoist") : "Esporta CSV Todoist"
                    accentColor: Qt.alpha(ThemeBackend.surface1, 0.75)
                    textColor: ThemeBackend.subtext0
                    onClicked: root.pickAndExportCsv()
                }

                // Clear All Tasks button inside management sheet
                ClickButton {
                    visible: root.totalCount > 0
                    Layout.preferredHeight: Scaler.s(32)
                    cornerRadius: Scaler.s(6)
                    buttonIcon: "󰆴"
                    buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.clear_all_btn", "Svuota lista") : "Svuota lista"
                    accentColor: Qt.alpha(ThemeBackend.red, 0.22)
                    textColor: ThemeBackend.red
                    onClicked: {
                        root.clearAll();
                        root.isImportSheetOpen = false;
                    }
                }
            }
        }
    }
}
