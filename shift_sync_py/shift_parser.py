# shift_sync.py
import re
from datetime import datetime
from pathlib import Path
from uuid import uuid4

import requests
from bs4 import BeautifulSoup


BASE_URL = "https://example-shift.com"

LOGIN_PAGE_URL = f"{BASE_URL}/login.php"
LOGIN_API_URL  = f"{BASE_URL}/cont/login/check_login.php"

# ★ここを cont/shift/look.php じゃなくて shift.php に
SHIFT_URL = f"{BASE_URL}/shift.php"

import os

ShiftWeb_ID = os.environ.get("ShiftWeb_ID", "")
ShiftWeb_PASSWORD = os.environ.get("ShiftWeb_PASSWORD", "")


# ---------- ログインしてシフトページ取得 ----------

def fetch_shift_page():
    s = requests.Session()

    # 1. ログインページを踏んでセッション開始
    r0 = s.get(LOGIN_PAGE_URL, params={"err": "1"})
    r0.raise_for_status()

    # 2. ログインAPI
    payload = {
        "id": ShiftWeb_ID,
        "password": ShiftWeb_PASSWORD,
        "savelogin": "1",
    }
    headers_login = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        "Origin": BASE_URL,
        "Referer": f"{BASE_URL}/login.php?err=1",
    }

    r1 = s.post(f"{LOGIN_API_URL}?{ShiftWeb_ID}", data=payload, headers=headers_login)
    r1.raise_for_status()
    print("login API response:", r1.text)

    # 3. シフト管理ページをブラウザと同じように叩く
    params_shift = {"mod": "look"}
    headers_shift = {
        "Referer": f"{BASE_URL}/shift.php",  # cURLと同じ
    }

    r2 = s.get(SHIFT_URL, params=params_shift, headers=headers_shift)
    print("shift status:", r2.status_code)
    r2.raise_for_status()

    html = r2.text
    Path("shift_page.html").write_text(html, encoding="utf-8")
    print("shift_page.html に保存したよ！（シフトページ）")
    return html


# ---------- HTML → shifts リスト ----------

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

    # 年・月は h3 の「2025年11月の確定シフト」から拾う
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

        # 時間セルのテキスト例：
        # "×"
        # "●14:30-19:45"
        time_text = time_td.get_text(strip=True)
        if "●" not in time_text or "-" not in time_text:
            # × の日などはスキップ
            continue

        # "●14:30-19:45" -> "14:30-19:45"
        time_part = time_text.split("●", 1)[1]
        start_str, end_str = [t.strip() for t in time_part.split("-", 1)]

        # 日付セルのテキスト例："11/4(火)\n未通知"
        date_text_full = date_td.get_text(separator="\n", strip=True).split("\n")[0]
        # "11/4(火)" -> "11/4"
        date_main = date_text_full.split("(", 1)[0]
        month_str, day_str = [x.strip() for x in date_main.split("/", 1)]

        m = int(month_str)
        d = int(day_str)

        # 念のため、ヘッダの月と違ってたらヘッダ優先でもいいけど、
        # 今回はそのまま m を使う
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
    """
    "2025年11月の確定シフト" みたいな文字列から (2025, 11) を取り出す
    """
    m = re.search(r"(\d{4})年(\d{1,2})月", title_text)
    if not m:
        now = datetime.now()
        return now.year, now.month
    return int(m.group(1)), int(m.group(2))


def _combine_date_time(year: int, month: int, day: int, hhmm: str) -> datetime:
    """
    year, month, day と "HH:MM" から datetime を作る
    """
    hour, minute = [int(x) for x in hhmm.split(":")]
    return datetime(year, month, day, hour, minute)


# ---------- shifts リスト → .ics ----------

def format_dt(dt: datetime) -> str:
    return dt.strftime("%Y%m%dT%H%M%S")


def generate_ics(shifts, filepath):
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


# ---------- メイン ----------

if __name__ == "__main__":
    html = fetch_shift_page()
    shifts = parse_shifts(html)
    print(f"パースできたシフト件数: {len(shifts)}")
    out_path = Path(__file__).resolve().parent / "shifts.ics"
    generate_ics(shifts, out_path)