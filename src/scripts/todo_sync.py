#!/usr/bin/env python3
"""
Serpantinum Todo Sync & CSV Engine
Manages persistent tasks and full CSV import/export for the desktop Todo widget.
"""

import sys
import os
import csv
import json
import time
import subprocess
from datetime import datetime

CONFIG_DIR = os.path.expanduser(os.environ.get("XDG_CONFIG_HOME", "~/.config") + "/serpantinum")
TODOS_FILE = os.path.join(CONFIG_DIR, "todos.json")

TITLE_HEADERS = {
    "title", "titolo", "task", "attivita", "attività", "todo", "name", "nome",
    "text", "testo", "content", "descrizione", "description", "item", "summary", "voce"
}
DONE_HEADERS = {
    "completed", "completato", "done", "fatto", "status", "stato", "complete",
    "check", "checked", "success"
}
PRIORITY_HEADERS = {"priority", "priorita", "priorità", "prio", "livello"}
CATEGORY_HEADERS = {"category", "categoria", "tag", "tags", "project", "progetto", "gruppo"}
DUE_HEADERS = {"due", "due_date", "scadenza", "data", "date"}

TRUE_VALUES = {"1", "true", "yes", "si", "sì", "done", "x", "checked", "completato", "fatto", "t", "y"}

def ensure_config_dir():
    os.makedirs(CONFIG_DIR, exist_ok=True)

def load_todos():
    ensure_config_dir()
    if os.path.isfile(TODOS_FILE):
        try:
            with open(TODOS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict) and "todos" in data:
                    return data
                elif isinstance(data, list):
                    return {"updated_at": int(time.time()), "todos": data}
        except Exception as e:
            pass
    return {"updated_at": int(time.time()), "todos": []}

def save_todos(data):
    ensure_config_dir()
    data["updated_at"] = int(time.time())
    tmp_path = TODOS_FILE + f".tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, TODOS_FILE)
    return data

def add_todo(title, priority="normal", category="", due_date=""):
    clean_title = (title or "").strip()
    if not clean_title:
        return {"status": "error", "message": "Empty title"}
    data = load_todos()
    now_ms = int(time.time() * 1000)
    new_item = {
        "id": f"todo_{now_ms}_{len(data['todos'])}",
        "title": clean_title,
        "completed": False,
        "priority": priority if priority in ("high", "normal", "low") else "normal",
        "category": (category or "").strip(),
        "due_date": (due_date or "").strip(),
        "created_at": int(time.time())
    }
    data["todos"].insert(0, new_item)
    save_todos(data)
    return {"status": "ok", "action": "added", "item": new_item, "total": len(data["todos"])}

def toggle_todo(todo_id):
    data = load_todos()
    target_id = str(todo_id).strip()
    found = None
    for item in data["todos"]:
        if str(item.get("id")).strip() == target_id:
            item["completed"] = not bool(item.get("completed"))
            found = item
            break
    if found is not None:
        save_todos(data)
        return {"status": "ok", "action": "toggled", "item": found}
    return {"status": "error", "message": "Item not found"}

def delete_todo(todo_id):
    data = load_todos()
    target_id = str(todo_id).strip()
    orig_len = len(data["todos"])
    data["todos"] = [it for it in data["todos"] if str(it.get("id")).strip() != target_id]
    if len(data["todos"]) < orig_len:
        save_todos(data)
        return {"status": "ok", "action": "deleted", "total": len(data["todos"])}
    return {"status": "error", "message": "Item not found"}

def clear_completed():
    data = load_todos()
    orig_len = len(data["todos"])
    data["todos"] = [it for it in data["todos"] if not bool(it.get("completed"))]
    cleared_count = orig_len - len(data["todos"])
    save_todos(data)
    return {"status": "ok", "action": "cleared", "cleared": cleared_count, "total": len(data["todos"])}

def detect_delimiter(sample_text):
    for delim in [",", ";", "\t", "|"]:
        lines = [line for line in sample_text.splitlines() if line.strip()][:5]
        if lines and all(delim in line for line in lines):
            return delim
    try:
        sniffer = csv.Sniffer()
        dialect = sniffer.sniff(sample_text)
        return dialect.delimiter
    except Exception:
        return ","

