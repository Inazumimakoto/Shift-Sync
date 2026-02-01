#!/usr/bin/env python3
import re
import getpass
import sys
import hashlib
from datetime import datetime
from pathlib import Path

import requests
import toml
import keyring
from bs4 import BeautifulSoup
import xml.etree.ElementTree as ET


# ================== ShiftWeb (シフトサイト) 関連 ==================

BASE_URL = "https://example-shift.com"

LOGIN_PAGE_URL = f"{BASE_URL}/login.php"
LOGIN_API_URL  = f"{BASE_URL}/cont/login/check_login.php"
SHIFT_URL      = f"{BASE_URL}/shift.php"


# ================== 設定ファイル & キーチェーン ==================

CONFIG_DIR  = Path.home() / ".shift_sync"
CONFIG_FILE = CONFIG_DIR / "config.toml"

ShiftWeb_SERVICE    = "shift-sync-web"
ICLOUD_SERVICE = "shift-sync-icloud"


# ================== CalDAV (iCloud) 関連 ==================

CALDAV_BASE_URL = "https://caldav.icloud.com/"

DAV_NS     = "DAV:"
CALDAV_NS  = "urn:ietf:params:xml:ns:caldav"
NS = {"d": DAV_NS, "c": CALDAV_NS}


def propfind(session: requests.Session, url: str, body: str, depth: str = "0") -> requests.Response:
    headers = {
        "Depth": depth,
        "Content-Type": "application/xml; charset=utf-8",
    }
    resp = session.request("PROPFIND", url, data=body.encode("utf-8"), headers=headers)
    resp.raise_for_status()
    return resp


def get_current_user_principal(session: requests.Session, base_url: str) -> str:
    body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:current-user-principal/>
  </d:prop>
</d:propfind>
"""
    resp = propfind(session, base_url, body, depth="0")
    root = ET.fromstring(resp.content)

    href_el = root.find(".//d:current-user-principal/d:href", NS)
    if href_el is None or not href_el.text:
        raise RuntimeError("current-user-principal が取れんかった…")

    from urllib.parse import urljoin
    principal_href = href_el.text
    principal_url = urljoin(resp.url, principal_href)
    return principal_url


def get_calendar_home_set(session: requests.Session, principal_url: str) -> str:
    body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <c:calendar-home-set/>
  </d:prop>
</d:propfind>
"""
    resp = propfind(session, principal_url, body, depth="0")
    root = ET.fromstring(resp.content)

    href_el = root.find(".//c:calendar-home-set/d:href", NS)
    if href_el is None or not href_el.text:
        raise RuntimeError("calendar-home-set が取れんかった…")

    from urllib.parse import urljoin
    home_href = href_el.text
    home_url = urljoin(resp.url, home_href)
    return home_url


def list_calendars(session: requests.Session, home_url: str):
    """
    calendar-home-set 配下のカレンダーを列挙して (displayname, href) のリストで返す
    """
    body = """<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:displayname/>
    <c:calendar-description/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>
"""
    resp = propfind(session, home_url, body, depth="1")
    root = ET.fromstring(resp.content)

    from urllib.parse import urljoin
    calendars = []
    for resp_el in root.findall("d:response", NS):
        href_el = resp_el.find("d:href", NS)
        if href_el is None or not href_el.text:
            continue
        href = urljoin(resp.url, href_el.text)

        # resourcetype に <c:calendar/> を含んでいるエントリだけ
        rt = resp_el.find("d:propstat/d:prop/d:resourcetype", NS)
        if rt is None or rt.find("c:calendar", NS) is None:
            continue

        display_el = resp_el.find("d:propstat/d:prop/d:displayname", NS)
        displayname = display_el.text if display_el is not None else "(no name)"

        calendars.append((displayname, href))

    return calendars


# ================== 設定ロード & 初回セットアップ ==================

