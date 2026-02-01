package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha1"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
	"github.com/PuerkitoBio/goquery"
	"github.com/zalando/go-keyring"
	"golang.org/x/term"
)

const (
	baseURL        = "https://example-shift.com"
	loginPageURL   = baseURL + "/login.php"
	loginAPIURL    = baseURL + "/cont/login/check_login.php"
	shiftURL       = baseURL + "/shift.php"
	caldavBaseURL  = "https://caldav.icloud.com/"
	configDirName  = ".shift_sync"
	configFileName = "config.toml"
	webService     = "shift-sync-web"
	icloudService  = "shift-sync-icloud"
	Version        = "v0.4.0"
)

type config struct {
	ShiftWeb struct {
		ID string `toml:"id"`
	} `toml:"shiftweb"`
	ICloud struct {
		AppleID     string `toml:"apple_id"`
		CalendarURL string `toml:"calendar_url"`
	} `toml:"icloud"`
}

type shift struct {
	Title    string
	Start    time.Time
	End      time.Time
	Location string
	Memo     string
}

type calendarInfo struct {
	Name string
	URL  string
}

type mkcalendarRequest struct {
	XMLName xml.Name      `xml:"C:mkcalendar"`
	XmlnsD  string        `xml:"xmlns:D,attr"`
	XmlnsC  string        `xml:"xmlns:C,attr"`
	Set     mkcalendarSet `xml:"D:set"`
}

type mkcalendarSet struct {
	Prop mkcalendarProp `xml:"D:prop"`
}

type mkcalendarProp struct {
	DisplayName                 string                               `xml:"D:displayname"`
	ResourceType                mkcalendarResourceType               `xml:"D:resourcetype"`
	SupportedCalendarComponents mkcalendarSupportedCalendarComponent `xml:"C:supported-calendar-component-set"`
}

type mkcalendarResourceType struct {
	Collection *struct{} `xml:"D:collection"`
	Calendar   *struct{} `xml:"C:calendar"`
}

type mkcalendarSupportedCalendarComponent struct {
	Components []mkcalendarComp `xml:"C:comp"`
}

type mkcalendarComp struct {
	Name string `xml:"name,attr"`
}

