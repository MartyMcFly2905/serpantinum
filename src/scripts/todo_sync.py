#!/usr/bin/env python3
"""
Serpantinum Todo Sync, Todoist API v1 Bidirectional Engine & CSV Manager
Manages persistent tasks, intelligent date parsing/grouping, Todoist API v1
two-way sync (with offline command queue), and full Todoist CSV import/export.
"""

import sys
import os
import re
import csv
import json
import time
import uuid
import ssl
import urllib.request
import urllib.error
import subprocess
from datetime import datetime, date, timedelta

CONFIG_DIR = os.path.expanduser(os.environ.get("XDG_CONFIG_HOME", "~/.config") + "/serpantinum")
TODOS_FILE = os.path.join(CONFIG_DIR, "todos.json")
TODOIST_TOKEN_FILE = os.path.join(CONFIG_DIR, "todoist_token.json")
TODOIST_SYNC_URL = "https://api.todoist.com/api/v1/sync"

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


# ==============================================================================
# DATE PARSING & NORMALIZATION
# ==============================================================================

def parse_natural_date(raw_str, ref_date=None):
    """
    Parses natural language date strings (Italian & English) or standard ISO dates.
    Returns (date_obj, time_str) or (None, "").
    """
    if not raw_str or not str(raw_str).strip():
        return None, ""

    if ref_date is None:
        ref_date = date.today()

    s = str(raw_str).strip()

    # Handle ISO 8601 datetime with 'T' (e.g. 2026-11-26T14:30:00Z or 2026-11-26T14:30:00)
    m_iso_dt = re.match(r"^(\d{4})-(\d{1,2})-(\d{1,2})[T ](\d{1,2}):(\d{2})", s)
    if m_iso_dt:
        try:
            d_obj = date(int(m_iso_dt.group(1)), int(m_iso_dt.group(2)), int(m_iso_dt.group(3)))
            t_str = f"{int(m_iso_dt.group(4)):02d}:{m_iso_dt.group(5)}"
            return d_obj, t_str
        except ValueError:
            pass

    s = s.lower()

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

    # Relative +N days
    m_rel = re.match(r"^\+\s*(\d+)\s*(?:d|dd|g|gg|days?|giorni?)?$", s)
    if m_rel:
        return ref_date + timedelta(days=int(m_rel.group(1))), time_part

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

    # Short European format (DD/MM)
    m_short_eur = re.match(r"^(\d{1,2})[-/.](\d{1,2})$", s)
    if m_short_eur:
        try:
            day_val = int(m_short_eur.group(1))
            mon_val = int(m_short_eur.group(2))
            cand = date(ref_date.year, mon_val, day_val)
            if cand < ref_date - timedelta(days=180):
                cand = date(ref_date.year + 1, mon_val, day_val)
            return cand, time_part
        except ValueError:
            pass

    # Named month: "15 nov 2026" or "15 nov" or "nov 15 2026"
    m_dm = re.search(r"\b(\d{1,2})\s+([a-zà-ü]+)(?:\s+(\d{4}))?\b", s)
    if m_dm and m_dm.group(2) in MONTHS:
        try:
            d_val = int(m_dm.group(1))
            m_val = MONTHS[m_dm.group(2)]
            y_val = int(m_dm.group(3)) if m_dm.group(3) else ref_date.year
            cand = date(y_val, m_val, d_val)
            if not m_dm.group(3) and cand < ref_date - timedelta(days=180):
                cand = date(y_val + 1, m_val, d_val)
            return cand, time_part
        except ValueError:
            pass

    m_md = re.search(r"\b([a-zà-ü]+)\s+(\d{1,2})(?:,?\s+(\d{4}))?\b", s)
    if m_md and m_md.group(1) in MONTHS:
        try:
            m_val = MONTHS[m_md.group(1)]
            d_val = int(m_md.group(2))
            y_val = int(m_md.group(3)) if m_md.group(3) else ref_date.year
            cand = date(y_val, m_val, d_val)
            if not m_md.group(3) and cand < ref_date - timedelta(days=180):
                cand = date(y_val + 1, m_val, d_val)
            return cand, time_part
        except ValueError:
            pass

    return None, time_part


