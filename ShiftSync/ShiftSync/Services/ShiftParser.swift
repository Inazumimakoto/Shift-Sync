import Foundation
import SwiftSoup

/// HTMLからシフト情報をパースする
/// Go版: parseShifts (main.go:740-815)
struct ShiftParser {
    
    static func parseShifts(html: String) throws -> [Shift] {
        let doc = try SwiftSoup.parse(html)
        
        // ヘッダーから年を取得
        var year = Calendar.current.component(.year, from: Date())
        if let header = try doc.select("h3.btn-block").first()?.text() {
            if let parsedYear = parseYearMonth(text: header)?.year {
                year = parsedYear
            }
        }
        
        // シフトテーブルを取得
        guard let table = try doc.select("table#shiftTable").first() else {
            throw ShiftWebError.parseFailed("shiftTable が見つかりませんでした")
        }
        
        var shifts: [Shift] = []
        let rows = try table.select("tr")
        
        for (index, row) in rows.enumerated() {
            // ヘッダー行をスキップ
            if index == 0 { continue }
            
            let dateText = try row.select("td.shiftDate").text().trimmingCharacters(in: .whitespaces)
            let shopText = try row.select("td.shiftMisName").text().trimmingCharacters(in: .whitespaces)
            let timeText = try row.select("td.shiftTime").text().trimmingCharacters(in: .whitespaces)
            
            if dateText.isEmpty || shopText.isEmpty || timeText.isEmpty {
                continue
            }
            
            // 時間テキストのパース（●10:00-19:00 のような形式）
            guard timeText.contains("●"), timeText.contains("-") else {
                continue
            }
            
            let timeParts = timeText.components(separatedBy: "●")
            guard timeParts.count >= 2 else { continue }
            
            let timeRange = timeParts[1].components(separatedBy: "-")
            guard timeRange.count == 2 else { continue }
            
            let startStr = timeRange[0].trimmingCharacters(in: .whitespaces)
            let endStr = timeRange[1].trimmingCharacters(in: .whitespaces)
            
            // 日付のパース（1/15(水) のような形式）
            var dateMain = dateText
            if let newlineIndex = dateMain.firstIndex(of: "\n") {
                dateMain = String(dateMain[..<newlineIndex])
            }
            if let parenIndex = dateMain.firstIndex(of: "(") {
                dateMain = String(dateMain[..<parenIndex])
            }
            
            let dateParts = dateMain.components(separatedBy: "/")
            guard dateParts.count == 2,
                  let month = Int(dateParts[0].trimmingCharacters(in: .whitespaces)),
                  let day = Int(dateParts[1].trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            
            // Date型に変換
            guard let startDate = combineDateTime(year: year, month: month, day: day, time: startStr),
                  let endDate = combineDateTime(year: year, month: month, day: day, time: endStr) else {
                continue
            }
            
            // 開始と終了が同じ場合はスキップ
            if startDate == endDate {
                continue
            }
            
            let shift = Shift(
                title: "バイト",
                start: startDate,
                end: endDate,
                location: shopText,
                memo: ""
            )
            shifts.append(shift)
        }
        
        return shifts
    }
    
    /// テキストから年月を抽出
    /// Go版: parseYearMonth (main.go:817-826)
    private static func parseYearMonth(text: String) -> (year: Int, month: Int)? {
        let patterns = [
            #"(\d{4})年(\d{1,2})月"#,
            #"(\d{4})-(\d{1,2})"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges >= 3,
               let yearRange = Range(match.range(at: 1), in: text),
               let monthRange = Range(match.range(at: 2), in: text),
               let year = Int(text[yearRange]),
               let month = Int(text[monthRange]) {
                return (year, month)
            }
        }
        return nil
    }
    
    /// 年月日と時刻文字列からDateを生成
    /// Go版: combineDateTime (main.go:828-839)
    private static func combineDateTime(year: Int, month: Int, day: Int, time: String) -> Date? {
        let parts = time.components(separatedBy: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone.current
        
        return Calendar.current.date(from: components)
    }
}
