package main

import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"
import "textfield"

Status_Kind :: enum {
	Info,
	Error,
	Ok,
}

Focus :: enum {
	None,
	Url,
	Dir,
	Limit,
}

App :: struct {
	cfg:         Config,
	url:         textfield.Field,
	dir:         textfield.Field,
	limit:       textfield.Field,
	focus:       Focus,
	dl:          Download,
	percent:     f32,
	status:      [300]u8,
	status_kind: Status_Kind,
	repeat:      Repeat_State,
}

buf_to_string :: proc(b: []u8) -> string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n += 1
	}
	return string(b[:n])
}

buf_set :: proc(b: []u8, s: string) {
	n := len(s)
	if n > len(b) - 1 {
		n = len(b) - 1
	}
	if n < 0 {
		n = 0
	}
	for i in 0 ..< n {
		b[i] = s[i]
	}
	if len(b) > 0 {
		b[n] = 0
	}
}

set_status :: proc(app: ^App, s: string, kind: Status_Kind = .Info) {
	buf_set(app.status[:], s)
	app.status_kind = kind
}

set_dir :: proc(app: ^App, dir: string) {
	textfield.set(&app.dir, dir)
	config_set_last_dir(&app.cfg, dir)
}

start_download :: proc(app: ^App) {
	url := textfield.value(&app.url)
	dir := textfield.value(&app.dir)
	lim := textfield.value(&app.limit)

	switch {
	case len(url) == 0:
		set_status(app, "Paste a YouTube URL first.", .Error)
		return
	case len(dir) == 0:
		set_status(app, "Choose a save folder first.", .Error)
		return
	case os.make_directory_all(dir) != nil:
		set_status(app, "Cannot create that folder. Check the drive exists.", .Error)
		return
	}

	limit_mbit: f32 = 0
	limit_bytes := 0
	if len(lim) > 0 {
		v, ok := strconv.parse_f32(lim)
		if !ok || v < 0 {
			set_status(app, "Speed limit must be a number in Mbit/s. 0 = unlimited.", .Error)
			return
		}
		limit_mbit = v
		// Mbit/s -> bytes/s. yt-dlp's own M suffix is mebibytes, so we always
		// pass raw bytes to avoid a 8x-understood-as-1024 mixup.
		limit_bytes = int(v * 1_000_000.0 / 8.0)
	}

	config_set_limit(&app.cfg, limit_mbit)
	config_set_last_dir(&app.cfg, dir)

	app.percent = 0
	if limit_bytes > 0 {
		set_status(app, "Starting yt-dlp...", .Info)
	} else {
		set_status(app, "Starting yt-dlp (no speed limit)...", .Info)
	}
	download_start(&app.dl, dir, url, limit_bytes)
}

drain :: proc(app: ^App) {
	for {
		ev, ok := download_pop(&app.dl)
		if !ok {
			break
		}
		switch ev.kind {
		case .Progress:
			app.percent = ev.percent
			set_status(app, ev.text, .Info)
		case .Stage:
			set_status(app, ev.text, .Info)
		case .Done:
			app.percent = 100
			set_status(app, ev.text, .Ok)
		case .Failed:
			set_status(app, ev.text, .Error)
		case .Meta, .Log:
			// Metadata becomes the filename; raw logs stay hidden.
		}
		delete(ev.text)
	}
}