def compute_date_meta(d_obj, time_part="", raw_str="", ref_date=None):
    if ref_date is None:
        ref_date = date.today()

    if d_obj is None:
        return {
            "due_date": "",
            "due_time": time_part or "",
            "due_raw": raw_str or "",
            "day_category": "nodate",
            "relative_label": raw_str or "",
            "days_diff": 999
        }

    diff = (d_obj - ref_date).days
    iso_str = d_obj.strftime("%Y-%m-%d")

    if diff < 0:
        cat = "overdue"
        if diff == -1:
            rel = "Ieri"
        else:
            rel = f"{d_obj.day} {MONTHS_ABBR_IT[d_obj.month]}"
    elif diff == 0:
        cat = "today"
        rel = "Oggi"
    elif diff == 1:
        cat = "tomorrow"
        rel = "Domani"
    elif diff <= 7:
        cat = "upcoming"
        rel = f"{WEEKDAYS_IT[d_obj.weekday()]} {d_obj.day}"
    else:
        cat = "future"
        rel = f"{d_obj.day} {MONTHS_ABBR_IT[d_obj.month]}"
        if d_obj.year != ref_date.year:
            rel += f" {d_obj.year}"

    if time_part:
        rel = f"{rel} {time_part}"

    return {
        "due_date": iso_str,
        "due_time": time_part or "",
        "due_raw": raw_str or iso_str,
        "day_category": cat,
        "relative_label": rel,
        "days_diff": diff
    }


def normalize_priority(raw_prio):
    """
    Normalizes priority to UI scale:
    1 = P1 (Urgent), 2 = P2 (High), 3 = P3 (Medium), 4 = P4 (Normal)
    """
    s = str(raw_prio or "4").strip().lower()
    if s in ("1", "p1", "urgent", "urgente", "high", "alta", "critical"):
        return 1, "P1", "#f38ba8"
    if s in ("2", "p2", "medium-high", "alta-media"):
        return 2, "P2", "#fab387"
    if s in ("3", "p3", "medium", "media"):
        return 3, "P3", "#89b4fa"
    return 4, "P4", "#a6adc8"


def ui_prio_to_todoist_api(ui_prio):
    """Todoist API v1 uses 4=Urgent(P1), 3=High(P2), 2=Medium(P3), 1=Normal(P4)."""
    try:
        p = int(ui_prio)
    except (ValueError, TypeError):
        p = 4
    return max(1, min(4, 5 - p))


def todoist_api_to_ui_prio(api_prio):
    """Converts Todoist API v1 priority (1..4) to UI priority (P1=1..P4=4)."""
    try:
        p = int(api_prio)
    except (ValueError, TypeError):
        p = 1
    return max(1, min(4, 5 - p))


def is_uncompletable_separator(text):
    if not text:
        return False
    s = text.strip()
    return s.startswith("* ") or s in ("---", "___", "***")


def clean_uncompletable_title(text):
    s = (text or "").strip()
    if s.startswith("* "):
        return s[2:].strip()
    return s


def extract_labels(text):
    """Extracts @label tokens from task text and returns (labels_list, first_category)."""
    if not text:
        return [], ""
    found = re.findall(r"@([a-zA-Z0-9_\-àèéìòù]+)", text)
    labels = []
    for l in found:
        if l not in labels:
            labels.append(l)
    return labels, (labels[0] if labels else "")


def strip_inline_labels(text):
    """Removes inline @label tokens when pushing clean content to Todoist (labels sent separately)."""
    if not text:
        return ""
    cleaned = re.sub(r"\s*@[a-zA-Z0-9_\-àèéìòù]+", "", text).strip()
    return cleaned or text.strip()


def refresh_task_dates(task, today=None):
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
    if "source" not in task:
        task["source"] = "todoist" if task.get("todoist_id") else "local"
    return task


# ==============================================================================
# TODOIST TOKEN & STATE MANAGEMENT (SECURE 0600)
# ==============================================================================