def load_or_setup_config():
    if CONFIG_FILE.exists():
        cfg = toml.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        return cfg

    # 初回セットアップ
    print("=== shift-sync 初期設定 ===")

    # ShiftWeb
    web_id = input("ShiftWeb のログインID: ").strip()
    if not web_id:
        print("ShiftWeb ID が空やで")
        sys.exit(1)
    web_pass = getpass.getpass("ShiftWeb のパスワード: ").strip()
    if not web_pass:
        print("ShiftWeb パスワードが空やで")
        sys.exit(1)

    # iCloud
    apple_id = input("Apple ID（iCloud, メールアドレス）: ").strip()
    if not apple_id:
        print("Apple ID が空やで")
        sys.exit(1)
    app_pass = getpass.getpass("iCloud アプリ用パスワード: ").strip()
    if not app_pass:
        print("アプリ用パスワードが空やで")
        sys.exit(1)

    # キーチェーンへ保存
    keyring.set_password(ShiftWeb_SERVICE, web_id, web_pass)
    keyring.set_password(ICLOUD_SERVICE, apple_id, app_pass)

    # iCloud カレンダー一覧取得
    session = requests.Session()
    session.auth = (apple_id, app_pass)

    print("\niCloud カレンダーを検索中…")
    principal_url = get_current_user_principal(session, CALDAV_BASE_URL)
    home_url = get_calendar_home_set(session, principal_url)
    calendars = list_calendars(session, home_url)

    if not calendars:
        print("カレンダーが一個も見つからん… iCloud設定を確認して。")
        sys.exit(1)

    print("\n=== 見つかったカレンダー ===")
    for i, (name, href) in enumerate(calendars, 1):
        print(f"[{i}] {name}  ->  {href}")

    while True:
        choice = input("\nどのカレンダーにシフトを登録する？ [1-{}]: ".format(len(calendars))).strip()
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(calendars):
                break
        except ValueError:
            pass
        print("番号を入れて〜。")

    calendar_name, calendar_url = calendars[idx]
    print(f"\n=> 『{calendar_name}』 を使用します")

    cfg = {
        "shiftweb": {
            "id": web_id,
        },
        "icloud": {
            "apple_id": apple_id,
            "calendar_url": calendar_url,
        },
    }

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(toml.dumps(cfg), encoding="utf-8")
    print(f"\n設定を保存したよ: {CONFIG_FILE}")

    return cfg


# ================== ShiftWeb シフト取得 ==================
from datetime import datetime  # もう import 済みならOK

def fetch_shift_page_for_month(web_id: str, web_password: str, year: int, month: int) -> str:
    """
    shift.php?mod=look&date2=YYYY-MM 形式で、
    指定した年月のシフトページHTMLを取得する。
    """
    s = requests.Session()

    # 1. ログインページ
    r0 = s.get(LOGIN_PAGE_URL, params={"err": "1"})
    r0.raise_for_status()

    # 2. ログインAPI
    payload = {
        "id": web_id,
        "password": web_password,
        "savelogin": "1",
    }
    headers_login = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        "Origin": BASE_URL,
        "Referer": f"{BASE_URL}/login.php?err=1",
    }
    r1 = s.post(f"{LOGIN_API_URL}?{web_id}", data=payload, headers=headers_login)
    r1.raise_for_status()
    print("login API response:", r1.text)

    # 3. 指定年月のシフトページ
    date2 = f"{year}-{month:02d}"   # 例: 2025-11
    params_shift = {
        "mod": "look",
        "date2": date2,
    }
    headers_shift = {
        "Referer": f"{BASE_URL}/shift.php",
    }

    r2 = s.get(SHIFT_URL, params=params_shift, headers=headers_shift)
    print(f"shift status ({date2}):", r2.status_code)
    r2.raise_for_status()

    html = r2.text
    Path(f"shift_page_{date2}.html").write_text(html, encoding="utf-8")
    print(f"shift_page_{date2}.html に保存したよ！（{date2} のシフトページ）")
    return html



