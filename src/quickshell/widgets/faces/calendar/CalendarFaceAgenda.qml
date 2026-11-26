import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "../../../reusables"
import "../../../"

/**
 * CalendarFaceAgenda (Widget B - Interactive Agenda & Tasks Widget)
 * Chronologically ordered list of events and tasks interconnected with
 * CalendarFaceMonth. Supports two-level interactivity:
 *  - Level 1: Local completion checkbox & archiving persisted in local cache,
 *             plus quick local task creation.
 *  - Level 2: Deep-link fallback to Google Calendar Web event editor/viewer.
 */
Item {
    id: root
    anchors.fill: parent
    clip: true

    property bool previewMode: false

    property real minWidth: Scaler.s(240)
    property real minHeight: Scaler.s(150)
    property real maxWidth: Scaler.s(900)
    property real maxHeight: Scaler.s(1000)
    property real minAspect: 0.45
    property real maxAspect: 3.5
    property bool isRound: false

    property bool isConfiguring: false
    property bool isAddingTask: false
    property string selectedCalColor: "#89b4fa"
    property bool wantsKeyboardFocus: !previewMode && (isConfiguring || isAddingTask)

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

    readonly property bool isDateFiltered: (typeof CalendarService !== "undefined") ? CalendarService.filterBySelectedDate : true

    readonly property var displayedEventsList: {
        if (typeof CalendarService === "undefined") return [];
        let dummy = CalendarService.eventsCount;
        let showArch = CalendarService.showArchived;
        if (CalendarService.filterBySelectedDate) {
            return CalendarService.getEventsForDate(
                CalendarService.selectedYear,
                CalendarService.selectedMonth + 1,
                CalendarService.selectedDay,
                showArch
            );
        }
        return CalendarService.getUpcomingEvents(25, showArch);
    }

    readonly property int completedCountInView: {
        let list = root.displayedEventsList;
        let c = 0;
        for (let i = 0; i < list.length; i++) {
            if (list[i].completed) c++;
        }
        return c;
    }

    readonly property string selectedHeaderTitle: {
        if (typeof CalendarService === "undefined") return "Agenda";
        if (!CalendarService.filterBySelectedDate) {
            return typeof I18n !== "undefined" ? I18n.t("widgets.calendar.upcoming", "Prossimi") : "Prossimi";
        }
        if (CalendarService.isSelectedToday) {
            try {
                let d = new Date(CalendarService.selectedYear, CalendarService.selectedMonth, CalendarService.selectedDay);
                let shortD = d.toLocaleDateString(Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "it"), "d MMM");
                let todayWord = typeof I18n !== "undefined" ? I18n.t("widgets.calendar.today", "Oggi") : "Oggi";
                return todayWord + ", " + shortD;
            } catch (e) {
                return typeof I18n !== "undefined" ? I18n.t("widgets.calendar.today", "Oggi") : "Oggi";
            }
        }
        try {
            let d = new Date(CalendarService.selectedYear, CalendarService.selectedMonth, CalendarService.selectedDay);
            return d.toLocaleDateString(Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "it"), "ddd d MMM");
        } catch (e) {
            return CalendarService.selectedDateStr;
        }
    }

    function formatEventDateHeader(dateStr) {
        if (!dateStr) return "";
        let today = new Date();
        let todayStr = today.getFullYear() + "-"
            + String(today.getMonth() + 1).padStart(2, "0") + "-"
            + String(today.getDate()).padStart(2, "0");

        let tmrw = new Date();
        tmrw.setDate(tmrw.getDate() + 1);
        let tmrwStr = tmrw.getFullYear() + "-"
            + String(tmrw.getMonth() + 1).padStart(2, "0") + "-"
            + String(tmrw.getDate()).padStart(2, "0");

        if (dateStr === todayStr) {
            return typeof I18n !== "undefined" ? I18n.t("widgets.calendar.today", "Oggi") : "Oggi";
        }
        if (dateStr === tmrwStr) {
            return typeof I18n !== "undefined" ? I18n.t("widgets.calendar.tomorrow", "Domani") : "Domani";
        }

        try {
            let parts = dateStr.split("-");
            let d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
            return d.toLocaleDateString(Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "it"), "ddd d MMM");
        } catch (e) {
            return dateStr;
        }
    }

    function submitQuickTask() {
        let title = newTaskTitleInput.text.trim();
        let timeStr = newTaskTimeInput.text.trim();
        if (title !== "" && typeof CalendarService !== "undefined") {
            CalendarService.addLocalTask(title, CalendarService.selectedDateStr, timeStr);
            newTaskTitleInput.text = "";
            newTaskTimeInput.text = "";
            root.isAddingTask = false;
            root.setKeyboardFocus(false);
        }
    }

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

        // Main Agenda & Tasks View
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(13)
            spacing: Scaler.s(8)
            visible: !root.isConfiguring

            // Header Bar
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(28)
                spacing: Scaler.s(4)

                // Selected Day / Mode Pill (click to toggle Selected Day vs All Upcoming)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(26)
                    radius: Scaler.s(8)
                    color: modeToggleMa.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.7) : "transparent"
                    Behavior on color { ColorAnimation { duration: 130 } }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Scaler.s(4)
                        anchors.rightMargin: Scaler.s(4)
                        spacing: Scaler.s(5)

                        Text {
                            text: root.selectedHeaderTitle
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(13)
                            font.weight: Font.Black
                            color: ThemeBackend.text
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }

                        Rectangle {
                            Layout.preferredHeight: Scaler.s(19)
                            Layout.preferredWidth: countBadgeText.implicitWidth + Scaler.s(10)
                            radius: Scaler.s(9.5)
                            color: Qt.alpha(ThemeBackend.mauve, 0.18)

                            Text {
                                id: countBadgeText
                                anchors.centerIn: parent
                                text: String(root.displayedEventsList.length)
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(9.5)
                                font.bold: true
                                color: ThemeBackend.mauve
                            }
                        }
                    }

                    MouseArea {
                        id: modeToggleMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.filterBySelectedDate = !CalendarService.filterBySelectedDate;
                            }
                        }
                    }
                }

                // Prev Day step button
                IconButton {
                    visible: root.isDateFiltered
                    size: Scaler.s(24)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰅁"
                    iconFontSize: Scaler.s(12)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.subtext0
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.stepSelectedDate(-1);
                        }
                    }
                }

                // Next Day step button
                IconButton {
                    visible: root.isDateFiltered
                    size: Scaler.s(24)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰅂"
                    iconFontSize: Scaler.s(12)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.subtext0
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.stepSelectedDate(1);
                        }
                    }
                }

                // Jump back to "Oggi" button when viewing another day
                IconButton {
                    visible: typeof CalendarService !== "undefined" && (!CalendarService.isSelectedToday || !CalendarService.filterBySelectedDate)
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰁝"
                    iconFontSize: Scaler.s(12)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.mauve
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.resetSelectionToToday(true);
                        }
                    }
                }

                // Clear completed tasks button
                IconButton {
                    visible: root.completedCountInView > 0
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰃢"
                    iconFontSize: Scaler.s(12)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.peach
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.clearCompletedTasks();
                        }
                    }
                }

                // Add Event / Task button
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: root.isAddingTask ? "󰅖" : "󰐕"
                    iconFontSize: Scaler.s(13)
                    accentColor: root.isAddingTask ? ThemeBackend.mauve : ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: root.isAddingTask ? ThemeBackend.crust : ThemeBackend.mauve
                    onClicked: {
                        root.isAddingTask = !root.isAddingTask;
                        root.setKeyboardFocus(root.isAddingTask);
                        if (root.isAddingTask) {
                            newTaskTitleInput.forceActiveFocus();
                        }
                    }
                }

                // Show/Hide Archived button
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰀼"
                    iconFontSize: Scaler.s(12)
                    accentColor: (typeof CalendarService !== "undefined" && CalendarService.showArchived)
                        ? Qt.alpha(ThemeBackend.mauve, 0.25)
                        : ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: (typeof CalendarService !== "undefined" && CalendarService.showArchived)
                        ? ThemeBackend.mauve
                        : ThemeBackend.subtext0
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.showArchived = !CalendarService.showArchived;
                        }
                    }
                }

                // Open Google Calendar Web
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰊭"
                    iconFontSize: Scaler.s(12)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.sapphire !== undefined ? ThemeBackend.sapphire : ThemeBackend.blue
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.openGoogleCalendarWeb(
                                CalendarService.selectedYear,
                                CalendarService.selectedMonth,
                                CalendarService.selectedDay
                            );
                        }
                    }
                }

                // Manual Async Sync button with rotation feedback
                Item {
                    Layout.preferredWidth: Scaler.s(26)
                    Layout.preferredHeight: Scaler.s(26)

                    IconButton {
                        id: agendaSyncBtn
                        anchors.fill: parent
                        size: Scaler.s(26)
                        cornerRadius: Scaler.s(8)
                        buttonIcon: "󰑐"
                        iconFontSize: Scaler.s(12)
                        accentColor: ThemeBackend.surface1
                        bgOpacity: ThemeBackend.elementOpacity
                        textColor: (typeof CalendarService !== "undefined" && CalendarService.isLoading) ? ThemeBackend.mauve : ThemeBackend.subtext0
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.sync(true, true);
                            }
                        }
                    }

                    RotationAnimator {
                        target: agendaSyncBtn
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                        running: typeof CalendarService !== "undefined" && CalendarService.isLoading
                        onStopped: agendaSyncBtn.rotation = 0
                    }
                }

                // Configure Calendars button
                IconButton {
                    size: Scaler.s(26)
                    cornerRadius: Scaler.s(8)
                    buttonIcon: "󰒓"
                    iconFontSize: Scaler.s(12)
                    accentColor: ThemeBackend.surface1
                    bgOpacity: ThemeBackend.elementOpacity
                    textColor: ThemeBackend.subtext0
                    onClicked: {
                        root.isAddingTask = false;
                        root.isConfiguring = true;
                        root.setKeyboardFocus(true);
                    }
                }
            }

            // Quick Add Task / Google Calendar Event Bar
            Rectangle {
                visible: root.isAddingTask
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(34)
                radius: Scaler.s(8)
                color: Qt.alpha(ThemeBackend.surface1, 0.78)
                border.width: 1
                border.color: Qt.alpha(ThemeBackend.mauve, 0.45)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Scaler.s(8)
                    anchors.rightMargin: Scaler.s(4)
                    spacing: Scaler.s(5)

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        TextInput {
                            id: newTaskTitleInput
                            anchors.fill: parent
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(11)
                            color: ThemeBackend.text
                            selectByMouse: true
                            clip: true
                            onAccepted: root.submitQuickTask()
                            onActiveFocusChanged: {
                                if (activeFocus) root.setKeyboardFocus(true);
                            }

                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                visible: !newTaskTitleInput.text
                                text: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.new_task_placeholder", "Nuova attività o impegno...") : "Nuova attività o impegno..."
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(10.5)
                                color: ThemeBackend.overlay0
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            cursorShape: Qt.IBeamCursor
                            onPressed: (mouse) => {
                                root.setKeyboardFocus(true);
                                newTaskTitleInput.forceActiveFocus();
                                mouse.accepted = false;
                            }
                        }
                    }

                    Rectangle {
                        Layout.preferredWidth: Scaler.s(48)
                        Layout.preferredHeight: Scaler.s(24)
                        radius: Scaler.s(5)
                        color: Qt.alpha(ThemeBackend.surface0, 0.7)

                        TextInput {
                            id: newTaskTimeInput
                            anchors.fill: parent
                            horizontalAlignment: TextInput.AlignHCenter
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            color: ThemeBackend.subtext0
                            selectByMouse: true
                            onAccepted: root.submitQuickTask()
                            onActiveFocusChanged: {
                                if (activeFocus) root.setKeyboardFocus(true);
                            }

                            Text {
                                anchors.centerIn: parent
                                visible: !newTaskTimeInput.text
                                text: "HH:MM"
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(9.5)
                                color: ThemeBackend.overlay0
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            cursorShape: Qt.IBeamCursor
                            onPressed: (mouse) => {
                                root.setKeyboardFocus(true);
                                newTaskTimeInput.forceActiveFocus();
                                mouse.accepted = false;
                            }
                        }
                    }

                    // Save Local Task (Level 1)
                    IconButton {
                        size: Scaler.s(26)
                        cornerRadius: Scaler.s(6)
                        buttonIcon: "󰄬"
                        iconFontSize: Scaler.s(13)
                        accentColor: ThemeBackend.green
                        textColor: ThemeBackend.crust
                        onClicked: root.submitQuickTask()
                    }

                    // Create on Google Calendar Web (Level 2 Deep-link)
                    IconButton {
                        size: Scaler.s(26)
                        cornerRadius: Scaler.s(6)
                        buttonIcon: "󰊭"
                        iconFontSize: Scaler.s(12)
                        accentColor: ThemeBackend.sapphire !== undefined ? ThemeBackend.sapphire : ThemeBackend.blue
                        textColor: ThemeBackend.crust
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.openGoogleCalendarNewEvent(
                                    CalendarService.selectedYear,
                                    CalendarService.selectedMonth,
                                    CalendarService.selectedDay,
                                    newTaskTitleInput.text.trim()
                                );
                            }
                            newTaskTitleInput.text = "";
                            root.isAddingTask = false;
                            root.setKeyboardFocus(false);
                        }
                    }
                }
            }

            // Events & Tasks List
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Scaler.s(6)
                model: root.displayedEventsList

                delegate: Rectangle {
                    id: eventItem
                    width: parent ? parent.width : Scaler.s(260)
                    implicitHeight: Math.max(Scaler.s(42), itemRow.implicitHeight + Scaler.s(12))
                    color: itemMa.containsMouse
                        ? Qt.alpha(ThemeBackend.surface2, 0.72)
                        : Qt.alpha(ThemeBackend.surface1, 0.55)
                    radius: Scaler.s(8)
                    border.width: 1
                    border.color: itemMa.containsMouse
                        ? Qt.alpha(modelData.calendar_color || ThemeBackend.mauve, 0.45)
                        : Qt.alpha(ThemeBackend.surface2, 0.28)
                    opacity: modelData.archived ? 0.45 : (modelData.completed ? 0.62 : 1.0)

                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on opacity { NumberAnimation { duration: 150 } }

                    // Colored left indicator strip
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Scaler.s(4)
                        radius: Scaler.s(2)
                        color: modelData.completed ? ThemeBackend.green : (modelData.calendar_color || ThemeBackend.blue)
                    }

                    // Background click opens event in Google Calendar Web (Level 2)
                    MouseArea {
                        id: itemMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.openGoogleCalendarEvent(modelData);
                            }
                        }
                    }

                    RowLayout {
                        id: itemRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Scaler.s(10)
                        anchors.rightMargin: Scaler.s(6)
                        spacing: Scaler.s(8)

                        // Level 1: Interactive Completion Checkbox
                        Rectangle {
                            Layout.preferredWidth: Scaler.s(22)
                            Layout.preferredHeight: Scaler.s(22)
                            Layout.alignment: Qt.AlignVCenter
                            radius: Scaler.s(6)
                            color: modelData.completed
                                ? Qt.alpha(ThemeBackend.green, 0.22)
                                : (checkMa.containsMouse ? Qt.alpha(ThemeBackend.surface2, 0.8) : Qt.alpha(ThemeBackend.surface0, 0.6))
                            border.width: 1.5
                            border.color: modelData.completed
                                ? ThemeBackend.green
                                : (checkMa.containsMouse ? ThemeBackend.mauve : ThemeBackend.overlay0)

                            Text {
                                anchors.centerIn: parent
                                text: modelData.completed ? "󰄬" : ""
                                font.family: ThemeBackend.iconFont
                                font.pixelSize: Scaler.s(12)
                                color: ThemeBackend.green
                            }

                            MouseArea {
                                id: checkMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof CalendarService !== "undefined") {
                                        CalendarService.toggleEventCompleted(modelData.id);
                                    }
                                }
                            }
                        }

                        // Event / Task Details Column
                        ColumnLayout {
                            id: itemCol
                            Layout.fillWidth: true
                            spacing: Scaler.s(2)

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Scaler.s(4)

                                Text {
                                    text: root.formatEventDateHeader(modelData.date)
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9.5)
                                    font.bold: true
                                    color: modelData.completed ? ThemeBackend.green : ThemeBackend.mauve
                                }

                                Text {
                                    text: "•"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9)
                                    color: ThemeBackend.overlay0
                                }

                                Text {
                                    text: modelData.time_str
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9.5)
                                    color: ThemeBackend.subtext0
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                text: modelData.title
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(11.5)
                                font.bold: true
                                font.strikeout: Boolean(modelData.completed)
                                color: modelData.completed ? ThemeBackend.subtext0 : ThemeBackend.text
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }

                            Text {
                                visible: modelData.location !== ""
                                text: "📍 " + modelData.location
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(9)
                                color: ThemeBackend.overlay1
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                maximumLineCount: 1
                            }
                        }

                        // Action Buttons: Edit/Open in Google Calendar (Level 2) & Archive/Delete (Level 1)
                        RowLayout {
                            spacing: Scaler.s(3)
                            Layout.alignment: Qt.AlignVCenter
                            opacity: (itemMa.containsMouse || openGcalBtn.isHoveredOrHighlighted || archiveBtn.isHoveredOrHighlighted) ? 1.0 : 0.65
                            Behavior on opacity { NumberAnimation { duration: 140 } }

                            IconButton {
                                id: openGcalBtn
                                size: Scaler.s(24)
                                cornerRadius: Scaler.s(6)
                                buttonIcon: "󰏌"
                                iconFontSize: Scaler.s(11)
                                accentColor: ThemeBackend.surface0
                                bgOpacity: 0.7
                                textColor: ThemeBackend.sapphire !== undefined ? ThemeBackend.sapphire : ThemeBackend.blue
                                onClicked: {
                                    if (typeof CalendarService !== "undefined") {
                                        CalendarService.openGoogleCalendarEvent(modelData);
                                    }
                                }
                            }

                            IconButton {
                                id: archiveBtn
                                size: Scaler.s(24)
                                cornerRadius: Scaler.s(6)
                                buttonIcon: modelData.is_local_task ? "󰅖" : (modelData.archived ? "󰦛" : "󰀼")
                                iconFontSize: Scaler.s(11)
                                accentColor: ThemeBackend.surface0
                                bgOpacity: 0.7
                                textColor: modelData.is_local_task ? ThemeBackend.red : ThemeBackend.subtext0
                                onClicked: {
                                    if (typeof CalendarService !== "undefined") {
                                        if (modelData.is_local_task) {
                                            CalendarService.removeLocalTask(modelData.id);
                                        } else {
                                            CalendarService.toggleEventArchived(modelData.id);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Empty state
                Item {
                    anchors.fill: parent
                    visible: root.displayedEventsList.length === 0

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: Scaler.s(6)

                        Text {
                            text: "󰃭"
                            font.family: ThemeBackend.iconFont
                            font.pixelSize: Scaler.s(28)
                            color: ThemeBackend.overlay0
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: root.isDateFiltered
                                ? (typeof I18n !== "undefined" ? I18n.t("widgets.calendar.no_events_day", "Nessun impegno per questa giornata") : "Nessun impegno per questa giornata")
                                : (typeof I18n !== "undefined" ? I18n.t("calendar.no_events", "Nessun impegno in programma") : "Nessun impegno in programma")
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10.5)
                            color: ThemeBackend.subtext0
                            Layout.alignment: Qt.AlignHCenter
                        }

                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: Scaler.s(6)

                            ClickButton {
                                visible: root.isDateFiltered
                                height: Scaler.s(26)
                                cornerRadius: Scaler.s(6)
                                buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.show_upcoming", "Mostra prossimi") : "Mostra prossimi"
                                accentColor: ThemeBackend.surface1
                                textColor: ThemeBackend.text
                                onClicked: {
                                    if (typeof CalendarService !== "undefined") {
                                        CalendarService.filterBySelectedDate = false;
                                    }
                                }
                            }

                            ClickButton {
                                height: Scaler.s(26)
                                cornerRadius: Scaler.s(6)
                                buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.add_event", "+ Aggiungi") : "+ Aggiungi"
                                accentColor: ThemeBackend.surface1
                                textColor: ThemeBackend.mauve
                                onClicked: {
                                    root.isAddingTask = true;
                                    root.setKeyboardFocus(true);
                                    newTaskTitleInput.forceActiveFocus();
                                }
                            }
                        }
                    }
                }
            }
        }

        // Inline Configuration Sheet (Google Calendar & ICS management)
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(12)
            spacing: Scaler.s(8)
            visible: root.isConfiguring

            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Text {
                    text: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.manage_calendars", "Manage Calendars") : "Manage Calendars"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(13)
                    font.bold: true
                    color: ThemeBackend.text
                    Layout.fillWidth: true
                }

                IconButton {
                    size: Scaler.s(28)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: "󰅖"
                    iconFontSize: Scaler.s(14)
                    accentColor: ThemeBackend.surface1
                    textColor: ThemeBackend.subtext0
                    onClicked: {
                        root.isConfiguring = false;
                        root.setKeyboardFocus(false);
                    }
                }
            }

            Text {
                text: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.gcal_help", "Google Calendar: Settings > Integrate calendar > Secret address in iCal format") : "Google Calendar: Settings > Integrate calendar > Secret address in iCal format"
                font.family: ThemeBackend.fontFamily
                font.pixelSize: Scaler.s(9.5)
                color: ThemeBackend.overlay1
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Rectangle {
                    Layout.preferredWidth: Scaler.s(85)
                    Layout.preferredHeight: Scaler.s(30)
                    color: Qt.alpha(ThemeBackend.surface1, 0.8)
                    radius: Scaler.s(6)
                    clip: true

                    TextInput {
                        id: calNameInput
                        anchors.fill: parent
                        anchors.margins: Scaler.s(6)
                        verticalAlignment: TextInput.AlignVCenter
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(10.5)
                        color: ThemeBackend.text
                        text: "Google"
                        selectByMouse: true
                        onActiveFocusChanged: {
                            if (activeFocus) root.setKeyboardFocus(true);
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.IBeamCursor
                        onPressed: (mouse) => {
                            root.setKeyboardFocus(true);
                            calNameInput.forceActiveFocus();
                            mouse.accepted = false;
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(30)
                    color: Qt.alpha(ThemeBackend.surface1, 0.8)
                    radius: Scaler.s(6)
                    clip: true

                    TextInput {
                        id: calUrlInput
                        anchors.fill: parent
                        anchors.margins: Scaler.s(6)
                        verticalAlignment: TextInput.AlignVCenter
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(10)
                        color: ThemeBackend.text
                        selectByMouse: true
                        onActiveFocusChanged: {
                            if (activeFocus) root.setKeyboardFocus(true);
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            visible: !calUrlInput.text
                            text: "https://calendar.google.com/.../basic.ics"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            color: ThemeBackend.overlay0
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        cursorShape: Qt.IBeamCursor
                        onPressed: (mouse) => {
                            root.setKeyboardFocus(true);
                            calUrlInput.forceActiveFocus();
                            mouse.accepted = false;
                        }
                    }
                }

                IconButton {
                    size: Scaler.s(30)
                    cornerRadius: Scaler.s(6)
                    buttonIcon: "󰐕"
                    iconFontSize: Scaler.s(14)
                    accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.crust
                    onClicked: {
                        let u = calUrlInput.text.trim();
                        let n = calNameInput.text.trim();
                        if (u !== "") {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.addCalendar(n !== "" ? n : "Google Calendar", u, root.selectedCalColor);
                            }
                            calUrlInput.text = "";
                        }
                    }
                }
            }

            // Color picker row for new calendar feeds
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Text {
                    text: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.feed_color", "Colore:") : "Colore:"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(9.5)
                    color: ThemeBackend.subtext0
                }

                Repeater {
                    model: ["#89b4fa", "#cba6f7", "#a6e3a1", "#fab387", "#f38ba8", "#f9e2af", "#94e2d5"]

                    Rectangle {
                        width: Scaler.s(18)
                        height: Scaler.s(18)
                        radius: Scaler.s(9)
                        color: modelData
                        border.width: root.selectedCalColor === modelData ? 2 : 0
                        border.color: ThemeBackend.text

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectedCalColor = modelData
                        }
                    }
                }

                Item { Layout.fillWidth: true }
            }

            // Error notice if sync had an issue
            Text {
                visible: typeof CalendarService !== "undefined" && CalendarService.lastError !== ""
                text: "󰀦 " + (typeof CalendarService !== "undefined" ? CalendarService.lastError : "")
                font.family: ThemeBackend.fontFamily
                font.pixelSize: Scaler.s(9.5)
                color: ThemeBackend.red
                Layout.fillWidth: true
                elide: Text.ElideRight
            }

            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Scaler.s(4)
                model: (typeof CalendarService !== "undefined" && CalendarService.calendars) ? CalendarService.calendars : []

                delegate: Rectangle {
                    width: parent ? parent.width : Scaler.s(240)
                    height: Scaler.s(32)
                    color: Qt.alpha(ThemeBackend.surface1, 0.75)
                    radius: Scaler.s(6)

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Scaler.s(8)
                        anchors.rightMargin: Scaler.s(6)
                        spacing: Scaler.s(6)

                        Rectangle {
                            width: Scaler.s(8)
                            height: Scaler.s(8)
                            radius: Scaler.s(4)
                            color: modelData.color || ThemeBackend.blue
                        }

                        Text {
                            text: (modelData.name || "Calendar") + (modelData.cached ? " 󰋊" : "")
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10.5)
                            font.bold: true
                            color: ThemeBackend.text
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }

                        IconButton {
                            size: Scaler.s(24)
                            cornerRadius: Scaler.s(4)
                            buttonIcon: "󰅖"
                            iconFontSize: Scaler.s(11)
                            accentColor: "transparent"
                            textColor: ThemeBackend.red
                            onClicked: {
                                if (typeof CalendarService !== "undefined") {
                                    CalendarService.removeCalendar(modelData.id || modelData.url);
                                }
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
                    height: Scaler.s(30)
                    cornerRadius: Scaler.s(6)
                    buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.sync_now", "Sync Now") : "Sync Now"
                    accentColor: ThemeBackend.mauve
                    textColor: ThemeBackend.crust
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.sync(true, true);
                        }
                        root.isConfiguring = false;
                        root.setKeyboardFocus(false);
                    }
                }
            }
        }
    }
}
