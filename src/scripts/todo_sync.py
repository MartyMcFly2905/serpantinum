#!/usr/bin/env python3
"""
Serpantinum Todo Sync & CSV Engine
Manages persistent tasks, intelligent date parsing/grouping, and full Todoist CSV import/export.
"""

import sys
import os
import re
import csv
import json
import time
import subprocess
from datetime import datetime, date, timedelta

CONFIG_DIR = os.path.expanduser(os.environ.get("XDG_CONFIG_HOME", "~/.config") + "/serpantinum")
TODOS_FILE = os.path.join(CONFIG_DIR, "todos.json")

MONTHS = {
    "gen": 1, "jan": 1, "gennaio": 1, "january": 1,
    "feb": 2, "febbraio": 2, "february": 2,
    "mar": 3, "marzo": 3, "march": 3,
    "apr": 4, "aprile": 4, "april": 4,
    "mag": 5, "may": 5, "maggio": 5,
    "giu": 6, "jun": 6, "giugno": 6, "june": 6,
    "lug": 7, "jul": 7, "luglio": 7, "july": 7,
    "ago": 8, "aug": 8, "agosto": 8, "august": 8,
    "set": 9, "sep": 9, "settembre": 9, "september": 9,
    "ott": 10, "oct": 10, "ottobre": 10, "october": 10,
    "nov": 11, "novembre": 11, "november": 11,
    "dic": 12, "dec": 12, "dicembre": 12, "december": 12
}

WEEKDAYS_IT = ["Lun", "Mar", "Mer", "Gio", "Ven", "Sab", "Dom"]
MONTHS_ABBR_IT = ["", "Gen", "Feb", "Mar", "Apr", "Mag", "Giu", "Lug", "Ago", "Set", "Ott", "Nov", "Dic"]

WEEKDAY_NAMES = {
    "lun": 0, "lunedì": 0, "lunedi": 0, "mon": 0, "monday": 0,
    "mar": 1, "martedì": 1, "martedi": 1, "tue": 1, "tuesday": 1,
    "mer": 2, "mercoledì": 2, "mercoledi": 2, "wed": 2, "wednesday": 2,
    "gio": 3, "giovedì": 3, "giovedi": 3, "thu": 3, "thursday": 3,
    "ven": 4, "venerdì": 4, "venerdi": 4, "fri": 4, "friday": 4,
    "sab": 5, "sabato": 5, "sat": 5, "saturday": 5,
    "dom": 6, "domenica": 6, "sun": 6, "sunday": 6
}

TRUE_VALUES = {"1", "true", "yes", "si", "sì", "done", "x", "checked", "completato", "fatto", "t", "y"}

def ensure_config_dir():
    os.makedirs(CONFIG_DIR, exist_ok=True)

