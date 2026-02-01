#!/usr/bin/env python3
"""
iCloud CalDAV のカレンダー一覧を表示するスクリプト（簡易版）

使い方:
    pip install requests
    python discover_icloud_calendars.py

実行すると:
    Apple ID メールアドレス
    アプリ用パスワード
を聞かれて、そのアカウントの CalDAV カレンダー一覧
  [番号] displayname  URL
を表示する。
"""

import getpass
import sys
from urllib.parse import urljoin

import requests
import xml.etree.ElementTree as ET


DAV_NS = "DAV:"
CALDAV_NS = "urn:ietf:params:xml:ns:caldav"
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
        raise RuntimeError("current-user-principal が取れなかった…")

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
        raise RuntimeError("calendar-home-set が取れなかった…")

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

    calendars = []
    for resp_el in root.findall("d:response", NS):
        href_el = resp_el.find("d:href", NS)
        if href_el is None or not href_el.text:
            continue
        href = urljoin(resp.url, href_el.text)

        # resourcetype に <c:calendar/> を含んでいるエントリだけに絞る
        rt = resp_el.find("d:propstat/d:prop/d:resourcetype", NS)
        if rt is None or rt.find("c:calendar", NS) is None:
            continue

        display_el = resp_el.find("d:propstat/d:prop/d:displayname", NS)
        displayname = display_el.text if display_el is not None else "(no name)"

        calendars.append((displayname, href))

    return calendars


def main():
    print("=== iCloud CalDAV カレンダー一覧取得 ===")
    apple_id = input("Apple ID（メールアドレス）: ").strip()
    if not apple_id:
        print("Apple ID が空だよ")
        sys.exit(1)

    app_pass = getpass.getpass("アプリ用パスワード: ").strip()
    if not app_pass:
        print("アプリ用パスワードが空だよ")
        sys.exit(1)

    # iCloud の CalDAV 入口
    base_url = "https://caldav.icloud.com/"

    session = requests.Session()
    session.auth = (apple_id, app_pass)

    try:
        print("\ncurrent-user-principal を取得中…")
        principal_url = get_current_user_principal(session, base_url)
        print("  principal:", principal_url)

        print("calendar-home-set を取得中…")
        home_url = get_calendar_home_set(session, principal_url)
        print("  calendar-home:", home_url)

        print("\nカレンダー一覧を取得中…")
        calendars = list_calendars(session, home_url)
    except Exception as e:
        print("エラーが起きた:", e)
        sys.exit(1)

    if not calendars:
        print("カレンダーが見つからんかった…")
        sys.exit(0)

    print("\n=== 見つかったカレンダー ===")
    for i, (name, href) in enumerate(calendars, 1):
        print(f"[{i}] {name}  ->  {href}")

    print("\nこの中から displayname が『バイト』の行を探して、")
    print("その URL を shift_sync.py の CALDAV_CALENDAR_URL にコピペすればOK！")


if __name__ == "__main__":
    main()