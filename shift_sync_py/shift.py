from datetime import datetime
from uuid import uuid4
from pathlib import Path

def format_dt(dt: datetime) -> str:
    return dt.strftime("%Y%m%dT%H%M%S")

def generate_ics(shifts, filepath: str):
    lines = []
    lines.append("BEGIN:VCALENDAR")
    lines.append("VERSION:2.0")
    lines.append("PRODID:-//Inazumi Shift Sync//JP")

    for shift in shifts:
        uid = str(uuid4())
        start = format_dt(shift["start"])
        end   = format_dt(shift["end"])

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

    # ここで絶対パスにしておくと安全
    filepath = Path(filepath)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"書き出したよ: {filepath}")

# ↓ ここをこう変える
if __name__ == "__main__":
    from shift.sfihtdata import shifts 
    # スクリプトと同じフォルダに出す版
    base_dir = Path(__file__).resolve().parent
    out_path = base_dir / "shifts.ics"

    generate_ics(shifts, out_path)