def parse_natural_date(raw_str, ref_date=None):
    """
    Parses natural language date strings (Italian & English) or standard ISO dates.
    Returns (date_obj, time_str) or (None, None).
    """
    if not raw_str or not str(raw_str).strip():
        return None, ""

    if ref_date is None:
        ref_date = date.today()

    s = str(raw_str).strip().lower()

    # Extract time component if present (e.g. 14:30 or 2:30pm)
    time_part = ""
    m_time = re.search(r"\b(\d{1,2}):(\d{2})(?::\d{2})?\b", s)
    if m_time:
        hh = int(m_time.group(1))
        mm = m_time.group(2)
        time_part = f"{hh:02d}:{mm}"
        s = re.sub(r"\b\d{1,2}:\d{2}(?::\d{2})?\b", "", s).strip()
    else:
        m_ampm = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", s)
        if m_ampm:
            hh = int(m_ampm.group(1))
            mm = m_ampm.group(2) or "00"
            ampm = m_ampm.group(3)
            if ampm == "pm" and hh < 12:
                hh += 12
            elif ampm == "am" and hh == 12:
                hh = 0
            time_part = f"{hh:02d}:{mm}"
            s = re.sub(r"\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b", "", s).strip()

    # Clean auxiliary words
    s = re.sub(r"\b(at|alle|ore|h|il|in|on|at the)\b", "", s).strip()

    if s in ("today", "oggi"):
        return ref_date, time_part
    if s in ("tomorrow", "domani"):
        return ref_date + timedelta(days=1), time_part
    if s in ("yesterday", "ieri"):
        return ref_date - timedelta(days=1), time_part
    if s in ("dopodomani", "day after tomorrow"):
        return ref_date + timedelta(days=2), time_part

    # Weekday check (e.g. "venerdì", "next friday")
    is_next = "next" in s or "prossim" in s
    for w_name, w_idx in WEEKDAY_NAMES.items():
        if re.search(r"\b" + re.escape(w_name) + r"\b", s):
            days_ahead = (w_idx - ref_date.weekday()) % 7
            if days_ahead == 0 or is_next:
                days_ahead += 7
            return ref_date + timedelta(days=days_ahead), time_part

    # Standard ISO (YYYY-MM-DD or YYYY/MM/DD)
    m_iso = re.match(r"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:\b.*)?$", s)
    if m_iso:
        try:
            return date(int(m_iso.group(1)), int(m_iso.group(2)), int(m_iso.group(3))), time_part
        except ValueError:
            pass

    # European format (DD/MM/YYYY or DD-MM-YYYY)
    m_eur = re.match(r"^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})(?:\b.*)?$", s)
    if m_eur:
        try:
            return date(int(m_eur.group(3)), int(m_eur.group(2)), int(m_eur.group(1))), time_part
        except ValueError:
            pass

    # Format like "15 nov", "15 novembre 2026", "nov 15"
    tokens = re.findall(r"[a-zA-Zà-ù]+|\d+", s)
    if len(tokens) >= 2:
        d_val = None
        m_val = None
        y_val = ref_date.year
        for tok in tokens:
            if tok.isdigit():
                val = int(tok)
                if val > 1900:
                    y_val = val
                elif d_val is None and 1 <= val <= 31:
                    d_val = val
            elif tok in MONTHS:
                m_val = MONTHS[tok]

        if d_val and m_val:
            try:
                # If date is earlier in the year and no year specified, assume current year or next
                return date(y_val, m_val, d_val), time_part
            except ValueError:
                pass

    return None, time_part

def compute_date_meta(date_obj, time_part, raw_str, today=None):
    if today is None:
        today = date.today()

    if not date_obj:
        return {
            "due_date": "",
            "due_time": time_part or "",
            "due_raw": (raw_str or "").strip(),
            "day_category": "nodate",
            "relative_label": (raw_str or "").strip(),
            "days_diff": 999
        }

    iso_date = date_obj.strftime("%Y-%m-%d")
    diff = (date_obj - today).days

    time_suffix = f" {time_part}" if time_part else ""

    if diff < 0:
        day_cat = "overdue"
        if diff == -1:
            rel = "Ieri" + time_suffix
        else:
            rel = f"Scaduta ({abs(diff)} gg fa)"
    elif diff == 0:
        day_cat = "today"
        rel = "Oggi" + time_suffix
    elif diff == 1:
        day_cat = "tomorrow"
        rel = "Domani" + time_suffix
    elif 2 <= diff <= 6:
        day_cat = "upcoming"
        wk = WEEKDAYS_IT[date_obj.weekday()]
        rel = f"{wk} {date_obj.day} {MONTHS_ABBR_IT[date_obj.month]}" + time_suffix
    else:
        day_cat = "future"
        rel = f"{date_obj.day} {MONTHS_ABBR_IT[date_obj.month]}" + time_suffix

    return {
        "due_date": iso_date,
        "due_time": time_part or "",
        "due_raw": (raw_str or "").strip(),
        "day_category": day_cat,
        "relative_label": rel,
        "days_diff": diff
    }

def normalize_priority(val):
    """
    Normalizes priority into Todoist standards:
    1 = P1 (Highest / Urgent / Red)
    2 = P2 (High / Orange)
    3 = P3 (Medium / Blue)
    4 = P4 (Normal / Default)
    """
    if val is None or str(val).strip() == "":
        return 4, "P4", "#a6adc8"
    s = str(val).strip().lower()
    if s in ("1", "p1", "urgent", "urgente", "critica", "max"):
        return 1, "P1", "#f38ba8"
    if s in ("2", "p2", "high", "alta"):
        return 2, "P2", "#fab387"
    if s in ("3", "p3", "medium", "media", "med"):
        return 3, "P3", "#89b4fa"
    return 4, "P4", "#a6adc8"

def extract_labels(content):
    """
    Extracts @label and #project from task content string.
    """
    labels = []
    category = ""
    for match in re.finditer(r"@([\w\-]+)", content):
        labels.append(match.group(1))
    cat_match = re.search(r"#([\w\-]+)", content)
    if cat_match:
        category = cat_match.group(1)
    return labels, category