# ================== HTML → shifts リスト ==================

def parse_shifts(html: str):
    """
    shift_page.html から
    [
      {"title": "バイト", "start": datetime(...), "end": datetime(...), "location": "...", "memo": "..."},
      ...
    ]
    を作る
    """
    soup = BeautifulSoup(html, "html.parser")

    h3 = soup.find("h3", class_="btn-block")
    year, month = _parse_year_month(h3.get_text(strip=True)) if h3 else (datetime.now().year,
                                                                         datetime.now().month)

    table = soup.find("table", id="shiftTable")
    if not table:
        raise RuntimeError("shiftTable が見つからんかった…HTML変わったかも")

    shifts = []

    for row in table.find_all("tr")[1:]:  # 先頭行はヘッダ
        date_td = row.find("td", class_="shiftDate")
        shop_td = row.find("td", class_="shiftMisName")
        time_td = row.find("td", class_="shiftTime")

        if not (date_td and shop_td and time_td):
            continue

        time_text = time_td.get_text(strip=True)
        if "●" not in time_text or "-" not in time_text:
            continue  # ×の日など

        time_part = time_text.split("●", 1)[1]
        start_str, end_str = [t.strip() for t in time_part.split("-", 1)]

        date_text_full = date_td.get_text(separator="\n", strip=True).split("\n")[0]
        date_main = date_text_full.split("(", 1)[0]
        month_str, day_str = [x.strip() for x in date_main.split("/", 1)]

        m = int(month_str)
        d = int(day_str)

        start_dt = _combine_date_time(year, m, d, start_str)
        end_dt = _combine_date_time(year, m, d, end_str)

        shifts.append(
            {
                "title": "バイト",
                "start": start_dt,
                "end": end_dt,
                "location": shop_td.get_text(strip=True),
                "memo": "",
            }
        )

    return shifts


def _parse_year_month(title_text: str):
    m = re.search(r"(\d{4})年(\d{1,2})月", title_text)
    if not m:
        now = datetime.now()
        return now.year, now.month
    return int(m.group(1)), int(m.group(2))


def _combine_date_time(year: int, month: int, day: int, hhmm: str) -> datetime:
    hour, minute = [int(x) for x in hhmm.split(":")]
    return datetime(year, month, day, hour, minute)


# ================== ics 出力（デバッグ用） ==================

def format_dt(dt: datetime) -> str:
    return dt.strftime("%Y%m%dT%H%M%S")


def generate_ics(shifts, filepath):
    from uuid import uuid4

    lines = []
    lines.append("BEGIN:VCALENDAR")
    lines.append("VERSION:2.0")
    lines.append("PRODID:-//Inazumi Shift Sync//JP")

    for shift in shifts:
        uid = str(uuid4())
        start = format_dt(shift["start"])
        end = format_dt(shift["end"])
        title = shift.get("title", "シフト")
        location = shift.get("location", "")
        memo = shift.get("memo", "")

        lines.append("BEGIN:VEVENT")
        lines.append(f"UID:{uid}")
        lines.append(f"DTSTART:{start}")
        lines.append(f"DTEND:{end}")
        lines.append(f"SUMMARY:{title}")
        if location:
            lines.append(f"LOCATION:{location}")
        if memo:
            lines.append(f"DESCRIPTION:{memo}")
        lines.append("END:VEVENT")

    lines.append("END:VCALENDAR")

    content = "\r\n".join(lines) + "\r\n"
    filepath = Path(filepath)
    filepath.write_text(content, encoding="utf-8")
    print(f"ICSを書き出したよ: {filepath}")


# ================== CalDAV への登録 ==================

