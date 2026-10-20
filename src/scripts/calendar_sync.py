#!/usr/bin/env python3
"""
Serpantinum Calendar Sync Engine
Syncs iCalendar feeds (Google Calendar, Nextcloud, iCloud, Outlook, local .ics)
and generates a normalized, cached JSON database of upcoming and ongoing events.
"""

import sys
import os
import re
import json
import time
import hashlib
import urllib.request
import urllib.error
import ssl
from datetime import datetime, date, timedelta, timezone

CONFIG_DIR = os.path.expanduser(os.environ.get("XDG_CONFIG_HOME", "~/.config") + "/serpantinum")
CACHE_DIR = os.path.expanduser(os.environ.get("XDG_CACHE_HOME", "~/.cache") + "/serpantinum/calendar")
CONFIG_FILE = os.path.join(CONFIG_DIR, "calendars.json")
CACHE_FILE = os.path.join(CACHE_DIR, "events.json")

STATE_FILE = os.path.join(CACHE_DIR, "state.json")
COOKIE_FILE = os.path.join(CACHE_DIR, "cookies.txt")

DEFAULT_CONFIG = {
    "refresh_interval_minutes": 15,
    "calendars": []
}

WEEKDAY_MAP = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}

class RateLimitError(Exception):
    pass

class CaptivePortalError(Exception):
    pass

class NetworkError(Exception):
    pass

def ensure_dirs():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    os.makedirs(CACHE_DIR, exist_ok=True)

def load_state():
    ensure_dirs()
    if os.path.isfile(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"calendars": {}}

def save_state(st):
    ensure_dirs()
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(st, f, indent=2, ensure_ascii=False)
    except Exception as e:
        sys.stderr.write(f"Warning: could not save state: {e}\n")

def get_ics_cache_path(cal_id):
    return os.path.join(CACHE_DIR, f"calendar_{cal_id}.ics")

def read_cached_ics(cal_id):
    path = get_ics_cache_path(cal_id)
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
                if "BEGIN:VCALENDAR" in content or "BEGIN:VEVENT" in content:
                    return content
        except Exception as e:
            sys.stderr.write(f"Warning: error reading cached ics {path}: {e}\n")
    return None

def write_cached_ics(cal_id, content):
    ensure_dirs()
    path = get_ics_cache_path(cal_id)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return True
    except Exception as e:
        sys.stderr.write(f"Warning: could not write cache for {cal_id}: {e}\n")
        return False

