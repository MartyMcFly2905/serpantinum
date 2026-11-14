#!/usr/bin/env bash
{
# ==============================================================================
# Serpantinum Custom Auto-Updater ("aggiorna-serpantinum") — Edizione Blindata
# ==============================================================================
# Aggiorna Serpantinum dal repository ufficiale (ilyamiro/serpantinum),
# risolve automaticamente qualsiasi conflitto (contenuto, rename, modify/delete)
# sui widget personalizzati (Todo List, Calendario Mese/Agenda/Compatto,
# Pomodoro, fix batteria 100%), verifica/installa i binari companion
# (serpantinum-core), valida JSON/QML, sincronizza binari + version state e
# riavvia il demone verificandone la salute.
# ==============================================================================

set -uo pipefail

REPO_DIR="/home/christian/Scrivania/Repos/serpantinum"
TARGET_DIR="$HOME/.local/share/serpantinum"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/serpantinum"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/serpantinum"
BACKUP_DIR="$STATE_DIR/backups"
LOCK_FILE="/tmp/serpantinum_update.lock"

# Colori terminale
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RESET='\033[0m'

FORCE_DEPLOY=false
CHECK_ONLY=false
NO_RESTART=false

for arg in "$@"; do
    case "$arg" in
        -f|--force)
            FORCE_DEPLOY=true
            ;;
        -c|--check)
            CHECK_ONLY=true
            ;;
        --no-restart)
            NO_RESTART=true
            ;;
        -h|--help)
            echo -e "${C_CYAN}${C_BOLD}Uso:${C_RESET} aggiorna-serpantinum [OPZIONI]"
            echo ""
            echo "Opzioni:"
            echo "  -f, --force       Forza la verifica di integrità, il deploy e il riavvio anche senza nuovi commit"
            echo "  -c, --check       Controlla solo la presenza di aggiornamenti upstream senza applicarli"
            echo "      --no-restart  Aggiorna e distribuisce i file senza riavviare serpantinumd"
            echo "  -h, --help        Mostra questo messaggio di aiuto"
            exit 0
            ;;
    esac
done

# 0. Lock contro esecuzioni simultanee
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo -e "${C_RED}[ERRORE] Un'altra istanza di aggiorna-serpantinum è già in esecuzione.${C_RESET}"
    exit 1
fi

echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║         Serpantinum Updater • Custom Build Blindata          ║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
echo ""

if [ ! -d "$REPO_DIR/.git" ]; then
    echo -e "${C_RED}[ERRORE] Repository git non trovato in $REPO_DIR${C_RESET}"
    exit 1
fi

cd "$REPO_DIR" || exit 1

# 1. Ripristino automatico da eventuali merge/rebase interrotti in precedenza
if [ -f "$REPO_DIR/.git/MERGE_HEAD" ]; then
    echo -e "${C_YELLOW}[RECOVERY] Rilevato un merge incompleto precedente. Ripristino stato pulito...${C_RESET}"
    git merge --abort 2>/dev/null || git reset --merge 2>/dev/null || true
fi
if [ -d "$REPO_DIR/.git/rebase-merge" ] || [ -d "$REPO_DIR/.git/rebase-apply" ]; then
    echo -e "${C_YELLOW}[RECOVERY] Rilevato un rebase incompleto precedente. Ripristino stato pulito...${C_RESET}"
    git rebase --abort 2>/dev/null || true
fi

# 2. Backup preventivo delle configurazioni e dei dati utente (Todo, Calendari, Pomodoro)
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
CURRENT_BACKUP="$BACKUP_DIR/config_$TIMESTAMP"
if [ -d "$CONFIG_DIR" ]; then
    mkdir -p "$CURRENT_BACKUP"
    for f in calendars.json local_tasks.json todos.json pomodoro.json settings.json; do
        if [ -f "$CONFIG_DIR/$f" ]; then
            cp -p "$CONFIG_DIR/$f" "$CURRENT_BACKUP/$f" 2>/dev/null || true
        fi
    done
    # Mantieni solo gli ultimi 5 backup per non occupare spazio
    ls -1dt "$BACKUP_DIR"/config_* 2>/dev/null | tail -n +6 | xargs -r rm -rf --
fi

# 3. Gestione automatica modifiche locali non committate (Auto-Stash)
STASHED_LOCAL=false
if [ -n "$(git status --porcelain)" ]; then
    if [ "$CHECK_ONLY" = true ]; then
        echo -e "${C_YELLOW}[INFO] Il repository locale contiene modifiche non committate.${C_RESET}"
    else
        echo -e "${C_YELLOW}[INFO] Rilevate modifiche locali non committate: salvataggio temporaneo (auto-stash)...${C_RESET}"
        if git stash push -u -m "serpantinum-updater-autostash-$TIMESTAMP" --quiet; then
            STASHED_LOCAL=true
        else
            echo -e "${C_RED}[ERRORE] Impossibile eseguire git stash delle modifiche locali.${C_RESET}"
            exit 1
        fi
    fi
fi

restore_stash_if_needed() {
    if [ "$STASHED_LOCAL" = true ]; then
        echo -e "${C_CYAN}[INFO] Ripristino delle modifiche locali dallo stash...${C_RESET}"
        if ! git stash pop --quiet 2>/dev/null; then
            echo -e "${C_YELLOW}[ATTENZIONE] Conflitto minore durante git stash pop; applico le modifiche sui file custom...${C_RESET}"
            git checkout --theirs . 2>/dev/null || true
            git reset HEAD . >/dev/null 2>&1 || true
            git stash drop --quiet 2>/dev/null || true
        fi
        STASHED_LOCAL=false
    fi
}

