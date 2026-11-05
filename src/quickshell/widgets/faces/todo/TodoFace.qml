import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
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
    property int filterMode: 0 // 0: all, 1: active, 2: completed
    property bool showAddRow: true
    property bool isImportSheetOpen: false
    property string importMode: "merge" // "merge" | "replace"
    property string newPriority: "normal" // "normal" | "high"
    property string statusText: ""
    property bool statusIsError: false

    // Keyboard focus integration for LayerShell panel window
    property bool isInputActive: false
    property bool isPathInputActive: false
    readonly property bool wantsKeyboardFocus: isInputActive || isPathInputActive

    readonly property int totalCount: todosList.length
    readonly property int completedCount: {
        let c = 0;
        for (let i = 0; i < todosList.length; i++) {
            if (todosList[i] && todosList[i].completed) c++;
        }
        return c;
    }
    readonly property int activeCount: totalCount - completedCount

    readonly property var filteredList: {
        let res = [];
        for (let i = 0; i < todosList.length; i++) {
            let it = todosList[i];
            if (!it) continue;
            if (filterMode === 1 && it.completed) continue;
            if (filterMode === 2 && !it.completed) continue;
            res.push(it);
        }
        return res;
    }

    function showStatus(msg, isErr) {
        statusText = msg;
        statusIsError = isErr === true;
        statusTimer.restart();
    }

    Timer {
        id: statusTimer
        interval: 3500
        onTriggered: root.statusText = ""
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

    function addTodo(title, prio) {
        let clean = (title || "").trim();
        if (clean === "") return;
        let p = prio || root.newPriority;

        // Optimistic UI update
        let nowMs = Date.now();
        let optimisticItem = {
            id: "todo_" + nowMs + "_" + root.todosList.length,
            title: clean,
            completed: false,
            priority: p,
            category: "",
            due_date: "",
            created_at: Math.floor(nowMs / 1000)
        };
        let updated = [optimisticItem].concat(root.todosList);
        root.todosList = updated;

        // Sync via process
        addProcess.cmdTitle = clean;
        addProcess.cmdPriority = p;
        addProcess.running = false;
        addProcess.running = true;
    }

    function toggleTodo(todoId) {
        if (!todoId) return;
        let updated = [];
        for (let i = 0; i < root.todosList.length; i++) {
            let item = Object.assign({}, root.todosList[i]);
            if (item.id === todoId) {
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
        property string cmdPriority: "normal"
        command: ["python3", root.scriptPath, "--add", cmdTitle, cmdPriority]
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
            spacing: Scaler.s(8)
            visible: !root.isImportSheetOpen

            // Header Bar
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(32)
                spacing: Scaler.s(6)

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
                    font.pixelSize: Scaler.s(14)
                    font.bold: true
                    color: ThemeBackend.text
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }

                // Progress Badge (e.g. "3/5")
                Rectangle {
                    visible: root.totalCount > 0
                    Layout.preferredHeight: Scaler.s(22)
                    Layout.preferredWidth: countLabel.implicitWidth + Scaler.s(12)
                    radius: Scaler.s(11)
                    color: Qt.alpha(ThemeBackend.surface1, 0.8)
                    border.width: 1
                    border.color: Qt.alpha(root.activeCount === 0 ? ThemeBackend.green : ThemeBackend.mauve, 0.35)

                    Text {
                        id: countLabel
                        anchors.centerIn: parent
                        text: root.completedCount + "/" + root.totalCount
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(10)
                        font.bold: true
                        color: root.activeCount === 0 ? ThemeBackend.green : ThemeBackend.subtext0
                    }
                }

                // Quick Import CSV button (Zenity file picker dialog)
                IconButton {
                    size: Scaler.s(28)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰈔"
                    iconFontSize: Scaler.s(14)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.blue
                    onClicked: root.pickAndImportCsv("merge")
                }

                // Quick Export CSV button
                IconButton {
                    size: Scaler.s(28)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰁆"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.subtext0
                    onClicked: root.pickAndExportCsv()
                }

                // Clear completed tasks button
                IconButton {
                    visible: root.completedCount > 0
                    size: Scaler.s(28)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰆴"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.red
                    onClicked: root.clearCompleted()
                }

                // Toggle Import / Settings Sheet
                IconButton {
                    size: Scaler.s(28)
                    cornerRadius: Scaler.s(7)
                    buttonIcon: "󰒓"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: root.isImportSheetOpen ? ThemeBackend.mauve : ThemeBackend.subtext0
                    onClicked: root.isImportSheetOpen = true
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

            // Quick Add Task Row
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
                        }

                        onAccepted: {
                            let val = taskInput.text.trim();
                            if (val !== "") {
                                root.addTodo(val, root.newPriority);
                                taskInput.text = "";
                            }
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: !taskInput.text && !taskInput.activeFocus
                            text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.new_placeholder", "Nuova attività... (premi Invio)") : "Nuova attività... (premi Invio)"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(11)
                            color: ThemeBackend.overlay1
                        }
                    }

                    // Priority toggle pill ("Normale" / "Alta")
                    Rectangle {
                        Layout.preferredHeight: Scaler.s(24)
                        Layout.preferredWidth: prioLabel.implicitWidth + Scaler.s(12)
                        radius: Scaler.s(6)
                        color: root.newPriority === "high" ? Qt.alpha(ThemeBackend.red, 0.25) : Qt.alpha(ThemeBackend.surface2, 0.5)
                        border.width: 1
                        border.color: root.newPriority === "high" ? ThemeBackend.red : Qt.alpha(ThemeBackend.surface2, 0.4)

                        Text {
                            id: prioLabel
                            anchors.centerIn: parent
                            text: root.newPriority === "high" ? "󰀦 Alta" : "Normale"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(9.5)
                            font.bold: true
                            color: root.newPriority === "high" ? ThemeBackend.red : ThemeBackend.subtext0
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.newPriority = root.newPriority === "high" ? "normal" : "high";
                            }
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
                                root.addTodo(val, root.newPriority);
                                taskInput.text = "";
                            }
                        }
                    }
                }
            }

            // Filter Pills (Tutte / Attive / Completate)
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(24)
                spacing: Scaler.s(6)

                Repeater {
                    model: [
                        { mode: 0, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_all", "Tutte") : "Tutte", count: root.totalCount },
                        { mode: 1, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_active", "Attive") : "Attive", count: root.activeCount },
                        { mode: 2, label: typeof I18n !== "undefined" ? I18n.t("widgets.todo.filter_done", "Completate") : "Completate", count: root.completedCount }
                    ]

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Scaler.s(22)
                        radius: Scaler.s(6)
                        color: root.filterMode === modelData.mode
                            ? Qt.alpha(ThemeBackend.mauve, 0.22)
                            : (filterMa.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.6) : "transparent")
                        border.width: 1
                        border.color: root.filterMode === modelData.mode ? Qt.alpha(ThemeBackend.mauve, 0.45) : Qt.alpha(ThemeBackend.surface2, 0.2)

                        Behavior on color { ColorAnimation { duration: 120 } }

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: Scaler.s(4)

                            Text {
                                text: modelData.label
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(10)
                                font.bold: root.filterMode === modelData.mode
                                color: root.filterMode === modelData.mode ? ThemeBackend.mauve : ThemeBackend.subtext0
                            }

                            Text {
                                visible: modelData.count > 0
                                text: "(" + modelData.count + ")"
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(9)
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

            // Task List
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: tasksView
                    anchors.fill: parent
                    clip: true
                    spacing: Scaler.s(5)
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.filteredList

                    delegate: Rectangle {
                        id: taskCard
                        width: tasksView.width
                        implicitHeight: taskContentRow.implicitHeight + Scaler.s(10)
                        radius: Scaler.s(7)
                        color: Qt.alpha(ThemeBackend.surface1, taskCardMa.containsMouse ? 0.75 : 0.5)
                        border.width: 1
                        border.color: Qt.alpha(ThemeBackend.surface2, taskCardMa.containsMouse ? 0.45 : 0.25)
                        opacity: modelData.completed ? 0.55 : 1.0

                        Behavior on color { ColorAnimation { duration: 120 } }
                        Behavior on opacity { NumberAnimation { duration: 150 } }

                        // Priority color indicator bar on left
                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: Scaler.s(3)
                            radius: Scaler.s(1.5)
                            color: {
                                if (modelData.priority === "high") return ThemeBackend.red;
                                if (modelData.priority === "low") return ThemeBackend.blue;
                                return ThemeBackend.mauve;
                            }
                        }

                        RowLayout {
                            id: taskContentRow
                            anchors.fill: parent
                            anchors.leftMargin: Scaler.s(8)
                            anchors.rightMargin: Scaler.s(6)
                            anchors.topMargin: Scaler.s(4)
                            anchors.bottomMargin: Scaler.s(4)
                            spacing: Scaler.s(8)

                            // Checkbox Button
                            Rectangle {
                                id: checkBtn
                                Layout.preferredWidth: Scaler.s(20)
                                Layout.preferredHeight: Scaler.s(20)
                                radius: Scaler.s(5)
                                color: modelData.completed ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface2, 0.4)
                                border.width: 1.5
                                border.color: modelData.completed ? ThemeBackend.mauve : ThemeBackend.subtext1

                                Behavior on color { ColorAnimation { duration: 120 } }

                                Text {
                                    anchors.centerIn: parent
                                    visible: Boolean(modelData.completed)
                                    text: "✓"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(11)
                                    font.bold: true
                                    color: ThemeBackend.crust
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleTodo(modelData.id)
                                }
                            }

                            // Task Text & Category
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Scaler.s(1)

                                Text {
                                    text: modelData.title || ""
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(11.5)
                                    font.strikeout: Boolean(modelData.completed)
                                    color: modelData.completed ? ThemeBackend.subtext0 : ThemeBackend.text
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                }

                                RowLayout {
                                    visible: (modelData.category && modelData.category !== "") || (modelData.due_date && modelData.due_date !== "")
                                    spacing: Scaler.s(4)

                                    Rectangle {
                                        visible: modelData.category && modelData.category !== ""
                                        Layout.preferredHeight: Scaler.s(16)
                                        Layout.preferredWidth: catLabel.implicitWidth + Scaler.s(8)
                                        radius: Scaler.s(4)
                                        color: Qt.alpha(ThemeBackend.surface2, 0.5)

                                        Text {
                                            id: catLabel
                                            anchors.centerIn: parent
                                            text: modelData.category || ""
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: Scaler.s(8.5)
                                            color: ThemeBackend.subtext1
                                        }
                                    }

                                    Text {
                                        visible: modelData.due_date && modelData.due_date !== ""
                                        text: "󰔛 " + modelData.due_date
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(8.5)
                                        color: ThemeBackend.subtext0
                                    }
                                }
                            }

                            // Delete Task Button (appears on hover)
                            IconButton {
                                visible: taskCardMa.containsMouse
                                size: Scaler.s(22)
                                cornerRadius: Scaler.s(5)
                                buttonIcon: "󰅖"
                                iconFontSize: Scaler.s(11)
                                accentColor: "transparent"
                                textColor: ThemeBackend.red
                                onClicked: root.deleteTodo(modelData.id)
                            }
                        }

                        MouseArea {
                            id: taskCardMa
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.NoButton
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
                                text: root.filterMode === 2 ? "󰄲" : "󰈔"
                                font.family: root.nerdFont
                                font.pixelSize: Scaler.s(28)
                                color: ThemeBackend.overlay0
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: {
                                    if (root.filterMode === 1) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_active", "Nessuna attività in sospeso!") : "Nessuna attività in sospeso!";
                                    if (root.filterMode === 2) return typeof I18n !== "undefined" ? I18n.t("widgets.todo.no_completed", "Nessuna attività completata") : "Nessuna attività completata";
                                    return typeof I18n !== "undefined" ? I18n.t("widgets.todo.empty", "Nessuna attività. Aggiungine una o importa un CSV.") : "Nessuna attività. Aggiungine una o importa un CSV.";
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
                                buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.btn_import_csv", "Importa CSV") : "Importa CSV"
                                accentColor: Qt.alpha(ThemeBackend.surface1, 0.8)
                                textColor: ThemeBackend.mauve
                                onClicked: root.pickAndImportCsv("merge")
                            }
                        }
                    }
                }
            }
        }

        // Inline Configuration & CSV Import/Export Sheet
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
                    text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.csv_manage_title", "Importa & Esporta CSV") : "Importa & Esporta CSV"
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
                text: typeof I18n !== "undefined" ? I18n.t("widgets.todo.csv_help", "Supporta CSV con intestazioni (title, done, priority, category) o elenchi semplici delimitati da virgola o punto e virgola.") : "Supporta CSV con intestazioni (title, done, priority, category) o elenchi semplici delimitati da virgola o punto e virgola."
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
                        }

                        onAccepted: {
                            if (pathInput.text.trim() !== "") {
                                root.importCsvPath(pathInput.text.trim(), root.importMode);
                            }
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: !pathInput.text && !pathInput.activeFocus
                            text: "~/Documenti/tasks.csv"
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

            // Export to CSV button
            ClickButton {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(32)
                cornerRadius: Scaler.s(6)
                buttonIcon: "󰁆"
                buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.todo.export_btn", "Esporta attività correnti in CSV") : "Esporta attività correnti in CSV"
                accentColor: Qt.alpha(ThemeBackend.surface1, 0.75)
                textColor: ThemeBackend.subtext0
                onClicked: root.pickAndExportCsv()
            }
        }
    }
}
