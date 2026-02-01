import Foundation

/// ICS形式でシフトをエクスポート
/// Go版: buildSingleEventICAL (main.go:945-964)
struct ICSExporter {
    
    /// シフト一覧をICS形式の文字列に変換
    static func exportShifts(_ shifts: [Shift]) -> String {
        var ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Inazumi Shift Sync//JP
        CALSCALE:GREGORIAN
        METHOD:PUBLISH
        
        """
        
        for shift in shifts {
            ics += buildEvent(shift)
        }
        
        ics += "END:VCALENDAR\r\n"
        return ics
    }
    
    /// 単一のシフトをVEVENTに変換
    private static func buildEvent(_ shift: Shift) -> String {
        let dtstart = formatDateTime(shift.start)
        let dtend = formatDateTime(shift.end)
        let dtstamp = formatDateTime(Date())
        
        var event = """
        BEGIN:VEVENT
        UID:\(shift.uid)
        DTSTAMP:\(dtstamp)
        DTSTART:\(dtstart)
        DTEND:\(dtend)
        SUMMARY:\(escapeICalText(shift.title))
        
        """
        
        if !shift.location.isEmpty {
            event += "LOCATION:\(escapeICalText(shift.location))\r\n"
        }
        
        if !shift.memo.isEmpty {
            event += "DESCRIPTION:\(escapeICalText(shift.memo))\r\n"
        }
        
        event += "END:VEVENT\r\n"
        return event
    }
    
    /// DateをiCalendar形式にフォーマット
    /// Go版: formatDT (main.go:841-843)
    private static func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
    
    /// iCalendarテキストのエスケープ
    /// Go版: escapeICalText (main.go:966-969)
    private static func escapeICalText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
    
    /// ICSファイルを一時ファイルとして保存
    static func saveToTempFile(_ shifts: [Shift]) throws -> URL {
        let icsContent = exportShifts(shifts)
        let fileName = "shifts_\(Date().timeIntervalSince1970).ics"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try icsContent.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }
}
