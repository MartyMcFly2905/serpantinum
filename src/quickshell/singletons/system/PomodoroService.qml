pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

/**
 * PomodoroService
 * Standalone singleton managing the Pomodoro workflow, state persistence
 * (~/.config/serpantinum/pomodoro.json), desktop notifications (notify-send),
 * and asynchronous audio feedback (pw-play / paplay / Sounds).
 */
Item {
    id: root

    readonly property string configDirPath: {
        let xdg = Quickshell.env("XDG_CONFIG_HOME");
        let base = (xdg && xdg !== "") ? xdg : ((Quickshell.env("HOME") || "") + "/.config");
        return base + "/serpantinum";
    }

    readonly property string configFilePath: configDirPath + "/pomodoro.json"

    // Phase constants: 0 = Work (Lavoro), 1 = Short Break (Pausa Breve), 2 = Long Break (Pausa Lunga)
    readonly property int phaseWork: 0
    readonly property int phaseShortBreak: 1
    readonly property int phaseLongBreak: 2

    // User preferences (persisted in ~/.config/serpantinum/pomodoro.json)
    property int workDuration: 25
    property int shortBreakDuration: 5
    property int longBreakDuration: 15
    property int targetSessions: 4
    property bool autoStartNext: false
    property bool soundEnabled: true
    property bool notificationsEnabled: true
    property string soundFile: "notifications/Progress.wav"

    // Runtime state (persisted in ~/.config/serpantinum/pomodoro.json)
    property int phase: 0
    property int sessionsCount: 0
    property int totalCompletedToday: 0
    property string lastActiveDate: ""
    property real targetEpoch: 0
    property int remainingMs: 25 * 60 * 1000
    property bool stateLoaded: false

    readonly property bool isRunning: targetEpoch > 0
    readonly property int currentPhaseTotalMs: getPhaseDurationMinutes(phase) * 60 * 1000
    readonly property bool isPausedMidSession: !isRunning && remainingMs > 0 && remainingMs < currentPhaseTotalMs
    readonly property bool isActiveOrPaused: isRunning || isPausedMidSession || phase !== 0 || sessionsCount > 0
    readonly property real progress: currentPhaseTotalMs > 0
        ? Math.max(0.0, Math.min(1.0, 1.0 - (remainingMs / currentPhaseTotalMs)))
        : 0.0

    readonly property string formattedTime: formatMs(remainingMs)

    readonly property string phaseKey: {
        if (phase === 1) return "short_break";
        if (phase === 2) return "long_break";
        return "work";
    }

    readonly property string phaseLabel: {
        if (typeof I18n === "undefined") {
            return phase === 0 ? "Lavoro" : (phase === 1 ? "Pausa Breve" : "Pausa Lunga");
        }
        if (phase === 0) return I18n.t("pomodoro.phase.work", I18n.t("quickactions.timer.pomodoro.phases.focus", "Work"));
        if (phase === 1) return I18n.t("pomodoro.phase.short_break", I18n.t("quickactions.timer.pomodoro.phases.short_break", "Short Break"));
        return I18n.t("pomodoro.phase.long_break", I18n.t("quickactions.timer.pomodoro.phases.long_break", "Long Break"));
    }

    readonly property string phaseShortLabel: {
        if (typeof I18n === "undefined") {
            return phase === 0 ? "Lavoro" : (phase === 1 ? "Breve" : "Lunga");
        }
        if (phase === 0) return I18n.t("pomodoro.phase.work_short", "Work");
        if (phase === 1) return I18n.t("pomodoro.phase.short_break_short", "Short");
        return I18n.t("pomodoro.phase.long_break_short", "Long");
    }

    readonly property string phaseIcon: {
        if (phase === 0) return "󰔟";
        if (phase === 1) return "󰒲";
        return "󰤄";
    }

    readonly property string phaseColorType: {
        if (phase === 0) return "mauve";
        if (phase === 1) return "green";
        return "sapphire";
    }

    readonly property color phaseColor: {
        if (typeof ThemeBackend === "undefined") return "#cba6f7";
        if (phase === 0) return ThemeBackend.mauve;
        if (phase === 1) return ThemeBackend.green;
        return ThemeBackend.sapphire !== undefined ? ThemeBackend.sapphire : ThemeBackend.blue;
    }

    signal sessionCompleted(int completedPhase)
    signal stateUpdated()

    function getTodayDateStr() {
        let now = new Date();
        return now.getFullYear() + "-"
            + String(now.getMonth() + 1).padStart(2, "0") + "-"
            + String(now.getDate()).padStart(2, "0");
    }

    function getPhaseDurationMinutes(p) {
        if (p === 1) return Math.max(1, root.shortBreakDuration);
        if (p === 2) return Math.max(1, root.longBreakDuration);
        return Math.max(1, root.workDuration);
    }

    function formatMs(ms) {
        let totalSeconds = Math.max(0, Math.ceil((ms || 0) / 1000));
        let hours = Math.floor(totalSeconds / 3600);
        let minutes = Math.floor((totalSeconds % 3600) / 60);
        let seconds = totalSeconds % 60;
        let mStr = minutes < 10 ? "0" + minutes : "" + minutes;
        let sStr = seconds < 10 ? "0" + seconds : "" + seconds;
        if (hours > 0) {
            let hStr = hours < 10 ? "0" + hours : "" + hours;
            return hStr + ":" + mStr + ":" + sStr;
        }
        return mStr + ":" + sStr;
    }

    // Play completion sound asynchronously via PipeWire/PulseAudio without blocking UI
    function playCompletionSound() {
        if (!root.soundEnabled) return;
        let relSound = (root.soundFile && root.soundFile.trim() !== "") ? root.soundFile.trim() : "notifications/Progress.wav";
        let fullPath = relSound.startsWith("/")
            ? relSound
            : ((typeof Caching !== "undefined" && Caching.serpantinumDir)
                ? (Caching.serpantinumDir + "/assets/sounds/" + relSound)
                : Qt.resolvedUrl("../../../assets/sounds/" + relSound).toString().replace(/^file:\/\//, ""));

        let escaped = fullPath.replace(/'/g, "'\\''");
        let cmd = "(pw-play --volume=1.0 '" + escaped + "' || paplay '" + escaped + "') >/dev/null 2>&1 &";
        try {
            Quickshell.execDetached(["sh", "-c", cmd]);
        } catch (e) {
            if (typeof Sounds !== "undefined") {
                Sounds.playSfx(relSound, 1.0, 0, true);
            }
        }
    }

    function sendNotification(title, body, iconName) {
        if (!root.notificationsEnabled) return;
        let appName = (typeof I18n !== "undefined")
            ? I18n.t("pomodoro.notification.app_name", "Pomodoro Timer")
            : "Pomodoro Timer";
        let ic = iconName || "preferences-system-time";
        try {
            Quickshell.execDetached([
                "notify-send",
                "-a", appName,
                "-i", ic,
                "-u", "normal",
                title,
                body
            ]);
        } catch (e) {}
    }

    // Public Controls
    function start() {
        if (root.isRunning) return;
        if (root.remainingMs <= 0) {
            root.remainingMs = root.getPhaseDurationMinutes(root.phase) * 60 * 1000;
        }
        root.targetEpoch = Date.now() + root.remainingMs;
        root.saveConfig();
        root.stateUpdated();
    }

    function pause() {
        if (!root.isRunning) return;
        root.remainingMs = Math.max(0, Math.round(root.targetEpoch - Date.now()));
        root.targetEpoch = 0;
        root.saveConfig();
        root.stateUpdated();
    }

    function toggle() {
        if (root.isRunning) {
            root.pause();
        } else {
            root.start();
        }
    }

    function reset() {
        root.targetEpoch = 0;
        root.remainingMs = root.getPhaseDurationMinutes(root.phase) * 60 * 1000;
        root.saveConfig();
        root.stateUpdated();
    }

    function fullReset() {
        root.targetEpoch = 0;
        root.phase = 0;
        root.sessionsCount = 0;
        root.remainingMs = root.workDuration * 60 * 1000;
        root.saveConfig();
        root.stateUpdated();
    }

    function selectPhase(newPhase, autoStart) {
        let p = Math.max(0, Math.min(2, Number(newPhase) || 0));
        root.targetEpoch = 0;
        root.phase = p;
        root.remainingMs = root.getPhaseDurationMinutes(p) * 60 * 1000;
        if (autoStart === true) {
            root.targetEpoch = Date.now() + root.remainingMs;
        }
        root.saveConfig();
        root.stateUpdated();
    }

    function skip() {
        let prevPhase = root.phase;
        root.targetEpoch = 0;
        root._advanceToNextPhase(false);
        let title = (typeof I18n !== "undefined")
            ? I18n.t("quickactions.timer.notification.pomo_skipped_title", "Session Skipped")
            : "Session Skipped";
        let body = prevPhase === 0
            ? ((typeof I18n !== "undefined") ? I18n.t("quickactions.timer.notification.pomo_skipped_focus_body", "Focus session skipped. Starting break.") : "Focus session skipped. Starting break.")
            : ((typeof I18n !== "undefined") ? I18n.t("quickactions.timer.notification.pomo_skipped_break_body", "Break skipped. Back to focus.") : "Break skipped. Back to focus.");
        root.sendNotification(title, body, "media-skip-forward");
    }

    function setWorkDuration(mins) {
        let val = Math.max(1, Math.min(180, Math.round(Number(mins) || 25)));
        if (root.workDuration === val) return;
        root.workDuration = val;
        if (!root.isRunning && root.phase === 0) {
            root.remainingMs = val * 60 * 1000;
        }
        root.saveConfig();
        root.stateUpdated();
    }

    function setShortBreakDuration(mins) {
        let val = Math.max(1, Math.min(60, Math.round(Number(mins) || 5)));
        if (root.shortBreakDuration === val) return;
        root.shortBreakDuration = val;
        if (!root.isRunning && root.phase === 1) {
            root.remainingMs = val * 60 * 1000;
        }
        root.saveConfig();
        root.stateUpdated();
    }

    function setLongBreakDuration(mins) {
        let val = Math.max(1, Math.min(120, Math.round(Number(mins) || 15)));
        if (root.longBreakDuration === val) return;
        root.longBreakDuration = val;
        if (!root.isRunning && root.phase === 2) {
            root.remainingMs = val * 60 * 1000;
        }
        root.saveConfig();
        root.stateUpdated();
    }

    function setTargetSessions(count) {
        let val = Math.max(1, Math.min(12, Math.round(Number(count) || 4)));
        if (root.targetSessions === val) return;
        root.targetSessions = val;
        root.saveConfig();
        root.stateUpdated();
    }

    function setAutoStartNext(enabled) {
        let val = Boolean(enabled);
        if (root.autoStartNext === val) return;
        root.autoStartNext = val;
        root.saveConfig();
    }

    function setSoundEnabled(enabled) {
        let val = Boolean(enabled);
        if (root.soundEnabled === val) return;
        root.soundEnabled = val;
        root.saveConfig();
    }

    function _advanceToNextPhase(allowAutoStart) {
        let completedPhase = root.phase;
        let today = root.getTodayDateStr();
        if (root.lastActiveDate !== today) {
            root.lastActiveDate = today;
            root.totalCompletedToday = 0;
        }

        if (completedPhase === 0) {
            root.sessionsCount++;
            root.totalCompletedToday++;
            if (root.sessionsCount >= root.targetSessions) {
                root.phase = 2;
                root.sessionsCount = 0;
                root.remainingMs = root.longBreakDuration * 60 * 1000;
            } else {
                root.phase = 1;
                root.remainingMs = root.shortBreakDuration * 60 * 1000;
            }
        } else {
            root.phase = 0;
            root.remainingMs = root.workDuration * 60 * 1000;
        }

        if (allowAutoStart && root.autoStartNext) {
            root.targetEpoch = Date.now() + root.remainingMs;
        } else {
            root.targetEpoch = 0;
        }

        root.saveConfig();
        root.sessionCompleted(completedPhase);
        root.stateUpdated();
    }

    function _onPhaseExpired() {
        let finishedPhase = root.phase;
        root.targetEpoch = 0;
        root.remainingMs = 0;

        root.playCompletionSound();

        if (finishedPhase === 0) {
            root.sendNotification(
                (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.notification.focus_complete_title", "Focus Session Complete!") : "Focus Session Complete!",
                (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.notification.focus_complete_body", "Great job! Time for a break.") : "Great job! Time for a break.",
                "preferences-system-time"
            );
        } else {
            root.sendNotification(
                (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.notification.break_over_title", "Break Over!") : "Break Over!",
                (typeof I18n !== "undefined") ? I18n.t("quickactions.timer.notification.break_over_body", "Ready to start your next focus session?") : "Ready to start your next focus session?",
                "preferences-system-time"
            );
        }

        root._advanceToNextPhase(true);
    }

    Timer {
        id: tickTimer
        interval: 250
        repeat: true
        running: root.isRunning
        onTriggered: {
            let now = Date.now();
            if (now >= root.targetEpoch) {
                root._onPhaseExpired();
            } else {
                root.remainingMs = Math.max(0, Math.round(root.targetEpoch - now));
            }
        }
    }

    Process {
        id: saveProc
    }

    function saveConfig() {
        if (!root.stateLoaded) return;
        let payload = {
            workDuration: root.workDuration,
            shortBreakDuration: root.shortBreakDuration,
            longBreakDuration: root.longBreakDuration,
            targetSessions: root.targetSessions,
            autoStartNext: root.autoStartNext,
            soundEnabled: root.soundEnabled,
            notificationsEnabled: root.notificationsEnabled,
            soundFile: root.soundFile,
            phase: root.phase,
            sessionsCount: root.sessionsCount,
            totalCompletedToday: root.totalCompletedToday,
            lastActiveDate: root.lastActiveDate || root.getTodayDateStr(),
            isRunning: root.isRunning,
            targetEpoch: root.targetEpoch,
            remainingMs: root.remainingMs
        };
        let jsonStr = JSON.stringify(payload, null, 2);
        let escapedDir = root.configDirPath.replace(/'/g, "'\\''");
        let escapedFile = root.configFilePath.replace(/'/g, "'\\''");
        let escapedJson = jsonStr.replace(/'/g, "'\\''");
        saveProc.running = false;
        saveProc.command = [
            "bash", "-c",
            "mkdir -p '" + escapedDir + "' && printf '%s\\n' '" + escapedJson + "' > '" + escapedFile + ".tmp' && mv '" + escapedFile + ".tmp' '" + escapedFile + "'"
        ];
        saveProc.running = true;
    }

    function restoreFromJson(rawText) {
        let txt = (rawText || "").trim();
        let today = root.getTodayDateStr();
        if (txt !== "") {
            try {
                let data = JSON.parse(txt);
                if (data && typeof data === "object") {
                    if (data.workDuration !== undefined) root.workDuration = Math.max(1, Math.min(180, Number(data.workDuration) || 25));
                    if (data.shortBreakDuration !== undefined) root.shortBreakDuration = Math.max(1, Math.min(60, Number(data.shortBreakDuration) || 5));
                    if (data.longBreakDuration !== undefined) root.longBreakDuration = Math.max(1, Math.min(120, Number(data.longBreakDuration) || 15));
                    if (data.targetSessions !== undefined) root.targetSessions = Math.max(1, Math.min(12, Number(data.targetSessions) || 4));
                    if (data.autoStartNext !== undefined) root.autoStartNext = Boolean(data.autoStartNext);
                    if (data.soundEnabled !== undefined) root.soundEnabled = Boolean(data.soundEnabled);
                    if (data.notificationsEnabled !== undefined) root.notificationsEnabled = Boolean(data.notificationsEnabled);
                    if (data.soundFile !== undefined && String(data.soundFile).trim() !== "") root.soundFile = String(data.soundFile).trim();

                    if (data.phase !== undefined) root.phase = Math.max(0, Math.min(2, Number(data.phase) || 0));
                    if (data.sessionsCount !== undefined) root.sessionsCount = Math.max(0, Number(data.sessionsCount) || 0);
                    if (data.lastActiveDate === today && data.totalCompletedToday !== undefined) {
                        root.totalCompletedToday = Math.max(0, Number(data.totalCompletedToday) || 0);
                        root.lastActiveDate = today;
                    } else {
                        root.totalCompletedToday = 0;
                        root.lastActiveDate = today;
                    }

                    let now = Date.now();
                    if (data.targetEpoch && Number(data.targetEpoch) > 0) {
                        let te = Number(data.targetEpoch);
                        if (now >= te) {
                            root.stateLoaded = true;
                            root._onPhaseExpired();
                            return;
                        } else {
                            root.targetEpoch = te;
                            root.remainingMs = Math.max(0, Math.round(te - now));
                        }
                    } else if (data.remainingMs !== undefined && Number(data.remainingMs) > 0) {
                        root.targetEpoch = 0;
                        root.remainingMs = Number(data.remainingMs);
                    } else {
                        root.targetEpoch = 0;
                        root.remainingMs = root.getPhaseDurationMinutes(root.phase) * 60 * 1000;
                    }
                }
            } catch (e) {
                root.remainingMs = root.workDuration * 60 * 1000;
            }
        } else {
            root.lastActiveDate = today;
            root.remainingMs = root.workDuration * 60 * 1000;
        }
        root.stateLoaded = true;
        root.saveConfig();
        root.stateUpdated();
    }

    Process {
        id: loadProc
        command: ["bash", "-c", "if [ -f '" + root.configFilePath.replace(/'/g, "'\\''") + "' ]; then cat '" + root.configFilePath.replace(/'/g, "'\\''") + "'; fi"]
        stdout: StdioCollector {
            id: loadStdout
            onStreamFinished: {
                root.restoreFromJson(loadStdout.text);
            }
        }
    }

    Component.onCompleted: {
        loadProc.running = true;
    }
}