def load_todoist_cfg():
    ensure_config_dir()
    if os.path.isfile(TODOIST_TOKEN_FILE):
        try:
            with open(TODOIST_TOKEN_FILE, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                if isinstance(cfg, dict):
                    cfg.setdefault("api_token", "")
                    cfg.setdefault("enabled", bool(cfg.get("api_token")))
                    cfg.setdefault("project_id", "")
                    cfg.setdefault("project_name", "Tutti i progetti")
                    cfg.setdefault("user_name", "")
                    cfg.setdefault("user_email", "")
                    cfg.setdefault("last_sync", 0)
                    cfg.setdefault("projects", [])
                    cfg.setdefault("pending_commands", [])
                    cfg.setdefault("sync_error", "")
                    return cfg
        except Exception:
            pass
    return {
        "api_token": "",
        "enabled": False,
        "project_id": "",
        "project_name": "Tutti i progetti",
        "user_name": "",
        "user_email": "",
        "last_sync": 0,
        "projects": [],
        "pending_commands": [],
        "sync_error": ""
    }


def save_todoist_cfg(cfg):
    ensure_config_dir()
    tmp_path = TODOIST_TOKEN_FILE + f".tmp.{os.getpid()}"
    fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, TODOIST_TOKEN_FILE)
    return cfg


def public_todoist_meta(cfg=None):
    """Non-sensitive Todoist status summary embedded into todos.json for QML."""
    if cfg is None:
        cfg = load_todoist_cfg()
    connected = bool(cfg.get("enabled") and cfg.get("api_token"))
    return {
        "connected": connected,
        "user_name": cfg.get("user_name", "") if connected else "",
        "user_email": cfg.get("user_email", "") if connected else "",
        "project_id": cfg.get("project_id", "") if connected else "",
        "project_name": cfg.get("project_name", "Tutti i progetti") if connected else "",
        "projects": cfg.get("projects", []) if connected else [],
        "last_sync": cfg.get("last_sync", 0) if connected else 0,
        "pending_count": len(cfg.get("pending_commands", [])) if connected else 0,
        "sync_error": cfg.get("sync_error", "") if connected else ""
    }


def todoist_api_sync_request(token, resource_types=None, commands=None, sync_token="*", timeout=15):
    payload = {"sync_token": sync_token}
    if resource_types is not None:
        payload["resource_types"] = resource_types
    if commands:
        payload["commands"] = commands

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        TODOIST_SYNC_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": "Serpantinum-TodoWidget/2.0"
        },
        method="POST"
    )
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        err_body = ""
        try:
            err_body = e.read().decode("utf-8", errors="ignore")[:240]
        except Exception:
            pass
        if e.code in (401, 403):
            raise RuntimeError("Token Todoist non valido o revocato (HTTP 401/403)")
        raise RuntimeError(f"Errore API Todoist (HTTP {e.code}): {err_body or e.reason}")
    except urllib.error.URLError as e:
        raise ConnectionError(f"Connessione a Todoist non disponibile: {e.reason}")
    except Exception as e:
        raise RuntimeError(f"Errore sincronizzazione Todoist: {e}")


def queue_todoist_command(cmd_obj):
    cfg = load_todoist_cfg()
    if not (cfg.get("enabled") and cfg.get("api_token")):
        return False
    cfg["pending_commands"].append(cmd_obj)
    save_todoist_cfg(cfg)
    return True


def flush_todoist_commands_only():
    """Flushes queued commands without a full pull (fast push for add/toggle/delete)."""
    cfg = load_todoist_cfg()
    if not (cfg.get("enabled") and cfg.get("api_token")):
        return None
    cmds = cfg.get("pending_commands", [])
    if not cmds:
        return {"status": "ok", "flushed": 0}
    try:
        resp = todoist_api_sync_request(cfg["api_token"], commands=cmds, sync_token="*", timeout=10)
        sync_status = resp.get("sync_status", {}) or {}
        remaining = []
        for c in cmds:
            st = sync_status.get(c["uuid"])
            if st != "ok":
                # Drop permanent client errors (4xx), keep transient network/5xx
                if isinstance(st, dict) and str(st.get("http_code", "")).startswith("4"):
                    continue
                remaining.append(c)
        cfg["pending_commands"] = remaining
        cfg["sync_error"] = ""
        cfg["last_sync"] = int(time.time())
        save_todoist_cfg(cfg)
        return {
            "status": "ok",
            "temp_id_mapping": resp.get("temp_id_mapping", {}) or {},
            "remaining": len(remaining)
        }
    except Exception as e:
        cfg["sync_error"] = str(e)
        save_todoist_cfg(cfg)
        return {"status": "offline", "message": str(e)}


