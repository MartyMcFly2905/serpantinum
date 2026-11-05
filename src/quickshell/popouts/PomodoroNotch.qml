import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../reusables"
import "../"

/**
 * PomodoroNotch
 * Floating glassmorphic Notch / Flyout anchored directly to the bar module.
 * Provides immediate Play/Pause/Skip/Reset controls, quick session selector
 * (Work, Short Break, Long Break), and inline duration preferences persisted
 * to ~/.config/serpantinum/pomodoro.json.
 */
PanelWindow {
    id: pomodoroNotch

    screen: PomodoroController.screen

    WlrLayershell.namespace: "pomodoro-notch"
    WlrLayershell.layer: WlrLayer.Top
    focusable: false
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    mask: Region {
        item: (pomodoroNotch.isVisible || menuContainer.animProgress > 0.001) ? menuContainer : null
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    function s(val) { return (typeof Scaler !== "undefined") ? Scaler.s(val) : val; }

    property bool isVisible: PomodoroController.isVisible
    property real targetX: PomodoroController.targetX
    property real targetY: PomodoroController.targetY
    property bool alignRight: PomodoroController.alignRight
    property bool alignBottom: PomodoroController.alignBottom
    property bool isSideBar: PomodoroController.isSideBar

    property bool showSettings: false
    property int configRevision: 0

    Connections {
        target: (typeof Config !== "undefined") ? Config : null
        function onSettingsLoaded() {
            PomodoroController.hide();
            pomodoroNotch.configRevision++;
        }
    }

    property string barStyle: {
        let dummy = configRevision;
        if (typeof Config === "undefined" || !Config.rawSettings || !Config.rawSettings.bar) return "modular";
        let st = Config.rawSettings.bar.style;
        if (typeof st === "string") return st;
        if (st && typeof st === "object") {
            if (st.fill || st.mode === "fill") return "fill";
            if (st.solid || st.mode === "solid") return "solid";
        }
        return "modular";
    }

    onBarStyleChanged: {
        PomodoroController.hide();
    }

    property bool isFill: barStyle === "fill"
    property bool isSolid: barStyle === "solid" || barStyle === "fill"

    property real barHeight: {
        let dummy = configRevision;
        return (typeof Config !== "undefined" && Config.rawSettings && Config.rawSettings.bar && Config.rawSettings.bar.height)
            ? s(Config.rawSettings.bar.height)
            : s(40);
    }

    property real cornerRadius: ThemeBackend.borderRadius || s(14)
    property real menuMargin: isSolid ? 0 : s(8)

    visible: isVisible || menuContainer.animProgress > 0.001

    property real menuWidth: s(300)
    property real menuHeight: showSettings ? s(285) : s(215)

    Behavior on menuHeight {
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }

    property real clampedX: {
        let w = menuWidth;
        let x = 0;
        if (isSideBar) {
            if (alignRight) {
                let barEdge = (targetX > pomodoroNotch.width / 2) ? targetX : (pomodoroNotch.width - barHeight);
                x = isSolid ? (pomodoroNotch.width - barHeight - w) : (barEdge - w - menuMargin);
            } else {
                let barEdge = (targetX > 0 && targetX < pomodoroNotch.width / 2) ? targetX : barHeight;
                x = isSolid ? barHeight : (barEdge + menuMargin);
            }
        } else {
            x = targetX - (w / 2);
        }
        let edgeBound = (isSolid && !isSideBar) ? (cornerRadius + s(4)) : s(8);
        return Math.max(edgeBound, Math.min(pomodoroNotch.width - w - edgeBound, x));
    }

    property real clampedY: {
        let h = menuHeight;
        let y = 0;
        if (isSideBar) {
            y = targetY - (h / 2) + s(4);
        } else {
            if (alignBottom) {
                let barEdge = (targetY > pomodoroNotch.height / 2) ? targetY : (pomodoroNotch.height - barHeight);
                y = isSolid ? (pomodoroNotch.height - barHeight - h) : (barEdge - h - menuMargin);
            } else {
                let barEdge = (targetY > 0 && targetY < pomodoroNotch.height / 2) ? targetY : barHeight;
                y = isSolid ? barHeight : (barEdge + menuMargin);
            }
        }
        let edgeBound = (isSolid && isSideBar) ? (cornerRadius + s(4)) : s(8);
        return Math.max(edgeBound, Math.min(pomodoroNotch.height - h - edgeBound, y));
    }

    Item {
        id: menuContainer

        property real dynamicCornerRadius: pomodoroNotch.isSolid
            ? Math.max(0, Math.min(pomodoroNotch.cornerRadius, (pomodoroNotch.isSideBar ? width : height)))
            : 0

        property real animProgress: pomodoroNotch.isVisible ? 1.0 : 0.0
        Behavior on animProgress {
            NumberAnimation {
                duration: pomodoroNotch.isVisible ? 280 : 220
                easing.type: Easing.OutCubic
            }
        }

        x: {
            if (pomodoroNotch.isSolid) {
                if (pomodoroNotch.isSideBar && pomodoroNotch.alignRight) {
                    return pomodoroNotch.clampedX + (pomodoroNotch.menuWidth - width);
                }
                return pomodoroNotch.clampedX;
            }
            let slideOffset = pomodoroNotch.s(14) * (1.0 - animProgress);
            if (pomodoroNotch.isSideBar) {
                return pomodoroNotch.alignRight ? (pomodoroNotch.clampedX + slideOffset) : (pomodoroNotch.clampedX - slideOffset);
            }
            return pomodoroNotch.clampedX;
        }

        y: {
            if (pomodoroNotch.isSolid) {
                if (!pomodoroNotch.isSideBar && pomodoroNotch.alignBottom) {
                    return pomodoroNotch.clampedY + (pomodoroNotch.menuHeight - height);
                }
                return pomodoroNotch.clampedY;
            }
            let slideOffset = pomodoroNotch.s(14) * (1.0 - animProgress);
            if (!pomodoroNotch.isSideBar) {
                return pomodoroNotch.alignBottom ? (pomodoroNotch.clampedY + slideOffset) : (pomodoroNotch.clampedY - slideOffset);
            }
            return pomodoroNotch.clampedY;
        }

        width: (pomodoroNotch.isSolid && pomodoroNotch.isSideBar) ? (pomodoroNotch.menuWidth * animProgress) : pomodoroNotch.menuWidth
        height: (pomodoroNotch.isSolid && !pomodoroNotch.isSideBar) ? (pomodoroNotch.menuHeight * animProgress) : pomodoroNotch.menuHeight

        opacity: animProgress
        scale: !pomodoroNotch.isSolid ? (0.93 + (0.07 * animProgress)) : 1.0

        transformOrigin: {
            if (pomodoroNotch.isSideBar) {
                return pomodoroNotch.alignRight ? Item.Right : Item.Left;
            }
            return pomodoroNotch.alignBottom ? Item.Bottom : Item.Top;
        }

        GlassFillets {
            id: menuFillets
            card: menuBox
            filletRadius: (pomodoroNotch.isSolid && menuContainer.dynamicCornerRadius > 0.5) ? menuContainer.dynamicCornerRadius : 0
            filletDir: pomodoroNotch.isSideBar
                ? (pomodoroNotch.alignRight ? Qt.vector2d(1, 0) : Qt.vector2d(-1, 0))
                : (pomodoroNotch.alignBottom ? Qt.vector2d(0, 1) : Qt.vector2d(0, -1))
        }

        Rectangle {
            id: menuBox
            anchors.fill: parent
            color: Qt.alpha(ThemeBackend.base, Math.min(0.95, Math.max(0.72, ThemeBackend.elementOpacity)))
            radius: pomodoroNotch.cornerRadius
            readonly property bool flatCorners: pomodoroNotch.isSolid
            topLeftRadius: (flatCorners && (pomodoroNotch.isSideBar ? !pomodoroNotch.alignRight : !pomodoroNotch.alignBottom)) ? 0 : pomodoroNotch.cornerRadius
            topRightRadius: (flatCorners && (pomodoroNotch.isSideBar ? pomodoroNotch.alignRight : !pomodoroNotch.alignBottom)) ? 0 : pomodoroNotch.cornerRadius
            bottomLeftRadius: (flatCorners && (pomodoroNotch.isSideBar ? !pomodoroNotch.alignRight : pomodoroNotch.alignBottom)) ? 0 : pomodoroNotch.cornerRadius
            bottomRightRadius: (flatCorners && (pomodoroNotch.isSideBar ? pomodoroNotch.alignRight : pomodoroNotch.alignBottom)) ? 0 : pomodoroNotch.cornerRadius
            border.width: pomodoroNotch.isSolid ? 0 : 1
            border.color: Qt.alpha(PomodoroService.phaseColor, 0.32)
            clip: true

            Behavior on border.color { ColorAnimation { duration: 250 } }

            WallpaperBlur {
                z: -2
                anchors.fill: parent
                rim: 0
                topLeftRadius: parent.topLeftRadius
                topRightRadius: parent.topRightRadius
                bottomLeftRadius: parent.bottomLeftRadius
                bottomRightRadius: parent.bottomRightRadius
                filletRadius: menuFillets.filletRadius
                filletDir: menuFillets.filletDir
            }

            GlassFill {
                id: notchGlass
                z: -1
                anchors.fill: parent
                radius: parent.radius
                tintColor: ThemeBackend.surface0
                tintAmount: 0.25
            }

            // Ambient soft glow matching active phase color
            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: -width * 0.35
                width: pomodoroNotch.s(130)
                height: width
                radius: width / 2
                color: PomodoroService.phaseColor
                opacity: PomodoroService.isRunning ? 0.14 : 0.07
                Behavior on color { ColorAnimation { duration: 300 } }
                Behavior on opacity { NumberAnimation { duration: 300 } }
            }

            HoverHandler {
                id: menuHoverHandler
                onHoveredChanged: {
                    PomodoroController.menuHovered = hovered;
                    if (hovered) {
                        PomodoroController.cancelHide();
                    } else {
                        PomodoroController.requestHide();
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                preventStealing: true
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: pomodoroNotch.s(12)
                anchors.bottomMargin: pomodoroNotch.s(12)
                anchors.leftMargin: pomodoroNotch.s(14)
                anchors.rightMargin: pomodoroNotch.s(14)
                spacing: pomodoroNotch.s(8)

                // Top Header: Title + Session Dots + Settings + Close
                RowLayout {
                    Layout.fillWidth: true
                    spacing: pomodoroNotch.s(6)

                    Text {
                        text: PomodoroService.phaseIcon
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: pomodoroNotch.s(14)
                        color: PomodoroService.phaseColor
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }

                    Text {
                        text: PomodoroService.phaseLabel
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: pomodoroNotch.s(12.5)
                        font.weight: Font.Black
                        color: ThemeBackend.text
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    // Session Progress Dots
                    Row {
                        spacing: pomodoroNotch.s(4)
                        Layout.alignment: Qt.AlignVCenter

                        Repeater {
                            model: Math.max(1, PomodoroService.targetSessions)
                            Rectangle {
                                width: pomodoroNotch.s(7)
                                height: pomodoroNotch.s(7)
                                radius: width / 2
                                readonly property bool isDone: index < PomodoroService.sessionsCount
                                readonly property bool isCurrent: index === PomodoroService.sessionsCount && PomodoroService.phase === 0
                                color: isDone
                                    ? PomodoroService.phaseColor
                                    : (isCurrent ? Qt.alpha(PomodoroService.phaseColor, 0.55) : Qt.alpha(ThemeBackend.surface2, 0.7))
                                border.width: isCurrent ? 1 : 0
                                border.color: PomodoroService.phaseColor
                            }
                        }
                    }

                    // Settings Toggle Button
                    IconButton {
                        size: pomodoroNotch.s(26)
                        cornerRadius: pomodoroNotch.s(8)
                        buttonIcon: "󰒓"
                        iconFontSize: pomodoroNotch.s(12)
                        accentColor: pomodoroNotch.showSettings ? Qt.alpha(PomodoroService.phaseColor, 0.25) : ThemeBackend.surface0
                        textColor: pomodoroNotch.showSettings ? PomodoroService.phaseColor : ThemeBackend.subtext0
                        onClicked: pomodoroNotch.showSettings = !pomodoroNotch.showSettings
                    }

                    // Close Notch Button
                    IconButton {
                        size: pomodoroNotch.s(26)
                        cornerRadius: pomodoroNotch.s(8)
                        buttonIcon: "󰅖"
                        iconFontSize: pomodoroNotch.s(12)
                        accentColor: ThemeBackend.surface0
                        textColor: ThemeBackend.subtext0
                        onClicked: PomodoroController.hide()
                    }
                }

                // Quick Session Selector Pills (Lavoro | Pausa Breve | Pausa Lunga)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: pomodoroNotch.s(30)
                    radius: pomodoroNotch.s(9)
                    color: Qt.alpha(ThemeBackend.surface0, 0.65)
                    border.width: 1
                    border.color: Qt.alpha(ThemeBackend.surface2, 0.35)

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: pomodoroNotch.s(3)
                        spacing: pomodoroNotch.s(3)

                        Repeater {
                            model: [
                                {
                                    phaseId: 0,
                                    label: (typeof I18n !== "undefined") ? I18n.t("pomodoro.phase.work", "Lavoro") : "Lavoro"
                                },
                                {
                                    phaseId: 1,
                                    label: (typeof I18n !== "undefined") ? I18n.t("pomodoro.phase.short_break", "Pausa Breve") : "Pausa Breve"
                                },
                                {
                                    phaseId: 2,
                                    label: (typeof I18n !== "undefined") ? I18n.t("pomodoro.phase.long_break", "Pausa Lunga") : "Pausa Lunga"
                                }
                            ]

                            Rectangle {
                                id: phaseTab
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: pomodoroNotch.s(7)
                                readonly property bool isSelected: PomodoroService.phase === modelData.phaseId
                                color: isSelected
                                    ? PomodoroService.phaseColor
                                    : (phaseTabMa.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.7) : "transparent")

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    anchors.centerIn: parent
                                    width: parent.width - pomodoroNotch.s(6)
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    text: modelData.label
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: pomodoroNotch.s(10)
                                    font.weight: phaseTab.isSelected ? Font.Black : Font.Bold
                                    color: phaseTab.isSelected ? ThemeBackend.crust : ThemeBackend.subtext0
                                }

                                MouseArea {
                                    id: phaseTabMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        PomodoroService.selectPhase(modelData.phaseId, false);
                                    }
                                }
                            }
                        }
                    }
                }

                // Main Timer Display & Controls (visible when not in settings view)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: pomodoroNotch.s(6)
                    visible: !pomodoroNotch.showSettings

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: pomodoroNotch.s(4)

                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: PomodoroService.formattedTime
                                font.family: ThemeBackend.fontFamily
                                font.weight: Font.Black
                                font.pixelSize: pomodoroNotch.s(42)
                                color: ThemeBackend.text
                            }

                            // Thin sleek progress bar under countdown
                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: pomodoroNotch.s(180)
                                Layout.preferredHeight: pomodoroNotch.s(4)
                                radius: pomodoroNotch.s(2)
                                color: Qt.alpha(ThemeBackend.surface2, 0.5)
                                clip: true

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: parent.width * PomodoroService.progress
                                    radius: parent.radius
                                    color: PomodoroService.phaseColor
                                    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }
                                    Behavior on color { ColorAnimation { duration: 250 } }
                                }
                            }
                        }
                    }

                    // Immediate Control Buttons: Reset | Play/Pause | Skip
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: pomodoroNotch.s(14)

                        // Reset Current Phase
                        IconButton {
                            size: pomodoroNotch.s(36)
                            cornerRadius: pomodoroNotch.s(11)
                            buttonIcon: "󰑐"
                            iconFontSize: pomodoroNotch.s(15)
                            accentColor: ThemeBackend.surface0
                            bgOpacity: ThemeBackend.elementOpacity
                            textColor: ThemeBackend.subtext0
                            onClicked: PomodoroService.reset()
                        }

                        // Primary Play / Pause Button
                        IconButton {
                            size: pomodoroNotch.s(46)
                            cornerRadius: pomodoroNotch.s(14)
                            buttonIcon: PomodoroService.isRunning ? "󰏤" : "󰐊"
                            iconFontSize: pomodoroNotch.s(20)
                            accentColor: PomodoroService.phaseColor
                            bgOpacity: 1.0
                            textColor: ThemeBackend.crust
                            onClicked: PomodoroService.toggle()
                        }

                        // Skip to Next Phase
                        IconButton {
                            size: pomodoroNotch.s(36)
                            cornerRadius: pomodoroNotch.s(11)
                            buttonIcon: "󰒭"
                            iconFontSize: pomodoroNotch.s(15)
                            accentColor: ThemeBackend.surface0
                            bgOpacity: ThemeBackend.elementOpacity
                            textColor: ThemeBackend.subtext0
                            onClicked: PomodoroService.skip()
                        }
                    }
                }

                // Inline Preferences View (persisted to ~/.config/serpantinum/pomodoro.json)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: pomodoroNotch.s(6)
                    visible: pomodoroNotch.showSettings

                    Repeater {
                        model: [
                            {
                                label: (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.pomodoro.settings.work", "Lavoro (min)") : "Lavoro (min)",
                                valueProp: "workDuration",
                                step: 5,
                                min: 5,
                                max: 120
                            },
                            {
                                label: (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.pomodoro.settings.short_break", "Pausa breve (min)") : "Pausa breve (min)",
                                valueProp: "shortBreakDuration",
                                step: 1,
                                min: 1,
                                max: 30
                            },
                            {
                                label: (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.pomodoro.settings.long_break", "Pausa lunga (min)") : "Pausa lunga (min)",
                                valueProp: "longBreakDuration",
                                step: 5,
                                min: 5,
                                max: 60
                            },
                            {
                                label: (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.pomodoro.settings.sessions", "Sessioni ciclo") : "Sessioni ciclo",
                                valueProp: "targetSessions",
                                step: 1,
                                min: 1,
                                max: 10
                            }
                        ]

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: pomodoroNotch.s(6)

                            Text {
                                text: modelData.label
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: pomodoroNotch.s(11)
                                font.bold: true
                                color: ThemeBackend.subtext0
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            IconButton {
                                size: pomodoroNotch.s(24)
                                cornerRadius: pomodoroNotch.s(6)
                                buttonIcon: "-"
                                iconFontSize: pomodoroNotch.s(13)
                                accentColor: ThemeBackend.surface1
                                textColor: ThemeBackend.text
                                onClicked: {
                                    let cur = PomodoroService[modelData.valueProp];
                                    let next = Math.max(modelData.min, cur - modelData.step);
                                    if (modelData.valueProp === "workDuration") PomodoroService.setWorkDuration(next);
                                    else if (modelData.valueProp === "shortBreakDuration") PomodoroService.setShortBreakDuration(next);
                                    else if (modelData.valueProp === "longBreakDuration") PomodoroService.setLongBreakDuration(next);
                                    else if (modelData.valueProp === "targetSessions") PomodoroService.setTargetSessions(next);
                                }
                            }

                            Text {
                                text: String(PomodoroService[modelData.valueProp])
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: pomodoroNotch.s(12)
                                font.weight: Font.Black
                                color: ThemeBackend.text
                                Layout.minimumWidth: pomodoroNotch.s(26)
                                horizontalAlignment: Text.AlignHCenter
                            }

                            IconButton {
                                size: pomodoroNotch.s(24)
                                cornerRadius: pomodoroNotch.s(6)
                                buttonIcon: "+"
                                iconFontSize: pomodoroNotch.s(13)
                                accentColor: ThemeBackend.surface1
                                textColor: ThemeBackend.text
                                onClicked: {
                                    let cur = PomodoroService[modelData.valueProp];
                                    let next = Math.min(modelData.max, cur + modelData.step);
                                    if (modelData.valueProp === "workDuration") PomodoroService.setWorkDuration(next);
                                    else if (modelData.valueProp === "shortBreakDuration") PomodoroService.setShortBreakDuration(next);
                                    else if (modelData.valueProp === "longBreakDuration") PomodoroService.setLongBreakDuration(next);
                                    else if (modelData.valueProp === "targetSessions") PomodoroService.setTargetSessions(next);
                                }
                            }
                        }
                    }

                    // Bottom toggles row: Audio Feedback + Auto-start next phase
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: pomodoroNotch.s(2)
                        spacing: pomodoroNotch.s(8)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: pomodoroNotch.s(28)
                            radius: pomodoroNotch.s(7)
                            color: PomodoroService.soundEnabled ? Qt.alpha(PomodoroService.phaseColor, 0.2) : Qt.alpha(ThemeBackend.surface1, 0.6)
                            border.width: 1
                            border.color: PomodoroService.soundEnabled ? Qt.alpha(PomodoroService.phaseColor, 0.5) : "transparent"

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: pomodoroNotch.s(5)
                                Text {
                                    text: PomodoroService.soundEnabled ? "󰕾" : "󰖁"
                                    font.family: ThemeBackend.iconFont
                                    font.pixelSize: pomodoroNotch.s(12)
                                    color: PomodoroService.soundEnabled ? PomodoroService.phaseColor : ThemeBackend.subtext0
                                }
                                Text {
                                    text: "Audio"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: pomodoroNotch.s(10.5)
                                    font.bold: true
                                    color: PomodoroService.soundEnabled ? ThemeBackend.text : ThemeBackend.subtext0
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: PomodoroService.setSoundEnabled(!PomodoroService.soundEnabled)
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: pomodoroNotch.s(28)
                            radius: pomodoroNotch.s(7)
                            color: PomodoroService.autoStartNext ? Qt.alpha(PomodoroService.phaseColor, 0.2) : Qt.alpha(ThemeBackend.surface1, 0.6)
                            border.width: 1
                            border.color: PomodoroService.autoStartNext ? Qt.alpha(PomodoroService.phaseColor, 0.5) : "transparent"

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: pomodoroNotch.s(5)
                                Text {
                                    text: "󰑖"
                                    font.family: ThemeBackend.iconFont
                                    font.pixelSize: pomodoroNotch.s(12)
                                    color: PomodoroService.autoStartNext ? PomodoroService.phaseColor : ThemeBackend.subtext0
                                }
                                Text {
                                    text: "Auto start"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: pomodoroNotch.s(10.5)
                                    font.bold: true
                                    color: PomodoroService.autoStartNext ? ThemeBackend.text : ThemeBackend.subtext0
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: PomodoroService.setAutoStartNext(!PomodoroService.autoStartNext)
                            }
                        }
                    }
                }
            }
        }
    }
}