def is_uncompletable_separator(title):
    """
    In Todoist, tasks starting with '* ' (asterisk + space) or '---' are uncompletable separator headers.
    """
    t = (title or "").strip()
    if t.startswith("* ") or t in ("---", "___", "***"):
        return True
    return False

def clean_uncompletable_title(title):
    t = (title or "").strip()
    if t.startswith("* "):
        return t[2:].strip()
    return t

def refresh_task_dates(task, today=None):
    """
    Recomputes day_category and relative_label for an existing task.
    """
    if today is None:
        today = date.today()

    due_date_str = task.get("due_date", "")
    time_part = task.get("due_time", "")
    raw_str = task.get("due_raw", "") or due_date_str

    if due_date_str:
        try:
            d_obj = datetime.strptime(due_date_str, "%Y-%m-%d").date()
            meta = compute_date_meta(d_obj, time_part, raw_str, today)
        except ValueError:
            meta = compute_date_meta(None, time_part, raw_str, today)
    elif raw_str:
        d_obj, t_part = parse_natural_date(raw_str, today)
        meta = compute_date_meta(d_obj, t_part or time_part, raw_str, today)
    else:
        meta = compute_date_meta(None, "", "", today)

    task.update(meta)
    p_num, p_lbl, p_col = normalize_priority(task.get("priority", 4))
    task["priority"] = p_num
    task["priority_label"] = p_lbl
    task["priority_color"] = p_col
    if "item_type" not in task:
        if is_uncompletable_separator(task.get("title", "")):
            task["item_type"] = "separator"
            task["uncompletable"] = True
        else:
            task["item_type"] = "task"
            task["uncompletable"] = False
    if "section_description" not in task:
        task["section_description"] = ""
    if "section_index" not in task:
        task["section_index"] = 0
    return task

def load_todos():
    ensure_config_dir()
    today = date.today()
    if os.path.isfile(TODOS_FILE):
        try:
            with open(TODOS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict) and "todos" in data:
                    todos = [refresh_task_dates(t, today) for t in data["todos"] if isinstance(t, dict)]
                    data["todos"] = todos
                    if "sections" not in data:
                        data["sections"] = extract_sections_from_todos(todos)
                    return data
                elif isinstance(data, list):
                    todos = [refresh_task_dates(t, today) for t in data if isinstance(t, dict)]
                    return {"updated_at": int(time.time()), "sections": extract_sections_from_todos(todos), "todos": todos}
        except Exception:
            pass
    return {"updated_at": int(time.time()), "sections": [], "todos": []}

def extract_sections_from_todos(todos):
    seen = {}
    sections = []
    for idx, t in enumerate(todos):
        cat = (t.get("category") or "").strip()
        if cat and cat not in seen:
            sec_obj = {
                "id": f"sec_{len(sections)}_{idx}",
                "title": cat,
                "description": (t.get("section_description") or "").strip(),
                "order": len(sections)
            }
            seen[cat] = sec_obj
            sections.append(sec_obj)
    return sections

def save_todos(data):
    ensure_config_dir()
    data["updated_at"] = int(time.time())
    if "todos" in data:
        data["sections"] = extract_sections_from_todos(data["todos"])
    tmp_path = TODOS_FILE + f".tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, TODOS_FILE)
    return data