def sync_with_todoist(override_token=None, override_project_id=None):
    """
    Full bidirectional sync with Todoist API v1:
    1. Flushes any offline pending commands (add/complete/uncomplete/delete).
    2. Pulls user info, projects, sections, and active items.
    3. Merges Todoist items into todos.json while preserving local-only tasks.
    """
    cfg = load_todoist_cfg()
    token = (override_token or cfg.get("api_token") or "").strip()
    if not token:
        return {"status": "error", "message": "Nessun token Todoist configurato"}

    cmds = cfg.get("pending_commands", []) if override_token is None else []

    try:
        resp = todoist_api_sync_request(
            token,
            resource_types=["user", "projects", "sections", "items"],
            commands=cmds if cmds else None,
            sync_token="*",
            timeout=15
        )
    except Exception as e:
        if override_token is None:
            cfg["sync_error"] = str(e)
            save_todoist_cfg(cfg)
            data = load_todos()
            data["todoist"] = public_todoist_meta(cfg)
            save_todos(data)
        return {"status": "error", "message": str(e)}

    # Update pending commands queue
    if cmds:
        sync_status = resp.get("sync_status", {}) or {}
        remaining = []
        for c in cmds:
            st = sync_status.get(c["uuid"])
            if st != "ok":
                if isinstance(st, dict) and str(st.get("http_code", "")).startswith("4"):
                    continue
                remaining.append(c)
        cfg["pending_commands"] = remaining

    user = resp.get("user") or {}
    raw_projects = [
        p for p in (resp.get("projects") or [])
        if not p.get("is_deleted") and not p.get("is_archived")
    ]
    raw_projects.sort(key=lambda p: (0 if p.get("inbox_project") else 1, p.get("child_order", 0)))

    projects_list = [
        {
            "id": str(p["id"]),
            "name": p.get("name", "Senza nome"),
            "is_inbox": bool(p.get("inbox_project")),
            "color": p.get("color", "")
        }
        for p in raw_projects
    ]
    proj_name_map = {p["id"]: p["name"] for p in projects_list}
    proj_inbox_ids = {p["id"] for p in projects_list if p["is_inbox"]}
    proj_order_map = {p["id"]: idx for idx, p in enumerate(projects_list)}

    raw_sections = [
        s for s in (resp.get("sections") or [])
        if not s.get("is_deleted") and not s.get("is_archived")
    ]
    raw_sections.sort(key=lambda s: (proj_order_map.get(str(s.get("project_id", "")), 999), s.get("section_order", 0)))
    sec_name_map = {str(s["id"]): s.get("name", "") for s in raw_sections}
    sec_order_map = {str(s["id"]): idx + 1 for idx, s in enumerate(raw_sections)}

    selected_project_id = cfg.get("project_id", "")
    if override_project_id is not None:
        selected_project_id = str(override_project_id).strip()

    if selected_project_id and selected_project_id not in proj_name_map:
        selected_project_id = ""

    selected_project_name = proj_name_map.get(selected_project_id, "Tutti i progetti") if selected_project_id else "Tutti i progetti"

    cfg["api_token"] = token
    cfg["enabled"] = True
    cfg["user_name"] = user.get("full_name") or user.get("email") or "Todoist"
    cfg["user_email"] = user.get("email") or ""
    cfg["projects"] = projects_list
    cfg["project_id"] = selected_project_id
    cfg["project_name"] = selected_project_name
    cfg["last_sync"] = int(time.time())
    cfg["sync_error"] = ""
    save_todoist_cfg(cfg)

    today = date.today()
    raw_items = resp.get("items") or []
    todoist_tasks = []

    for idx, it in enumerate(raw_items):
        if it.get("is_deleted"):
            continue
        is_done = bool(it.get("checked") or it.get("is_completed"))
        proj_id = str(it.get("project_id") or "")
        if selected_project_id and proj_id != selected_project_id:
            continue

        sec_id = str(it.get("section_id") or "")
        raw_content = (it.get("content") or "").strip()
        if not raw_content:
            continue

        uncomp = is_uncompletable_separator(raw_content)
        clean_title = clean_uncompletable_title(raw_content) if uncomp else raw_content

        # Determine section/category label
        if sec_id and sec_id in sec_name_map:
            cat_name = sec_name_map[sec_id]
            sec_idx = sec_order_map.get(sec_id, 0)
            if not selected_project_id and proj_id not in proj_inbox_ids and proj_id in proj_name_map:
                cat_name = f"{proj_name_map[proj_id]} · {cat_name}"
        elif not selected_project_id and proj_id in proj_name_map and proj_id not in proj_inbox_ids:
            cat_name = proj_name_map[proj_id]
            sec_idx = (proj_order_map.get(proj_id, 0) + 1) * 100
        else:
            cat_name = ""
            sec_idx = 0

        # Parse Todoist due object
        due_obj = it.get("due")
        due_date_raw = ""
        due_str_raw = ""
        if isinstance(due_obj, dict):
            due_date_raw = str(due_obj.get("date") or "")
            due_str_raw = str(due_obj.get("string") or due_date_raw)

        d_obj, t_part = parse_natural_date(due_date_raw, today)
        date_meta = compute_date_meta(d_obj, t_part, due_str_raw, today)

        ui_p = todoist_api_to_ui_prio(it.get("priority", 1))
        p_num, p_lbl, p_col = normalize_priority(ui_p)

        labels = [str(l) for l in (it.get("labels") or []) if str(l).strip()]
        indent_level = 2 if it.get("parent_id") else 1
        created_ts = int(time.time())
        added_at = it.get("added_at") or it.get("created_at") or ""
        if added_at:
            try:
                created_ts = int(datetime.fromisoformat(added_at.replace("Z", "+00:00")).timestamp())
            except Exception:
                pass

        todoist_tasks.append({
            "id": f"td_{it['id']}",
            "todoist_id": str(it["id"]),
            "source": "todoist",
            "project_id": proj_id,
            "section_id": sec_id,
            "item_type": "separator" if uncomp else "task",
            "uncompletable": uncomp,
            "title": clean_title,
            "raw_title": raw_content,
            "description": (it.get("description") or "").strip(),
            "completed": is_done,
            "priority": p_num,
            "priority_label": p_lbl,
            "priority_color": p_col,
            "indent": indent_level,
            "category": cat_name,
            "section_description": "",
            "section_index": sec_idx,
            "labels": labels,
            "due_date": date_meta["due_date"],
            "due_time": date_meta["due_time"],
            "due_raw": date_meta["due_raw"],
            "day_category": date_meta["day_category"],
            "relative_label": date_meta["relative_label"],
            "days_diff": date_meta["days_diff"],
            "created_at": created_ts,
            "csv_order": int(it.get("child_order", idx))
        })

    # Merge with existing local-only (non-Todoist) tasks
    data = load_todos()
    local_only = [
        t for t in data.get("todos", [])
        if t.get("source") != "todoist" and not t.get("todoist_id")
    ]
    data["todos"] = todoist_tasks + local_only
    data["todoist"] = public_todoist_meta(cfg)
    save_todos(data)

    return {
        "status": "ok",
        "action": "todoist_synced",
        "synced_count": len(todoist_tasks),
        "total_count": len(data["todos"]),
        "todoist": data["todoist"],
        "todos": data["todos"]
    }


