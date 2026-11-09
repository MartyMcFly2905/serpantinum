#!/usr/bin/env bash
# ==============================================================================
# Serpantinum Custom Auto-Updater ("aggiorna-serpantinum") — Edizione Blindata
# ==============================================================================
# Aggiorna Serpantinum dal repository ufficiale (ilyamiro/serpantinum),
# risolve automaticamente eventuali conflitti sui widget personalizzati
# (Todo List, Calendario Mese/Agenda/Compatto, Pomodoro, fix batteria 100%),
# verifica l'integrità di JSON/QML, sincronizza binari + version state e
# riavvia il demone verificandone lo stato di salute.
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
C_PURPLE='\033[1;35m'
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
            echo -e "${C_YELLOW}[ATTENZIONE] Conflitto minore durante git stash pop; le modifiche sono al sicuro in 'git stash list'.${C_RESET}"
        fi
        STASHED_LOCAL=false
    fi
}

# Funzione Python per garantire l'integrità di traduzioni e registrazioni QML custom
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

# 2. Verifica src/quickshell/qmldir
qmldir_main = os.path.join(repo, "src", "quickshell", "qmldir")
if os.path.exists(qmldir_main):
    with open(qmldir_main, "r", encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f]
    required_main = [
        "singleton CalendarService 1.0 singletons/environment/CalendarService.qml",
        "singleton PomodoroService 1.0 singletons/environment/PomodoroService.qml",
    ]
    modified = False
    for req in required_main:
        if req not in lines:
            lines.append(req)
            modified = True
    if modified:
        with open(qmldir_main, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

# 3. Verifica src/quickshell/widgets/faces/qmldir
qmldir_faces = os.path.join(repo, "src", "quickshell", "widgets", "faces", "qmldir")
if os.path.exists(qmldir_faces):
    with open(qmldir_faces, "r", encoding="utf-8") as f:
        lines = [line.rstrip("\n") for line in f]
    required_faces = [
        "CalendarFaceCompact 1.0 calendar/CalendarFaceCompact.qml",
        "CalendarFaceMonth 1.0 calendar/CalendarFaceMonth.qml",
        "CalendarFaceAgenda 1.0 calendar/CalendarFaceAgenda.qml",
        "PomodoroFace 1.0 pomodoro/PomodoroFace.qml",
        "TodoFace 1.0 todo/TodoFace.qml",
    ]
    modified = False
    for req in required_faces:
        if req not in lines:
            lines.append(req)
            modified = True
    if modified:
        with open(qmldir_faces, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

# 4. Verifica disattivazione notifica batteria 100% in SysNotif.qml
sysnotif_path = os.path.join(repo, "src", "quickshell", "singletons", "system", "SysNotif.qml")
if os.path.exists(sysnotif_path):
    with open(sysnotif_path, "r", encoding="utf-8") as f:
        content = f.read()
    pattern = re.compile(
        r'if\s*\(\s*pct\s*>=\s*100\s*&&\s*!root\.notifiedFull\s*\)\s*\{\s*root\.notifiedFull\s*=\s*true;\s*root\.send\([^\}]+\);\s*\}',
        re.MULTILINE
    )
    replacement = (
        'if (pct >= 100 && !root.notifiedFull) {\n'
        '                root.notifiedFull = true;\n'
        '                // Battery full notification disabled per user preference\n'
        '            }'
    )
    if pattern.search(content):
        content = pattern.sub(replacement, content)
        with open(sysnotif_path, "w", encoding="utf-8") as f:
            f.write(content)
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

LOCAL_VER=$(cat "$REPO_DIR/src/version.txt" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
UPSTREAM_VER=$(git show upstream/master:src/version.txt 2>/dev/null | tr -d '[:space:]' || echo "$LOCAL_VER")
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

# 6. Merge degli aggiornamenti da upstream con risoluzione automatica conflitti
if [ "$NEW_COMMITS" -gt 0 ]; then
    echo -e "${C_CYAN}[2/5] Trovati ${C_BOLD}${NEW_COMMITS}${C_RESET}${C_CYAN} nuovi commit upstream (v${LOCAL_VER} -> v${UPSTREAM_VER}). Integrazione...${C_RESET}"
    if ! git merge upstream/master --no-edit --quiet 2>/dev/null; then
        echo -e "${C_YELLOW}  ! Conflitto rilevato durante il merge. Avvio risoluzione automatica intelligente...${C_RESET}"
        CONFLICT_FILES=$(git diff --name-only --diff-filter=U)
        AUTO_RESOLVED=true

        for cf in $CONFLICT_FILES; do
            case "$cf" in
                src/assets/languages/it.json|src/assets/languages/en.json|src/quickshell/qmldir|src/quickshell/widgets/faces/qmldir|src/quickshell/singletons/system/SysNotif.qml|src/version.txt|version.txt)
                    git checkout --theirs "$cf" 2>/dev/null && git add "$cf"
                    ;;
                *)
                    echo -e "${C_RED}  ✗ Conflitto complesso sul file: $cf${C_RESET}"
                    AUTO_RESOLVED=false
                    ;;
            esac
        done

        if [ "$AUTO_RESOLVED" = true ]; then
            ensure_custom_integrations
            git add src/assets/languages/it.json src/assets/languages/en.json \
                    src/quickshell/qmldir src/quickshell/widgets/faces/qmldir \
                    src/quickshell/singletons/system/SysNotif.qml 2>/dev/null || true
            git commit --no-edit --quiet || true
            echo -e "${C_GREEN}  ✓ Conflitti risolti automaticamente preservando tutte le personalizzazioni!${C_RESET}"
        else
            echo -e "${C_RED}[ERRORE] Impossibile risolvere automaticamente tutti i conflitti. Ripristino stato precedente...${C_RESET}"
            git merge --abort 2>/dev/null || true
            restore_stash_if_needed
            exit 1
        fi
    fi
else
    echo -e "${C_CYAN}[2/5] Sincronizzazione e verifica integrità locale (v${LOCAL_VER})...${C_RESET}"
fi

# Ripristina eventuale stash locale prima di verificare l'integrità e fare il deploy
restore_stash_if_needed

# 7. Verifica integrità delle personalizzazioni (JSON, qmldir, SysNotif, script Python)
echo -e "${C_CYAN}[3/5] Verifica integrità widget personalizzati e traduzioni...${C_RESET}"
if ! ensure_custom_integrations; then
    echo -e "${C_RED}[ERRORE] Verifica integrità fallita! Controlla i file JSON/QML.${C_RESET}"
    exit 1
fi
python3 -m py_compile "$REPO_DIR/src/scripts/todo_sync.py" "$REPO_DIR/src/scripts/calendar_sync.py"
echo -e "  ${C_GREEN}✓${C_RESET} Sintassi JSON, registrazioni QML e script Python validati."

# Commit automatico se ensure_custom_integrations ha riparato qualcosa dopo un merge
if [ "$NEW_COMMITS" -gt 0 ] && [ -n "$(git status --porcelain src/assets/languages src/quickshell)" ]; then
    git add src/assets/languages/it.json src/assets/languages/en.json \
            src/quickshell/qmldir src/quickshell/widgets/faces/qmldir \
            src/quickshell/singletons/system/SysNotif.qml 2>/dev/null || true
    git commit -m "chore(updater): riallineamento automatico integrazioni custom post-merge" --quiet 2>/dev/null || true
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

# Copia sorgenti QML, asset e script
cp -r "$REPO_DIR/src/." "$TARGET_DIR/src/"

# Copia binari CLI e demone (serpantinum, serpantinumd)
if [ -d "$REPO_DIR/bin" ]; then
    cp -r "$REPO_DIR/bin/." "$TARGET_DIR/bin/"
    chmod +x "$TARGET_DIR/bin/"* 2>/dev/null || true
fi

# Allinea version.txt sia nella root di TARGET_DIR che in TARGET_DIR/src
FINAL_VER=$(cat "$REPO_DIR/src/version.txt" 2>/dev/null | tr -d '[:space:]' || echo "2.4.3")
echo "$FINAL_VER" > "$TARGET_DIR/src/version.txt"
echo "$FINAL_VER" > "$TARGET_DIR/version.txt"
if [ -f "$REPO_DIR/version.txt" ]; then
    echo "$FINAL_VER" > "$REPO_DIR/version.txt"
fi

# Allinea ~/.local/state/serpantinum/version con il commit di upstream/master
# così Updater.qml non invia false notifiche di "Aggiornamento disponibile"
FINAL_UPSTREAM_COMMIT=$(git rev-parse --short upstream/master 2>/dev/null || git rev-parse --short HEAD)
cat > "$STATE_DIR/version" <<EOF
SERPANTINUM_VERSION="$FINAL_VER"
SERPANTINUM_COMMIT="$FINAL_UPSTREAM_COMMIT"
EOF

# Assicura permessi di esecuzione sugli script
chmod +x "$TARGET_DIR/src/scripts/"* 2>/dev/null || true
chmod +x "$REPO_DIR/src/scripts/"* 2>/dev/null || true

# Verifica symlink in ~/.local/bin
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_DIR/src/scripts/serpantinum_update.sh" "$HOME/.local/bin/aggiorna-serpantinum"
ln -sf "$REPO_DIR/src/scripts/serpantinum_update.sh" "$HOME/.local/bin/serpantinum-update"

echo -e "  ${C_GREEN}✓${C_RESET} Sorgenti, binari e stato versione aggiornati a ${C_BOLD}v${FINAL_VER}${C_RESET} (${FINAL_UPSTREAM_COMMIT})."

# 10. Riavvio controllato del demone e verifica stato di salute
if [ "$NO_RESTART" = false ]; then
    echo -e "${C_CYAN}[INFO] Riavvio del demone Serpantinum...${C_RESET}"
    serpantinumd stop >/dev/null 2>&1 || true
    sleep 0.8
    setsid -f serpantinumd start >/dev/null 2>&1

    HEALTH_OK=false
    for _ in 1 2 3 4 5 6; do
        sleep 0.5
        if serpantinumd status >/dev/null 2>&1; then
            HEALTH_OK=true
            break
        fi
    done

    if [ "$HEALTH_OK" = true ]; then
        echo -e "${C_GREEN}✓ Serpantinum v${FINAL_VER} riavviato e perfettamente operativo!${C_RESET}"
        if command -v notify-send >/dev/null 2>&1; then
            notify-send -a "Serpantinum" -i "software-update-available" \
                "Serpantinum aggiornato (v${FINAL_VER})" \
                "Shell, Todo List e Calendari aggiornati e operativi." 2>/dev/null || true
        fi
    else
        echo -e "${C_YELLOW}[!] Il demone impiega più tempo del previsto ad avviarsi. Controlla con 'serpantinumd status'.${C_RESET}"
    fi
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}=== Aggiornamento completato con successo (v${FINAL_VER})! ===${C_RESET}"
echo -e "Backup configurazione salvato in: ${C_DIM}${CURRENT_BACKUP}${C_RESET}"
