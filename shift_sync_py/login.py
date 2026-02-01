# login.py
import requests
from pathlib import Path

BASE_URL = "https://example-shift.com"

LOGIN_PAGE_URL = f"{BASE_URL}/login.php"
LOGIN_API_URL = f"{BASE_URL}/cont/login/check_login.php"
#HOME_URL = f"{BASE_URL}/main.php"  # とりあえずログイン後トップを見に行く
HOME_URL = f"{BASE_URL}/shift.php?mod=look"  # シフトページを直接見に行く版

import os

# 環境変数から認証情報を取得（.env ファイルか export で設定）
ShiftWeb_ID = os.environ.get("ShiftWeb_ID", "")
ShiftWeb_PASSWORD = os.environ.get("ShiftWeb_PASSWORD", "")

def fetch_shift_page():
    s = requests.Session()

    # 1. ログインページを一度踏んでセッションID(PHPSESSID)をもらう
    r0 = s.get(LOGIN_PAGE_URL, params={"err": "1"})
    r0.raise_for_status()

    # 2. ブラウザが投げていたのと同じ形でログインAPIにPOST
    payload = {
        "id": ShiftWeb_ID,
        "password": ShiftWeb_PASSWORD,
        "savelogin": "1",
    }

    headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
        "Origin": BASE_URL,
        "Referer": f"{BASE_URL}/login.php?err=1",
    }

    # URLの ?1622 部分はたぶん意味薄いけど、真似したければ f"{LOGIN_API_URL}?{ShiftWeb_ID}"
    r1 = s.post(f"{LOGIN_API_URL}?{ShiftWeb_ID}", data=payload, headers=headers)
    r1.raise_for_status()

    print("login API response:", r1.text)  # "ok" とかエラー文字列が返ってくるはず

    # 3. ログイン済みセッションでメインページ（or シフトページ）を取得
    r2 = s.get(HOME_URL)
    r2.raise_for_status()

    html = r2.text
    Path("shift_page.html").write_text(html, encoding="utf-8")
    print("shift_page.html に保存したよ！（ログイン後想定）")

    return html


if __name__ == "__main__":
    fetch_shift_page()