func main() {
	flag.Usage = func() {
		fmt.Print(`シフト管理サイトから今月＋来月の確定シフトを取得し、iCloud カレンダーに同期するツールです。

使い方:
  shift-sync               今月＋来月のシフトを同期する
  shift-sync -setup        初期セットアップを行う（ShiftWeb / iCloud の設定）
  shift-sync -change-calendar
                           同期先カレンダーを変更してから、そのまま同期する
  shift-sync -list         ShiftWeb 側のシフト一覧だけを表示する（カレンダーには書き込まない）
  shift-sync -show-config  現在の設定内容を表示する
  shift-sync -version      バージョン情報を表示する

Options:
  -setup
      初期セットアップを実行する
  -change-calendar
      同期先カレンダーのみ変更する（変更後に同期も実行）
  -list
      ShiftWeb 側のシフト一覧だけを表示する（CalDAV にはアクセスしない）
  -from=YYYY-MM
      -list と併用。取得開始月を指定（例: 2025-01）
  -to=YYYY-MM
      -list と併用。取得終了月を指定（例: 2025-03）
  -show-config
      現在の設定内容を表示する（パスワードは表示しない）
  -version
      バージョン情報を表示する
`)
	}

	setupFlag := flag.Bool("setup", false, "初期セットアップを実行する")
	changeCalFlag := flag.Bool("change-calendar", false, "同期先カレンダーのみ変更する")
	listFlag := flag.Bool("list", false, "ShiftWeb 側のシフト一覧だけを表示する（CalDAV には書き込まない）")
	showConfigFlag := flag.Bool("show-config", false, "現在の設定内容を表示する")
	versionFlag := flag.Bool("version", false, "バージョン情報を表示する")
	fromMonth := flag.String("from", "", "取得開始月 (YYYY-MM, -listと併用)")
	toMonth := flag.String("to", "", "取得終了月 (YYYY-MM, -listと併用)")
	flag.Parse()

	if *versionFlag {
		if *setupFlag || *changeCalFlag || *listFlag || *showConfigFlag || *fromMonth != "" || *toMonth != "" {
			fmt.Println("`-version` は他のフラグと同時に使えません。")
			flag.Usage()
			os.Exit(1)
		}
		fmt.Printf("shift-sync version %s\n", Version)
		return
	}

	modeCount := 0
	for _, f := range []bool{*setupFlag, *changeCalFlag, *listFlag, *showConfigFlag} {
		if f {
			modeCount++
		}
	}
	if modeCount > 1 {
		fmt.Println("フラグの組み合わせが正しくありません。")
		flag.Usage()
		os.Exit(1)
	}
	if (*fromMonth != "" || *toMonth != "") && !*listFlag {
		fmt.Println("`-from` と `-to` は `-list` と一緒に使ってください。")
		flag.Usage()
		os.Exit(1)
	}

	if flag.NArg() > 0 {
		fmt.Println("位置引数は不要です。")
		flag.Usage()
		os.Exit(1)
	}

	cfgPath, err := configPath()
	if err != nil {
		fmt.Println("設定ファイルパスの取得に失敗:", err)
		os.Exit(1)
	}

	var cfg *config
	ranChange := false
	switch {
	case *changeCalFlag:
		cfg, err = loadConfig(cfgPath)
		if err != nil {
			fmt.Println("設定の読み込みに失敗:", err)
			fmt.Println("`--setup` を先に実行して設定してください。")
			os.Exit(1)
		}
		if err := runChangeCalendar(cfgPath, cfg); err != nil {
			fmt.Println("カレンダー変更に失敗:", err)
			os.Exit(1)
		}
		fmt.Println("カレンダー変更が完了したので、そのまま同期を実行します…")
		ranChange = true
	case *setupFlag:
		cfg, err = runSetup(cfgPath)
		if err != nil {
			fmt.Println("セットアップに失敗:", err)
			os.Exit(1)
		}
	default:
		cfg, err = loadConfig(cfgPath)
		if errors.Is(err, os.ErrNotExist) {
			if *listFlag || *showConfigFlag {
				fmt.Println("まだセットアップされていません。shift-sync -setup を実行してください。")
				os.Exit(1)
			}
			cfg, err = runSetup(cfgPath)
		}
		if err != nil {
			fmt.Println("設定の読み込みに失敗:", err)
			fmt.Println("`--setup` で初期設定をやり直してみてください。")
			os.Exit(1)
		}
	}

	if *showConfigFlag {
		if err := runShowConfig(cfgPath, cfg); err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		return
	}

	if *listFlag {
		if err := runList(cfg, *fromMonth, *toMonth); err != nil {
			fmt.Println("シフト一覧表示に失敗:", err)
			os.Exit(1)
		}
		return
	}

	webPass, err := keyring.Get(webService, cfg.ShiftWeb.ID)
	if err != nil || webPass == "" {
		fmt.Println("ShiftWeb パスワードをキーチェーンから取得できませんでした。`--setup` を試してください。")
		os.Exit(1)
	}
	appPass, err := keyring.Get(icloudService, cfg.ICloud.AppleID)
	if err != nil || appPass == "" {
		fmt.Println("iCloud アプリ用パスワードをキーチェーンから取得できませんでした。`--setup` を試してください。")
		os.Exit(1)
	}

	now := time.Now()
	thisYear, thisMonth := now.Year(), int(now.Month())
	nextYear, nextMonth := thisYear, thisMonth+1
	if thisMonth == 12 {
		nextYear, nextMonth = thisYear+1, 1
	}

	webClient, err := loginShiftWeb(cfg.ShiftWeb.ID, webPass)
	if err != nil {
		fmt.Println("ShiftWeb ログインに失敗:", err)
		os.Exit(1)
	}

	htmlThis, err := fetchShiftPageForMonth(webClient, thisYear, thisMonth)
	if err != nil {
		fmt.Println("今月のシフト取得に失敗:", err)
		os.Exit(1)
	}
	shiftsThis, err := parseShifts(htmlThis)
	if err != nil {
		fmt.Println("今月のシフト解析に失敗:", err)
		os.Exit(1)
	}
	fmt.Printf("今月のシフト件数: %d\n", len(shiftsThis))

	htmlNext, err := fetchShiftPageForMonth(webClient, nextYear, nextMonth)
	if err != nil {
		fmt.Println("来月のシフト取得に失敗:", err)
		os.Exit(1)
	}
	shiftsNext, err := parseShifts(htmlNext)
	if err != nil {
		fmt.Println("来月のシフト解析に失敗:", err)
		os.Exit(1)
	}
	fmt.Printf("来月のシフト件数: %d\n", len(shiftsNext))

	shifts := append(shiftsThis, shiftsNext...)
	fmt.Printf("合計シフト件数: %d\n", len(shifts))

	fmt.Println("CalDAV（iCloud）にシフトを登録するよ…")
	if err := syncShiftsToCalDAV(shifts, cfg.ICloud.AppleID, appPass, cfg.ICloud.CalendarURL); err != nil {
		fmt.Println("CalDAV 同期中にエラー:", err)
		os.Exit(1)
	}
	if ranChange {
		fmt.Println("カレンダー変更後の同期が完了しました。")
	} else {
		fmt.Println("CalDAVへの登録処理おわり。")
	}
}

func configPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, configDirName, configFileName), nil
}

func loadConfig(path string) (*config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func saveConfig(path string, cfg *config) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := toml.NewEncoder(&buf).Encode(cfg); err != nil {
		return err
	}
	return os.WriteFile(path, buf.Bytes(), 0o644)
}

