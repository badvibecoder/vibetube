package textfield

// A small, dependency-free single-line text editor.
//
// This replaces raygui's GuiTextBox, which insists on toggling its own edit
// mode per click and consumes raylib's key queue, making typed input
// unreliable. Everything here is pure data manipulation, so it is unit
// testable without a window.

MAX :: 512

Field :: struct {
	buf:    [MAX]u8,
	len:    int,
	cursor: int,
	scroll: f32, // horizontal pixel offset, owned by the renderer
}

value :: proc(f: ^Field) -> string {
	return string(f.buf[:f.len])
}

set :: proc(f: ^Field, s: string) {
	n := len(s)
	if n > MAX - 1 {
		n = MAX - 1
	}
	for i in 0 ..< n {
		f.buf[i] = s[i]
	}
	f.len = n
	f.cursor = n
	f.scroll = 0
}

clear :: proc(f: ^Field) {
	f.len = 0
	f.cursor = 0
	f.scroll = 0
}

// Inserts one byte at the caret. Control bytes are rejected; bytes >= 0x80 are
// accepted so that pasted UTF-8 paths survive intact.
insert_byte :: proc(f: ^Field, c: u8) -> bool {
	if c < 32 {
		return false
	}
	if f.len >= MAX - 1 {
		return false
	}
	if f.cursor < 0 {
		f.cursor = 0
	}
	if f.cursor > f.len {
		f.cursor = f.len
	}
	for i := f.len; i > f.cursor; i -= 1 {
		f.buf[i] = f.buf[i - 1]
	}
	f.buf[f.cursor] = c
	f.cursor += 1
	f.len += 1
	return true
}

insert_str :: proc(f: ^Field, s: string) -> int {
	inserted := 0
	for i in 0 ..< len(s) {
		if insert_byte(f, s[i]) {
			inserted += 1
		}
	}
	return inserted
}

backspace :: proc(f: ^Field) -> bool {
	if f.cursor <= 0 || f.len == 0 {
		return false
	}
	for i := f.cursor - 1; i < f.len - 1; i += 1 {
		f.buf[i] = f.buf[i + 1]
	}
	f.cursor -= 1
	f.len -= 1
	return true
}

delete_forward :: proc(f: ^Field) -> bool {
	if f.cursor >= f.len {
		return false
	}
	for i := f.cursor; i < f.len - 1; i += 1 {
		f.buf[i] = f.buf[i + 1]
	}
	f.len -= 1
	return true
}

move_left :: proc(f: ^Field) {
	if f.cursor > 0 {
		f.cursor -= 1
	}
}

move_right :: proc(f: ^Field) {
	if f.cursor < f.len {
		f.cursor += 1
	}
}

move_home :: proc(f: ^Field) {
	f.cursor = 0
}

move_end :: proc(f: ^Field) {
	f.cursor = f.len
}