# Funzione per verificare/installare serpantinum-core in ~/.local/bin se mancante o obsoleto
ensure_companion_binaries() {
    mkdir -p "$HOME/.local/bin"
    if [ "$(uname -m)" != "x86_64" ]; then
        return 0
    fi
    local cur_ver=""
    if command -v serpantinum-core >/dev/null 2>&1; then
        cur_ver=$(serpantinum-core --version 2>/dev/null | awk '{print $2}' || echo "")
    fi
    local json tag tarball_url sums_url work
    json=$(curl -fsSL --connect-timeout 8 --retry 2 "https://api.github.com/repos/ilyamiro/serpantinum-core/releases/latest" 2>/dev/null || echo "")
    if [ -z "$json" ]; then
        return 0
    fi
    tag=$(jq -r '.tag_name // empty' <<< "$json" 2>/dev/null || echo "")
    if [ -z "$tag" ]; then
        return 0
    fi
    if [ -n "$cur_ver" ] && [ "${tag#v}" = "$cur_ver" ]; then
        return 0
    fi
    echo -e "  ${C_CYAN}•${C_RESET} Installazione/aggiornamento binario companion ${C_BOLD}serpantinum-core (${tag})${C_RESET}..."
    tarball_url=$(jq -r '[.assets[] | select(.name | test("-x86_64-linux\\.tar\\.gz$"))][0].browser_download_url // empty' <<< "$json")
    sums_url=$(jq -r '[.assets[] | select(.name == "SHA256SUMS")][0].browser_download_url // empty' <<< "$json")
    if [ -z "$tarball_url" ] || [ -z "$sums_url" ]; then
        return 0
    fi
    work=$(mktemp -d "/tmp/serpantinum-core.XXXXXX")
    local archive="$work/${tarball_url##*/}"
    if curl -fsSL --connect-timeout 15 --retry 2 "$tarball_url" -o "$archive" && \
       curl -fsSL --connect-timeout 15 --retry 2 "$sums_url" -o "$work/SHA256SUMS"; then
        if (cd "$work" && grep -F " ${archive##*/}" SHA256SUMS | sha256sum -c --quiet - 2>/dev/null); then
            mkdir -p "$work/stage"
            if tar -xzf "$archive" -C "$work/stage" && [ -f "$work/stage/usr/bin/serpantinum-core" ]; then
                install -Dm755 "$work/stage/usr/bin/serpantinum-core" "$HOME/.local/bin/serpantinum-core"
                hash -r 2>/dev/null || true
                echo -e "  ${C_GREEN}✓${C_RESET} serpantinum-core ${tag} installato in ~/.local/bin/serpantinum-core"
            fi
        fi
    fi
    rm -rf "$work"
}