func runSetup(cfgPath string) (*config, error) {
	reader := bufio.NewReader(os.Stdin)

	fmt.Print("ShiftWeb のログインID: ")
	webID, _ := reader.ReadString('\n')
	webID = strings.TrimSpace(webID)
	if webID == "" {
		return nil, errors.New("ShiftWeb ID が空です")
	}

	fmt.Print("ShiftWeb のパスワード: ")
	webPassBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		return nil, fmt.Errorf("ShiftWeb パスワード入力に失敗: %w", err)
	}
	webPass := strings.TrimSpace(string(webPassBytes))
	if webPass == "" {
		return nil, errors.New("ShiftWeb パスワードが空です")
	}

	fmt.Print("Apple ID（iCloud, メールアドレス）: ")
	appleID, _ := reader.ReadString('\n')
	appleID = strings.TrimSpace(appleID)
	if appleID == "" {
		return nil, errors.New("Apple ID が空です")
	}

	fmt.Print("iCloud アプリ用パスワード: ")
	appPassBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		return nil, fmt.Errorf("iCloud パスワード入力に失敗: %w", err)
	}
	appPass := strings.TrimSpace(string(appPassBytes))
	if appPass == "" {
		return nil, errors.New("アプリ用パスワードが空です")
	}

	if err := keyring.Set(webService, webID, webPass); err != nil {
		return nil, fmt.Errorf("ShiftWeb パスワードの保存に失敗: %w", err)
	}
	if err := keyring.Set(icloudService, appleID, appPass); err != nil {
		return nil, fmt.Errorf("iCloud パスワードの保存に失敗: %w", err)
	}

	fmt.Println("\niCloud カレンダーを検索中…")
	homeURL, cals, err := discoverCalendars(appleID, appPass)
	if err != nil {
		return nil, err
	}
	if len(cals) == 0 {
		fmt.Println("既存のカレンダーが見つかりませんでした。")
	}

	fmt.Println("\n=== 見つかったカレンダー ===")
	fmt.Println("[0] 新しいカレンダーを作成")
	if len(cals) == 0 {
		fmt.Println("  (既存カレンダーなし)")
	} else {
		for i, cal := range cals {
			fmt.Printf("[%d] %s  ->  %s\n", i+1, cal.Name, cal.URL)
		}
	}

	var selected calendarInfo
	for {
		fmt.Printf("\nどのカレンダーにシフトを登録する？ [0-%d]: ", len(cals))
		choice, _ := reader.ReadString('\n')
		choice = strings.TrimSpace(choice)
		idx, err := parseChoice(choice, len(cals), true)
		if err != nil {
			fmt.Println("番号を入れて〜。")
			continue
		}
		if idx == -1 {
			selected, err = createNewCalendarFlow(reader, homeURL, appleID, appPass)
			if err != nil {
				fmt.Println("新しいカレンダーの作成に失敗:", err)
				continue
			}
		} else {
			selected = cals[idx]
		}
		break
	}

	cfg := &config{}
	cfg.ShiftWeb.ID = webID
	cfg.ICloud.AppleID = appleID
	cfg.ICloud.CalendarURL = selected.URL

	if err := saveConfig(cfgPath, cfg); err != nil {
		return nil, err
	}
	fmt.Printf("\n設定を保存したよ: %s\n", cfgPath)
	return cfg, nil
}

func runChangeCalendar(cfgPath string, cfg *config) error {
	reader := bufio.NewReader(os.Stdin)

	if cfg.ICloud.AppleID == "" {
		return errors.New("設定に Apple ID がありません。`--setup` を実行してください。")
	}

	appPass, err := keyring.Get(icloudService, cfg.ICloud.AppleID)
	if err != nil || appPass == "" {
		return errors.New("iCloud アプリ用パスワードをキーチェーンから取得できませんでした。`--setup` を試してください。")
	}

	client := &http.Client{Timeout: 30 * time.Second}
	currentDisplay := "(取得できませんでした)"
	if cfg.ICloud.CalendarURL != "" {
		if name, err := getCalendarDisplayName(client, cfg.ICloud.AppleID, appPass, cfg.ICloud.CalendarURL); err == nil && name != "" {
			currentDisplay = name
		}
	}
	if cfg.ICloud.CalendarURL != "" {
		fmt.Printf("現在のカレンダー: %s (%s)\n\n", currentDisplay, cfg.ICloud.CalendarURL)
	} else {
		fmt.Println("現在のカレンダー: 未設定")
	}

	fmt.Println("iCloud カレンダーを検索中…")
	homeURL, cals, err := discoverCalendars(cfg.ICloud.AppleID, appPass)
	if err != nil {
		return err
	}
	if len(cals) == 0 {
		fmt.Println("既存のカレンダーが見つかりませんでした。")
	}

	fmt.Println("\n=== 見つかったカレンダー ===")
	fmt.Println("[0] 新しいカレンダーを作成")
	if len(cals) == 0 {
		fmt.Println("  (既存カレンダーなし)")
	} else {
		for i, cal := range cals {
			fmt.Printf("[%d] %s  ->  %s\n", i+1, cal.Name, cal.URL)
		}
	}

	var selected calendarInfo
	for {
		fmt.Printf("\nどのカレンダーにシフトを登録する？ [0-%d]: ", len(cals))
		choice, _ := reader.ReadString('\n')
		choice = strings.TrimSpace(choice)
		idx, err := parseChoice(choice, len(cals), true)
		if err != nil {
			fmt.Println("番号を入れて〜。")
			continue
		}
		if idx == -1 {
			selected, err = createNewCalendarFlow(reader, homeURL, cfg.ICloud.AppleID, appPass)
			if err != nil {
				fmt.Println("新しいカレンダーの作成に失敗:", err)
				continue
			}
		} else {
			selected = cals[idx]
		}
		break
	}

	if selected.URL != cfg.ICloud.CalendarURL && cfg.ICloud.CalendarURL != "" {
		fmt.Println("\n前のカレンダーから shift-*.ics を削除してから、新しいカレンダーに切り替えます。")
		deleteShiftEventsFromCalendar(client, cfg.ICloud.AppleID, appPass, cfg.ICloud.CalendarURL)
	} else if selected.URL == cfg.ICloud.CalendarURL {
		fmt.Println("同じカレンダーが選択されたため、設定変更のみ行います。")
	}

	cfg.ICloud.CalendarURL = selected.URL
	if err := saveConfig(cfgPath, cfg); err != nil {
		return err
	}
	fmt.Printf("\n設定を保存したよ: %s\n", cfgPath)
	return nil
}