def add_todo(title, priority=4, category="", due_date="", description=""):
    clean_title = (title or "").strip()
    if not clean_title:
        return {"status": "error", "message": "Titolo attività vuoto"}

    uncomp = is_uncompletable_separator(clean_title)
    labels, auto_cat = extract_labels(clean_title)
    final_cat = (category or auto_cat or "").strip()

    today = date.today()
    d_obj, t_part = parse_natural_date(due_date, today)
    date_meta = compute_date_meta(d_obj, t_part, due_date, today)

    p_num, p_lbl, p_col = normalize_priority(priority)

    data = load_todos()
    now_ms = int(time.time() * 1000)
    new_item = {
        "id": f"todo_{now_ms}_{len(data['todos'])}",
        "item_type": "separator" if uncomp else "task",
        "uncompletable": uncomp,
        "title": clean_uncompletable_title(clean_title) if uncomp else clean_title,
        "raw_title": clean_title,
        "description": (description or "").strip(),
        "completed": False,
        "priority": p_num,
        "priority_label": p_lbl,
        "priority_color": p_col,
        "category": final_cat,
        "section_description": "",
        "section_index": 0,
        "labels": labels,
        "due_date": date_meta["due_date"],
        "due_time": date_meta["due_time"],
        "due_raw": date_meta["due_raw"],
        "day_category": date_meta["day_category"],
        "relative_label": date_meta["relative_label"],
        "days_diff": date_meta["days_diff"],
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
            if item.get("uncompletable") or item.get("item_type") == "separator":
                return {"status": "ok", "action": "ignored_separator", "item": item}
            item["completed"] = not bool(item.get("completed"))
            found = item
            break
    if found is not None:
        save_todos(data)
        return {"status": "ok", "action": "toggled", "item": found}
    return {"status": "error", "message": "Elemento non trovato"}

def delete_todo(todo_id):
    data = load_todos()
    target_id = str(todo_id).strip()
    orig_len = len(data["todos"])
    data["todos"] = [it for it in data["todos"] if str(it.get("id")).strip() != target_id]
    if len(data["todos"]) < orig_len:
        save_todos(data)
        return {"status": "ok", "action": "deleted", "total": len(data["todos"])}
    return {"status": "error", "message": "Elemento non trovato"}

def clear_completed():
    data = load_todos()
    orig_len = len(data["todos"])
    data["todos"] = [it for it in data["todos"] if not bool(it.get("completed"))]
    cleared_count = orig_len - len(data["todos"])
    save_todos(data)
    return {"status": "ok", "action": "cleared", "cleared": cleared_count, "total": len(data["todos"])}

def clear_all():
    data = load_todos()
    orig_len = len(data["todos"])
    data["todos"] = []
    data["sections"] = []
    save_todos(data)
    return {"status": "ok", "action": "cleared_all", "cleared": orig_len, "total": 0}

def detect_delimiter(sample_text):
    for delim in [";", ",", "\t", "|"]:
        lines = [line for line in sample_text.splitlines() if line.strip()][:5]
        if lines and all(delim in line for line in lines):
            return delim
    try:
        sniffer = csv.Sniffer()
        return sniffer.sniff(sample_text).delimiter
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

def parse_todoist_or_generic_csv(content):
    """
    Parses CSV content matching Todoist templates or generic CSV formats.
    Supports:
    - TYPE=section (with CONTENT and DESCRIPTION)
    - TYPE=task (including uncompletable '* ' separator tasks)
    - TYPE=note (appended to previous task or section description)
    """
    if not content or not content.strip():
        return []

    delim = detect_delimiter(content)
    reader = csv.reader(content.splitlines(), delimiter=delim)
    rows = [r for r in reader if r and any(cell.strip() for cell in r)]
    if not rows:
        return []

    header = [c.strip().upper() for c in rows[0]]

    # Detect Todoist standard template columns
    is_todoist_format = "CONTENT" in header or "TYPE" in header
    col_map = {}
    for idx, col in enumerate(header):
        col_map[col] = idx

    today = date.today()
    parsed_items = []
    current_section = ""
    current_section_desc = ""
    current_section_idx = 0
    last_task = None
    base_time = int(time.time() * 1000)

    start_idx = 1 if (is_todoist_format or any(h in header for h in ("TITLE", "TASK", "NAME", "TESTO", "TITOLO"))) else 0

    for r_idx, row in enumerate(rows[start_idx:]):
        if not row:
            continue

        if is_todoist_format:
            row_type = row[col_map.get("TYPE", 0)].strip().lower() if "TYPE" in col_map and col_map["TYPE"] < len(row) else "task"
            content_val = row[col_map.get("CONTENT", 1)].strip() if "CONTENT" in col_map and col_map["CONTENT"] < len(row) else ""
            desc_val = row[col_map.get("DESCRIPTION", -1)].strip() if "DESCRIPTION" in col_map and col_map["DESCRIPTION"] < len(row) else ""
            prio_val = row[col_map.get("PRIORITY", -1)].strip() if "PRIORITY" in col_map and col_map["PRIORITY"] < len(row) else "4"
            date_val = row[col_map.get("DATE", -1)].strip() if "DATE" in col_map and col_map["DATE"] < len(row) else ""
            indent_val = row[col_map.get("INDENT", -1)].strip() if "INDENT" in col_map and col_map["INDENT"] < len(row) else "1"

            if row_type in ("section", "separator"):
                if content_val:
                    current_section = clean_uncompletable_title(content_val)
                    current_section_desc = desc_val
                    current_section_idx += 1
                    last_task = None
                continue

            if row_type == "note":
                if last_task and content_val:
                    if last_task.get("description"):
                        last_task["description"] += "\n" + content_val
                    else:
                        last_task["description"] = content_val
                elif current_section and content_val:
                    if current_section_desc:
                        current_section_desc += "\n" + content_val
                    else:
                        current_section_desc = content_val
                continue

            if not content_val:
                continue

            uncomp = is_uncompletable_separator(content_val)
            clean_title = clean_uncompletable_title(content_val) if uncomp else content_val

            labels, auto_cat = extract_labels(clean_title)
            d_obj, t_part = parse_natural_date(date_val, today)
            date_meta = compute_date_meta(d_obj, t_part, date_val, today)
            p_num, p_lbl, p_col = normalize_priority(prio_val)

            try:
                indent_num = max(1, int(indent_val))
            except ValueError:
                indent_num = 1

            item = {
                "id": f"todo_{base_time}_{r_idx}",
                "item_type": "separator" if uncomp else "task",
                "uncompletable": uncomp,
                "title": clean_title,
                "raw_title": content_val,
                "description": desc_val,
                "completed": False,
                "priority": p_num,
                "priority_label": p_lbl,
                "priority_color": p_col,
                "indent": indent_num,
                "category": current_section or auto_cat or "",
                "section_description": current_section_desc,
                "section_index": current_section_idx,
                "labels": labels,
                "due_date": date_meta["due_date"],
                "due_time": date_meta["due_time"],
                "due_raw": date_meta["due_raw"],
                "day_category": date_meta["day_category"],
                "relative_label": date_meta["relative_label"],
                "days_diff": date_meta["days_diff"],
                "created_at": int(time.time()),
                "csv_order": r_idx
            }
            parsed_items.append(item)
            last_task = item

        else:
            # Generic CSV parser
            title = row[0].strip()
            if not title:
                continue

            uncomp = is_uncompletable_separator(title)
            clean_title = clean_uncompletable_title(title) if uncomp else title

            done = False
            prio = "4"
            cat = ""
            due = ""
            desc = ""

            for c_idx, cell in enumerate(row[1:], start=1):
                val = cell.strip()
                if not val:
                    continue
                if val.lower() in TRUE_VALUES or val.lower() in ("false", "0", "no"):
                    done = val.lower() in TRUE_VALUES
                elif val.lower() in ("1", "2", "3", "4", "p1", "p2", "p3", "p4", "high", "alta", "low", "bassa"):
                    prio = val
                elif not due:
                    d_test, _ = parse_natural_date(val, today)
                    if d_test:
                        due = val
                    elif len(val) > 45 and not desc:
                        desc = val
                    elif not cat:
                        cat = val
                elif len(val) > 45 and not desc:
                    desc = val
                elif not cat:
                    cat = val

            labels, auto_cat = extract_labels(clean_title)
            d_obj, t_part = parse_natural_date(due, today)
            date_meta = compute_date_meta(d_obj, t_part, due, today)
            p_num, p_lbl, p_col = normalize_priority(prio)

            item = {
                "id": f"todo_{base_time}_{r_idx}",
                "item_type": "separator" if uncomp else "task",
                "uncompletable": uncomp,
                "title": clean_title,
                "raw_title": title,
                "description": desc,
                "completed": done,
                "priority": p_num,
                "priority_label": p_lbl,
                "priority_color": p_col,
                "indent": 1,
                "category": cat or auto_cat or "",
                "section_description": "",
                "section_index": 0,
                "labels": labels,
                "due_date": date_meta["due_date"],
                "due_time": date_meta["due_time"],
                "due_raw": date_meta["due_raw"],
                "day_category": date_meta["day_category"],
                "relative_label": date_meta["relative_label"],
                "days_diff": date_meta["days_diff"],
                "created_at": int(time.time()),
                "csv_order": r_idx
            }
            parsed_items.append(item)
            last_task = item

    return parsed_items

def import_csv_file(filepath, mode="merge"):
    clean_path = os.path.expanduser(filepath.strip())
    if not os.path.isfile(clean_path):
        return {"status": "error", "message": f"File non trovato: {clean_path}"}

    try:
        content = read_file_with_encodings(clean_path)
        new_items = parse_todoist_or_generic_csv(content)
        if not new_items:
            return {"status": "error", "message": "Nessuna attività valida trovata nel file CSV"}

        data = load_todos()
        if mode == "replace":
            data["todos"] = new_items
            imported_count = len(new_items)
        else:
            existing_map = {
                (it.get("title", "").strip().lower(), it.get("category", "").strip().lower()): it
                for it in data["todos"]
            }
            added = []
            updated_existing = 0
            for item in new_items:
                sig = (item["title"].strip().lower(), item["category"].strip().lower())
                if sig not in existing_map:
                    added.append(item)
                    existing_map[sig] = item
                else:
                    # Update description and section_description if newer CSV has them
                    ex = existing_map[sig]
                    if item.get("description") and not ex.get("description"):
                        ex["description"] = item["description"]
                    if item.get("section_description"):
                        ex["section_description"] = item["section_description"]
                    if item.get("section_index"):
                        ex["section_index"] = item["section_index"]
                    updated_existing += 1
            data["todos"] = added + data["todos"]
            imported_count = len(added) if added else updated_existing

        save_todos(data)
        return {
            "status": "ok",
            "action": "imported",
            "mode": mode,
            "filepath": clean_path,
            "imported_count": imported_count,
            "total_count": len(data["todos"]),
            "sections": data.get("sections", []),
            "todos": data["todos"]
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}

def export_csv_todoist(destination=None):
    """
    Exports tasks matching Todoist official template schema:
    TYPE,CONTENT,DESCRIPTION,PRIORITY,INDENT,AUTHOR,RESPONSIBLE,DATE,DATE_LANG,TIMEZONE
    """
    data = load_todos()
    ensure_config_dir()
    if not destination or not str(destination).strip():
        dest_path = os.path.join(CONFIG_DIR, "todoist_export.csv")
    else:
        dest_path = os.path.expanduser(str(destination).strip())

    try:
        dest_dir = os.path.dirname(dest_path)
        if dest_dir:
            os.makedirs(dest_dir, exist_ok=True)

        # Group tasks by section/category preserving order
        sections = {}
        section_descs = {}
        for it in data["todos"]:
            cat = it.get("category", "").strip() or "Generale"
            if cat not in sections:
                sections[cat] = []
                section_descs[cat] = it.get("section_description", "")
            sections[cat].append(it)

        with open(dest_path, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f, delimiter=",")
            writer.writerow(["TYPE", "CONTENT", "DESCRIPTION", "PRIORITY", "INDENT", "AUTHOR", "RESPONSIBLE", "DATE", "DATE_LANG", "TIMEZONE"])

            for sec_name, tasks in sections.items():
                if sec_name != "Generale":
                    writer.writerow(["section", sec_name, section_descs.get(sec_name, ""), "1", "1", "", "", "", "it", "Europe/Rome"])
                for task in tasks:
                    due_str = task.get("due_date", "")
                    if task.get("due_time"):
                        due_str += f" {task.get('due_time')}"
                    title_out = task.get("raw_title") or (f"* {task.get('title', '')}" if task.get("uncompletable") else task.get("title", ""))
                    writer.writerow([
                        "task",
                        title_out,
                        task.get("description", ""),
                        str(task.get("priority", 4)),
                        str(task.get("indent", 1)),
                        "",
                        "",
                        due_str,
                        "it",
                        "Europe/Rome"
                    ])

        return {
            "status": "ok",
            "action": "exported",
            "format": "todoist",
            "path": dest_path,
            "exported_count": len(data["todos"])
        }
    except Exception as e:
        return {"status": "error", "message": str(e)}

def pick_csv_dialog(mode="merge"):
    try:
        res = subprocess.run([
            "zenity", "--file-selection",
            "--title=Seleziona file CSV Todoist da importare",
            "--file-filter=File CSV Todoist (*.csv) | *.csv",
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
            "--title=Esporta attività in formato Todoist CSV",
            "--filename=todoist_tasks.csv",
            "--file-filter=File CSV (*.csv) | *.csv",
            "--file-filter=Tutti i file | *"
        ], capture_output=True, text=True, check=False)
        selected = res.stdout.strip()
        if not selected or res.returncode != 0:
            return {"status": "cancelled", "message": "Salvataggio annullato"}
        if not selected.lower().endswith(".csv"):
            selected += ".csv"
        return export_csv_todoist(selected)
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
        prio = sys.argv[3] if len(sys.argv) > 3 else "4"
        cat = sys.argv[4] if len(sys.argv) > 4 else ""
        due = sys.argv[5] if len(sys.argv) > 5 else ""
        desc = sys.argv[6] if len(sys.argv) > 6 else ""
        res = add_todo(title, priority=prio, category=cat, due_date=due, description=desc)
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

    elif cmd in ("--clear-all", "--empty"):
        res = clear_all()
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

    elif cmd in ("--export-csv", "--export-todoist"):
        path = sys.argv[2] if len(sys.argv) > 2 else None
        res = export_csv_todoist(path)
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