draw_ui :: proc(app: ^App) {
	title_col := rl.Color{232, 232, 240, 255}
	label_col := rl.Color{140, 140, 152, 255}
	dim_col := rl.Color{100, 100, 112, 255}

	url_rec := rl.Rectangle{24, 84, 712, 36}
	dir_rec := rl.Rectangle{24, 160, 560, 36}
	browse_rec := rl.Rectangle{596, 160, 140, 36}
	dl_rec := rl.Rectangle{24, 212, 170, 40}
	limit_rec := rl.Rectangle{322, 212, 80, 40}

	mouse := rl.GetMousePosition()
	if rl.IsMouseButtonPressed(.LEFT) {
		switch {
		case rl.CheckCollisionPointRec(mouse, url_rec):
			app.focus = .Url
			app.repeat.active = false
		case rl.CheckCollisionPointRec(mouse, dir_rec):
			app.focus = .Dir
			app.repeat.active = false
		case rl.CheckCollisionPointRec(mouse, limit_rec):
			app.focus = .Limit
			app.repeat.active = false
		case rl.CheckCollisionPointRec(mouse, browse_rec), rl.CheckCollisionPointRec(mouse, dl_rec):
			// Buttons handle their own clicks.
		case:
			app.focus = .None
		}
	}

	keys := collect_keys()
	if keys.tab {
		switch app.focus {
		case .None, .Limit:
			app.focus = .Url
		case .Url:
			app.focus = .Dir
		case .Dir:
			app.focus = .Limit
		}
		app.repeat.active = false
	}
	if keys.esc {
		app.focus = .None
		app.repeat.active = false
	}

	switch app.focus {
	case .Url:
		handle_text_input(&app.url, keys, &app.repeat)
	case .Dir:
		handle_text_input(&app.dir, keys, &app.repeat)
	case .Limit:
		handle_text_input(&app.limit, keys, &app.repeat)
	case .None:
	}

	if keys.enter && app.focus != .None && !download_is_running(&app.dl) {
		start_download(app)
	}

	rl.DrawText("vibetube", 24, 14, 30, title_col)

	rl.DrawText("YouTube URL", 24, 60, 20, label_col)
	draw_text_field(&app.url, url_rec, app.focus == .Url)

	rl.DrawText("Save to", 24, 136, 20, label_col)
	draw_text_field(&app.dir, dir_rec, app.focus == .Dir)

	if rl.GuiButton(browse_rec, "Browse...") {
		if path, ok := pick_folder(); ok {
			set_dir(app, path)
			delete(path)
		}
	}

	running := download_is_running(&app.dl)
	if running {
		rl.GuiDisable()
	}
	clicked := rl.GuiButton(dl_rec, "Download")
	if running {
		rl.GuiEnable()
	}
	if clicked && !running {
		start_download(app)
	}

	rl.DrawText("Speed limit", 210, 224, 20, label_col)
	draw_text_field(&app.limit, limit_rec, app.focus == .Limit)
	rl.DrawText("Mbit/s", 412, 224, 20, label_col)
	rl.DrawText("0 = unlimited", 486, 228, 16, dim_col)

	rl.GuiProgressBar(rl.Rectangle{24, 272, 712, 28}, "", "", &app.percent, 0, 100)

	col := rl.Color{200, 200, 210, 255}
	switch app.status_kind {
	case .Ok:
		col = rl.Color{120, 210, 130, 255}
	case .Error:
		col = rl.Color{235, 110, 110, 255}
	case .Info:
		col = rl.Color{200, 200, 210, 255}
	}
	draw_clipped(buf_to_string(app.status[:]), 24, 314, 18, WINDOW_W - 48, col)
}

// Draws `text` at `size`, trimming it with an ellipsis so it never runs past
// `max_w`. Binary search keeps this to a handful of MeasureText calls.
draw_clipped :: proc(text: string, x, y, size: i32, max_w: i32, color: rl.Color) {
	if len(text) == 0 {
		return
	}

	buf: [512]u8
	buf_set(buf[:], text)

	if rl.MeasureText(cast(cstring)&buf[0], size) <= max_w {
		rl.DrawText(cast(cstring)&buf[0], x, y, size, color)
		return
	}

	lo := 0
	hi := len(text)
	best := 0
	for lo <= hi {
		mid := (lo + hi) / 2
		tmp: [512]u8
		k := 0
		for i in 0 ..< mid {
			tmp[i] = buf[i]
			k = i + 1
		}
		tmp[k] = '.'
		tmp[k + 1] = '.'
		tmp[k + 2] = '.'
		tmp[k + 3] = 0
		if rl.MeasureText(cast(cstring)&tmp[0], size) <= max_w {
			best = mid
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}

	out: [512]u8
	k := 0
	for i in 0 ..< best {
		out[i] = buf[i]
		k = i + 1
	}
	out[k] = '.'
	out[k + 1] = '.'
	out[k + 2] = '.'
	out[k + 3] = 0
	rl.DrawText(cast(cstring)&out[0], x, y, size, color)
}