def read_file_with_encodings(filepath):
    encodings = ["utf-8-sig", "utf-8", "cp1252", "latin-1", "iso-8859-1"]
    for enc in encodings:
        try:
            with open(filepath, "r", encoding=enc) as f:
                return f.read()
        except UnicodeDecodeError:
            continue
    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        return f.read()

def parse_csv_content(content):
    if not content or not content.strip():
        return []
    delimiter = detect_delimiter(content)
    reader = csv.reader(content.splitlines(), delimiter=delimiter)
    rows = [r for r in reader if r and any(cell.strip() for cell in r)]
    if not rows:
        return []

    first_row = [c.strip().lower() for c in rows[0]]
    has_header = False
    title_idx = -1
    done_idx = -1
    prio_idx = -1
    cat_idx = -1
    due_idx = -1

    for idx, col in enumerate(first_row):
        col_clean = col.replace(" ", "_").replace("-", "_")
        if title_idx == -1 and col_clean in TITLE_HEADERS:
            title_idx = idx
            has_header = True
        elif done_idx == -1 and col_clean in DONE_HEADERS:
            done_idx = idx
            has_header = True
        elif prio_idx == -1 and col_clean in PRIORITY_HEADERS:
            prio_idx = idx
            has_header = True
        elif cat_idx == -1 and col_clean in CATEGORY_HEADERS:
            cat_idx = idx
            has_header = True
        elif due_idx == -1 and col_clean in DUE_HEADERS:
            due_idx = idx
            has_header = True

    start_idx = 1 if has_header else 0
    if title_idx == -1:
        # Default first column as title
        title_idx = 0
        if len(first_row) > 1 and first_row[1] in TRUE_VALUES or first_row[1] in {"false", "0", "no"}:
            done_idx = 1

    parsed = []
    base_time = int(time.time() * 1000)

    for row_num, row in enumerate(rows[start_idx:]):
        if not row:
            continue
        title = row[title_idx].strip() if title_idx < len(row) else ""
        if not title:
            continue

        completed = False
        if done_idx != -1 and done_idx < len(row):
            val = row[done_idx].strip().lower()
            completed = val in TRUE_VALUES

        priority = "normal"
        if prio_idx != -1 and prio_idx < len(row):
            pval = row[prio_idx].strip().lower()
            if pval in {"high", "alta", "urgent", "urgente", "1", "max"}:
                priority = "high"
            elif pval in {"low", "bassa", "min", "3"}:
                priority = "low"

        category = row[cat_idx].strip() if (cat_idx != -1 and cat_idx < len(row)) else ""
        due_date = row[due_idx].strip() if (due_idx != -1 and due_idx < len(row)) else ""

        parsed.append({
            "id": f"todo_{base_time}_{row_num}",
            "title": title,
            "completed": completed,
            "priority": priority,
            "category": category,
            "due_date": due_date,
            "created_at": int(time.time())
        })

    return parsed

def import_csv_file(filepath, mode="merge"):
    clean_path = os.path.expanduser(filepath.strip())
    if not os.path.isfile(clean_path):
        return {"status": "error", "message": f"File non trovato: {clean_path}"}

    try:
        content = read_file_with_encodings(clean_path)
        new_items = parse_csv_content(content)
        if not new_items:
            return {"status": "error", "message": "Nessuna voce valida trovata nel file CSV"}

        data = load_todos()
        if mode == "replace":
            data["todos"] = new_items
            imported_count = len(new_items)
        else:
            # Merge: skip items with duplicate normalized title and category
            existing_signatures = {
                (it.get("title", "").strip().lower(), it.get("category", "").strip().lower())
                for it in data["todos"]
            }
            added = []
            for item in new_items:
                sig = (item["title"].strip().lower(), item["category"].strip().lower())
                if sig not in existing_signatures:
                    added.append(item)
                    existing_signatures.add(sig)
            data["todos"] = added + data["todos"]
            imported_count = len(added)

        save_todos(data)
        return {
            "status": "ok",
            "action": "imported",
            "mode": mode,
            "filepath": clean_path,
            "imported_count": imported_count,
            "total_count": len(data["todos"]),
            "todos": data["todos"]
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}

