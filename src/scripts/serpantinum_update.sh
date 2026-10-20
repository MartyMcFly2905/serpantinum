#!/usr/bin/env bash
# Serpantinum Custom Auto-Updater
# Aggiorna Serpantinum preservando i calendari personalizzati e le impostazioni.

set -e

REPO_DIR="/home/christian/Scrivania/Repos/serpantinum"
TARGET_DIR="$HOME/.local/share/serpantinum"

# Colori per il terminale
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

echo -e "${C_CYAN}${C_BOLD}=== Serpantinum Updater (Custom Build) ===${C_RESET}"
echo ""

if [ ! -d "$REPO_DIR/.git" ]; then
    echo -e "${C_RED}[ERRORE] Repository non trovato in $REPO_DIR${C_RESET}"
    exit 1
fi

cd "$REPO_DIR"

# 1. Controlla se ci sono modifiche non committate
if [ -n "$(git status --porcelain)" ]; then
    echo -e "${C_YELLOW}[ATTENZIONE] Ci sono modifiche non salvate nella cartella del repository.${C_RESET}"
    echo -e "Esegui un commit o metti da parte le modifiche prima di procedere."
    git status -s
    exit 1
fi

# 2. Assicurati che il remote upstream sia configurato
if ! git remote | grep -q "^upstream$"; then
    echo -e "${C_CYAN}[INFO] Configurazione remote upstream (ilyamiro/serpantinum)...${C_RESET}"
    git remote add upstream https://github.com/ilyamiro/serpantinum.git
fi

# 3. Scarica gli aggiornamenti dal repository ufficiale
echo -e "${C_CYAN}[1/4] Controllo aggiornamenti da upstream (ilyamiro/serpantinum)...${C_RESET}"
git fetch upstream master --quiet

# Controlla quanti commit nuovi ci sono
NEW_COMMITS=$(git rev-list HEAD..upstream/master --count)

if [ "$NEW_COMMITS" -eq 0 ] && [ "$1" != "--force" ] && [ "$1" != "-f" ]; then
    echo -e "${C_GREEN}[OK] Serpantinum è già aggiornato all'ultima versione disponibile!${C_RESET}"
    echo -e "I tuoi calendari personali sono salvaguardati e attivi."
    echo -e "${C_CYAN}(Usa 'aggiorna-serpantinum --force' se vuoi reinstallare forzatamente).${C_RESET}"
    exit 0
fi

if [ "$NEW_COMMITS" -gt 0 ]; then
    echo -e "${C_CYAN}[2/4] Trovati $NEW_COMMITS nuovi aggiornamenti. Integrazione nel codice...${C_RESET}"
    if ! git merge upstream/master -m "merge: aggiornamento automatico da upstream" --quiet; then
        echo -e "${C_YELLOW}[ATTENZIONE] Rilevato un conflitto durante il merge automatico.${C_RESET}"
        echo -e "Risoluzione guidata o controllo manuale necessario."
        exit 1
    fi
else
    echo -e "${C_CYAN}[2/4] Riesecuzione deploy su richiesta (--force)...${C_RESET}"
fi

# 4. Salva su GitHub personale (origin) se possibile
echo -e "${C_CYAN}[3/4] Sincronizzazione con il tuo repository GitHub personale...${C_RESET}"
if GIT_TERMINAL_PROMPT=0 git push origin master --quiet 2>/dev/null; then
    echo -e "  ${C_GREEN}✓${C_RESET} Backup GitHub aggiornato con successo."
else
    echo -e "  ${C_YELLOW}!${C_RESET} Push su GitHub saltato (richiede 'git push' manuale o token)."
fi

# 5. Distribuisci i file in ~/.local/share/serpantinum/src
echo -e "${C_CYAN}[4/4] Applicazione aggiornamenti alla shell...${C_RESET}"
mkdir -p "$TARGET_DIR/src"
cp -r src/. "$TARGET_DIR/src/"
chmod +x "$TARGET_DIR/src/scripts/"* 2>/dev/null || true
if [ -f "$TARGET_DIR/src/scripts/calendar_sync.py" ]; then
    chmod +x "$TARGET_DIR/src/scripts/calendar_sync.py"
fi

# 6. Riavvia serpantinumd
echo -e "${C_CYAN}[INFO] Riavvio del demone Serpantinum...${C_RESET}"
serpantinumd stop >/dev/null 2>&1 || true
sleep 0.5
nohup serpantinumd start > /dev/null 2>&1 &
sleep 1.5

if serpantinumd status >/dev/null 2>&1; then
    echo -e "${C_GREEN}✓ Serpantinum riavviato e funzionante con successo!${C_RESET}"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Serpantinum" -i "software-update-available" "Aggiornamento completato" "Serpantinum è stato aggiornato con successo. I calendari sono attivi!" 2>/dev/null || true
    fi
else
    echo -e "${C_YELLOW}[!] Il demone potrebbe non essersi riavviato automaticamente. Prova 'serpantinumd start'.${C_RESET}"
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}=== Aggiornamento completato con successo! ===${C_RESET}"
echo -e "Tutti i tuoi calendari e le tue impostazioni sono rimasti intatti."
