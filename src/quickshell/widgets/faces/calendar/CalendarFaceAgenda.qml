import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "../../../reusables"
import "../../../"

Item {
    id: root
    anchors.fill: parent
    clip: true

    property real minWidth: Scaler.s(240)
    property real minHeight: Scaler.s(160)
    property real maxWidth: Scaler.s(900)
    property real maxHeight: Scaler.s(1000)
    property real minAspect: 0.5
    property real maxAspect: 3.5
    property bool isRound: false

    property bool isConfiguring: false
    property bool wantsKeyboardFocus: isConfiguring

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
        } catch(e) {}
    }

    readonly property var upcomingEventsList: {
        if (typeof CalendarService === "undefined") return [];
        return CalendarService.getUpcomingEvents(20);
    }

    function formatEventDateHeader(dateStr) {
        if (!dateStr) return "";
        let today = new Date();
        let todayStr = today.getFullYear() + "-"
            + String(today.getMonth() + 1).padStart(2, '0') + "-"
            + String(today.getDate()).padStart(2, '0');

        let tmrw = new Date();
        tmrw.setDate(tmrw.getDate() + 1);
        let tmrwStr = tmrw.getFullYear() + "-"
            + String(tmrw.getMonth() + 1).padStart(2, '0') + "-"
            + String(tmrw.getDate()).padStart(2, '0');

        if (dateStr === todayStr) {
            return typeof I18n !== "undefined" ? I18n.t("widgets.calendar.today", "Today") : "Today";
        }
        if (dateStr === tmrwStr) {
            return typeof I18n !== "undefined" ? I18n.t("widgets.calendar.tomorrow", "Tomorrow") : "Tomorrow";
        }

        try {
            let parts = dateStr.split("-");
            let d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
            return d.toLocaleDateString(Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "en"), "dddd, d MMM");
        } catch (e) {
            return dateStr;
        }
    }

    Rectangle {
        id: bgCard
        anchors.fill: parent
        color: ThemeBackend.surface0
        radius: ThemeBackend.clampedBorderRadius !== undefined ? ThemeBackend.clampedBorderRadius : ThemeBackend.borderRadius
        clip: true

        // Main Agenda View
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(12)
            spacing: Scaler.s(8)
            visible: !root.isConfiguring

            // Header Bar
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: Scaler.s(32)
                spacing: Scaler.s(6)

                Text {
                    text: "󰃭"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(16)
                    color: ThemeBackend.mauve
                }

                Text {
                    text: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.agenda_title", "Agenda") : "Agenda"
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(13)
                    font.bold: true
                    color: ThemeBackend.text
                    Layout.fillWidth: true
                }

                IconButton {
                    size: Scaler.s(28)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: "󰑐"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    textColor: (typeof CalendarService !== "undefined" && CalendarService.isLoading) ? ThemeBackend.mauve : ThemeBackend.subtext0
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.sync(true, true);
                        }
                    }
                }

                // Offline / Cached indicator badge
                Rectangle {
                    visible: typeof CalendarService !== "undefined" && CalendarService.isCached
                    Layout.preferredHeight: Scaler.s(24)
                    Layout.preferredWidth: Scaler.s(24)
                    radius: Scaler.s(12)
                    color: Qt.rgba(ThemeBackend.peach.r, ThemeBackend.peach.g, ThemeBackend.peach.b, 0.2)

                    Text {
                        anchors.centerIn: parent
                        text: "󰋊"
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(12)
                        color: ThemeBackend.peach
                    }
                }

                IconButton {
                    size: Scaler.s(28)
                    cornerRadius: ThemeBackend.borderRadius
                    buttonIcon: "󰒓"
                    iconFontSize: Scaler.s(13)
                    accentColor: ThemeBackend.surface1
                    textColor: ThemeBackend.subtext0
                    onClicked: {
                        root.isConfiguring = true;
                        root.setKeyboardFocus(true);
                    }
                }
            }

            // Events List
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Scaler.s(6)
                model: root.upcomingEventsList

                delegate: Rectangle {
                    id: eventItem
                    width: parent ? parent.width : Scaler.s(260)
                    implicitHeight: itemCol.implicitHeight + Scaler.s(14)
                    color: itemMa.containsMouse ? ThemeBackend.surface2 : ThemeBackend.surface1
                    radius: Scaler.s(8)

                    Behavior on color { ColorAnimation { duration: 120 } }

                    // Colored left indicator strip
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Scaler.s(4)
                        radius: Scaler.s(2)
                        color: modelData.calendar_color || ThemeBackend.blue
                    }

                    ColumnLayout {
                        id: itemCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: Scaler.s(12)
                        anchors.rightMargin: Scaler.s(8)
                        anchors.topMargin: Scaler.s(6)
                        spacing: Scaler.s(2)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Scaler.s(4)

                            Text {
                                text: root.formatEventDateHeader(modelData.date)
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: Scaler.s(10)
                                font.bold: true
                                color: ThemeBackend.mauve
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
                            }
                        }

                        Text {
                            text: modelData.title
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(11.5)
                            font.bold: true
                            color: ThemeBackend.text
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

                    MouseArea {
                        id: itemMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                    }
                }

                // Empty state
                Item {
                    anchors.fill: parent
                    visible: root.upcomingEventsList.length === 0

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: Scaler.s(6)

                        Text {
                            text: "󰃭"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(32)
                            color: ThemeBackend.overlay0
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: typeof I18n !== "undefined" ? I18n.t("calendar.no_events", "No scheduled events.") : "No scheduled events."
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(11)
                            color: ThemeBackend.subtext0
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            visible: typeof CalendarService !== "undefined" && CalendarService.lastError !== ""
                            text: "⚠️ " + (typeof CalendarService !== "undefined" ? CalendarService.lastError : "")
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            color: ThemeBackend.red
                            Layout.alignment: Qt.AlignHCenter
                            Layout.maximumWidth: root.width - Scaler.s(40)
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Text {
                            visible: typeof CalendarService !== "undefined" && CalendarService.lastError === "" && CalendarService.lastWarning !== ""
                            text: "ℹ️ " + (typeof CalendarService !== "undefined" ? CalendarService.lastWarning : "")
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(9.5)
                            color: ThemeBackend.peach
                            Layout.alignment: Qt.AlignHCenter
                            Layout.maximumWidth: root.width - Scaler.s(40)
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }

                        ClickButton {
                            Layout.alignment: Qt.AlignHCenter
                            height: Scaler.s(28)
                            cornerRadius: Scaler.s(6)
                            buttonText: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.add_calendar", "Add Calendar") : "Add Calendar"
                            accentColor: ThemeBackend.surface1
                            textColor: ThemeBackend.mauve
                            onClicked: {
                                root.isConfiguring = true;
                                root.setKeyboardFocus(true);
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

            // Inputs for adding a new calendar
            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(6)

                Rectangle {
                    Layout.preferredWidth: Scaler.s(90)
                    Layout.preferredHeight: Scaler.s(30)
                    color: ThemeBackend.surface1
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
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(30)
                    color: ThemeBackend.surface1
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
                                CalendarService.addCalendar(n !== "" ? n : "Google Calendar", u, "#89b4fa");
                            }
                            calUrlInput.text = "";
                        }
                    }
                }
            }

            // List of configured calendars
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Scaler.s(4)
                model: (typeof CalendarService !== "undefined" && CalendarService.calendars) ? CalendarService.calendars : []

                delegate: Rectangle {
                    width: parent ? parent.width : Scaler.s(240)
                    height: Scaler.s(32)
                    color: ThemeBackend.surface1
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
                            text: modelData.name || "Calendar"
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

            // Bottom action row
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
                            CalendarService.sync(true);
                        }
                        root.isConfiguring = false;
                        root.setKeyboardFocus(false);
                    }
                }
            }
        }
    }
}