def load_config():
    ensure_dirs()
    if os.path.isfile(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            sys.stderr.write(f"Error reading {CONFIG_FILE}: {e}\n")
    return dict(DEFAULT_CONFIG)

def save_config(cfg):
    ensure_dirs()
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

def unfold_lines(text):
    # RFC 5545 line unfolding: CRLF or LF followed by space or tab
    return re.sub(r'\r?\n[ \t]', '', text)

def unescape_ics_text(val):
    if not val:
        return ""
    val = val.replace('\\n', '\n').replace('\\N', '\n')
    val = val.replace('\\,', ',').replace('\\;', ';')
    val = val.replace('\\\\', '\\')
    return val.strip()

def parse_ics_datetime(dt_str, params=None):
    """
    Parses DTSTART / DTEND strings into a datetime object (or date if DATE).
    Returns (dt_obj, is_all_day).
    """
    if not dt_str:
        return None, False
    dt_str = dt_str.strip()
    params = params or {}

    is_all_day = (params.get("VALUE") == "DATE") or (len(dt_str) == 8 and dt_str.isdigit())

    if is_all_day:
        try:
            d = datetime.strptime(dt_str[:8], "%Y%m%d").date()
            dt = datetime(d.year, d.month, d.day, 0, 0, 0)
            return dt, True
        except Exception:
            return None, True

    # Check for UTC 'Z'
    is_utc = dt_str.endswith("Z")
    clean_dt = dt_str.rstrip("Z")

    formats = [
        "%Y%m%dT%H%M%S",
        "%Y%m%dT%H%M",
        "%Y%m%d"
    ]
    for fmt in formats:
        try:
            dt = datetime.strptime(clean_dt, fmt)
            if is_utc:
                # Convert UTC to local time
                dt_utc = dt.replace(tzinfo=timezone.utc)
                local_tz = datetime.now().astimezone().tzinfo
                dt = dt_utc.astimezone(local_tz).replace(tzinfo=None)
            return dt, False
        except ValueError:
            continue

    return None, False

def parse_duration(dur_str):
    """Parses basic ISO duration like PT1H30M, P1D"""
    if not dur_str:
        return timedelta(hours=1)
    dur_str = dur_str.strip().upper()
    days = 0
    hours = 0
    minutes = 0
    seconds = 0
    m_day = re.search(r'(\d+)D', dur_str)
    if m_day:
        days = int(m_day.group(1))
    m_hr = re.search(r'(\d+)H', dur_str)
    if m_hr:
        hours = int(m_hr.group(1))
    m_min = re.search(r'(\d+)M', dur_str)
    if m_min:
        minutes = int(m_min.group(1))
    m_sec = re.search(r'(\d+)S', dur_str)
    if m_sec:
        seconds = int(m_sec.group(1))
    td = timedelta(days=days, hours=hours, minutes=minutes, seconds=seconds)
    return td if td.total_seconds() > 0 else timedelta(hours=1)

def parse_vevent(lines, cal_info):
    """
    Parses a single VEVENT block into event dictionaries.
    Expands recurring events within a range around today.
    """
    props = {}
    params = {}
    rrule_str = ""

    for line in lines:
        if not line or ':' not in line:
            continue
        head, val = line.split(':', 1)
        parts = head.split(';')
        key = parts[0].upper()
        p_dict = {}
        for p in parts[1:]:
            if '=' in p:
                pk, pv = p.split('=', 1)
                p_dict[pk.upper()] = pv
        if key == "RRULE":
            rrule_str = val
        else:
            props[key] = val
            params[key] = p_dict

    # Check status
    if props.get("STATUS", "").upper() == "CANCELLED":
        return []

    summary = unescape_ics_text(props.get("SUMMARY", "Untitled Event"))
    location = unescape_ics_text(props.get("LOCATION", ""))
    description = unescape_ics_text(props.get("DESCRIPTION", ""))
    uid = props.get("UID", hashlib.md5((summary + str(time.time())).encode('utf-8')).hexdigest())

    dtstart_raw = props.get("DTSTART")
    if not dtstart_raw:
        return []

    start_dt, is_all_day = parse_ics_datetime(dtstart_raw, params.get("DTSTART"))
    if not start_dt:
        return []

    # Determine end time
    if "DTEND" in props:
        end_dt, _ = parse_ics_datetime(props["DTEND"], params.get("DTEND"))
    elif "DURATION" in props:
        end_dt = start_dt + parse_duration(props["DURATION"])
    elif is_all_day:
        end_dt = start_dt + timedelta(days=1)
    else:
        end_dt = start_dt + timedelta(hours=1)

    duration = (end_dt - start_dt) if end_dt else timedelta(hours=1)
    if duration.total_seconds() <= 0:
        duration = timedelta(days=1) if is_all_day else timedelta(hours=1)

    now = datetime.now()
    window_start = now - timedelta(days=60)
    window_end = now + timedelta(days=240)

    events = []

    def make_event(s_dt, e_dt, occ_id):
        # Format strings
        date_str = s_dt.strftime("%Y-%m-%d")
        if is_all_day:
            time_str = "All Day"
        else:
            s_time = s_dt.strftime("%H:%M")
            e_time = e_dt.strftime("%H:%M")
            time_str = f"{s_time} - {e_time}" if s_time != e_time else s_time

        ev_id = f"{cal_info['id']}_{uid}_{occ_id}"
        return {
            "id": ev_id,
            "uid": uid,
            "title": summary,
            "start": s_dt.strftime("%Y-%m-%dT%H:%M:%S"),
            "end": e_dt.strftime("%Y-%m-%dT%H:%M:%S"),
            "date": date_str,
            "year": s_dt.year,
            "month": s_dt.month,
            "day": s_dt.day,
            "time_str": time_str,
            "is_all_day": is_all_day,
            "location": location,
            "description": description,
            "calendar_id": cal_info["id"],
            "calendar_name": cal_info["name"],
            "calendar_color": cal_info.get("color", "#89b4fa")
        }

    if not rrule_str:
        if window_start <= start_dt <= window_end or (start_dt <= window_start and end_dt >= window_start):
            events.append(make_event(start_dt, end_dt, "0"))
        return events

    # Recurrence handling
    rrule_parts = dict(part.split('=', 1) for part in rrule_str.split(';') if '=' in part)
    freq = rrule_parts.get("FREQ", "").upper()
    interval = int(rrule_parts.get("INTERVAL", 1))
    count = int(rrule_parts.get("COUNT", 9999))
    until_dt = None
    if "UNTIL" in rrule_parts:
        u_dt, _ = parse_ics_datetime(rrule_parts["UNTIL"])
        if u_dt:
            until_dt = u_dt

    byday = []
    if "BYDAY" in rrule_parts:
        for day_code in rrule_parts["BYDAY"].split(','):
            code = day_code.strip()[-2:].upper()
            if code in WEEKDAY_MAP:
                byday.append(WEEKDAY_MAP[code])

    cur_start = start_dt
    gen_count = 0
    max_iterations = 600

    while gen_count < count and max_iterations > 0:
        max_iterations -= 1
        if until_dt and cur_start > until_dt:
            break
        if cur_start > window_end:
            break

        cur_end = cur_start + duration

        if freq == "WEEKLY" and byday:
            for day_offset in range(7):
                candidate_s = cur_start + timedelta(days=day_offset)
                if candidate_s.weekday() in byday:
                    if until_dt and candidate_s > until_dt:
                        break
                    if candidate_s >= window_start and candidate_s <= window_end:
                        candidate_e = candidate_s + duration
                        events.append(make_event(candidate_s, candidate_e, str(gen_count)))
                    gen_count += 1
                    if gen_count >= count:
                        break
            cur_start += timedelta(weeks=interval)
        else:
            if cur_start >= window_start and cur_start <= window_end:
                events.append(make_event(cur_start, cur_end, str(gen_count)))
            gen_count += 1

            if freq == "DAILY":
                cur_start += timedelta(days=interval)
            elif freq == "WEEKLY":
                cur_start += timedelta(weeks=interval)
            elif freq == "MONTHLY":
                month = cur_start.month + interval
                year = cur_start.year + (month - 1) // 12
                month = ((month - 1) % 12) + 1
                try:
                    cur_start = cur_start.replace(year=year, month=month)
                except ValueError:
                    cur_start = cur_start.replace(year=year, month=month, day=28)
            elif freq == "YEARLY":
                cur_start = cur_start.replace(year=cur_start.year + interval)
            else:
                break

    return events

def parse_ics_content(ics_text, cal_info):
    unfolded = unfold_lines(ics_text)
    raw_lines = unfolded.splitlines()

    events = []
    in_vevent = False
    vevent_lines = []

    for line in raw_lines:
        line_s = line.strip()
        if line_s == "BEGIN:VEVENT":
            in_vevent = True
            vevent_lines = []
        elif line_s == "END:VEVENT":
            if in_vevent:
                evs = parse_vevent(vevent_lines, cal_info)
                events.extend(evs)
                in_vevent = False
        elif in_vevent:
            vevent_lines.append(line)

    return events

def fetch_feed(url, cal_id=None, force=False):
    clean_url = url.strip()
    if clean_url.startswith("webcal://"):
        clean_url = "https://" + clean_url[9:]
    elif clean_url.startswith("webcals://"):
        clean_url = "https://" + clean_url[10:]

    if clean_url.startswith("file://"):
        path = clean_url[7:]
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()

    if os.path.isfile(clean_url):
        with open(clean_url, "r", encoding="utf-8", errors="replace") as f:
            return f.read()

    st = load_state()
    cal_st = st.get("calendars", {}).get(cal_id, {}) if cal_id else {}
    cooldown_until = cal_st.get("cooldown_until", 0)

    if not force and cooldown_until > time.time():
        remaining = int(cooldown_until - time.time())
        mins = max(1, remaining // 60)
        raise RateLimitError(f"Protezione anti-bot / rate-limit attiva su questa rete. In pausa per {mins} min.")

    # Try curl first (handles IPv4, persistent cookies, redirects and SSL robustly)
    curl_args = [
        "curl", "-sSL", "-4", "--compressed",
        "--connect-timeout", "8",
        "-m", "20",
        "-c", COOKIE_FILE,
        "-b", COOKIE_FILE,
        "-H", "Accept: text/calendar, application/calendar+xml, text/plain;q=0.9, */*;q=0.8",
        "-H", "Accept-Language: it-IT,it;q=0.9,en-US;q=0.8,en;q=0.7",
        "-A", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        clean_url
    ]

    try:
        import subprocess
        proc = subprocess.run(
            curl_args,
            capture_output=True,
            text=True,
            timeout=25
        )
        res_text = proc.stdout
        if proc.returncode == 0 and ("BEGIN:VCALENDAR" in res_text or "BEGIN:VEVENT" in res_text):
            if cal_id:
                if "calendars" not in st:
                    st["calendars"] = {}
                st["calendars"][cal_id] = {
                    "last_success": datetime.now().isoformat(),
                    "last_attempt": datetime.now().isoformat(),
                    "cooldown_until": 0,
                    "last_error": None
                }
                save_state(st)
                write_cached_ics(cal_id, res_text)
            return res_text
        elif "We're sorry" in res_text or "automated queries" in res_text:
            if cal_id:
                if "calendars" not in st:
                    st["calendars"] = {}
                st["calendars"][cal_id] = {
                    "last_attempt": datetime.now().isoformat(),
                    "cooldown_until": time.time() + 1800,
                    "last_error": "Google Calendar Rate Limit / Bot Protection"
                }
                save_state(st)
            raise RateLimitError("Google Calendar ha temporaneamente bloccato le richieste da questa rete (Rate Limit / Captcha).")
        elif "<html" in res_text.lower() and not ("BEGIN:VCALENDAR" in res_text):
            raise CaptivePortalError("Rete universitaria o captive portal: ricevuta pagina HTML invece del feed calendario.")
    except (RateLimitError, CaptivePortalError):
        raise
    except Exception:
        pass

    # Fallback to urllib.request
    req = urllib.request.Request(
        clean_url,
        headers={
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
            "Accept": "text/calendar, application/calendar+xml, text/plain;q=0.9, */*;q=0.8"
        }
    )

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as response:
            content = response.read()
            try:
                decoded = content.decode("utf-8")
            except UnicodeDecodeError:
                decoded = content.decode("latin-1", errors="replace")
            if "BEGIN:VCALENDAR" in decoded or "BEGIN:VEVENT" in decoded:
                if cal_id:
                    if "calendars" not in st:
                        st["calendars"] = {}
                    st["calendars"][cal_id] = {
                        "last_success": datetime.now().isoformat(),
                        "last_attempt": datetime.now().isoformat(),
                        "cooldown_until": 0,
                        "last_error": None
                    }
                    save_state(st)
                    write_cached_ics(cal_id, decoded)
                return decoded
            if "We're sorry" in decoded or "automated queries" in decoded:
                if cal_id:
                    if "calendars" not in st:
                        st["calendars"] = {}
                    st["calendars"][cal_id] = {
                        "last_attempt": datetime.now().isoformat(),
                        "cooldown_until": time.time() + 1800,
                        "last_error": "Google Calendar Rate Limit 429"
                    }
                    save_state(st)
                raise RateLimitError("Google Calendar ha risposto con HTTP 429 (Troppe richieste da questo IP).")
            raise NetworkError("Contenuto ricevuto non è un file iCalendar valido.")
    except urllib.error.HTTPError as e:
        if e.code == 429:
            if cal_id:
                if "calendars" not in st:
                    st["calendars"] = {}
                st["calendars"][cal_id] = {
                    "last_attempt": datetime.now().isoformat(),
                    "cooldown_until": time.time() + 1800,
                    "last_error": "HTTP 429"
                }
                save_state(st)
            raise RateLimitError("Google Calendar ha risposto con HTTP 429 (Troppe richieste da questo IP).")
        raise NetworkError(f"Errore HTTP {e.code}: {e.reason}")
    except Exception as e:
        raise NetworkError(f"Impossibile contattare il server: {e}")

def sync_all(force=False):
    cfg = load_config()
    calendars = cfg.get("calendars", [])

    all_events = []
    synced_calendars = []
    warnings = []
    errors = []

    for cal in calendars:
        if not cal.get("enabled", True):
            continue
        cal_id = cal.get("id", hashlib.md5(cal.get("url", "").encode('utf-8')).hexdigest()[:8])
        cal_name = cal.get("name", "Calendar")
        cal_color = cal.get("color", "#89b4fa")
        cal_url = cal.get("url", "")

        cal_info = {
            "id": cal_id,
            "name": cal_name,
            "color": cal_color,
            "url": cal_url,
            "cached": False
        }

        if not cal_url:
            continue

        ics_data = None
        try:
            ics_data = fetch_feed(cal_url, cal_id=cal_id, force=force)
        except Exception as e:
            # Network failed or rate limited: fall back to local cached .ics
            cached_ics = read_cached_ics(cal_id)
            if cached_ics:
                ics_data = cached_ics
                cal_info["cached"] = True
                cal_info["cache_reason"] = str(e)
                warnings.append({
                    "calendar": cal_name,
                    "message": "Visualizzati eventi salvati (rete protetta o rate limit)",
                    "detail": str(e)
                })
            else:
                errors.append({"calendar": cal_name, "error": str(e)})
                sys.stderr.write(f"Error syncing {cal_name}: {e}\n")

        if ics_data:
            try:
                evs = parse_ics_content(ics_data, cal_info)
                all_events.extend(evs)
                synced_calendars.append(cal_info)
            except Exception as e:
                errors.append({"calendar": cal_name, "error": f"Errore parsing iCal: {e}"})

    # Sort events chronologically
    all_events.sort(key=lambda ev: (ev["start"], ev["title"]))

    # Remove duplicates if any (same calendar_id, start and title)
    unique_events = []
    seen = set()
    for ev in all_events:
        key = (ev["calendar_id"], ev["start"], ev["title"])
        if key not in seen:
            seen.add(key)
            unique_events.append(ev)

    has_cached = any(c.get("cached", False) for c in synced_calendars)
    if errors and len(synced_calendars) == 0:
        overall_status = "error"
    elif errors:
        overall_status = "partial"
    elif has_cached:
        overall_status = "cached"
    else:
        overall_status = "ok"

    output = {
        "last_sync": datetime.now().isoformat(),
        "status": overall_status,
        "calendars_count": len(synced_calendars),
        "events_count": len(unique_events),
        "calendars": synced_calendars,
        "warnings": warnings,
        "errors": errors,
        "events": unique_events
    }

    ensure_dirs()
    with open(CACHE_FILE, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)

    return output

def add_calendar(name, url, color="#89b4fa"):
    cfg = load_config()
    cal_id = hashlib.md5((name + url).encode('utf-8')).hexdigest()[:8]
    # Remove existing with same URL if any
    cfg["calendars"] = [c for c in cfg.get("calendars", []) if c.get("url") != url]
    cfg["calendars"].append({
        "id": cal_id,
        "name": name,
        "url": url,
        "color": color,
        "enabled": True
    })
    save_config(cfg)
    return sync_all(force=True)

def remove_calendar(id_or_url):
    cfg = load_config()
    cfg["calendars"] = [c for c in cfg.get("calendars", []) if c.get("id") != id_or_url and c.get("url") != id_or_url]
    save_config(cfg)
    return sync_all(force=False)

def toggle_calendar(id_or_url):
    cfg = load_config()
    for c in cfg.get("calendars", []):
        if c.get("id") == id_or_url or c.get("url") == id_or_url:
            c["enabled"] = not c.get("enabled", True)
    save_config(cfg)
    return sync_all(force=False)

def get_cached():
    if os.path.isfile(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"status": "empty", "events": [], "calendars": [], "last_sync": ""}

def main():
    force = False
    args = sys.argv[1:]
    if "--force-sync" in args or "-f" in args or "--force" in args:
        force = True
        args = [a for a in args if a not in ("--force-sync", "-f", "--force")]

    if len(args) == 0 or args[0] in ("--sync", "-s"):
        res = sync_all(force=force)
        print(json.dumps(res, ensure_ascii=False))
    elif args[0] in ("--get", "-g"):
        res = get_cached()
        print(json.dumps(res, ensure_ascii=False))
    elif args[0] in ("--list", "-l"):
        cfg = load_config()
        print(json.dumps(cfg, indent=2, ensure_ascii=False))
    elif args[0] == "--add":
        if len(args) >= 3:
            name = args[1]
            url = args[2]
            color = args[3] if len(args) >= 4 else "#89b4fa"
            res = add_calendar(name, url, color)
            print(json.dumps(res, ensure_ascii=False))
        else:
            sys.stderr.write("Usage: calendar_sync.py --add <name> <url> [color]\n")
            sys.exit(1)
    elif args[0] == "--remove":
        if len(args) >= 2:
            res = remove_calendar(args[1])
            print(json.dumps(res, ensure_ascii=False))
        else:
            sys.stderr.write("Usage: calendar_sync.py --remove <id_or_url>\n")
            sys.exit(1)
    elif args[0] == "--toggle":
        if len(args) >= 2:
            res = toggle_calendar(args[1])
            print(json.dumps(res, ensure_ascii=False))
        else:
            sys.stderr.write("Usage: calendar_sync.py --toggle <id_or_url>\n")
            sys.exit(1)
    elif args[0] == "--test":
        if len(args) >= 2:
            url = args[1]
            data = fetch_feed(url, force=True)
            cal_info = {"id": "test", "name": "Test", "color": "#89b4fa", "url": url}
            evs = parse_ics_content(data, cal_info)
            print(json.dumps({"events_count": len(evs), "sample": evs[:5]}, indent=2, ensure_ascii=False))
    else:
        print(json.dumps({"status": "unknown_arg", "events": []}))

if __name__ == "__main__":
    main()
