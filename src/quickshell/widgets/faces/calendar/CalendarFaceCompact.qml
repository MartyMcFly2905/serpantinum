import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import "../../../reusables"
import "../../../"

Item {
    id: root
    anchors.fill: parent
    clip: true

    property real minWidth: Scaler.s(160)
    property real minHeight: Scaler.s(90)
    property real maxWidth: Scaler.s(600)
    property real maxHeight: Scaler.s(400)
    property real minAspect: 0.8
    property real maxAspect: 3.5
    property bool isRound: false

    readonly property bool isStacked: (width / Math.max(1, height)) < 1.4

    readonly property var nextEvent: {
        if (typeof CalendarService === "undefined") return null;
        let dummy = CalendarService.eventsCount;
        let evs = CalendarService.getUpcomingEvents(1);
        return (evs && evs.length > 0) ? evs[0] : null;
    }

    readonly property var todayDate: {
        let _tick = (typeof DateTime !== "undefined" && DateTime.now) ? DateTime.now : null;
        let _sync = (typeof CalendarService !== "undefined") ? CalendarService.eventsCount : 0;
        return new Date();
    }
    readonly property string dayNumStr: String(todayDate.getDate())
    readonly property string weekdayStr: {
        try {
            return todayDate.toLocaleDateString(Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "it"), "dddd");
        } catch (e) {
            return "";
        }
    }
    readonly property string monthStr: {
        try {
            return todayDate.toLocaleDateString(Qt.locale(typeof I18n !== "undefined" ? I18n.currentLang : "it"), "MMM").toUpperCase();
        } catch (e) {
            return "";
        }
    }

    Rectangle {
        id: bgContainer
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

        // Soft accent glow circle in the corner
        Rectangle {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: -width * 0.3
            width: Math.min(parent.width, parent.height) * 0.7
            height: width
            radius: width / 2
            color: ThemeBackend.mauve
            opacity: 0.12
            antialiasing: true
        }

        // Horizontal Layout (Wide)
        RowLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(10)
            spacing: Scaler.s(10)
            visible: !root.isStacked

            // Left Date Badge (click to reset selection to Today)
            Rectangle {
                Layout.preferredWidth: Scaler.s(70)
                Layout.fillHeight: true
                color: Qt.alpha(ThemeBackend.surface1, 0.65)
                radius: Scaler.s(8)
                border.width: 1
                border.color: Qt.alpha(ThemeBackend.surface2, 0.3)

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 0

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.monthStr
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9)
                        font.bold: true
                        color: ThemeBackend.mauve
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.dayNumStr
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(22)
                        font.bold: true
                        color: ThemeBackend.text
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: root.weekdayStr
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9)
                        color: ThemeBackend.subtext0
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.resetSelectionToToday(true);
                        }
                    }
                }
            }

            // Right Next Event Box
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.alignment: Qt.AlignVCenter
                spacing: Scaler.s(3)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Scaler.s(4)

                    Text {
                        text: typeof I18n !== "undefined" ? I18n.t("widgets.calendar.next_event", "Next Event") : "Next Event"
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9.5)
                        font.bold: true
                        color: ThemeBackend.overlay1
                        Layout.fillWidth: true
                    }

                    IconButton {
                        size: Scaler.s(22)
                        cornerRadius: Scaler.s(4)
                        buttonIcon: "󰊭"
                        iconFontSize: Scaler.s(11)
                        accentColor: "transparent"
                        textColor: ThemeBackend.sapphire !== undefined ? ThemeBackend.sapphire : ThemeBackend.blue
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.openGoogleCalendarWeb();
                            }
                        }
                    }

                    IconButton {
                        size: Scaler.s(22)
                        cornerRadius: Scaler.s(4)
                        buttonIcon: "󰑐"
                        iconFontSize: Scaler.s(11)
                        accentColor: "transparent"
                        textColor: (typeof CalendarService !== "undefined" && CalendarService.isLoading) ? ThemeBackend.mauve : ThemeBackend.overlay0
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.sync(true, true);
                            }
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: nextEventTitle.implicitHeight

                    Text {
                        id: nextEventTitle
                        anchors.fill: parent
                        text: root.nextEvent ? root.nextEvent.title : (typeof I18n !== "undefined" ? I18n.t("calendar.no_events", "No events scheduled") : "No events scheduled")
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(11.5)
                        font.bold: true
                        color: ThemeBackend.text
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof CalendarService !== "undefined") {
                                CalendarService.openGoogleCalendarEvent(root.nextEvent);
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: root.nextEvent !== null
                    spacing: Scaler.s(4)

                    Rectangle {
                        width: Scaler.s(6)
                        height: Scaler.s(6)
                        radius: Scaler.s(3)
                        color: (root.nextEvent && root.nextEvent.calendar_color) ? root.nextEvent.calendar_color : ThemeBackend.blue
                    }

                    Text {
                        text: root.nextEvent ? root.nextEvent.time_str : ""
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: Scaler.s(9.5)
                        color: ThemeBackend.subtext0
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // Stacked Layout (Square / Tall)
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(8)
            spacing: Scaler.s(4)
            visible: root.isStacked

            RowLayout {
                Layout.fillWidth: true
                spacing: Scaler.s(4)

                Text {
                    text: root.monthStr + " " + root.dayNumStr
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: Scaler.s(14)
                    font.bold: true
                    color: ThemeBackend.mauve
                    Layout.fillWidth: true
                }

                IconButton {
                    size: Scaler.s(22)
                    cornerRadius: Scaler.s(4)
                    buttonIcon: "󰊭"
                    iconFontSize: Scaler.s(11)
                    accentColor: "transparent"
                    textColor: ThemeBackend.sapphire !== undefined ? ThemeBackend.sapphire : ThemeBackend.blue
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.openGoogleCalendarWeb();
                        }
                    }
                }

                IconButton {
                    size: Scaler.s(22)
                    cornerRadius: Scaler.s(4)
                    buttonIcon: "󰑐"
                    iconFontSize: Scaler.s(11)
                    accentColor: "transparent"
                    textColor: (typeof CalendarService !== "undefined" && CalendarService.isLoading) ? ThemeBackend.mauve : ThemeBackend.overlay0
                    onClicked: {
                        if (typeof CalendarService !== "undefined") {
                            CalendarService.sync(true, true);
                        }
                    }
                }
            }

            Text {
                text: root.weekdayStr
                font.family: ThemeBackend.fontFamily
                font.pixelSize: Scaler.s(9.5)
                color: ThemeBackend.subtext0
            }

            Rectangle {
                Layout.fillWidth: true
                height: Scaler.s(1)
                color: Qt.alpha(ThemeBackend.surface2, 0.4)
            }

            Text {
                text: root.nextEvent ? root.nextEvent.title : (typeof I18n !== "undefined" ? I18n.t("calendar.no_events", "No events") : "No events")
                font.family: ThemeBackend.fontFamily
                font.pixelSize: Scaler.s(11)
                font.bold: true
                color: ThemeBackend.text
                Layout.fillWidth: true
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Text {
                visible: root.nextEvent !== null
                text: root.nextEvent ? root.nextEvent.time_str : ""
                font.family: ThemeBackend.fontFamily
                font.pixelSize: Scaler.s(9)
                color: ThemeBackend.subtext0
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }
    }
}
