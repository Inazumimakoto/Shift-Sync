pub fn generate_ics(shifts: Vec<Shift>) -> String {
    let mut ics_format=String::from("BEGIN:VCALENDAR\nVERSION:2.0\n");

    for shift in shifts {
	let mut start = String::new();
	let mut end = String::new;
	
	fomrat!("{shift.start[]}",start);	

	format!("
BEGIN:VEVENT\n
SUMMERY:{shift.titile}\n
DTSTART:{shift.start}\n
DTEND:{shift.end}\n
LOCATION:{shift.location}\n
END:VEVENT\n",ics_format);
    }
}