def disconnect_todoist(remove_synced_tasks=False):
    if os.path.isfile(TODOIST_TOKEN_FILE):
        try:
            os.remove(TODOIST_TOKEN_FILE)
        except Exception:
            pass
    data = load_todos()
    if remove_synced_tasks:
        data["todos"] = [
            t for t in data.get("todos", [])
            if t.get("source") != "todoist" and not t.get("todoist_id")
        ]
    else:
        for t in data.get("todos", []):
            t["source"] = "local"
            t.pop("todoist_id", None)
    data["todoist"] = public_todoist_meta(load_todoist_cfg())
    save_todos(data)
    return {
        "status": "ok",
        "action": "todoist_disconnected",
        "todoist": data["todoist"],
        "todos": data["todos"]
    }


# ==============================================================================
# LOCAL PERSISTENCE & CRUD (WITH AUTOMATIC TODOIST PUSH)
# ==============================================================================

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


def load_todos():
    ensure_config_dir()
    today = date.today()
    td_meta = public_todoist_meta()
    if os.path.isfile(TODOS_FILE):
        try:
            with open(TODOS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict) and "todos" in data:
                    todos = [refresh_task_dates(t, today) for t in data["todos"] if isinstance(t, dict)]
                    data["todos"] = todos
                    if "sections" not in data:
                        data["sections"] = extract_sections_from_todos(todos)
                    data["todoist"] = td_meta
                    return data
                elif isinstance(data, list):
                    todos = [refresh_task_dates(t, today) for t in data if isinstance(t, dict)]
                    return {
                        "updated_at": int(time.time()),
                        "sections": extract_sections_from_todos(todos),
                        "todoist": td_meta,
                        "todos": todos
                    }
        except Exception:
            pass
    return {"updated_at": int(time.time()), "sections": [], "todoist": td_meta, "todos": []}