def export_csv_file(destination=None):
    data = load_todos()
    ensure_config_dir()
    if not destination or not str(destination).strip():
        dest_path = os.path.join(CONFIG_DIR, "todos_export.csv")
    else:
        dest_path = os.path.expanduser(str(destination).strip())

    try:
        dest_dir = os.path.dirname(dest_path)
        if dest_dir:
            os.makedirs(dest_dir, exist_ok=True)

        with open(dest_path, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["title", "completed", "priority", "category", "due_date", "created_at"])
            for it in data["todos"]:
                writer.writerow([
                    it.get("title", ""),
                    "true" if it.get("completed") else "false",
                    it.get("priority", "normal"),
                    it.get("category", ""),
                    it.get("due_date", ""),
                    datetime.fromtimestamp(it.get("created_at", time.time())).strftime("%Y-%m-%d %H:%M:%S")
                ])
        return {
            "status": "ok",
            "action": "exported",
            "path": dest_path,
            "exported_count": len(data["todos"])
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}

def pick_csv_dialog(mode="merge"):
    try:
        res = subprocess.run([
            "zenity", "--file-selection",
            "--title=Seleziona file CSV da importare",
            "--file-filter=File CSV (*.csv) | *.csv",
            "--file-filter=Tutti i file | *"
        ], capture_output=True, text=True, check=False)
        selected = res.stdout.strip()
        if not selected or res.returncode != 0:
            return {"status": "cancelled", "message": "Selezione annullata"}
        return import_csv_file(selected, mode=mode)
    except Exception as e:
        return {"status": "error", "message": str(e)}

def pick_export_dialog():
    try:
        res = subprocess.run([
            "zenity", "--file-selection", "--save", "--confirm-overwrite",
            "--title=Esporta attività in CSV",
            "--filename=todos.csv",
            "--file-filter=File CSV (*.csv) | *.csv",
            "--file-filter=Tutti i file | *"
        ], capture_output=True, text=True, check=False)
        selected = res.stdout.strip()
        if not selected or res.returncode != 0:
            return {"status": "cancelled", "message": "Salvataggio annullato"}
        if not selected.lower().endswith(".csv"):
            selected += ".csv"
        return export_csv_file(selected)
    except Exception as e:
        return {"status": "error", "message": str(e)}

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--get", "-g"):
        data = load_todos()
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return

    cmd = sys.argv[1]
    if cmd == "--add":
        title = sys.argv[2] if len(sys.argv) > 2 else ""
        prio = sys.argv[3] if len(sys.argv) > 3 else "normal"
        cat = sys.argv[4] if len(sys.argv) > 4 else ""
        due = sys.argv[5] if len(sys.argv) > 5 else ""
        res = add_todo(title, priority=prio, category=cat, due_date=due)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--toggle":
        tid = sys.argv[2] if len(sys.argv) > 2 else ""
        res = toggle_todo(tid)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--delete":
        tid = sys.argv[2] if len(sys.argv) > 2 else ""
        res = delete_todo(tid)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--clear-completed":
        res = clear_completed()
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--import-csv":
        path = sys.argv[2] if len(sys.argv) > 2 else ""
        mode = "merge"
        if len(sys.argv) > 3 and sys.argv[3].startswith("--mode="):
            mode = sys.argv[3].split("=", 1)[1]
        elif len(sys.argv) > 4 and sys.argv[3] == "--mode":
            mode = sys.argv[4]
        res = import_csv_file(path, mode=mode)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--export-csv":
        path = sys.argv[2] if len(sys.argv) > 2 else None
        res = export_csv_file(path)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--pick-csv":
        mode = "merge"
        if len(sys.argv) > 2 and sys.argv[2].startswith("--mode="):
            mode = sys.argv[2].split("=", 1)[1]
        elif len(sys.argv) > 3 and sys.argv[2] == "--mode":
            mode = sys.argv[3]
        res = pick_csv_dialog(mode=mode)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--pick-export-csv":
        res = pick_export_dialog()
        print(json.dumps(res, ensure_ascii=False))

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
