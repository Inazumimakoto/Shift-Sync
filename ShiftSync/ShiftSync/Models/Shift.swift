import Foundation
import CryptoKit

struct Shift: Codable, Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let title: String
    let start: Date
    let end: Date
    let location: String
    let memo: String
    
    /// Go版と同じロジックでUIDを生成（上書き互換性のため）
    /// Go版: makeShiftUID in main.go:938-943
    static func makeUID(start: Date, end: Date, location: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)
        let key = "\(startStr)-\(endStr)-\(location)"
        
        // SHA1ハッシュの先頭8文字
        let data = Data(key.utf8)
        let hash = Insecure.SHA1.hash(data: data)
        let hashHex = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let datePart = dateFormatter.string(from: start)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmm"
        let startTime = timeFormatter.string(from: start)
        let endTime = timeFormatter.string(from: end)
        
        return "shift-\(datePart)-\(startTime)-\(endTime)-\(hashHex)"
    }
    
    init(title: String = "バイト", start: Date, end: Date, location: String, memo: String = "") {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.memo = memo
        self.uid = Self.makeUID(start: start, end: end, location: location)
    }
    
    // Codableのためのカスタムinit
    init(uid: String, title: String, start: Date, end: Date, location: String, memo: String) {
        self.uid = uid
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.memo = memo
    }
}

extension Shift {
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: start)
    }
    
    var dayOfWeek: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: start)
    }
    
    var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }
}