def save_todos(data):
    ensure_config_dir()
    data["updated_at"] = int(time.time())
    if "todos" in data:
        data["sections"] = extract_sections_from_todos(data["todos"])
    if "todoist" not in data:
        data["todoist"] = public_todoist_meta()
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
    cfg = load_todoist_cfg()
    is_td_connected = bool(cfg.get("enabled") and cfg.get("api_token"))

    temp_id = str(uuid.uuid4())
    new_item = {
        "id": f"todo_{now_ms}_{len(data['todos'])}",
        "source": "todoist" if is_td_connected else "local",
        "item_type": "separator" if uncomp else "task",
        "uncompletable": uncomp,
        "title": clean_uncompletable_title(clean_title) if uncomp else clean_title,
        "raw_title": clean_title,
        "description": (description or "").strip(),
        "completed": False,
        "priority": p_num,
        "priority_label": p_lbl,
        "priority_color": p_col,
        "indent": 1,
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

    if is_td_connected:
        args = {
            "content": strip_inline_labels(clean_title) if labels else clean_title,
            "priority": ui_prio_to_todoist_api(p_num)
        }
        if new_item["description"]:
            args["description"] = new_item["description"]
        if labels:
            args["labels"] = labels
        if cfg.get("project_id"):
            args["project_id"] = cfg["project_id"]
        if date_meta["due_date"]:
            if date_meta["due_time"]:
                args["due"] = {"date": f"{date_meta['due_date']}T{date_meta['due_time']}:00"}
            else:
                args["due"] = {"date": date_meta["due_date"]}
        elif due_date and str(due_date).strip():
            args["due"] = {"string": str(due_date).strip()}

        queue_todoist_command({
            "type": "item_add",
            "uuid": str(uuid.uuid4()),
            "temp_id": temp_id,
            "args": args
        })
        flush_res = flush_todoist_commands_only()
        if flush_res and flush_res.get("status") == "ok":
            real_id = flush_res.get("temp_id_mapping", {}).get(temp_id)
            if real_id:
                new_item["todoist_id"] = str(real_id)
                new_item["id"] = f"td_{real_id}"

    data["todos"].insert(0, new_item)
    data["todoist"] = public_todoist_meta()
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
        td_id = found.get("todoist_id")
        if td_id:
            cmd_type = "item_complete" if found["completed"] else "item_uncomplete"
            queue_todoist_command({
                "type": cmd_type,
                "uuid": str(uuid.uuid4()),
                "args": {"id": str(td_id)}
            })
            flush_todoist_commands_only()
        data["todoist"] = public_todoist_meta()
        save_todos(data)
        return {"status": "ok", "action": "toggled", "item": found}
    return {"status": "error", "message": "Elemento non trovato"}


def delete_todo(todo_id):
    data = load_todos()
    target_id = str(todo_id).strip()
    target_item = None
    remaining = []
    for it in data["todos"]:
        if str(it.get("id")).strip() == target_id:
            target_item = it
        else:
            remaining.append(it)

    if target_item is not None:
        td_id = target_item.get("todoist_id")
        if td_id:
            queue_todoist_command({
                "type": "item_delete",
                "uuid": str(uuid.uuid4()),
                "args": {"id": str(td_id)}
            })
            flush_todoist_commands_only()
        data["todos"] = remaining
        data["todoist"] = public_todoist_meta()
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


# ==============================================================================
# CSV IMPORT / EXPORT (TODOIST TEMPLATE COMPATIBLE)
# ==============================================================================

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
    if not content or not content.strip():
        return []

    delim = detect_delimiter(content)
    reader = csv.reader(content.splitlines(), delimiter=delim)
    rows = list(reader)
    if not rows:
        return []

    header_raw = [c.strip().lstrip("\ufeff") for c in rows[0]]
    header_upper = [c.upper() for c in header_raw]

    is_todoist = ("TYPE" in header_upper and "CONTENT" in header_upper)
    col_map = {name: idx for idx, name in enumerate(header_upper)}

    def get_col(row, name):
        idx = col_map.get(name, -1)
        if idx >= 0 and idx < len(row):
            return row[idx].strip()
        return ""

    today = date.today()
    base_time = int(time.time() * 1000)
    parsed_items = []
    current_section = ""
    current_section_desc = ""
    current_section_idx = 0
    last_task = None

    start_row = 1 if is_todoist or any(h in ("TITLE", "TASK", "CONTENUTO", "ATTIVITA", "ATTIVITÀ", "NAME", "NOME") for h in header_upper) else 0

    for r_idx, row in enumerate(rows[start_row:], start=1):
        if not row or not any(c.strip() for c in row):
            continue

        if is_todoist:
            row_type = get_col(row, "TYPE").lower()
            content_val = get_col(row, "CONTENT")
            desc_val = get_col(row, "DESCRIPTION")

            if row_type == "section":
                if content_val:
                    current_section = content_val
                    current_section_desc = desc_val
                    current_section_idx += 1
                    last_task = None
                continue

            if row_type == "note":
                if content_val:
                    if last_task is not None:
                        existing_desc = last_task.get("description", "")
                        last_task["description"] = (existing_desc + "\n" + content_val).strip() if existing_desc else content_val
                    elif current_section:
                        current_section_desc = (current_section_desc + "\n" + content_val).strip() if current_section_desc else content_val
                continue

            if row_type and row_type not in ("task", "item"):
                continue

            if not content_val:
                continue

            prio_val = get_col(row, "PRIORITY")
            date_val = get_col(row, "DATE")
            indent_val = get_col(row, "INDENT") or "1"

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
                "source": "local",
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
            title = row[0].strip() if len(row) > 0 else ""
            if not title:
                continue

            uncomp = is_uncompletable_separator(title)
            clean_title = clean_uncompletable_title(title) if uncomp else title

            done = False
            prio = "4"
            cat = ""
            due = ""
            desc = ""

            for cell in row[1:]:
                val = cell.strip()
                if not val:
                    continue
                low = val.lower()
                if low in TRUE_VALUES or low in ("0", "false", "no", "pending", "open"):
                    done = low in TRUE_VALUES
                elif low in ("1", "2", "3", "4", "p1", "p2", "p3", "p4", "high", "medium", "low", "urgent"):
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
                "source": "local",
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

    elif cmd == "--todoist-status":
        print(json.dumps({"status": "ok", "todoist": public_todoist_meta()}, ensure_ascii=False))

    elif cmd == "--todoist-connect":
        token = sys.argv[2] if len(sys.argv) > 2 else ""
        proj_id = sys.argv[3] if len(sys.argv) > 3 else ""
        res = sync_with_todoist(override_token=token, override_project_id=proj_id)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--todoist-sync":
        res = sync_with_todoist()
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--todoist-set-project":
        proj_id = sys.argv[2] if len(sys.argv) > 2 else ""
        res = sync_with_todoist(override_project_id=proj_id)
        print(json.dumps(res, ensure_ascii=False))

    elif cmd == "--todoist-disconnect":
        remove_tasks = len(sys.argv) > 2 and sys.argv[2] in ("--remove-tasks", "1", "true")
        res = disconnect_todoist(remove_synced_tasks=remove_tasks)
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