func runShowConfig(cfgPath string, cfg *config) error {
	if cfg == nil {
		return errors.New("設定が読み込まれていません")
	}
	fmt.Printf("ShiftWeb ID: %s\n", cfg.ShiftWeb.ID)
	fmt.Printf("Apple ID: %s\n", cfg.ICloud.AppleID)

	if cfg.ICloud.CalendarURL == "" {
		fmt.Println("カレンダー: 未設定")
	} else {
		calName := "(取得できませんでした)"
		if cfg.ICloud.AppleID != "" {
			if appPass, err := keyring.Get(icloudService, cfg.ICloud.AppleID); err == nil && appPass != "" {
				client := &http.Client{Timeout: 30 * time.Second}
				if name, err := getCalendarDisplayName(client, cfg.ICloud.AppleID, appPass, cfg.ICloud.CalendarURL); err == nil && name != "" {
					calName = name
				}
			}
		}
		fmt.Printf("カレンダー: %s (%s)\n", calName, cfg.ICloud.CalendarURL)
	}

	fmt.Printf("設定ファイル: %s\n", cfgPath)
	if logPath, err := logFilePath(); err == nil {
		fmt.Printf("ログファイル: %s\n", logPath)
	}
	return nil
}

func runList(cfg *config, from, to string) error {
	if cfg.ShiftWeb.ID == "" {
		return errors.New("ShiftWeb ID が設定されていません。`-setup` を実行してください。")
	}
	webPass, err := keyring.Get(webService, cfg.ShiftWeb.ID)
	if err != nil || webPass == "" {
		return errors.New("ShiftWeb パスワードをキーチェーンから取得できませんでした。`-setup` を実行してください。")
	}

	months, err := buildMonthRange(from, to)
	if err != nil {
		return err
	}

	client, err := loginShiftWeb(cfg.ShiftWeb.ID, webPass)
	if err != nil {
		return fmt.Errorf("ShiftWeb ログインに失敗: %w", err)
	}

	var shifts []shift
	for _, ym := range months {
		html, err := fetchShiftPageForMonth(client, ym.Year, ym.Month)
		if err != nil {
			return fmt.Errorf("%04d-%02d のシフト取得に失敗: %w", ym.Year, ym.Month, err)
		}
		ss, err := parseShifts(html)
		if err != nil {
			return fmt.Errorf("%04d-%02d のシフト解析に失敗: %w", ym.Year, ym.Month, err)
		}
		shifts = append(shifts, ss...)
	}

	sort.Slice(shifts, func(i, j int) bool {
		return shifts[i].Start.Before(shifts[j].Start)
	})

	for _, s := range shifts {
		fmt.Printf("%s  %s-%s  %s\n", s.Start.Format("2006-01-02"), s.Start.Format("15:04"), s.End.Format("15:04"), s.Location)
	}
	fmt.Printf("合計 %d 件\n", len(shifts))
	return nil
}

func parseChoice(text string, max int, allowZero bool) (int, error) {
	idx := -1
	fmt.Sscanf(text, "%d", &idx)
	if allowZero && idx == 0 {
		return -1, nil
	}
	if idx < 1 || idx > max {
		return 0, errors.New("invalid choice")
	}
	return idx - 1, nil
}

func createNewCalendarFlow(reader *bufio.Reader, homeURL, appleID, appPassword string) (calendarInfo, error) {
	const defaultCalName = "バイト"

	fmt.Printf("新しく作るカレンダーの名前を入力して下さい（例: %s）: ", defaultCalName)
	name, _ := reader.ReadString('\n')
	name = strings.TrimSpace(name)
	if name == "" {
		name = defaultCalName
	}

	newID, err := generateUUID()
	if err != nil {
		return calendarInfo{}, fmt.Errorf("カレンダーIDの生成に失敗: %w", err)
	}
	newURL := strings.TrimRight(homeURL, "/") + "/" + newID + "/"

	client := &http.Client{Timeout: 30 * time.Second}
	fmt.Printf("新しいカレンダーを作成します: %s (%s)\n", name, newURL)
	if err := createCalendar(client, appleID, appPassword, newURL, name); err != nil {
		return calendarInfo{}, err
	}
	return calendarInfo{Name: name, URL: newURL}, nil
}

func generateUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	hexStr := hex.EncodeToString(b[:])
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexStr[0:8], hexStr[8:12], hexStr[12:16], hexStr[16:20], hexStr[20:32]), nil
}

