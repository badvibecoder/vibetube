package textfield

import "core:testing"

@(test)
typing_appends :: proc(t: ^testing.T) {
	f: Field
	for c in "hello" {
		testing.expect(t, insert_byte(&f, u8(c)), "insert should succeed")
	}
	testing.expect_value(t, value(&f), "hello")
	testing.expect_value(t, f.cursor, 5)
}

@(test)
backspace_removes_before_cursor :: proc(t: ^testing.T) {
	f: Field
	set(&f, "abc")
	testing.expect(t, backspace(&f))
	testing.expect_value(t, value(&f), "ab")
	testing.expect_value(t, f.cursor, 2)
	testing.expect(t, backspace(&f))
	testing.expect(t, backspace(&f))
	testing.expect(t, !backspace(&f), "backspace at start is a no-op")
	testing.expect_value(t, value(&f), "")
}

@(test)
insert_in_the_middle :: proc(t: ^testing.T) {
	f: Field
	set(&f, "ac")
	move_left(&f)
	insert_byte(&f, 'b')
	testing.expect_value(t, value(&f), "abc")
	testing.expect_value(t, f.cursor, 2)
}

@(test)
delete_forward_behavior :: proc(t: ^testing.T) {
	f: Field
	set(&f, "abc")
	move_home(&f)
	testing.expect(t, delete_forward(&f))
	testing.expect_value(t, value(&f), "bc")
	move_end(&f)
	testing.expect(t, !delete_forward(&f), "delete at end is a no-op")
}

@(test)
control_bytes_rejected :: proc(t: ^testing.T) {
	f: Field
	testing.expect(t, !insert_byte(&f, 10), "newline rejected")
	testing.expect(t, !insert_byte(&f, 0), "nul rejected")
	testing.expect(t, !insert_byte(&f, 9), "tab rejected")
	testing.expect_value(t, f.len, 0)
}

@(test)
paste_keeps_utf8_bytes_but_drops_controls :: proc(t: ^testing.T) {
	f: Field
	n := insert_str(&f, "a\r\nb")
	testing.expect_value(t, n, 2)
	testing.expect_value(t, value(&f), "ab")

	f2: Field
	insert_str(&f2, "Café")
	testing.expect_value(t, value(&f2), "Café")
}

@(test)
respects_max_length :: proc(t: ^testing.T) {
	f: Field
	long: [MAX + 50]u8
	for i in 0 ..< len(long) {
		long[i] = 'x'
	}
	n := insert_str(&f, string(long[:]))
	testing.expect_value(t, n, MAX - 1)
	testing.expect_value(t, f.len, MAX - 1)
}

@(test)
long_url_pastes_and_navigates :: proc(t: ^testing.T) {
	f: Field
	url := "https://www.youtube.com/watch?v=dWRCooFKk3c"
	insert_str(&f, url)
	testing.expect_value(t, value(&f), url)
	move_home(&f)
	testing.expect_value(t, f.cursor, 0)
	move_end(&f)
	testing.expect_value(t, f.cursor, len(url))
}

@(test)
set_places_cursor_at_end :: proc(t: ^testing.T) {
	f: Field
	set(&f, "F:\\DEV\\DSH\\vibetube")
	testing.expect_value(t, f.cursor, f.len)
	clear(&f)
	testing.expect_value(t, f.len, 0)
	testing.expect_value(t, f.cursor, 0)
}