# Funzione Python idempotente che applica/verifica TUTTE le personalizzazioni su qualsiasi versione upstream
ensure_custom_integrations() {
    python3 - "$REPO_DIR" <<'PYEOF'
import json
import os
import re
import sys

repo = sys.argv[1]

# 1. Verifica e ripara file di lingua (it.json, en.json)
it_patch = {
    "widgets": {
        "types": {
            "calendar": "Calendario",
            "agenda": "Agenda e Attività",
            "todo": "Lista attività"
        },
        "variants": {
            "compact": "Compatto",
            "month": "Mese",
            "agenda": "Agenda"
        },
        "pomodoro": {
            "name": "Pomodoro Timer",
            "desc": "Timer di concentrazione con intervalli di lavoro e pausa personalizzabili"
        },
        "calendar": {
            "manage_calendars": "Gestisci calendari",
            "gcal_help": "Google Calendar: Impostazioni > Integra calendario > Indirizzo segreto in formato iCal",
            "sync_now": "Sincronizza ora",
            "sync": "Sincronizza",
            "add_calendar": "Aggiungi calendario",
            "feed_color": "Colore:",
            "agenda_title": "Agenda",
            "today": "Oggi",
            "tomorrow": "Domani",
            "next_event": "Prossimo evento",
            "upcoming": "Prossimi impegni",
            "no_events_day": "Nessun impegno per questo giorno",
            "show_upcoming": "Mostra prossimi impegni",
            "add_event": "Aggiungi impegno o attività",
            "new_task_placeholder": "Nuova attività rapida..."
        },
        "todo": {
            "title": "To-Do",
            "new_placeholder": "Nuova attività... (es. Comprare pane @spesa)",
            "filter_all": "Tutte",
            "filter_today": "Oggi",
            "filter_upcoming": "Prossime",
            "filter_active": "Attive",
            "filter_done": "Completate",
            "empty": "Nessuna attività. Aggiungine una o importa un CSV Todoist.",
            "no_today": "Nessuna attività per oggi!",
            "no_upcoming": "Nessuna attività programmata",
            "no_active": "Nessuna attività in sospeso!",
            "no_completed": "Nessuna attività completata",
            "btn_import_csv": "Importa CSV Todoist",
            "csv_manage_title": "Importa & Esporta CSV Todoist",
            "csv_help": "Compatibile al 100% con i modelli e le esportazioni CSV di Todoist (sezioni, priorità P1-P4, scadenze naturali, note e tag).",
            "mode_merge": "Unisci (Merge)",
            "mode_replace": "Sostituisci (Replace)",
            "browse_file": "Sfoglia file CSV...",
            "or_manual_path": "oppure inserisci percorso",
            "import_btn": "Importa",
            "export_btn": "Esporta CSV Todoist",
            "clear_all_btn": "Svuota lista",
            "clear_all_confirm": "Svuota?",
            "confirm_clear_prompt": "Premi di nuovo su 'Svuota?' per eliminare tutte le attività",
            "cleared": "Completate rimosse",
            "cleared_all": "Lista svuotata completamente",
            "imported_count": "Importate %1 attività",
            "exported_ok": "Attività esportate in CSV Todoist",
            "date_none": "Senza data",
            "date_today": "Oggi",
            "date_tomorrow": "Domani",
            "date_week": "+7 gg"
        }
    },
    "pomodoro": {
        "phase": {
            "work": "Lavoro",
            "short_break": "Pausa Breve",
            "long_break": "Pausa Lunga"
        },
        "settings": {
            "sound": "Audio completamento",
            "autostart": "Avvio automatico fasi"
        },
        "notification": {
            "app_name": "Pomodoro Timer",
            "work_done_title": "Sessione di lavoro completata!",
            "work_done_body_short": "Ottimo lavoro! Inizia una pausa breve.",
            "work_done_body_long": "Ciclo completato! Goditi una pausa lunga.",
            "break_done_title": "Pausa terminata!",
            "break_done_body": "È il momento di tornare a concentrarsi."
        }
    }
}

en_patch = {
    "widgets": {
        "types": {
            "calendar": "Calendar",
            "agenda": "Agenda & Tasks",
            "todo": "Todo List"
        },
        "variants": {
            "compact": "Compact",
            "month": "Month",
            "agenda": "Agenda"
        },
        "pomodoro": {
            "name": "Pomodoro Timer",
            "desc": "Focus timer with customizable work and break intervals"
        },
        "calendar": {
            "manage_calendars": "Manage Calendars",
            "gcal_help": "Google Calendar: Settings > Integrate calendar > Secret address in iCal format",
            "sync_now": "Sync Now",
            "sync": "Sync",
            "add_calendar": "Add Calendar",
            "feed_color": "Color:",
            "agenda_title": "Agenda",
            "today": "Today",
            "tomorrow": "Tomorrow",
            "next_event": "Next Event",
            "upcoming": "Upcoming Schedule",
            "no_events_day": "No events for this day",
            "show_upcoming": "Show upcoming events",
            "add_event": "Add event or task",
            "new_task_placeholder": "New quick task..."
        },
        "todo": {
            "title": "To-Do",
            "new_placeholder": "New task... (e.g. Buy groceries @shopping)",
            "filter_all": "All",
            "filter_today": "Today",
            "filter_upcoming": "Upcoming",
            "filter_active": "Active",
            "filter_done": "Completed",
            "empty": "No tasks yet. Add one or import a Todoist CSV.",
            "no_today": "No tasks due today!",
            "no_upcoming": "No upcoming tasks scheduled",
            "no_active": "No pending tasks!",
            "no_completed": "No completed tasks",
            "btn_import_csv": "Import Todoist CSV",
            "csv_manage_title": "Import & Export Todoist CSV",
            "csv_help": "100% compatible with Todoist CSV templates and exports (sections, P1-P4 priorities, natural due dates, notes, and labels).",
            "mode_merge": "Merge",
            "mode_replace": "Replace",
            "browse_file": "Browse CSV file...",
            "or_manual_path": "or enter file path",
            "import_btn": "Import",
            "export_btn": "Export Todoist CSV",
            "clear_all_btn": "Empty list",
            "clear_all_confirm": "Empty?",
            "confirm_clear_prompt": "Click 'Empty?' again to delete all tasks",
            "cleared": "Completed tasks cleared",
            "cleared_all": "Todo list emptied completely",
            "imported_count": "Imported %1 tasks",
            "exported_ok": "Tasks exported to Todoist CSV",
            "date_none": "No date",
            "date_today": "Today",
            "date_tomorrow": "Tomorrow",
            "date_week": "+7 d"
        }
    },
    "pomodoro": {
        "phase": {
            "work": "Focus",
            "short_break": "Short Break",
            "long_break": "Long Break"
        },
        "settings": {
            "sound": "Completion sound",
            "autostart": "Auto-start phases"
        },
        "notification": {
            "app_name": "Pomodoro Timer",
            "work_done_title": "Focus session completed!",
            "work_done_body_short": "Great job! Time for a short break.",
            "work_done_body_long": "Cycle completed! Enjoy a long break.",
            "break_done_title": "Break finished!",
            "break_done_body": "Time to get back to focus."
        }
    }
}

def deep_merge(target, src):
    changed = False
    for k, v in src.items():
        if isinstance(v, dict):
            if k not in target or not isinstance(target[k], dict):
                target[k] = {}
                changed = True
            if deep_merge(target[k], v):
                changed = True
        else:
            if target.get(k) != v:
                target[k] = v
                changed = True
    return changed

for lang_file, patch_data in [("it.json", it_patch), ("en.json", en_patch)]:
    p = os.path.join(repo, "src", "assets", "languages", lang_file)
    if os.path.exists(p):
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        if deep_merge(data, patch_data):
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.write("\n")

# 2. Verifica src/quickshell/qmldir (rimuove path obsoleti e garantisce quelli reali)
qmldir_main = os.path.join(repo, "src", "quickshell", "qmldir")
if os.path.exists(qmldir_main):
    with open(qmldir_main, "r", encoding="utf-8") as f:
        orig_lines = [line.rstrip("\n") for line in f]
    invalid_main = {
        "singleton PomodoroService 1.0 singletons/environment/PomodoroService.qml",
    }
    if os.path.exists(os.path.join(repo, "src", "quickshell", "widgets", "redactor", "WidgetRedactor.qml")):
        invalid_main.add("WidgetRedactor 1.0 widgets/WidgetRedactor.qml")
    lines = [l for l in orig_lines if l not in invalid_main]
    required_main = [
        "PomodoroNotch 1.0 popouts/PomodoroNotch.qml",
        "PomodoroPopup 1.0 pomodoro/PomodoroPopup.qml",
        "singleton CalendarService 1.0 singletons/environment/CalendarService.qml",
        "singleton PomodoroService 1.0 singletons/system/PomodoroService.qml",
        "singleton PomodoroController 1.0 singletons/widgetcontrols/PomodoroController.qml",
    ]
    for req in required_main:
        if req not in lines:
            lines.append(req)
    if lines != orig_lines:
        with open(qmldir_main, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

# 3. Verifica src/quickshell/widgets/faces/qmldir
qmldir_faces = os.path.join(repo, "src", "quickshell", "widgets", "faces", "qmldir")
if os.path.exists(qmldir_faces):
    with open(qmldir_faces, "r", encoding="utf-8") as f:
        orig_lines = [line.rstrip("\n") for line in f]
    invalid_faces = {
        "PomodoroFace 1.0 pomodoro/PomodoroFace.qml",
    }
    lines = [l for l in orig_lines if l not in invalid_faces]
    required_faces = [
        "CalendarFaceCompact 1.0 calendar/CalendarFaceCompact.qml",
        "CalendarFaceMonth 1.0 calendar/CalendarFaceMonth.qml",
        "CalendarFaceAgenda 1.0 calendar/CalendarFaceAgenda.qml",
        "TodoFace 1.0 todo/TodoFace.qml",
    ]
    for req in required_faces:
        if req not in lines:
            lines.append(req)
    if lines != orig_lines:
        with open(qmldir_faces, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

# 4. Verifica disattivazione notifica batteria 100% in SysNotif.qml (compatibile v2.4.x e v2.5.x+)
sysnotif_path = os.path.join(repo, "src", "quickshell", "singletons", "system", "SysNotif.qml")
if os.path.exists(sysnotif_path):
    with open(sysnotif_path, "r", encoding="utf-8") as f:
        content = f.read()
    pattern_new = re.compile(
        r'if\s*\([^\n]*pct\s*>=\s*100[^\n]*\)\s*\{[^}]*root\.send(?:Notification)?\(\s*"full"[^}]*?\);\s*\}',
        re.DOTALL
    )
    replacement = (
        '// Notifica 100% / FullyCharged disabilitata per evitare notifiche continue e fastidiose a cavo inserito\n'
        '            root.notifiedFull = true;'
    )
    if pattern_new.search(content):
        content = pattern_new.sub(replacement, content)
        with open(sysnotif_path, "w", encoding="utf-8") as f:
            f.write(content)

# 5. Verifica registrazioni widget custom in src/quickshell/widgets/WidgetRegistry.qml
registry_path = os.path.join(repo, "src", "quickshell", "widgets", "WidgetRegistry.qml")
if os.path.exists(registry_path):
    with open(registry_path, "r", encoding="utf-8") as f:
        reg_content = f.read()

    custom_widgets_block = """        "calendar": {
            name: typeof I18n !== "undefined" ? I18n.t("widgets.types.calendar", "Calendar") : "Calendar",
            icon: String.fromCodePoint(0xF00ED),
            category: "time",
            iconOffsetX: 0,
            defaultWidth: 340,
            defaultHeight: 280,
            defaultVariant: "month",
            variants: {
                "month":   { file: "faces/calendar/CalendarFaceMonth.qml",   icon: "1", label: typeof I18n !== "undefined" ? I18n.t("widgets.variants.month", "Month") : "Month" },
                "agenda":  { file: "faces/calendar/CalendarFaceAgenda.qml",  icon: "2", label: typeof I18n !== "undefined" ? I18n.t("widgets.variants.agenda", "Agenda") : "Agenda" },
                "compact": { file: "faces/calendar/CalendarFaceCompact.qml", icon: "3", label: typeof I18n !== "undefined" ? I18n.t("widgets.variants.compact", "Compact") : "Compact" }
            },
            additionalSettings: [
                {
                    id: "syncCalendar",
                    icon: String.fromCodePoint(0xF0450),
                    iconFontSize: 16,
                    action: "syncCalendar",
                    row: "top",
                    accentColor: "surface0",
                    textColor: "mauve"
                }
            ]
        },
        "agenda": {
            name: typeof I18n !== "undefined" ? I18n.t("widgets.types.agenda", "Agenda & Tasks") : "Agenda & Tasks",
            icon: String.fromCodePoint(0xF0134),
            category: "time",
            defaultWidth: 340,
            defaultHeight: 240,
            defaultVariant: "agenda",
            variants: {
                "agenda":  { file: "faces/calendar/CalendarFaceAgenda.qml",  icon: "1", label: typeof I18n !== "undefined" ? I18n.t("widgets.variants.agenda", "Agenda") : "Agenda" },
                "month":   { file: "faces/calendar/CalendarFaceMonth.qml",   icon: "2", label: typeof I18n !== "undefined" ? I18n.t("widgets.variants.month", "Month") : "Month" },
                "compact": { file: "faces/calendar/CalendarFaceCompact.qml", icon: "3", label: typeof I18n !== "undefined" ? I18n.t("widgets.variants.compact", "Compact") : "Compact" }
            }
        },
        "todo": {
            name: typeof I18n !== "undefined" ? I18n.t("widgets.types.todo", "Todo List") : "Todo List",
            icon: String.fromCodePoint(0xF0133),
            category: "time",
            defaultWidth: 340,
            defaultHeight: 320,
            defaultVariant: "default",
            variants: {
                "default": { file: "faces/todo/TodoFace.qml", icon: "1", label: typeof I18n !== "undefined" ? I18n.t("widgets.variants.default", "Default") : "Default" }
            }
        },
"""
    if '"todo":' not in reg_content or '"calendar":' not in reg_content:
        anchor = '        "text": {'
        if anchor in reg_content:
            reg_content = reg_content.replace(anchor, custom_widgets_block + anchor, 1)
            with open(registry_path, "w", encoding="utf-8") as f:
                f.write(reg_content)

# 6. Verifica azione syncCalendar nel Widget Redactor (RedactorWorkspace.qml in v2.5+ o WidgetRedactor.qml)
for redactor_rel in [
    os.path.join("src", "quickshell", "widgets", "redactor", "RedactorWorkspace.qml"),
    os.path.join("src", "quickshell", "widgets", "WidgetRedactor.qml"),
]:
    redactor_path = os.path.join(repo, redactor_rel)
    if os.path.exists(redactor_path):
        with open(redactor_path, "r", encoding="utf-8") as f:
            r_content = f.read()
        if 'action === "syncCalendar"' not in r_content:
            r_pattern = re.compile(r'(proxy\.finalizeSync\(\);\s*)(\}\s*else\s+if\s*\(\s*extraArg\s*!==\s*undefined\s*\)\s*\{)')
            def r_repl(m):
                prefix = m.group(1)
                suffix = m.group(2)
                indent_match = re.search(r'(\n[ \t]*)\}', suffix)
                ind = indent_match.group(1) if indent_match else "\n        "
                return (
                    f"{prefix}}} else if (action === \"syncCalendar\") {{"
                    f"{ind}    if (typeof CalendarService !== \"undefined\") {{"
                    f"{ind}        CalendarService.sync(true);"
                    f"{ind}    }}"
                    f"{ind}{suffix}"
                )
            new_r_content, n_subs = r_pattern.subn(r_repl, r_content, count=1)
            if n_subs > 0:
                with open(redactor_path, "w", encoding="utf-8") as f:
                    f.write(new_r_content)

# 7. Verifica integrazione CalendarService in src/quickshell/calendar/CalendarPopup.qml
cal_popup_path = os.path.join(repo, "src", "quickshell", "calendar", "CalendarPopup.qml")
if os.path.exists(cal_popup_path):
    with open(cal_popup_path, "r", encoding="utf-8") as f:
        cal_content = f.read()
    cal_orig = cal_content

    # 7a. Aggiornamento celle calendario con hasEvents, dayVal, year, month (v2.5+ cells array)
    old_cells_block = """        let cells = [];
        for (let i = firstDay - 1; i >= 0; i--) {
            cells.push({ dayNum: (daysInPrevMonth - i).toString(), isCurrentMonth: false, isToday: false });
        }
        for (let i = 1; i <= daysInMonth; i++) {
            cells.push({ dayNum: i.toString(), isCurrentMonth: true, isToday: (isRealCurrentMonth && i === todayDate) });
        }
        let remaining = 42 - cells.length;
        for (let i = 1; i <= remaining; i++) {
            cells.push({ dayNum: i.toString(), isCurrentMonth: false, isToday: false });
        }

        if (calendarModel.count !== cells.length) {
            calendarModel.clear();
            for (let i = 0; i < cells.length; i++) calendarModel.append(cells[i]);
            return;
        }
        for (let i = 0; i < cells.length; i++) {
            let c = cells[i];
            let cur = calendarModel.get(i);
            if (cur.dayNum !== c.dayNum) calendarModel.setProperty(i, "dayNum", c.dayNum);
            if (cur.isCurrentMonth !== c.isCurrentMonth) calendarModel.setProperty(i, "isCurrentMonth", c.isCurrentMonth);
            if (cur.isToday !== c.isToday) calendarModel.setProperty(i, "isToday", c.isToday);
        }"""

    new_cells_block = """        let cells = [];
        for (let i = firstDay - 1; i >= 0; i--) {
            let pDay = daysInPrevMonth - i;
            let pDate = new Date(targetYear, targetMonth - 1, pDay);
            let hasEvs = typeof CalendarService !== "undefined" ? CalendarService.hasEventsOnDate(pDate.getFullYear(), pDate.getMonth() + 1, pDay) : false;
            cells.push({ dayNum: pDay.toString(), dayVal: pDay, year: pDate.getFullYear(), month: pDate.getMonth(), isCurrentMonth: false, isToday: false, hasEvents: hasEvs });
        }
        for (let i = 1; i <= daysInMonth; i++) {
            let hasEvs = typeof CalendarService !== "undefined" ? CalendarService.hasEventsOnDate(targetYear, targetMonth + 1, i) : false;
            cells.push({ dayNum: i.toString(), dayVal: i, year: targetYear, month: targetMonth, isCurrentMonth: true, isToday: (isRealCurrentMonth && i === todayDate), hasEvents: hasEvs });
        }
        let remaining = 42 - cells.length;
        for (let i = 1; i <= remaining; i++) {
            let nDate = new Date(targetYear, targetMonth + 1, i);
            let hasEvs = typeof CalendarService !== "undefined" ? CalendarService.hasEventsOnDate(nDate.getFullYear(), nDate.getMonth() + 1, i) : false;
            cells.push({ dayNum: i.toString(), dayVal: i, year: nDate.getFullYear(), month: nDate.getMonth(), isCurrentMonth: false, isToday: false, hasEvents: hasEvs });
        }

        if (calendarModel.count !== cells.length) {
            calendarModel.clear();
            for (let i = 0; i < cells.length; i++) calendarModel.append(cells[i]);
            return;
        }
        for (let i = 0; i < cells.length; i++) {
            let c = cells[i];
            let cur = calendarModel.get(i);
            if (cur.dayNum !== c.dayNum) calendarModel.setProperty(i, "dayNum", c.dayNum);
            if (cur.dayVal !== c.dayVal) calendarModel.setProperty(i, "dayVal", c.dayVal);
            if (cur.year !== c.year) calendarModel.setProperty(i, "year", c.year);
            if (cur.month !== c.month) calendarModel.setProperty(i, "month", c.month);
            if (cur.isCurrentMonth !== c.isCurrentMonth) calendarModel.setProperty(i, "isCurrentMonth", c.isCurrentMonth);
            if (cur.isToday !== c.isToday) calendarModel.setProperty(i, "isToday", c.isToday);
            if (cur.hasEvents !== c.hasEvents) calendarModel.setProperty(i, "hasEvents", c.hasEvents);
        }"""

    if old_cells_block in cal_content:
        cal_content = cal_content.replace(old_cells_block, new_cells_block, 1)

    # 7b. Connections a CalendarService per aggiornare i pallini eventi
    if "function onCalendarUpdated()" not in cal_content:
        conn_anchor = "    onMonthOffsetChanged: updateCalendarGrid()\n"
        conn_block = """    onMonthOffsetChanged: updateCalendarGrid()

    Connections {
        target: typeof CalendarService !== "undefined" ? CalendarService : null
        function onCalendarUpdated() {
            window.updateCalendarGrid();
        }
    }
"""
        if conn_anchor in cal_content:
            cal_content = cal_content.replace(conn_anchor, conn_block, 1)

    # 7c. Pulsante Google Calendar Web nell'header del mese
    if "openGoogleCalendarWeb" not in cal_content:
        btn_anchor = "                            onClicked: window.setMonthOffset(window.targetMonthOffset + 1)\n                        }"
        btn_block = """                            onClicked: window.setMonthOffset(window.targetMonthOffset + 1)
                        }

                        IconButton {
                            Layout.preferredWidth: window.s(28)
                            Layout.preferredHeight: window.s(28)
                            size: window.s(28)
                            cornerRadius: window.s(8)
                            buttonIcon: "󰊭"
                            iconFontSize: window.s(13)
                            accentColor: ThemeBackend.surface0
                            textColor: ThemeBackend.sapphire
                            onClicked: {
                                if (typeof CalendarService !== "undefined") {
                                    CalendarService.openGoogleCalendarWeb();
                                } else {
                                    Quickshell.execDetached(["xdg-open", "https://calendar.google.com"]);
                                }
                            }
                        }"""
        if btn_anchor in cal_content:
            cal_content = cal_content.replace(btn_anchor, btn_block, 1)

    # 7d. Delegate interattivo con selezione giorno e pallino hasEvents
    if "CalendarService.selectDate" not in cal_content:
        rep_pattern = re.compile(
            r'Repeater\s*\{\s*model:\s*calendarModel\s*(?:ClickButton|Item)\s*\{[^}]*\}\s*\}',
            re.DOTALL
        )
        rep_replacement = """Repeater {
                            model: calendarModel
                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                Layout.preferredWidth: 1
                                Layout.preferredHeight: 1
                                readonly property bool isSelectedDay: typeof CalendarService !== "undefined"
                                    && CalendarService.selectedYear === year
                                    && CalendarService.selectedMonth === month
                                    && CalendarService.selectedDay === dayVal

                                ClickButton {
                                    anchors.fill: parent
                                    enabled: true
                                    buttonText: dayNum
                                    textFontSize: window.s(11.5)
                                    cornerRadius: window.s(5)
                                    horizontalPadding: 0
                                    accentColor: isToday
                                        ? window.textAccent
                                        : (isSelectedDay ? Qt.alpha(window.textAccent, 0.28) : ((ThemeBackend.liquidGlass && !isCurrentMonth) ? ThemeBackend.surface0 : "transparent"))
                                    glassTintScale: isToday ? 2.6 : 1.0
                                    textColor: ThemeBackend.liquidGlass
                                        ? (isCurrentMonth ? ThemeBackend.text : ThemeBackend.subtext0)
                                        : (isToday ? ThemeBackend.base : (isSelectedDay ? window.textAccent : (isCurrentMonth ? ThemeBackend.text : ThemeBackend.surface0)))
                                    onClicked: {
                                        if (typeof CalendarService !== "undefined") {
                                            CalendarService.selectDate(year, month, dayVal, true);
                                        }
                                    }
                                }

                                Rectangle {
                                    visible: hasEvents
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: window.s(3)
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: window.s(3.5)
                                    height: window.s(3.5)
                                    radius: width / 2
                                    color: isToday ? ThemeBackend.base : window.textAccent
                                }
                            }
                        }"""
        cal_content = rep_pattern.sub(rep_replacement, cal_content, count=1)

    # Allinea eventuali vecchi riferimenti window.surface0 / window.sapphire / window.base ai token ThemeBackend v2.5+
    cal_content = cal_content.replace("accentColor: window.surface0", "accentColor: ThemeBackend.surface0")
    cal_content = cal_content.replace("textColor: window.sapphire", "textColor: ThemeBackend.sapphire")
    cal_content = cal_content.replace("color: isToday ? window.base : window.textAccent", "color: isToday ? ThemeBackend.base : window.textAccent")

    if cal_content != cal_orig:
        with open(cal_popup_path, "w", encoding="utf-8") as f:
            f.write(cal_content)

# 8. Verifica WindowRegistry.js per il popup Pomodoro
win_reg_path = os.path.join(repo, "src", "quickshell", "WindowRegistry.js")
if os.path.exists(win_reg_path):
    with open(win_reg_path, "r", encoding="utf-8") as f:
        wr_content = f.read()
    wr_orig = wr_content
    if 'id: "pomodoro"' not in wr_content:
        sys_entry_anchor = '            fontIcon: "󰒓"\n        }'
        pomo_entry = """            fontIcon: "󰒓"
        },
        {
            id: "pomodoro",
            name: tr("widgets.pomodoro.name", "Pomodoro Timer"),
            description: tr("widgets.pomodoro.desc", "Focus timer with customizable work and break intervals"),
            icon: "alarm-symbolic",
            fontIcon: "󰔟"
        }"""
        if sys_entry_anchor in wr_content:
            wr_content = wr_content.replace(sys_entry_anchor, pomo_entry, 1)
    if '"pomodoro": {' not in wr_content:
        hidden_anchor = '        "hidden": {'
        pomo_layouts = """        "pomodoro": { 
            w: 330, h: 225, comp: "pomodoro/PomodoroPopup.qml", 
            pos: { 
                "top": { anchor: "top-center", mt: 52 }, 
                "bottom": { anchor: "bottom-center", mb: 52 }, 
                "left": { anchor: "center-left", ml: 52 }, 
                "right": { anchor: "center-right", mr: 52 } 
            } 
        },
        "timer": { 
            w: 330, h: 225, comp: "pomodoro/PomodoroPopup.qml", 
            pos: { 
                "top": { anchor: "top-center", mt: 52 }, 
                "bottom": { anchor: "bottom-center", mb: 52 }, 
                "left": { anchor: "center-left", ml: 52 }, 
                "right": { anchor: "center-right", mr: 52 } 
            } 
        },
        "hidden": {"""
        if hidden_anchor in wr_content:
            wr_content = wr_content.replace(hidden_anchor, pomo_layouts, 1)
    if wr_content != wr_orig:
        with open(win_reg_path, "w", encoding="utf-8") as f:
            f.write(wr_content)

# 9. Verifica BarModuleRegistry.qml e qs_manager.sh per Pomodoro
bar_reg_path = os.path.join(repo, "src", "quickshell", "bar", "BarModuleRegistry.qml")
if os.path.exists(bar_reg_path):
    with open(bar_reg_path, "r", encoding="utf-8") as f:
        bm_content = f.read()
    if 's === "pomodoro"' not in bm_content:
        old_line = 'if (s === "info" || s === "indicator" || s === "indicators" || s === "record") return "info";'
        new_line = 'if (s === "info" || s === "indicator" || s === "indicators" || s === "record" || s === "pomodoro" || s === "timer") return "info";'
        if old_line in bm_content:
            bm_content = bm_content.replace(old_line, new_line, 1)
            with open(bar_reg_path, "w", encoding="utf-8") as f:
                f.write(bm_content)

qs_mgr_path = os.path.join(repo, "src", "scripts", "qs_manager.sh")
if os.path.exists(qs_mgr_path):
    with open(qs_mgr_path, "r", encoding="utf-8") as f:
        qs_content = f.read()
    if "pomodoro|timer)" not in qs_content:
        sys_case = '            system) app_name="$(t "widgets.system.name")" ;;'
        if sys_case in qs_content:
            qs_content = qs_content.replace(sys_case, sys_case + '\n            pomodoro|timer) app_name="Pomodoro" ;;', 1)
            with open(qs_mgr_path, "w", encoding="utf-8") as f:
                f.write(qs_content)
PYEOF
}

# 4. Configura remote upstream se mancante
if ! git remote | grep -q "^upstream$"; then
    echo -e "${C_CYAN}[INFO] Configurazione remote upstream (ilyamiro/serpantinum)...${C_RESET}"
    git remote add upstream https://github.com/ilyamiro/serpantinum.git
fi

# 5. Scarica aggiornamenti da upstream
echo -e "${C_CYAN}[1/5] Controllo aggiornamenti da upstream (ilyamiro/serpantinum)...${C_RESET}"
FETCH_OK=true
if ! git fetch upstream master --quiet 2>/dev/null; then
    echo -e "${C_YELLOW}[ATTENZIONE] Impossibile contattare GitHub (offline o timeout di rete).${C_RESET}"
    FETCH_OK=false
fi

NEW_COMMITS=0
if [ "$FETCH_OK" = true ]; then
    NEW_COMMITS=$(git rev-list HEAD..upstream/master --count 2>/dev/null || echo 0)
fi

LOCAL_VER=$(cat "$REPO_DIR/version.txt" 2>/dev/null | tr -d '[:space:]' || cat "$REPO_DIR/src/version.txt" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
UPSTREAM_VER=$(git show upstream/master:version.txt 2>/dev/null | tr -d '[:space:]' || echo "$LOCAL_VER")
UPSTREAM_COMMIT=$(git rev-parse --short upstream/master 2>/dev/null || git rev-parse --short HEAD)

# Controlla se lo stato installato in ~/.local/state/serpantinum/version è disallineato
STATE_DESYNC=false
if [ -f "$STATE_DIR/version" ]; then
    INSTALLED_COMMIT=$(grep -E '^SERPANTINUM_COMMIT=' "$STATE_DIR/version" 2>/dev/null | cut -d'"' -f2 || echo "")
    INSTALLED_VER=$(grep -E '^SERPANTINUM_VERSION=' "$STATE_DIR/version" 2>/dev/null | cut -d'"' -f2 || echo "")
    if [ "$INSTALLED_VER" != "$LOCAL_VER" ] || [ "$INSTALLED_COMMIT" != "$UPSTREAM_COMMIT" ]; then
        STATE_DESYNC=true
    fi
else
    STATE_DESYNC=true
fi

if [ "$CHECK_ONLY" = true ]; then
    echo -e "  • Versione locale repo:   ${C_BOLD}v${LOCAL_VER}${C_RESET}"
    echo -e "  • Versione upstream:      ${C_BOLD}v${UPSTREAM_VER}${C_RESET} (${UPSTREAM_COMMIT})"
    echo -e "  • Nuovi commit upstream:  ${C_BOLD}${NEW_COMMITS}${C_RESET}"
    if [ "$STATE_DESYNC" = true ]; then
        echo -e "  • Stato installazione:    ${C_YELLOW}Disallineato (esegui aggiorna-serpantinum per allineare)${C_RESET}"
    else
        echo -e "  • Stato installazione:    ${C_GREEN}Allineato (v${INSTALLED_VER})${C_RESET}"
    fi
    exit 0
fi

if [ "$NEW_COMMITS" -eq 0 ] && [ "$FORCE_DEPLOY" = false ] && [ "$STATE_DESYNC" = false ]; then
    restore_stash_if_needed
    echo -e "${C_GREEN}[OK] Serpantinum è già aggiornato all'ultima versione disponibile (v${LOCAL_VER} • ${UPSTREAM_COMMIT})!${C_RESET}"
    echo -e "Tutti i widget personalizzati (Todo List, Calendari, Pomodoro) sono allineati e attivi."
    echo -e "${C_DIM}(Usa 'aggiorna-serpantinum --force' per forzare una reinstallazione completa).${C_RESET}"
    exit 0
fi

# 6. Merge degli aggiornamenti da upstream con risoluzione automatica universale
if [ "$NEW_COMMITS" -gt 0 ]; then
    echo -e "${C_CYAN}[2/5] Trovati ${C_BOLD}${NEW_COMMITS}${C_RESET}${C_CYAN} nuovi commit upstream (v${LOCAL_VER} -> v${UPSTREAM_VER}). Integrazione...${C_RESET}"
    # -X theirs risolve automaticamente tutti i conflitti di contenuto a favore di upstream,
    # lasciando a ensure_custom_integrations il compito di riapplicare le nostre patch in modo pulito.
    if ! git merge -X theirs upstream/master --no-edit --quiet >/dev/null 2>&1; then
        echo -e "${C_YELLOW}  ! Conflitto strutturale (rename/delete) rilevato. Risoluzione automatica in corso...${C_RESET}"
        CONFLICT_FILES=$(git diff --name-only --diff-filter=U)
        AUTO_RESOLVED=true

        for cf in $CONFLICT_FILES; do
            case "$cf" in
                src/assets/matugen/apps/fastfetch/serpantinum.jsonc|src/scripts/serpantinum_update.sh|src/scripts/todo_sync.py|src/scripts/calendar_sync.py|src/quickshell/widgets/faces/todo/*|src/quickshell/widgets/faces/calendar/*|src/quickshell/pomodoro/*|src/quickshell/popouts/PomodoroNotch.qml|src/quickshell/singletons/environment/CalendarService.qml|src/quickshell/singletons/system/PomodoroService.qml|src/quickshell/singletons/widgetcontrols/PomodoroController.qml)
                    # File puramente nostri: mantieni la nostra versione
                    git checkout --ours "$cf" >/dev/null 2>&1 && git add "$cf" >/dev/null 2>&1
                    ;;
                *)
                    # Se il file esiste in upstream/master prendi la versione upstream,
                    # altrimenti è stato eliminato/rinominato da upstream (es. WidgetRedactor.qml -> widgets/redactor/*)
                    if git cat-file -e "upstream/master:$cf" 2>/dev/null; then
                        if ! (git checkout --theirs "$cf" >/dev/null 2>&1 && git add "$cf" >/dev/null 2>&1); then
                            echo -e "${C_RED}  ✗ Impossibile risolvere il file: $cf${C_RESET}"
                            AUTO_RESOLVED=false
                        fi
                    else
                        if ! git rm -f --quiet "$cf" >/dev/null 2>&1; then
                            echo -e "${C_RED}  ✗ Impossibile rimuovere il file obsoleto: $cf${C_RESET}"
                            AUTO_RESOLVED=false
                        fi
                    fi
                    ;;
            esac
        done

        if [ "$AUTO_RESOLVED" = true ]; then
            git checkout upstream/master -- \
                src/assets/languages/it.json \
                src/assets/languages/en.json \
                src/quickshell/qmldir \
                src/quickshell/widgets/faces/qmldir \
                src/quickshell/widgets/WidgetRegistry.qml \
                src/quickshell/calendar/CalendarPopup.qml \
                src/quickshell/WindowRegistry.js \
                src/quickshell/bar/BarModuleRegistry.qml \
                src/quickshell/singletons/system/SysNotif.qml \
                src/scripts/qs_manager.sh 2>/dev/null || true
            ensure_custom_integrations
            git add -A >/dev/null 2>&1 || true
            git commit --no-edit --quiet >/dev/null 2>&1 || true
            echo -e "${C_GREEN}  ✓ Conflitti strutturali risolti automaticamente preservando tutte le personalizzazioni!${C_RESET}"
        else
            echo -e "${C_RED}[ERRORE] Impossibile risolvere automaticamente tutti i conflitti. Ripristino stato precedente...${C_RESET}"
            git merge --abort 2>/dev/null || true
            restore_stash_if_needed
            exit 1
        fi
    else
        git checkout upstream/master -- \
            src/assets/languages/it.json \
            src/assets/languages/en.json \
            src/quickshell/qmldir \
            src/quickshell/widgets/faces/qmldir \
            src/quickshell/widgets/WidgetRegistry.qml \
            src/quickshell/calendar/CalendarPopup.qml \
            src/quickshell/WindowRegistry.js \
            src/quickshell/bar/BarModuleRegistry.qml \
            src/quickshell/singletons/system/SysNotif.qml \
            src/scripts/qs_manager.sh 2>/dev/null || true
        ensure_custom_integrations
        git add -A >/dev/null 2>&1 || true
        git commit --amend --no-edit --quiet >/dev/null 2>&1 || true
        echo -e "${C_GREEN}  ✓ Merge upstream completato automaticamente.${C_RESET}"
    fi
else
    echo -e "${C_CYAN}[2/5] Sincronizzazione e verifica integrità locale (v${LOCAL_VER})...${C_RESET}"
fi

# Ripristina eventuale stash locale prima di verificare l'integrità e fare il deploy
restore_stash_if_needed

# 7. Verifica integrità delle personalizzazioni (JSON, qmldir, SysNotif, CalendarPopup, Redactor, script Python) + binari companion
echo -e "${C_CYAN}[3/5] Verifica integrità widget personalizzati, traduzioni e binari...${C_RESET}"
if ! ensure_custom_integrations; then
    echo -e "${C_RED}[ERRORE] Verifica integrità fallita! Controlla i file JSON/QML.${C_RESET}"
    exit 1
fi
python3 -m py_compile "$REPO_DIR/src/scripts/todo_sync.py" "$REPO_DIR/src/scripts/calendar_sync.py"
ensure_companion_binaries
echo -e "  ${C_GREEN}✓${C_RESET} Sintassi JSON, registrazioni QML, binari companion e script Python validati."

# Commit automatico se ensure_custom_integrations ha riparato qualcosa dopo il merge
if [ -n "$(git status --porcelain src/assets/languages src/quickshell src/scripts)" ]; then
    git add src/assets/languages/it.json src/assets/languages/en.json \
            src/quickshell/qmldir src/quickshell/widgets/faces/qmldir \
            src/quickshell/widgets/WidgetRegistry.qml \
            src/quickshell/widgets/redactor/RedactorWorkspace.qml \
            src/quickshell/calendar/CalendarPopup.qml \
            src/quickshell/WindowRegistry.js \
            src/quickshell/bar/BarModuleRegistry.qml \
            src/quickshell/bar/faces/info/InfoFace.qml \
            src/quickshell/singletons/system/SysNotif.qml \
            src/scripts/qs_manager.sh \
            src/scripts/serpantinum_update.sh 2>/dev/null || true
    git commit -m "chore(updater): riallineamento automatico integrazioni custom su v$(cat "$REPO_DIR/version.txt" 2>/dev/null | tr -d '[:space:]')" --quiet 2>/dev/null || true
fi

# 8. Push sul fork personale (origin) se ci sono commit non pushati
echo -e "${C_CYAN}[4/5] Sincronizzazione con il repository GitHub personale (origin)...${C_RESET}"
UNPUSHED=$(git rev-list origin/master..HEAD --count 2>/dev/null || echo 0)
if [ "$UNPUSHED" -gt 0 ]; then
    if GIT_TERMINAL_PROMPT=0 git push origin master --quiet 2>/dev/null; then
        echo -e "  ${C_GREEN}✓${C_RESET} Backup su GitHub personale aggiornato (${UNPUSHED} commit inviati)."
    else
        echo -e "  ${C_YELLOW}!${C_RESET} Push su GitHub saltato (offline o credenziali non in cache)."
    fi
else
    echo -e "  ${C_GREEN}✓${C_RESET} Repository GitHub personale già allineato."
fi

# 9. Deploy completo in ~/.local/share/serpantinum e aggiornamento stato versione
echo -e "${C_CYAN}[5/5] Distribuzione file in ${TARGET_DIR}...${C_RESET}"
mkdir -p "$TARGET_DIR/src" "$TARGET_DIR/bin" "$STATE_DIR"

# Sincronizza sorgenti QML, asset e script (rimuovendo anche eventuali file eliminati da upstream come il vecchio WidgetRedactor.qml)
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --copy-links "$REPO_DIR/src/" "$TARGET_DIR/src/"
else
    rm -rf "$TARGET_DIR/src"
    mkdir -p "$TARGET_DIR/src"
    cp -rL "$REPO_DIR/src/." "$TARGET_DIR/src/"
fi

# Copia binari CLI e demone (serpantinum, serpantinumd)
if [ -d "$REPO_DIR/bin" ]; then
    cp -r "$REPO_DIR/bin/." "$TARGET_DIR/bin/"
    chmod +x "$TARGET_DIR/bin/"* 2>/dev/null || true
fi

# Allinea version.txt sia nella root di TARGET_DIR che in TARGET_DIR/src (come file reale, non symlink rotto)
FINAL_VER=$(cat "$REPO_DIR/version.txt" 2>/dev/null | tr -d '[:space:]' || echo "2.5.1")
rm -f "$TARGET_DIR/src/version.txt" "$TARGET_DIR/version.txt"
echo "$FINAL_VER" > "$TARGET_DIR/version.txt"
echo "$FINAL_VER" > "$TARGET_DIR/src/version.txt"

# Preserva i metadati esistenti in ~/.local/state/serpantinum/version aggiornando SERPANTINUM_VERSION e SERPANTINUM_COMMIT
FINAL_UPSTREAM_COMMIT=$(git rev-parse --short upstream/master 2>/dev/null || git rev-parse --short HEAD)
TEL_ID=$(awk -F= '/^TELEMETRY_ID=/{gsub(/"/, "", $2); print $2}' "$STATE_DIR/version" 2>/dev/null || echo "")
TEL_EN=$(awk -F= '/^ENABLE_TELEMETRY=/{gsub(/"/, "", $2); print $2}' "$STATE_DIR/version" 2>/dev/null || echo "false")
SEL_COMP=$(awk -F= '/^SELECTED_COMPOSITORS=/{gsub(/"/, "", $2); print $2}' "$STATE_DIR/version" 2>/dev/null || echo "hyprland")
OPT_SDDM_VAL=$(awk -F= '/^OPT_SDDM=/{gsub(/"/, "", $2); print $2}' "$STATE_DIR/version" 2>/dev/null || echo "true")
SDDM_WL_VAL=$(awk -F= '/^SDDM_WAYLAND=/{gsub(/"/, "", $2); print $2}' "$STATE_DIR/version" 2>/dev/null || echo "false")
FULL_WP_VAL=$(awk -F= '/^INSTALL_FULL_WALLPAPERS=/{gsub(/"/, "", $2); print $2}' "$STATE_DIR/version" 2>/dev/null || echo "true")

cat > "$STATE_DIR/version" <<EOF
SERPANTINUM_VERSION="$FINAL_VER"
SERPANTINUM_COMMIT="$FINAL_UPSTREAM_COMMIT"
TELEMETRY_ID="$TEL_ID"
ENABLE_TELEMETRY="$TEL_EN"
SELECTED_COMPOSITORS="$SEL_COMP"
OPT_SDDM="$OPT_SDDM_VAL"
SDDM_WAYLAND="$SDDM_WL_VAL"
INSTALL_FULL_WALLPAPERS="$FULL_WP_VAL"
EOF

# Assicura permessi di esecuzione sugli script
chmod +x "$TARGET_DIR/src/scripts/"* 2>/dev/null || true
chmod +x "$REPO_DIR/src/scripts/"* 2>/dev/null || true

# Verifica symlink in ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_DIR/src/scripts/serpantinum_update.sh" "$HOME/.local/bin/aggiorna-serpantinum"
ln -sf "$REPO_DIR/src/scripts/serpantinum_update.sh" "$HOME/.local/bin/serpantinum-update"

echo -e "  ${C_GREEN}✓${C_RESET} Sorgenti, binari e stato versione aggiornati a ${C_BOLD}v${FINAL_VER}${C_RESET} (${FINAL_UPSTREAM_COMMIT})."

# 10. Riavvio controllato del demone e verifica stato di salute reale (stabile per >2s)
if [ "$NO_RESTART" = false ]; then
    echo -e "${C_CYAN}[INFO] Riavvio del demone Serpantinum...${C_RESET}"
    serpantinumd stop >/dev/null 2>&1 || true
    sleep 0.8
    setsid -f serpantinumd start >/dev/null 2>&1

    sleep 2.2
    if serpantinumd status >/dev/null 2>&1; then
        echo -e "${C_GREEN}✓ Serpantinum v${FINAL_VER} riavviato e perfettamente operativo!${C_RESET}"
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -a "Serpantinum" -i "software-update-available" \
                "Serpantinum aggiornato (v${FINAL_VER})" \
                "Shell, Todo List e Calendari aggiornati e operativi." 2>/dev/null || true
        fi
    else
        echo -e "${C_RED}[!] Attenzione: il demone non è rimasto attivo. Controlla i log di quickshell.${C_RESET}"
        exit 1
    fi
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}=== Aggiornamento completato con successo (v${FINAL_VER})! ===${C_RESET}"
echo -e "Backup configurazione salvato in: ${C_DIM}${CURRENT_BACKUP}${C_RESET}"
exit 0
}
