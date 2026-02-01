mod shift;
use shift::Shift;


fn main() {
    //Shiftのインスタンス作成
    let my_shift = Shift {
	title: String::from("バイト"),
	start: String::from("2026-01-10 09:00"),
	end: String::from("2026-01-10 18:00"),
	location: String::from("本社"),
    };
    println!("シフト: {}",my_shift.title);
    println!("開始: {}",my_shift.start);
    println!("終了: {}",my_shift.end);
    println!("場所: {}",my_shift.location);
}