func createCalendar(client *http.Client, appleID, appPassword, calendarURL, displayName string) error {
	reqBody := mkcalendarRequest{
		XmlnsD: "DAV:",
		XmlnsC: "urn:ietf:params:xml:ns:caldav",
		Set: mkcalendarSet{
			Prop: mkcalendarProp{
				DisplayName: displayName,
				ResourceType: mkcalendarResourceType{
					Collection: &struct{}{},
					Calendar:   &struct{}{},
				},
				SupportedCalendarComponents: mkcalendarSupportedCalendarComponent{
					Components: []mkcalendarComp{{Name: "VEVENT"}},
				},
			},
		},
	}
	raw, err := xml.Marshal(reqBody)
	if err != nil {
		return err
	}
	body := append([]byte(xml.Header), raw...)

	req, err := http.NewRequest("MKCALENDAR", calendarURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.SetBasicAuth(appleID, appPassword)
	req.Header.Set("Content-Type", "application/xml; charset=utf-8")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	resBody, _ := io.ReadAll(resp.Body)
	fmt.Printf("[CalDAV] MKCALENDAR %s => status=%d\n", calendarURL, resp.StatusCode)
	if resp.StatusCode >= 300 {
		return fmt.Errorf("MKCALENDAR status=%d body=%s", resp.StatusCode, string(resBody))
	}
	fmt.Printf("  => body: %s\n", string(resBody))
	return nil
}

func loginShiftWeb(webID, webPassword string) (*http.Client, error) {
	jar, _ := cookiejar.New(nil)
	client := &http.Client{
		Jar:     jar,
		Timeout: 30 * time.Second,
	}

	r0, err := client.Get(loginPageURL + "?err=1")
	if err != nil {
		return nil, fmt.Errorf("ログインページ取得失敗: %w", err)
	}
	r0.Body.Close()

	payload := url.Values{
		"id":        {webID},
		"password":  {webPassword},
		"savelogin": {"1"},
	}
	req, err := http.NewRequest(http.MethodPost, fmt.Sprintf("%s?%s", loginAPIURL, webID), strings.NewReader(payload.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	req.Header.Set("Origin", baseURL)
	req.Header.Set("Referer", baseURL+"/login.php?err=1")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ログインAPI失敗: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("ログインAPI status=%d body=%s", resp.StatusCode, string(body))
	}
	fmt.Printf("login API response: %s\n", string(body))
	return client, nil
}

func fetchShiftPageForMonth(client *http.Client, year, month int) (string, error) {
	date2 := fmt.Sprintf("%04d-%02d", year, month)
	params := url.Values{
		"mod":   {"look"},
		"date2": {date2},
	}
	reqURL := fmt.Sprintf("%s?%s", shiftURL, params.Encode())
	req, err := http.NewRequest(http.MethodGet, reqURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Referer", shiftURL)

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("shift status (%s): %d body=%s", date2, resp.StatusCode, string(body))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	fmt.Printf("shift status (%s): %d\n", date2, resp.StatusCode)
	return string(body), nil
}

func parseShifts(html string) ([]shift, error) {
	doc, err := goquery.NewDocumentFromReader(strings.NewReader(html))
	if err != nil {
		return nil, err
	}

	year := time.Now().Year()
	header := strings.TrimSpace(doc.Find("h3.btn-block").First().Text())
	if y, _ := parseYearMonth(header); y != 0 {
		year = y
	}

	table := doc.Find("table#shiftTable")
	if table.Length() == 0 {
		return nil, errors.New("shiftTable が見つからんかった…HTML変わったかも")
	}

	var shifts []shift
	table.Find("tr").Each(func(i int, tr *goquery.Selection) {
		if i == 0 {
			return // skip header
		}
		dateText := strings.TrimSpace(tr.Find("td.shiftDate").Text())
		shopText := strings.TrimSpace(tr.Find("td.shiftMisName").Text())
		timeText := strings.TrimSpace(tr.Find("td.shiftTime").Text())

		if dateText == "" || shopText == "" || timeText == "" {
			return
		}
		if !strings.Contains(timeText, "●") || !strings.Contains(timeText, "-") {
			return
		}

		timePart := strings.SplitN(timeText, "●", 2)[1]
		timeParts := strings.SplitN(timePart, "-", 2)
		if len(timeParts) != 2 {
			return
		}
		startStr := strings.TrimSpace(timeParts[0])
		endStr := strings.TrimSpace(timeParts[1])

		dateMain := strings.SplitN(dateText, "\n", 2)[0]
		dateMain = strings.SplitN(dateMain, "(", 2)[0]
		parts := strings.SplitN(dateMain, "/", 2)
		if len(parts) != 2 {
			return
		}
		m, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
		d, err2 := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err1 != nil || err2 != nil {
			return
		}

		startDT, err := combineDateTime(year, m, d, startStr)
		if err != nil {
			return
		}
		endDT, err := combineDateTime(year, m, d, endStr)
		if err != nil {
			return
		}
		if startDT.Equal(endDT) {
			return
		}

		shifts = append(shifts, shift{
			Title:    "バイト",
			Start:    startDT,
			End:      endDT,
			Location: shopText,
			Memo:     "",
		})
	})

	return shifts, nil
}

func parseYearMonth(text string) (int, int) {
	for _, re := range []string{`(\d{4})年(\d{1,2})月`, `(\d{4})-(\d{1,2})`} {
		if m := regexp.MustCompile(re).FindStringSubmatch(text); len(m) == 3 {
			year, _ := strconv.Atoi(m[1])
			month, _ := strconv.Atoi(m[2])
			return year, month
		}
	}
	return 0, 0
}

func combineDateTime(year, month, day int, hhmm string) (time.Time, error) {
	parts := strings.Split(hhmm, ":")
	if len(parts) != 2 {
		return time.Time{}, fmt.Errorf("invalid time %q", hhmm)
	}
	hour, err1 := strconv.Atoi(parts[0])
	min, err2 := strconv.Atoi(parts[1])
	if err1 != nil || err2 != nil {
		return time.Time{}, fmt.Errorf("invalid time %q", hhmm)
	}
	return time.Date(year, time.Month(month), day, hour, min, 0, 0, time.Local), nil
}

func formatDT(t time.Time) string {
	return t.Format("20060102T150405")
}

func logFilePath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Logs", "shift-sync.log"), nil
}

type yearMonth struct {
	Year  int
	Month int
}

func buildMonthRange(fromStr, toStr string) ([]yearMonth, error) {
	now := time.Now()
	cur := yearMonth{Year: now.Year(), Month: int(now.Month())}

	var from, to yearMonth
	var err error
	switch {
	case fromStr == "" && toStr == "":
		return []yearMonth{cur, addMonths(cur, 1)}, nil
	case fromStr != "" && toStr != "":
		from, err = parseYYYYMM(fromStr)
		if err != nil {
			return nil, fmt.Errorf("from が不正です: %w", err)
		}
		to, err = parseYYYYMM(toStr)
		if err != nil {
			return nil, fmt.Errorf("to が不正です: %w", err)
		}
	case fromStr != "":
		from, err = parseYYYYMM(fromStr)
		if err != nil {
			return nil, fmt.Errorf("from が不正です: %w", err)
		}
		to = addMonths(from, 1)
	case toStr != "":
		to, err = parseYYYYMM(toStr)
		if err != nil {
			return nil, fmt.Errorf("to が不正です: %w", err)
		}
		from = cur
	}

	if compareYearMonth(from, to) > 0 {
		return nil, errors.New("from が to より未来になっています")
	}

	const maxMonths = 12
	var list []yearMonth
	for ym := from; ; ym = addMonths(ym, 1) {
		list = append(list, ym)
		if compareYearMonth(ym, to) == 0 {
			break
		}
		if len(list) > maxMonths {
			return nil, fmt.Errorf("期間が広すぎます（最大 %d ヶ月まで）", maxMonths)
		}
	}
	return list, nil
}

func parseYYYYMM(s string) (yearMonth, error) {
	t, err := time.Parse("2006-01", s)
	if err != nil {
		return yearMonth{}, err
	}
	return yearMonth{Year: t.Year(), Month: int(t.Month())}, nil
}

func addMonths(ym yearMonth, add int) yearMonth {
	t := time.Date(ym.Year, time.Month(ym.Month), 1, 0, 0, 0, 0, time.UTC)
	t = t.AddDate(0, add, 0)
	return yearMonth{Year: t.Year(), Month: int(t.Month())}
}

func compareYearMonth(a, b yearMonth) int {
	if a.Year != b.Year {
		if a.Year < b.Year {
			return -1
		}
		return 1
	}
	if a.Month < b.Month {
		return -1
	}
	if a.Month > b.Month {
		return 1
	}
	return 0
}

func makeShiftUID(s shift) string {
	key := fmt.Sprintf("%s-%s-%s", s.Start.Format("20060102T1504"), s.End.Format("20060102T1504"), s.Location)
	digest := sha1.Sum([]byte(key))
	hash := hex.EncodeToString(digest[:])[:8]
	return fmt.Sprintf("shift-%s-%s-%s-%s", s.Start.Format("20060102"), s.Start.Format("1504"), s.End.Format("1504"), hash)
}

func buildSingleEventICAL(s shift, uid string) string {
	var b strings.Builder
	b.WriteString("BEGIN:VCALENDAR\r\n")
	b.WriteString("VERSION:2.0\r\n")
	b.WriteString("PRODID:-//Inazumi Shift Sync//JP\r\n")
	b.WriteString("BEGIN:VEVENT\r\n")
	b.WriteString(fmt.Sprintf("UID:%s\r\n", uid))
	b.WriteString(fmt.Sprintf("DTSTART:%s\r\n", formatDT(s.Start)))
	b.WriteString(fmt.Sprintf("DTEND:%s\r\n", formatDT(s.End)))
	b.WriteString(fmt.Sprintf("SUMMARY:%s\r\n", escapeICalText(s.Title)))
	if s.Location != "" {
		b.WriteString(fmt.Sprintf("LOCATION:%s\r\n", escapeICalText(s.Location)))
	}
	if s.Memo != "" {
		b.WriteString(fmt.Sprintf("DESCRIPTION:%s\r\n", escapeICalText(s.Memo)))
	}
	b.WriteString("END:VEVENT\r\n")
	b.WriteString("END:VCALENDAR\r\n")
	return b.String()
}

func escapeICalText(text string) string {
	replacer := strings.NewReplacer("\\", "\\\\", ";", "\\;", ",", "\\,", "\n", "\\n")
	return replacer.Replace(text)
}

func listShiftEventUIDs(client *http.Client, appleID, appPassword, calendarURL string) (map[string]struct{}, error) {
	body := `<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>
`
	data, base, err := propfind(client, calendarURL, body, "1", appleID, appPassword)
	if err != nil {
		return nil, err
	}
	var res propfindResponse
	if err := xml.Unmarshal(data, &res); err != nil {
		return nil, fmt.Errorf("calendar resource list parse error: %w", err)
	}

	uids := make(map[string]struct{})
	for _, r := range res.Responses {
		href := strings.TrimSpace(r.Href)
		if href == "" {
			continue
		}
		fullHref := resolveHref(base, href)

		var p prop
		if len(r.Propstat) > 0 {
			p = r.Propstat[0].Prop
		}
		if p.ResourceType.Calendar != nil {
			continue
		}

		u, err := url.Parse(fullHref)
		var name string
		if err == nil && u.Path != "" {
			name = path.Base(u.Path)
		} else {
			name = path.Base(fullHref)
		}
		if !strings.HasPrefix(name, "shift-") || !strings.HasSuffix(name, ".ics") {
			continue
		}
		uid := strings.TrimSuffix(name, ".ics")
		uids[uid] = struct{}{}
	}

	return uids, nil
}

func deleteShiftEventsFromCalendar(client *http.Client, appleID, appPassword, calendarURL string) {
	uids, err := listShiftEventUIDs(client, appleID, appPassword, calendarURL)
	if err != nil {
		fmt.Println("  => 既存イベント一覧取得エラー:", err)
		return
	}
	if len(uids) == 0 {
		fmt.Println("  => shift-*.ics は見つかりませんでした。")
		return
	}
	base := strings.TrimRight(calendarURL, "/")
	for uid := range uids {
		eventURL := fmt.Sprintf("%s/%s.ics", base, uid)
		fmt.Printf("[CalDAV] DELETE %s\n", eventURL)
		req, err := http.NewRequest(http.MethodDelete, eventURL, nil)
		if err != nil {
			fmt.Println("  => リクエスト作成エラー:", err)
			continue
		}
		req.SetBasicAuth(appleID, appPassword)

		resp, err := client.Do(req)
		if err != nil {
			fmt.Println("  => HTTPエラー:", err)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
			fmt.Printf("  => エラー status=%d, body=%s\n", resp.StatusCode, string(body))
		} else {
			fmt.Printf("  => 削除OK (%d)\n", resp.StatusCode)
		}
	}
}

func syncShiftsToCalDAV(shifts []shift, appleID, appPassword, calendarURL string) error {
	if !strings.HasPrefix(calendarURL, "http") {
		return errors.New("calendar_url が変やで: " + calendarURL)
	}
	base := strings.TrimRight(calendarURL, "/")
	client := &http.Client{Timeout: 30 * time.Second}

	type shiftEntry struct {
		UID   string
		Shift shift
	}

	desiredSet := make(map[string]struct{})
	var desiredShifts []shiftEntry
	for _, s := range shifts {
		if s.Start.Equal(s.End) {
			continue
		}
		uid := makeShiftUID(s)
		if _, exists := desiredSet[uid]; exists {
			continue
		}
		desiredSet[uid] = struct{}{}
		desiredShifts = append(desiredShifts, shiftEntry{UID: uid, Shift: s})
	}

	existingUIDs, err := listShiftEventUIDs(client, appleID, appPassword, calendarURL)
	if err != nil {
		fmt.Println("既存イベント一覧取得エラー:", err)
		existingUIDs = map[string]struct{}{}
	}

	var toDelete []string
	for uid := range existingUIDs {
		if _, ok := desiredSet[uid]; !ok {
			toDelete = append(toDelete, uid)
		}
	}

	for _, uid := range toDelete {
		eventURL := fmt.Sprintf("%s/%s.ics", base, uid)
		fmt.Printf("[CalDAV] DELETE %s\n", eventURL)
		req, err := http.NewRequest(http.MethodDelete, eventURL, nil)
		if err != nil {
			fmt.Println("  => リクエスト作成エラー:", err)
			continue
		}
		req.SetBasicAuth(appleID, appPassword)

		resp, err := client.Do(req)
		if err != nil {
			fmt.Println("  => HTTPエラー:", err)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
			fmt.Printf("  => エラー status=%d, body=%s\n", resp.StatusCode, string(body))
		} else {
			fmt.Printf("  => 削除OK (%d)\n", resp.StatusCode)
		}
	}

	for _, entry := range desiredShifts {
		icalBody := buildSingleEventICAL(entry.Shift, entry.UID)
		eventURL := fmt.Sprintf("%s/%s.ics", base, entry.UID)

		fmt.Printf("[CalDAV] PUT %s\n", eventURL)
		req, err := http.NewRequest(http.MethodPut, eventURL, strings.NewReader(icalBody))
		if err != nil {
			fmt.Println("  => リクエスト作成エラー:", err)
			continue
		}
		req.SetBasicAuth(appleID, appPassword)
		req.Header.Set("Content-Type", "text/calendar; charset=utf-8")

		resp, err := client.Do(req)
		if err != nil {
			fmt.Println("  => HTTPエラー:", err)
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
			fmt.Printf("  => エラー status=%d, body=%s\n", resp.StatusCode, string(body))
		} else {
			fmt.Printf("  => OK (%d)\n", resp.StatusCode)
		}
	}
	return nil
}

type propfindResponse struct {
	XMLName   xml.Name        `xml:"multistatus"`
	Responses []responseEntry `xml:"response"`
}

type responseEntry struct {
	Href     string        `xml:"href"`
	Propstat []propstatEnt `xml:"propstat"`
}

type propstatEnt struct {
	Prop prop `xml:"prop"`
}

type prop struct {
	CurrentUserPrincipal hrefProp     `xml:"current-user-principal"`
	CalendarHomeSet      hrefProp     `xml:"calendar-home-set"`
	DisplayName          string       `xml:"displayname"`
	ResourceType         resourceType `xml:"resourcetype"`
	CalendarDescription  string       `xml:"calendar-description"`
}

type hrefProp struct {
	Href string `xml:"href"`
}

type resourceType struct {
	Calendar *struct{} `xml:"calendar"`
}

func discoverCalendars(appleID, appPassword string) (string, []calendarInfo, error) {
	client := &http.Client{Timeout: 30 * time.Second}

	principalURL, err := getCurrentUserPrincipal(client, appleID, appPassword)
	if err != nil {
		return "", nil, err
	}

	homeURL, err := getCalendarHomeSet(client, appleID, appPassword, principalURL)
	if err != nil {
		return "", nil, err
	}

	cals, err := listCalendars(client, appleID, appPassword, homeURL)
	if err != nil {
		return "", nil, err
	}
	return homeURL, cals, nil
}

func getCalendarDisplayName(client *http.Client, appleID, appPassword, calendarURL string) (string, error) {
	body := `<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:displayname/>
  </d:prop>
</d:propfind>
`
	data, _, err := propfind(client, calendarURL, body, "0", appleID, appPassword)
	if err != nil {
		return "", err
	}
	var res propfindResponse
	if err := xml.Unmarshal(data, &res); err != nil {
		return "", err
	}
	for _, r := range res.Responses {
		for _, ps := range r.Propstat {
			if ps.Prop.DisplayName != "" {
				return ps.Prop.DisplayName, nil
			}
		}
	}
	return "", nil
}

func getCurrentUserPrincipal(client *http.Client, appleID, appPassword string) (string, error) {
	body := `<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:current-user-principal/>
  </d:prop>
</d:propfind>
`
	data, base, err := propfind(client, caldavBaseURL, body, "0", appleID, appPassword)
	if err != nil {
		return "", err
	}
	var res propfindResponse
	if err := xml.Unmarshal(data, &res); err != nil {
		return "", fmt.Errorf("current-user-principal parse error: %w", err)
	}
	for _, r := range res.Responses {
		for _, ps := range r.Propstat {
			if ps.Prop.CurrentUserPrincipal.Href != "" {
				return resolveHref(base, ps.Prop.CurrentUserPrincipal.Href), nil
			}
		}
	}
	return "", errors.New("current-user-principal が取れんかった…")
}

func getCalendarHomeSet(client *http.Client, appleID, appPassword, principalURL string) (string, error) {
	body := `<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <c:calendar-home-set/>
  </d:prop>
</d:propfind>
`
	data, base, err := propfind(client, principalURL, body, "0", appleID, appPassword)
	if err != nil {
		return "", err
	}
	var res propfindResponse
	if err := xml.Unmarshal(data, &res); err != nil {
		return "", fmt.Errorf("calendar-home-set parse error: %w", err)
	}
	for _, r := range res.Responses {
		for _, ps := range r.Propstat {
			if ps.Prop.CalendarHomeSet.Href != "" {
				return resolveHref(base, ps.Prop.CalendarHomeSet.Href), nil
			}
		}
	}
	return "", errors.New("calendar-home-set が取れんかった…")
}

func listCalendars(client *http.Client, appleID, appPassword, homeURL string) ([]calendarInfo, error) {
	body := `<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:displayname/>
    <c:calendar-description/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>
`
	data, base, err := propfind(client, homeURL, body, "1", appleID, appPassword)
	if err != nil {
		return nil, err
	}
	var res propfindResponse
	if err := xml.Unmarshal(data, &res); err != nil {
		return nil, fmt.Errorf("calendar list parse error: %w", err)
	}

	var cals []calendarInfo
	for _, r := range res.Responses {
		var p prop
		if len(r.Propstat) > 0 {
			p = r.Propstat[0].Prop
		}
		if p.ResourceType.Calendar == nil {
			continue
		}
		name := strings.TrimSpace(p.DisplayName)
		if name == "" {
			name = "(no name)"
		}
		href := strings.TrimSpace(r.Href)
		if href == "" && p.CalendarHomeSet.Href != "" {
			href = p.CalendarHomeSet.Href
		}
		if href == "" {
			continue
		}
		cals = append(cals, calendarInfo{
			Name: name,
			URL:  resolveHref(base, href),
		})
	}
	return cals, nil
}

func propfind(client *http.Client, urlStr, body, depth, appleID, appPassword string) ([]byte, *url.URL, error) {
	req, err := http.NewRequest("PROPFIND", urlStr, strings.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Depth", depth)
	req.Header.Set("Content-Type", "application/xml; charset=utf-8")
	req.SetBasicAuth(appleID, appPassword)

	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return nil, resp.Request.URL, fmt.Errorf("PROPFIND %s status=%d body=%s", urlStr, resp.StatusCode, string(b))
	}
	data, err := io.ReadAll(resp.Body)
	return data, resp.Request.URL, err
}

func resolveHref(base *url.URL, href string) string {
	if u, err := url.Parse(href); err == nil {
		if u.IsAbs() {
			return u.String()
		}
		return base.ResolveReference(u).String()
	}
	return href
}
