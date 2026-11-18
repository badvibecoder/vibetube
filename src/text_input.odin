package main

import rl "vendor:raylib"
import "textfield"

// Raylib glue for textfield.Field: drawing, caret, scrolling and key handling.
//
// Keys are taken from raylib's key *queue* (GetKeyPressed) rather than from
// IsKeyPressed, because IsKeyPressed samples state once per poll: a tap whose
// press and release both land inside one frame is invisible to it. The queue
// records every keydown, so nothing is missed.

FIELD_FONT :: 20
FIELD_PAD :: 10

REPEAT_DELAY :: 18
REPEAT_RATE :: 2
MAX_FRAME_KEYS :: 32

Repeat_State :: struct {
	active: bool,
	key:    rl.KeyboardKey,
	frames: int,
}

// Everything the OS delivered since the last frame.
Frame_Keys :: struct {
	list:  [MAX_FRAME_KEYS]rl.KeyboardKey,
	n:     int,
	ctrl:  bool,
	enter: bool,
	tab:   bool,
	esc:   bool,
}

collect_keys :: proc() -> Frame_Keys {
	k := Frame_Keys{}
	// Held state catches a chord that is still down at poll time.
	k.ctrl = rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)

	for {
		key := rl.GetKeyPressed()
		if key == .KEY_NULL {
			break
		}
		// The queue catches a chord that completed between two frames.
		if key == .LEFT_CONTROL || key == .RIGHT_CONTROL {
			k.ctrl = true
		}
		if key == .ENTER {
			k.enter = true
		}
		if key == .TAB {
			k.tab = true
		}
		if key == .ESCAPE {
			k.esc = true
		}
		if k.n < MAX_FRAME_KEYS {
			k.list[k.n] = key
			k.n += 1
		}
	}
	return k
}

_as_cstring :: proc(s: string, buf: []u8) -> cstring {
	n := len(s)
	if n > len(buf) - 1 {
		n = len(buf) - 1
	}
	for i in 0 ..< n {
		buf[i] = s[i]
	}
	buf[n] = 0
	return cast(cstring)&buf[0]
}

draw_text_field :: proc(f: ^textfield.Field, rec: rl.Rectangle, focused: bool) {
	bg := rl.Color{30, 30, 36, 255}
	border := rl.Color{70, 70, 82, 255}
	if focused {
		bg = rl.Color{38, 38, 46, 255}
		border = rl.Color{120, 170, 240, 255}
	}
	rl.DrawRectangleRec(rec, bg)
	rl.DrawRectangleLinesEx(rec, 1, border)

	inner := rl.Rectangle{rec.x + FIELD_PAD, rec.y + 4, rec.width - FIELD_PAD * 2, rec.height - 8}
	text := textfield.value(f)

	prefix_buf: [textfield.MAX + 8]u8
	cursor_x := f32(rl.MeasureText(_as_cstring(text[:f.cursor], prefix_buf[:]), FIELD_FONT))

	// Keep the caret inside the visible area.
	if cursor_x - f.scroll > inner.width - 6 {
		f.scroll = cursor_x - (inner.width - 6)
	}
	if cursor_x - f.scroll < 0 {
		f.scroll = cursor_x
	}
	if f.scroll < 0 {
		f.scroll = 0
	}

	rl.BeginScissorMode(i32(inner.x), i32(inner.y), i32(inner.width), i32(inner.height))
	text_buf: [textfield.MAX + 8]u8
	rl.DrawText(
		_as_cstring(text, text_buf[:]),
		i32(inner.x - f.scroll),
		i32(inner.y + 2),
		FIELD_FONT,
		rl.Color{226, 226, 234, 255},
	)
	rl.EndScissorMode()

	if focused {
		rl.DrawRectangle(
			i32(inner.x + cursor_x - f.scroll),
			i32(inner.y + 3),
			2,
			i32(inner.height - 6),
			rl.Color{130, 180, 250, 255},
		)
	}
}

handle_text_input :: proc(f: ^textfield.Field, keys: Frame_Keys, rep: ^Repeat_State) {
	// Printable ASCII from the character queue; pastes may carry UTF-8 bytes.
	for {
		c := rl.GetCharPressed()
		if c == 0 {
			break
		}
		if c >= 32 && c < 127 {
			_ = textfield.insert_byte(f, u8(c))
		}
	}

	if keys.ctrl {
		for i in 0 ..< keys.n {
			if keys.list[i] == .V {
				if clip := rl.GetClipboardText(); clip != nil {
					_ = textfield.insert_str(f, string(clip))
				}
			}
		}
	}

	for i in 0 ..< keys.n {
		#partial switch keys.list[i] {
		case .BACKSPACE:
			_ = textfield.backspace(f)
			_rep_begin(rep, .BACKSPACE)
		case .DELETE:
			_ = textfield.delete_forward(f)
			_rep_begin(rep, .DELETE)
		case .LEFT:
			textfield.move_left(f)
			_rep_begin(rep, .LEFT)
		case .RIGHT:
			textfield.move_right(f)
			_rep_begin(rep, .RIGHT)
		case .HOME:
			textfield.move_home(f)
			rep.active = false
		case .END:
			textfield.move_end(f)
			rep.active = false
		}
	}

	// Auto-repeat while a movement/delete key stays held.
	if rep.active {
		if rl.IsKeyDown(rep.key) {
			rep.frames += 1
			if rep.frames > REPEAT_DELAY && (rep.frames - REPEAT_DELAY) % REPEAT_RATE == 0 {
				#partial switch rep.key {
				case .BACKSPACE:
					_ = textfield.backspace(f)
				case .DELETE:
					_ = textfield.delete_forward(f)
				case .LEFT:
					textfield.move_left(f)
				case .RIGHT:
					textfield.move_right(f)
				}
			}
		} else {
			rep.active = false
			rep.frames = 0
		}
	}
}

_rep_begin :: proc(rep: ^Repeat_State, key: rl.KeyboardKey) {
	rep.active = true
	rep.key = key
	rep.frames = 0
}
