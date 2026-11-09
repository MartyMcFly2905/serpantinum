import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import "../../../reusables"
import "../../../"

/**
 * CalendarFaceMonth (Widget A - Full Calendar Month View)
 * Glassmorphic monthly grid widget with event indicator dots, fast month/today
 * navigation, direct Google Calendar Web launcher, and interconnected day
 * filtering with CalendarFaceAgenda.
 */
Item {
    id: root
    anchors.fill: parent
    clip: true

    property real minWidth: Scaler.s(250)
    property real minHeight: Scaler.s(210)
    property real maxWidth: Scaler.s(1200)
    property real maxHeight: Scaler.s(900)
    property real minAspect: 0.6
    property real maxAspect: 3.2
    property bool isRound: false

    property int monthOffset: 0
    readonly property int selectedDay: (typeof CalendarService !== "undefined") ? CalendarService.selectedDay : new Date().getDate()
    readonly property int selectedMonth: (typeof CalendarService !== "undefined") ? CalendarService.selectedMonth : new Date().getMonth()
    readonly property int selectedYear: (typeof CalendarService !== "undefined") ? CalendarService.selectedYear : new Date().getFullYear()

    property bool isConfiguring: false
    property string selectedCalColor: "#89b4fa"
    property bool wantsKeyboardFocus: isConfiguring

    readonly property bool isWide: root.width >= Scaler.s(520)

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

    readonly property var currentMonthDate: {
        let d = new Date();
        d.setDate(1);
        d.setMonth(d.getMonth() + root.monthOffset);
        return d;
    }

    readonly property int displayYear: currentMonthDate.getFullYear()
    readonly property int displayMonth: currentMonthDate.getMonth()
    readonly property string displayMonthTitle: {
        try {
            let loc = Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "it");
            let mName = loc.standaloneMonthName(displayMonth, Locale.LongFormat);
            return mName.charAt(0).toUpperCase() + mName.slice(1) + " " + displayYear;
        } catch (e) {
            return currentMonthDate.toLocaleDateString(Qt.locale(), "MMMM yyyy");
        }
    }

    ListModel {
        id: monthDaysModel
    }

    function refreshDaysGrid() {
        monthDaysModel.clear();
        let targetYear = root.displayYear;
        let targetMonth = root.displayMonth;

        let actualToday = new Date();
        let isRealCurrentMonth = (actualToday.getMonth() === targetMonth && actualToday.getFullYear() === targetYear);
        let todayDate = actualToday.getDate();

        let firstDay = new Date(targetYear, targetMonth, 1).getDay();
        firstDay = (firstDay === 0) ? 6 : firstDay - 1; // Mon = 0, Sun = 6

        let daysInMonth = new Date(targetYear, targetMonth + 1, 0).getDate();
        let daysInPrevMonth = new Date(targetYear, targetMonth, 0).getDate();

        // Prev month padding
        for (let i = firstDay - 1; i >= 0; i--) {
            let prevDay = daysInPrevMonth - i;
            let prevD = new Date(targetYear, targetMonth - 1, prevDay);
            let hasEvs = typeof CalendarService !== "undefined" ? CalendarService.hasEventsOnDate(prevD.getFullYear(), prevD.getMonth() + 1, prevDay) : false;
            let evColors = typeof CalendarService !== "undefined" ? CalendarService.getEventColorsForDate(prevD.getFullYear(), prevD.getMonth() + 1, prevDay) : [];
            monthDaysModel.append({
                dayNum: prevDay,
                year: prevD.getFullYear(),
                month: prevD.getMonth(),
                isCurrentMonth: false,
                isToday: false,
                hasEvents: hasEvs,
                color0: evColors.length > 0 ? evColors[0] : "",
                color1: evColors.length > 1 ? evColors[1] : "",
                color2: evColors.length > 2 ? evColors[2] : ""
            });
        }

        // Current month days
        for (let i = 1; i <= daysInMonth; i++) {
            let hasEvs = typeof CalendarService !== "undefined" ? CalendarService.hasEventsOnDate(targetYear, targetMonth + 1, i) : false;
            let evColors = typeof CalendarService !== "undefined" ? CalendarService.getEventColorsForDate(targetYear, targetMonth + 1, i) : [];
            monthDaysModel.append({
                dayNum: i,
                year: targetYear,
                month: targetMonth,
                isCurrentMonth: true,
                isToday: (isRealCurrentMonth && i === todayDate),
                hasEvents: hasEvs,
                color0: evColors.length > 0 ? evColors[0] : "",
                color1: evColors.length > 1 ? evColors[1] : "",
                color2: evColors.length > 2 ? evColors[2] : ""
            });
        }

        // Next month padding to fill 42 cells (6 weeks)
        let remaining = 42 - monthDaysModel.count;
        for (let i = 1; i <= remaining; i++) {
            let nextD = new Date(targetYear, targetMonth + 1, i);
            let hasEvs = typeof CalendarService !== "undefined" ? CalendarService.hasEventsOnDate(nextD.getFullYear(), nextD.getMonth() + 1, i) : false;
            let evColors = typeof CalendarService !== "undefined" ? CalendarService.getEventColorsForDate(nextD.getFullYear(), nextD.getMonth() + 1, i) : [];
            monthDaysModel.append({
                dayNum: i,
                year: nextD.getFullYear(),
                month: nextD.getMonth(),
                isCurrentMonth: false,
                isToday: false,
                hasEvents: hasEvs,
                color0: evColors.length > 0 ? evColors[0] : "",
                color1: evColors.length > 1 ? evColors[1] : "",
                color2: evColors.length > 2 ? evColors[2] : ""
            });
        }
    }

    onMonthOffsetChanged: refreshDaysGrid()

    Connections {
        target: typeof CalendarService !== "undefined" ? CalendarService : null
        function onCalendarUpdated() {
            root.refreshDaysGrid();
        }
        function onSelectedDateChanged() {
            if (typeof CalendarService !== "undefined") {
                let now = new Date();
                let targetOffset = (CalendarService.selectedYear - now.getFullYear()) * 12 + (CalendarService.selectedMonth - now.getMonth());
                if (root.monthOffset !== targetOffset) {
                    root.monthOffset = targetOffset;
                }
            }
        }
    }

    Component.onCompleted: {
        refreshDaysGrid();
    }

    readonly property var selectedDayEvents: {
        if (typeof CalendarService === "undefined") return [];
        let dummy = CalendarService.eventsCount;
        return CalendarService.getEventsForDate(root.selectedYear, root.selectedMonth + 1, root.selectedDay);
    }

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
        RowLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(12)
            spacing: Scaler.s(12)
            visible: !root.isConfiguring

            // Calendar Grid Column
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Scaler.s(6)

                // Header bar (Month title + Today + Prev/Next + Google Calendar Web + Sync + Config)
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(30)
                    spacing: Scaler.s(4)

                    Text {
                        text: root.displayMonthTitle
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(13.5)
                        font.weight: Font.Black
                        color: ThemeBackend.text
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    // "Oggi" (Today) quick pill button
                    Rectangle {
                        visible: root.monthOffset !== 0 || (typeof CalendarService !== "undefined" && !CalendarService.isSelectedToday)
                        Layout.preferredHeight: Scaler.s(26)
                        Layout.preferredWidth: todayBtnLabel.implicitWidth + Scaler.s(14)
                        radius: ThemeBackend.borderRadius
                        color: todayBtnMa.containsMouse ? ThemeBackend.mauve : Qt.alpha(ThemeBackend.surface1, 0.75)
                        border.width: 1
                        border.color: Qt.alpha(ThemeBackend.mauve, 0.45)

                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            id: todayBtnLabel
                            anchors.centerIn: parent
                            text: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.today", "Oggi") : "Oggi"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            font.bold: true
                            color: todayBtnMa.containsMouse ? ThemeBackend.crust : ThemeBackend.mauve
                        }

                        MouseArea {
                            id: todayBtnMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.monthOffset = 0;
                                if (typeof CalendarService !== "undefined") {
                                    CalendarService.resetSelectionToToday(true);
                                }
                            }
                        }
                    }

                    // Prev Month
                    IconButton {
                        size: Scaler.s(26)
                        cornerRadius: ThemeBackend.borderRadius
                        buttonIcon: "󰅁"
                        iconFontSize: Scaler.s(13)
                        accentColor: ThemeBackend.surface1
                        bgOpacity: ThemeBackend.elementOpacity
                        textColor: ThemeBackend.subtext0
                        onClicked: root.monthOffset--
                    }

                    // Next Month
                    IconButton {
                        size: Scaler.s(26)
                        cornerRadius: ThemeBackend.borderRadius
                        buttonIcon: "󰅂"
                        iconFontSize: Scaler.s(13)
                        accentColor: ThemeBackend.surface1
                        bgOpacity: ThemeBackend.elementOpacity
                        textColor: ThemeBackend.subtext0
                        onClicked: root.monthOffset++
                    }

                    // Open Google Calendar in Browser (xdg-open "https://calendar.google.com")
                    IconButton {
                        size: Scaler.s(26)
                        cornerRadius: ThemeBackend.borderRadius
                        buttonIcon: "󰊭"
                        iconFontSize: Scaler.s(12)
                        accentColor: ThemeBackend.surface1
                        bgOpacity: ThemeBackend.elementOpacity
                        textColor: ThemeBackend.sapphire !== undefined ? ThemeBackend.sapphire : ThemeBackend.blue
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.openGoogleCalendarWeb();
                            } else {
                                Quickshell.execDetached(["xdg-open", "https://calendar.google.com"]);
                            }
                        }
                    }

                    // Manual Async Sync button with rotation feedback
                    Item {
                        Layout.preferredWidth: Scaler.s(26)
                        Layout.preferredHeight: Scaler.s(26)

                        IconButton {
                            id: syncBtn
                            anchors.fill: parent
                            size: Scaler.s(26)
                            cornerRadius: ThemeBackend.borderRadius
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
                            target: syncBtn
                            from: 0
                            to: 360
                            duration: 900
                            loops: Animation.Infinite
                            running: typeof CalendarService !== "undefined" && CalendarService.isLoading
                            onStopped: syncBtn.rotation = 0
                        }
                    }

                    // Offline / Cached indicator badge
                    Rectangle {
                        visible: typeof CalendarService !== "undefined" && CalendarService.isCached
                        Layout.preferredHeight: Scaler.s(22)
                        Layout.preferredWidth: Scaler.s(22)
                        radius: Scaler.s(11)
                        color: Qt.rgba(ThemeBackend.peach.r, ThemeBackend.peach.g, ThemeBackend.peach.b, 0.2)

                        Text {
                            anchors.centerIn: parent
                            text: "󰋊"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(11)
                            color: ThemeBackend.peach
                        }
                    }

                    // Configure feeds button
                    IconButton {
                        size: Scaler.s(26)
                        cornerRadius: ThemeBackend.borderRadius
                        buttonIcon: "󰒓"
                        iconFontSize: Scaler.s(12)
                        accentColor: ThemeBackend.surface1
                        bgOpacity: ThemeBackend.elementOpacity
                        textColor: ThemeBackend.subtext0
                        onClicked: {
                            root.isConfiguring = true;
                            root.setKeyboardFocus(true);
                        }
                    }
                }

                // Weekday labels
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Scaler.s(18)
                    spacing: 0

                    Repeater {
                        model: [
                            typeof I18n !== "undefined" ? I18n.t("calendar.days.mo", "Mo") : "Mo",
                            typeof I18n !== "undefined" ? I18n.t("calendar.days.tu", "Tu") : "Tu",
                            typeof I18n !== "undefined" ? I18n.t("calendar.days.we", "We") : "We",
                            typeof I18n !== "undefined" ? I18n.t("calendar.days.th", "Th") : "Th",
                            typeof I18n !== "undefined" ? I18n.t("calendar.days.fr", "Fr") : "Fr",
                            typeof I18n !== "undefined" ? I18n.t("calendar.days.sa", "Sa") : "Sa",
                            typeof I18n !== "undefined" ? I18n.t("calendar.days.su", "Su") : "Su"
                        ]

                        Text {
                            Layout.fillWidth: true
                            text: modelData
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(10)
                            font.bold: true
                            color: ThemeBackend.overlay0
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }

                // Calendar Grid
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            if (event.angleDelta.y > 0) {
                                root.monthOffset--;
                            } else if (event.angleDelta.y < 0) {
                                root.monthOffset++;
                            }
                        }
                    }

                    GridLayout {
                        anchors.fill: parent
                        columns: 7
                        rows: 6
                        columnSpacing: Scaler.s(3)
                        rowSpacing: Scaler.s(3)

                        Repeater {
                            model: monthDaysModel

                            Rectangle {
                                id: dayCell
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: Scaler.s(7)

                                readonly property bool isSelectedDay: (model.year === root.selectedYear && model.month === root.selectedMonth && model.dayNum === root.selectedDay)

                                color: {
                                    if (model.isToday) return ThemeBackend.mauve;
                                    if (isSelectedDay) return Qt.alpha(ThemeBackend.mauve, 0.25);
                                    if (dayMa.containsMouse) return Qt.alpha(ThemeBackend.surface1, 0.75);
                                    return "transparent";
                                }

                                border.width: model.isToday ? 0 : (isSelectedDay ? 1.5 : 0)
                                border.color: ThemeBackend.mauve

                                Behavior on color { ColorAnimation { duration: 120 } }

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: Scaler.s(1)

                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: model.dayNum
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: Scaler.s(11)
                                        font.bold: model.isToday || isSelectedDay
                                        color: {
                                            if (model.isToday) return ThemeBackend.crust;
                                            if (isSelectedDay) return ThemeBackend.mauve;
                                            if (!model.isCurrentMonth) return ThemeBackend.overlay0;
                                            return ThemeBackend.text;
                                        }
                                    }

                                    // Event indicator dots
                                    Row {
                                        Layout.alignment: Qt.AlignHCenter
                                        spacing: Scaler.s(2)
                                        visible: model.hasEvents

                                        Rectangle {
                                            width: Scaler.s(4)
                                            height: Scaler.s(4)
                                            radius: Scaler.s(2)
                                            color: model.isToday ? ThemeBackend.crust : (model.color0 !== "" ? model.color0 : ThemeBackend.blue)
                                        }
                                        Rectangle {
                                            visible: model.color1 !== ""
                                            width: Scaler.s(4)
                                            height: Scaler.s(4)
                                            radius: Scaler.s(2)
                                            color: model.isToday ? ThemeBackend.crust : model.color1
                                        }
                                        Rectangle {
                                            visible: model.color2 !== ""
                                            width: Scaler.s(4)
                                            height: Scaler.s(4)
                                            radius: Scaler.s(2)
                                            color: model.isToday ? ThemeBackend.crust : model.color2
                                        }
                                    }
                                }

                                MouseArea {
                                    id: dayMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (typeof CalendarService !== "undefined") {
                                            CalendarService.selectDate(model.year, model.month, model.dayNum, true);
                                        }
                                    }
                                    onDoubleClicked: {
                                        if (typeof CalendarService !== "undefined") {
                                            CalendarService.openGoogleCalendarNewEvent(model.year, model.month, model.dayNum, "");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Events sidebar (visible when widget is wide enough)
            Rectangle {
                visible: root.isWide
                Layout.preferredWidth: Scaler.s(210)
                Layout.fillHeight: true
                color: Qt.alpha(ThemeBackend.surface1, 0.55)
                radius: ThemeBackend.borderRadius
                border.width: 1
                border.color: Qt.alpha(ThemeBackend.surface2, 0.35)
                clip: true

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Scaler.s(10)
                    spacing: Scaler.s(8)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Scaler.s(4)

                        Text {
                            text: {
                                try {
                                    let d = new Date(root.selectedYear, root.selectedMonth, root.selectedDay);
                                    return d.toLocaleDateString(Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "it"), "d MMMM");
                                } catch (e) {
                                    return root.selectedDay + " " + root.displayMonthTitle;
                                }
                            }
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: Scaler.s(12)
                            font.bold: true
                            color: ThemeBackend.text
                            Layout.fillWidth: true
                        }

                        IconButton {
                            size: Scaler.s(22)
                            cornerRadius: Scaler.s(6)
                            buttonIcon: "󰐕"
                            iconFontSize: Scaler.s(11)
                            accentColor: ThemeBackend.surface0
                            textColor: ThemeBackend.mauve
                            onClicked: {
                                if (typeof CalendarService !== "undefined") {
                                    CalendarService.openGoogleCalendarNewEvent(root.selectedYear, root.selectedMonth, root.selectedDay, "");
                                }
                            }
                        }
                    }

                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: Scaler.s(6)
                        model: root.selectedDayEvents

                        delegate: Rectangle {
                            width: parent ? parent.width : Scaler.s(190)
                            implicitHeight: evCol.implicitHeight + Scaler.s(10)
                            color: Qt.alpha(ThemeBackend.surface0, 0.75)
                            radius: Scaler.s(6)
                            opacity: modelData.completed ? 0.55 : 1.0

                            Rectangle {
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: Scaler.s(3)
                                radius: Scaler.s(1.5)
                                color: modelData.calendar_color || ThemeBackend.mauve
                            }

                            ColumnLayout {
                                id: evCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Scaler.s(8)
                                anchors.rightMargin: Scaler.s(6)
                                anchors.topMargin: Scaler.s(5)
                                spacing: Scaler.s(2)

                                Text {
                                    text: modelData.title
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(11)
                                    font.bold: true
                                    font.strikeout: Boolean(modelData.completed)
                                    color: ThemeBackend.text
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                }

                                Text {
                                    text: modelData.time_str
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(9.5)
                                    color: ThemeBackend.subtext0
                                    Layout.fillWidth: true
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (typeof CalendarService !== "undefined") {
                                        CalendarService.openGoogleCalendarEvent(modelData);
                                    }
                                }
                            }
                        }

                        Item {
                            anchors.fill: parent
                            visible: root.selectedDayEvents.length === 0

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: Scaler.s(4)

                                Text {
                                    text: "󰃭"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(24)
                                    color: ThemeBackend.overlay0
                                    Layout.alignment: Qt.AlignHCenter
                                }

                                Text {
                                    text: typeof I18n !== "undefined" ? I18n.t("calendar.no_events", "No events") : "No events"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: Scaler.s(10.5)
                                    color: ThemeBackend.subtext0
                                    Layout.alignment: Qt.AlignHCenter
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
