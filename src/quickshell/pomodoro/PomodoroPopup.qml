import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../reusables"
import "../"

Item {
    id: root
    visible: false
    focus: true

    function s(val) {
        return (typeof Scaler !== "undefined") ? Scaler.s(val) : val;
    }

    property bool showSettings: false

    property real targetMasterWidth: root.s(330)
    property real targetMasterHeight: showSettings ? root.s(300) : root.s(225)
    implicitWidth: targetMasterWidth
    implicitHeight: targetMasterHeight
    width: targetMasterWidth
    height: targetMasterHeight

    function gotoTab(tab) {
        if (tab === "settings") {
            showSettings = true;
        } else {
            showSettings = false;
        }
    }

    property var exitCallback: null

    function startExit(onFinished) {
        introAnim.stop();
        exitCallback = onFinished;
        exitAnim.restart();
    }

    function resetAndPlayIntro() {
        exitAnim.stop();
        introMain = 0;
        introAnim.restart();
    }

    Timer {
        id: focusTimer
        interval: 50
        repeat: false
        onTriggered: root.forceActiveFocus()
    }

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus();
            focusTimer.restart();
            resetAndPlayIntro();
        } else {
            introAnim.stop();
            exitAnim.stop();
            introMain = 0;
        }
    }

    property real introMain: 0

    ParallelAnimation {
        id: introAnim
        running: false
        NumberAnimation { target: root; property: "introMain"; from: 0; to: 1.0; duration: 400; easing.type: Easing.OutQuart }
    }

    SequentialAnimation {
        id: exitAnim
        running: false
        NumberAnimation { target: root; property: "introMain"; to: 0; duration: 150; easing.type: Easing.InCubic }
        ScriptAction {
            script: {
                if (root.exitCallback) {
                    let cb = root.exitCallback;
                    root.exitCallback = null;
                    cb();
                }
            }
        }
    }

    Item {
        id: mainWrapper
        anchors.fill: parent
        scale: 0.94 + (0.06 * root.introMain)
        opacity: root.introMain

        Rectangle {
            id: popupBg
            anchors.fill: parent
            radius: ThemeBackend.clampedBorderRadius !== undefined ? ThemeBackend.clampedBorderRadius : ThemeBackend.borderRadius
            color: popupGlass.active ? "transparent" : Qt.alpha(ThemeBackend.base, Math.min(0.95, Math.max(0.75, ThemeBackend.elementOpacity)))
            clip: true

            border.width: 1
            border.color: Qt.alpha(PomodoroService.phaseColor, 0.22)
            Behavior on border.color { ColorAnimation { duration: 250 } }

            WallpaperBlur {
                z: -2
                anchors.fill: parent
                radius: parent.radius
            }

            GlassFill {
                id: popupGlass
                z: -1
                anchors.fill: parent
                radius: parent.radius
                tintColor: ThemeBackend.surface0
                tintAmount: 0.24
            }

            // Subtle ambient glow matching active phase color
            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: -width * 0.35
                width: root.s(140)
                height: width
                radius: width / 2
                color: PomodoroService.phaseColor
                opacity: PomodoroService.isRunning ? 0.10 : 0.04
                Behavior on color { ColorAnimation { duration: 300 } }
                Behavior on opacity { NumberAnimation { duration: 300 } }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.topMargin: root.s(12)
                anchors.bottomMargin: root.s(12)
                anchors.leftMargin: root.s(14)
                anchors.rightMargin: root.s(14)
                spacing: root.s(8)

                // Top Header: Title + Session Dots + Settings + Close
                RowLayout {
                    Layout.fillWidth: true
                    spacing: root.s(6)

                    Text {
                        text: PomodoroService.phaseIcon
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: root.s(14)
                        color: PomodoroService.phaseColor
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }

                    Text {
                        text: PomodoroService.phaseLabel
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: root.s(12.5)
                        font.weight: Font.Black
                        color: ThemeBackend.text
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    // Session Progress Dots
                    Row {
                        spacing: root.s(4)
                        Layout.alignment: Qt.AlignVCenter

                        Repeater {
                            model: Math.max(1, PomodoroService.targetSessions)
                            Rectangle {
                                width: root.s(7)
                                height: root.s(7)
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
                        size: root.s(26)
                        cornerRadius: root.s(8)
                        buttonIcon: "󰒓"
                        iconFontSize: root.s(12)
                        accentColor: root.showSettings ? Qt.alpha(PomodoroService.phaseColor, 0.25) : ThemeBackend.surface0
                        textColor: root.showSettings ? PomodoroService.phaseColor : ThemeBackend.subtext0
                        onClicked: root.showSettings = !root.showSettings
                    }

                    // Close Button
                    IconButton {
                        size: root.s(26)
                        cornerRadius: root.s(8)
                        buttonIcon: "󰅖"
                        iconFontSize: root.s(12)
                        accentColor: ThemeBackend.surface0
                        textColor: ThemeBackend.subtext0
                        onClicked: {
                            Quickshell.execDetached(["bash", Caching.serpantinumDir + "/scripts/qs_manager.sh", "close"]);
                        }
                    }
                }

                // Quick Session Selector Pills (Lavoro | Pausa Breve | Pausa Lunga)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.s(30)
                    radius: root.s(9)
                    color: Qt.alpha(ThemeBackend.surface0, 0.65)
                    border.width: 1
                    border.color: Qt.alpha(ThemeBackend.surface2, 0.35)

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: root.s(3)
                        spacing: root.s(3)

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
                                radius: root.s(7)
                                readonly property bool isSelected: PomodoroService.phase === modelData.phaseId
                                color: isSelected
                                    ? PomodoroService.phaseColor
                                    : (phaseTabMa.containsMouse ? Qt.alpha(ThemeBackend.surface1, 0.7) : "transparent")

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    anchors.centerIn: parent
                                    width: parent.width - root.s(6)
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    text: modelData.label
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: root.s(10)
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

                // Main Timer Display & Controls (visible when !showSettings)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: root.s(6)
                    visible: !root.showSettings

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: root.s(4)

                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: PomodoroService.formattedTime
                                font.family: ThemeBackend.fontFamily
                                font.weight: Font.Black
                                font.pixelSize: root.s(42)
                                color: ThemeBackend.text
                            }

                            // Thin sleek progress bar under countdown
                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: root.s(180)
                                Layout.preferredHeight: root.s(4)
                                radius: root.s(2)
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
                        spacing: root.s(14)

                        // Reset Current Phase
                        IconButton {
                            size: root.s(36)
                            cornerRadius: root.s(11)
                            buttonIcon: "󰑐"
                            iconFontSize: root.s(15)
                            accentColor: ThemeBackend.surface0
                            bgOpacity: ThemeBackend.elementOpacity
                            textColor: ThemeBackend.subtext0
                            onClicked: PomodoroService.reset()
                        }

                        // Primary Play / Pause Button
                        IconButton {
                            size: root.s(46)
                            cornerRadius: root.s(14)
                            buttonIcon: PomodoroService.isRunning ? "󰏤" : "󰐊"
                            iconFontSize: root.s(20)
                            accentColor: PomodoroService.phaseColor
                            bgOpacity: 1.0
                            textColor: ThemeBackend.crust
                            onClicked: PomodoroService.toggle()
                        }

                        // Skip to Next Phase
                        IconButton {
                            size: root.s(36)
                            cornerRadius: root.s(11)
                            buttonIcon: "󰒭"
                            iconFontSize: root.s(15)
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
                    spacing: root.s(6)
                    visible: root.showSettings

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
                            spacing: root.s(6)

                            Text {
                                text: modelData.label
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: root.s(11)
                                font.bold: true
                                color: ThemeBackend.subtext0
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            IconButton {
                                size: root.s(24)
                                cornerRadius: root.s(6)
                                buttonIcon: "-"
                                iconFontSize: root.s(13)
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
                                font.pixelSize: root.s(12)
                                font.weight: Font.Black
                                color: ThemeBackend.text
                                Layout.minimumWidth: root.s(26)
                                horizontalAlignment: Text.AlignHCenter
                            }

                            IconButton {
                                size: root.s(24)
                                cornerRadius: root.s(6)
                                buttonIcon: "+"
                                iconFontSize: root.s(13)
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

                    // Bottom toggles row: Audio + Auto start
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: root.s(2)
                        spacing: root.s(8)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: root.s(28)
                            radius: root.s(7)
                            color: PomodoroService.soundEnabled ? Qt.alpha(PomodoroService.phaseColor, 0.2) : Qt.alpha(ThemeBackend.surface1, 0.6)
                            border.width: 1
                            border.color: PomodoroService.soundEnabled ? Qt.alpha(PomodoroService.phaseColor, 0.5) : "transparent"

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: root.s(5)
                                Text {
                                    text: PomodoroService.soundEnabled ? "󰕾" : "󰖁"
                                    font.family: ThemeBackend.iconFont
                                    font.pixelSize: root.s(12)
                                    color: PomodoroService.soundEnabled ? PomodoroService.phaseColor : ThemeBackend.subtext0
                                }
                                Text {
                                    text: "Audio"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: root.s(10.5)
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
                            Layout.preferredHeight: root.s(28)
                            radius: root.s(7)
                            color: PomodoroService.autoStartNext ? Qt.alpha(PomodoroService.phaseColor, 0.2) : Qt.alpha(ThemeBackend.surface1, 0.6)
                            border.width: 1
                            border.color: PomodoroService.autoStartNext ? Qt.alpha(PomodoroService.phaseColor, 0.5) : "transparent"

                            RowLayout {
                                anchors.centerIn: parent
                                spacing: root.s(5)
                                Text {
                                    text: "󰑖"
                                    font.family: ThemeBackend.iconFont
                                    font.pixelSize: root.s(12)
                                    color: PomodoroService.autoStartNext ? PomodoroService.phaseColor : ThemeBackend.subtext0
                                }
                                Text {
                                    text: "Auto start"
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: root.s(10.5)
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
