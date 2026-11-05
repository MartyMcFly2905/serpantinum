import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../../../reusables"
import "../../../"

Item {
    id: root

    property var module: null
    property var widget: module

    property string orientation: module ? module.orientation : "horizontal"
    readonly property bool isVertical: orientation === "vertical"

    readonly property bool isCompact: module ? module.isCompact : false
    readonly property var barWindow: module ? module.barWindow : null
    readonly property bool isBottomBar: barWindow ? (barWindow.barPosition === "bottom") : false
    readonly property bool isRightBar: module ? module.isRightBar : (barWindow ? (barWindow.barPosition === "right") : false)

    readonly property bool isRecording: RecordingState.isRecording
    readonly property string recTimeFormatted: RecordingState.recTimeFormatted
    readonly property bool wantsRecording: !module || module.moduleActive
    property bool recSubscribed: false

    // Filter out legacy Pomodoro entries from TimerState since PomodoroService is rendered natively
    readonly property var timerEntries: {
        let raw = TimerState.entries || [];
        let filtered = [];
        for (let i = 0; i < raw.length; i++) {
            if (raw[i] && raw[i].icon !== "\uF085" && raw[i].type !== "pomodoro") {
                filtered.push(raw[i]);
            }
        }
        return filtered;
    }
    readonly property bool isTimerActive: timerEntries.length > 0
    readonly property color greenColor: (typeof ThemeBackend !== "undefined" && ThemeBackend.green !== undefined) ? ThemeBackend.green : Qt.rgba(166/255, 227/255, 161/255, 1.0)

    // Pomodoro bar integration (always available on bar unless explicitly hidden in config)
    readonly property bool hidePomodoroWhenIdle: {
        if (typeof Config !== "undefined" && Config.rawSettings && Config.rawSettings.bar) {
            if (Config.rawSettings.bar.pomodoroHideWhenIdle === true) return true;
        }
        return false;
    }
    readonly property bool isPomodoroHighlighted: PomodoroService.isRunning || PomodoroService.isPausedMidSession || PomodoroController.isVisible
    readonly property bool showPomodoroItem: !hidePomodoroWhenIdle || isPomodoroHighlighted

    readonly property bool hasActiveContent: isRecording || isTimerActive || showPomodoroItem

    property alias recRow: recLayout
    property alias recCol: recLayout
    property alias timerRow: timerLayout
    property alias timerCol: timerLayout

    function syncRecordingSubscription() {
        if (wantsRecording === recSubscribed) return;
        recSubscribed = wantsRecording;
        if (wantsRecording) RecordingState.subscribe();
        else RecordingState.unsubscribe();
    }

    onWantsRecordingChanged: syncRecordingSubscription()

    property real lengthPadding: barWindow ? barWindow.cs(isCompact ? 10 : 12) : (isCompact ? 10 : 12)
    property real innerSpacing: isVertical ? (barWindow ? barWindow.cs(isCompact ? 8 : 10) : (isCompact ? 8 : 10)) : (barWindow ? barWindow.cs(isCompact ? 10 : 12) : (isCompact ? 10 : 12))

    property real recLength: isRecording ? (isVertical ? recLayout.implicitHeight : recLayout.implicitWidth) : 0
    property real timerLength: isTimerActive ? (isVertical ? timerLayout.implicitHeight : timerLayout.implicitWidth) : 0
    property real pomoLength: showPomodoroItem ? (isVertical ? pomoContainer.implicitHeight : pomoContainer.implicitWidth) : 0

    readonly property int visibleSectionsCount: (isRecording ? 1 : 0) + (isTimerActive ? 1 : 0) + (showPomodoroItem ? 1 : 0)
    property real activeSpacing: visibleSectionsCount > 1 ? innerSpacing * (visibleSectionsCount - 1) : 0
    property real targetLength: hasActiveContent ? (recLength + timerLength + pomoLength + activeSpacing + (lengthPadding * 2)) : 0
    property bool showLayout: (!barWindow || barWindow.isStartupReady) ? true : false
    property bool isFaceVisible: showLayout && hasActiveContent && targetLength > 0

    implicitWidth: isVertical ? (parent ? parent.width : 0) : targetLength
    implicitHeight: isVertical ? targetLength : (parent ? parent.height : 0)

    Timer {
        running: !root.showLayout && barWindow && barWindow.isStartupReady
        interval: 120
        onTriggered: root.showLayout = true
    }

    function togglePomodoroNotch() {
        let targetItem = module ? module : pomoContainer;
        let pt = targetItem.mapToItem(null, 0, 0);
        let scr = (barWindow && barWindow.screen) ? barWindow.screen : null;
        let globX = root.isVertical
            ? (root.isRightBar ? pt.x : (pt.x + targetItem.width))
            : (pt.x + (targetItem.width / 2));
        let globY = root.isVertical
            ? (pt.y + (targetItem.height / 2))
            : (root.isBottomBar ? pt.y : (pt.y + targetItem.height));
        PomodoroController.toggle(
            scr,
            globX,
            globY,
            root.isVertical && root.isRightBar,
            !root.isVertical && root.isBottomBar,
            root.isVertical
        );
    }

    Item {
        id: topArea
        anchors.fill: parent

        AxisFlow {
            id: centerActiveLayout
            vertical: root.isVertical
            horizontalItemAlignment: Grid.AlignHCenter
            anchors.centerIn: parent
            spacing: root.innerSpacing

            AxisFlow {
                id: recLayout
                vertical: root.isVertical
                horizontalItemAlignment: Grid.AlignHCenter
                verticalItemAlignment: Grid.AlignVCenter
                spacing: root.isVertical ? (barWindow ? barWindow.cs(root.isCompact ? 3 : 4) : (root.isCompact ? 3 : 4)) : (barWindow ? barWindow.cs(root.isCompact ? 5 : 6) : (root.isCompact ? 5 : 6))
                visible: root.isRecording
                opacity: root.isRecording ? 1.0 : 0.0
                Behavior on opacity {
                    enabled: barWindow ? !barWindow.positionChanging : true
                    NumberAnimation { duration: 250 }
                }

                Rectangle {
                    id: recDot
                    width: barWindow ? barWindow.cs(root.isCompact ? 8 : 10) : (root.isCompact ? 8 : 10)
                    height: barWindow ? barWindow.cs(root.isCompact ? 8 : 10) : (root.isCompact ? 8 : 10)
                    radius: width * 0.5
                    color: root.isCompact ? Qt.lighter(ThemeBackend.red, 1.08) : ThemeBackend.red

                    SequentialAnimation on opacity {
                        running: root.isRecording
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                    }
                }

                Text {
                    id: recText
                    text: root.recTimeFormatted
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: root.isVertical ? (barWindow ? barWindow.cs(root.isCompact ? 11 : 12) : (root.isCompact ? 11 : 12)) : (barWindow ? barWindow.cs(root.isCompact ? 13 : 14) : (root.isCompact ? 13 : 14))
                    font.weight: Font.Bold
                    color: root.isCompact ? Qt.lighter(ThemeBackend.red, 1.08) : ThemeBackend.red
                }
            }

            // Interactive Pomodoro Bar Control
            Item {
                id: pomoContainer
                visible: root.showPomodoroItem
                implicitWidth: pomoLayout.implicitWidth
                implicitHeight: pomoLayout.implicitHeight
                width: implicitWidth
                height: implicitHeight

                readonly property bool isSessionActive: PomodoroService.isRunning || PomodoroService.isPausedMidSession
                readonly property color activeColor: {
                    if (isSessionActive) {
                        return root.isCompact ? Qt.lighter(PomodoroService.phaseColor, 1.08) : PomodoroService.phaseColor;
                    }
                    if (pomoMouse.containsMouse) {
                        return ThemeBackend.text;
                    }
                    return Qt.alpha(ThemeBackend.subtext0, 0.45);
                }

                AxisFlow {
                    id: pomoLayout
                    vertical: root.isVertical
                    horizontalItemAlignment: Grid.AlignHCenter
                    verticalItemAlignment: Grid.AlignVCenter
                    spacing: root.isVertical
                        ? (barWindow ? barWindow.cs(root.isCompact ? 3 : 4) : (root.isCompact ? 3 : 4))
                        : (barWindow ? barWindow.cs(root.isCompact ? 5 : 6) : (root.isCompact ? 5 : 6))

                    scale: pomoMouse.pressed ? 0.95 : (pomoMouse.containsMouse ? 1.04 : 1.0)
                    Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                    Text {
                        text: PomodoroService.phaseIcon
                        font.family: ThemeBackend.iconFont
                        font.pixelSize: root.isVertical
                            ? (barWindow ? barWindow.cs(root.isCompact ? 11 : 12) : (root.isCompact ? 11 : 12))
                            : (barWindow ? barWindow.cs(root.isCompact ? 12 : 13) : (root.isCompact ? 12 : 13))
                        color: pomoContainer.activeColor
                        opacity: pomoContainer.isSessionActive ? 1.0 : (pomoMouse.containsMouse ? 0.9 : 0.6)
                        Behavior on color { ColorAnimation { duration: 200 } }
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }

                    Text {
                        text: PomodoroService.formattedTime
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: root.isVertical
                            ? (barWindow ? barWindow.cs(root.isCompact ? 10.5 : 11.5) : (root.isCompact ? 10.5 : 11.5))
                            : (barWindow ? barWindow.cs(root.isCompact ? 12.5 : 13.5) : (root.isCompact ? 12.5 : 13.5))
                        font.weight: pomoContainer.isSessionActive ? Font.Black : Font.Bold
                        color: pomoContainer.activeColor
                        visible: pomoContainer.isSessionActive
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }

                MouseArea {
                    id: pomoMouse
                    anchors.fill: parent
                    anchors.margins: -(barWindow ? barWindow.cs(6) : 6)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

                    onEntered: {
                        let targetItem = module ? module : pomoContainer;
                        let pt = targetItem.mapToItem(null, 0, 0);
                        let scr = (barWindow && barWindow.screen) ? barWindow.screen : null;
                        let globX = root.isVertical
                            ? (root.isRightBar ? pt.x : (pt.x + targetItem.width))
                            : (pt.x + (targetItem.width / 2));
                        let globY = root.isVertical
                            ? (pt.y + (targetItem.height / 2))
                            : (root.isBottomBar ? pt.y : (pt.y + targetItem.height));
                        PomodoroController.itemEntered(
                            scr,
                            globX,
                            globY,
                            root.isVertical && root.isRightBar,
                            !root.isVertical && root.isBottomBar,
                            root.isVertical
                        );
                    }

                    onExited: {
                        PomodoroController.itemExited();
                    }

                    onClicked: function(mouse) {
                        if (mouse.button === Qt.LeftButton) {
                            root.togglePomodoroNotch();
                        } else if (mouse.button === Qt.MiddleButton || mouse.button === Qt.RightButton) {
                            PomodoroService.toggle();
                        }
                    }
                }
            }

            AxisFlow {
                id: timerLayout
                vertical: root.isVertical
                horizontalItemAlignment: Grid.AlignHCenter
                spacing: root.innerSpacing
                visible: root.isTimerActive

                Repeater {
                    model: root.timerEntries

                    AxisFlow {
                        id: timerItem
                        vertical: root.isVertical
                        horizontalItemAlignment: Grid.AlignHCenter
                        verticalItemAlignment: Grid.AlignVCenter
                        required property var modelData
                        readonly property color entryColor: modelData.colorType === "green" ? root.greenColor : ThemeBackend.mauve
                        spacing: root.isVertical ? (barWindow ? barWindow.cs(root.isCompact ? 3 : 4) : (root.isCompact ? 3 : 4)) : (barWindow ? barWindow.cs(root.isCompact ? 5 : 6) : (root.isCompact ? 5 : 6))

                        Text {
                            text: timerItem.modelData.icon
                            font.family: ThemeBackend.iconFont
                            font.pixelSize: root.isVertical ? (barWindow ? barWindow.cs(root.isCompact ? 10 : 11) : (root.isCompact ? 10 : 11)) : (barWindow ? barWindow.cs(root.isCompact ? 11 : 12) : (root.isCompact ? 11 : 12))
                            color: root.isCompact ? Qt.lighter(timerItem.entryColor, 1.08) : timerItem.entryColor
                            Behavior on color { ColorAnimation { duration: 250 } }
                        }

                        Text {
                            text: timerItem.modelData.time
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: root.isVertical ? (barWindow ? barWindow.cs(root.isCompact ? 11 : 12) : (root.isCompact ? 11 : 12)) : (barWindow ? barWindow.cs(root.isCompact ? 13 : 14) : (root.isCompact ? 13 : 14))
                            font.weight: Font.Bold
                            color: root.isCompact ? Qt.lighter(timerItem.entryColor, 1.08) : timerItem.entryColor
                            Behavior on color { ColorAnimation { duration: 250 } }
                        }
                    }
                }
            }
        }
    }

    Component.onCompleted: syncRecordingSubscription()

    Component.onDestruction: {
        if (recSubscribed) RecordingState.unsubscribe();
    }
}