def make_shift_uid(shift) -> str:
    """
    シフトの内容から決まるUIDを生成する。
    同じ日付・時間・場所なら毎回同じUIDになる。
    """
    start = shift["start"]
    end = shift["end"]
    location = shift.get("location", "")

    key = f"{start.strftime('%Y%m%dT%H%M')}-{end.strftime('%Y%m%dT%H%M')}-{location}"
    digest = hashlib.sha1(key.encode("utf-8")).hexdigest()[:8]
    uid = f"shift-{start.strftime('%Y%m%d')}-{start.strftime('%H%M')}-{end.strftime('%H%M')}-{digest}"
    return uid


def build_single_event_ical(shift, uid: str) -> str:
    start = format_dt(shift["start"])
    end = format_dt(shift["end"])
    title = shift.get("title", "シフト")
    location = shift.get("location", "")
    memo = shift.get("memo", "")

    lines = []
    lines.append("BEGIN:VCALENDAR")
    lines.append("VERSION:2.0")
    lines.append("PRODID:-//Inazumi Shift Sync//JP")
    lines.append("BEGIN:VEVENT")
    lines.append(f"UID:{uid}")
    lines.append(f"DTSTART:{start}")
    lines.append(f"DTEND:{end}")
    lines.append(f"SUMMARY:{title}")
    if location:
        lines.append(f"LOCATION:{location}")
    if memo:
        lines.append(f"DESCRIPTION:{memo}")
    lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")

    return "\r\n".join(lines) + "\r\n"


def sync_shifts_to_caldav(shifts, apple_id: str, app_password: str, calendar_url: str):
    """
    shifts を iCloud カレンダーに登録する。
    同じシフトは毎回同じUID/URLになるので、重複せず上書きになる。
    """
    if not calendar_url.startswith("https://"):
        raise RuntimeError("calendar_url が変やで:", calendar_url)

    session = requests.Session()
    session.auth = (apple_id, app_password)

    headers = {
        "Content-Type": "text/calendar; charset=utf-8",
    }

    base = calendar_url.rstrip("/")

    for shift in shifts:
        uid = make_shift_uid(shift)
        ical_body = build_single_event_ical(shift, uid)
        event_url = f"{base}/{uid}.ics"

        print(f"[CalDAV] PUT {event_url}")
        resp = session.put(event_url, data=ical_body.encode("utf-8"), headers=headers)
        if resp.status_code not in (200, 201, 204):
            print(f"  => エラー status={resp.status_code}, body={resp.text[:200]}")
        else:
            print(f"  => OK ({resp.status_code})")


# ================== メイン ==================

def main():
    cfg = load_or_setup_config()

    web_id = cfg["shiftweb"]["id"]
    web_pass = keyring.get_password(ShiftWeb_SERVICE, web_id)
    ...
    apple_id = cfg["icloud"]["apple_id"]
    app_pass = keyring.get_password(ICLOUD_SERVICE, apple_id)
    calendar_url = cfg["icloud"]["calendar_url"]

    # ★ 今月と来月の年月を計算
    now = datetime.now()
    this_year = now.year
    this_month = now.month
    if this_month == 12:
        next_year, next_month = this_year + 1, 1
    else:
        next_year, next_month = this_year, this_month + 1

    # ★ 今月ぶん
    html_this = fetch_shift_page_for_month(web_id, web_pass, this_year, this_month)
    shifts_this = parse_shifts(html_this)
    print(f"今月のシフト件数: {len(shifts_this)}")

    # ★ 来月ぶん
    html_next = fetch_shift_page_for_month(web_id, web_pass, next_year, next_month)
    shifts_next = parse_shifts(html_next)
    print(f"来月のシフト件数: {len(shifts_next)}")

    # ★ 合体
    shifts = shifts_this + shifts_next
    print(f"合計シフト件数: {len(shifts)}")

    out_path = Path(__file__).resolve().parent / "shifts.ics"
    generate_ics(shifts, out_path)

    print("CalDAV（iCloud）にシフトを登録するよ…")
    sync_shifts_to_caldav(shifts, apple_id, app_pass, calendar_url)
    print("CalDAVへの登録処理おわり。")


if __name__ == "__main__":
    main()