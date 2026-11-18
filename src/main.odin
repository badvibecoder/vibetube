package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"
import win32 "core:sys/windows"
import "textfield"

WINDOW_W :: 760
WINDOW_H :: 420

VERSION :: "1.0"
WINDOW_TITLE :: "vibetube - v" + VERSION

// Icons are embedded in the binary, so the app stays a single file with no
// asset folder to ship. Sizes match what Windows asks for: title bar, taskbar
// and Alt-Tab each get a real bitmap instead of one badly rescaled one.
icon16 :: #load("../assets/icon16.png")
icon24 :: #load("../assets/icon24.png")
icon32 :: #load("../assets/icon32.png")
icon48 :: #load("../assets/icon48.png")
icon64 :: #load("../assets/icon64.png")

apply_window_icons :: proc() {
	sources := [5][]u8{icon16, icon24, icon32, icon48, icon64}
	images: [5]rl.Image
	count := 0
	for src in sources {
		img := rl.LoadImageFromMemory(".png", raw_data(src), i32(len(src)))
		if rl.IsImageValid(img) {
			images[count] = img
			count += 1
		} else {
			rl.UnloadImage(img)
		}
	}
	if count > 0 {
		rl.SetWindowIcons(cast([^]rl.Image)&images[0], i32(count))
	}
	for i in 0 ..< count {
		rl.UnloadImage(images[i])
	}
}

mbit_to_bytes :: proc(mbit: f32) -> int {
	if mbit <= 0 {
		return 0
	}
	// Mbit/s -> bytes/s. Deliberately raw bytes: yt-dlp's M suffix is
	// mebibytes, which would silently mean 8.4x more traffic.
	return int(mbit * 1_000_000.0 / 8.0)
}

main :: proc() {
	win32.CoInitializeEx(nil, win32.COINIT.APARTMENTTHREADED)
	defer win32.CoUninitialize()

	// The child inherits this process' environment. Force UTF-8 so non-ASCII
	// titles survive the pipe (Python would otherwise use the ANSI codepage).
	_ = os.set_env("PYTHONUTF8", "1")
	_ = os.set_env("PYTHONIOENCODING", "utf-8")

	args := os.args

	// Dev-only entry points, used by the self test. Not part of the UI.
	selftest := false
	selftest_url := ""
	selftest_dir := ""
	demo_url := ""
	demo_dir := ""
	shot := ""
	fill := ""
	limit_arg := ""

	i := 1
	for i < len(args) {
		switch args[i] {
		case "--selftest":
			selftest = true
			i += 1
			if i < len(args) {
				selftest_url = args[i]
			}
			i += 1
			if i < len(args) {
				selftest_dir = args[i]
			}
		case "--demo":
			i += 1
			if i < len(args) {
				demo_url = args[i]
			}
			i += 1
			if i < len(args) {
				demo_dir = args[i]
			}
		case "--shot":
			i += 1
			if i < len(args) {
				shot = args[i]
			}
		case "--fill":
			i += 1
			if i < len(args) {
				fill = args[i]
			}
		case "--limit":
			i += 1
			if i < len(args) {
				limit_arg = args[i]
			}
		case:
		}
		i += 1
	}

	if selftest {
		limit_bytes := 0
		if len(limit_arg) > 0 {
			if v, ok := strconv.parse_f32(limit_arg); ok {
				limit_bytes = mbit_to_bytes(v)
			}
		}
		run_selftest(selftest_url, selftest_dir, limit_bytes)
		return
	}

	app: App
	app.cfg = config_load()
	textfield.set(&app.dir, app.cfg.last_dir)
	lim_str := fmt.aprintf("%v", app.cfg.limit_mbit)
	textfield.set(&app.limit, lim_str)
	delete(lim_str)
	if len(limit_arg) > 0 {
		textfield.set(&app.limit, limit_arg)
	}
	set_status(&app, "Paste a URL, choose a folder, then press Download.", .Info)

	if len(fill) > 0 {
		textfield.set(&app.url, fill)
		app.focus = .Url
	}

	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(WINDOW_W, WINDOW_H, WINDOW_TITLE)
	defer rl.CloseWindow()
	apply_window_icons()
	rl.SetTargetFPS(60)

	if len(demo_url) > 0 {
		textfield.set(&app.url, demo_url)
		textfield.set(&app.dir, demo_dir)
		start_download(&app)
	}

	frame := 0
	for !rl.WindowShouldClose() {
		drain(&app)

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{22, 22, 26, 255})
		draw_ui(&app)
		rl.EndDrawing()

		frame += 1

		if len(demo_url) > 0 {
			if frame > 2 && !download_is_running(&app.dl) {
				// The worker may have pushed its final events after the drain
				// at the top of this frame; pick them up before we paint.
				drain(&app)
				if len(shot) > 0 {
					capture_frame(&app, shot)
				}
				break
			}
		} else if len(shot) > 0 && frame >= 3 {
			capture_frame(&app, shot)
			break
		}
	}

	// Closing the window must not leave an orphaned yt-dlp behind.
	if download_is_running(&app.dl) {
		download_cancel(&app.dl)
	}
	config_save(&app.cfg)
}

// Renders the UI into a render texture and exports it. Drawing to a texture
// flushes the command batch deterministically, which a window framebuffer read
// mid-frame does not.
capture_frame :: proc(app: ^App, path: string) {
	rt := rl.LoadRenderTexture(WINDOW_W, WINDOW_H)
	defer rl.UnloadRenderTexture(rt)

	rl.BeginTextureMode(rt)
	rl.ClearBackground(rl.Color{22, 22, 26, 255})
	draw_ui(app)
	rl.EndTextureMode()

	img := rl.LoadImageFromTexture(rt.texture)
	defer rl.UnloadImage(img)
	rl.ImageFlipVertical(&img)

	pb: [300]u8
	buf_set(pb[:], path)
	_ = rl.ExportImage(img, cast(cstring)&pb[0])
}

// Headless end-to-end run of the real download pipeline.
// Usage: vibetube-dev.exe --selftest <url> <outdir> [--limit <mbit>]
run_selftest :: proc(url, dir: string, limit_bytes: int) {
	fmt.printfln("selftest url   : %s", url)
	fmt.printfln("selftest outdir: %s", dir)
	if limit_bytes > 0 {
		fmt.printfln("speed limit    : %d bytes/s (%.2f Mbit/s)", limit_bytes, f64(limit_bytes) * 8.0 / 1_000_000.0)
	} else {
		fmt.printfln("speed limit    : none")
	}

	if os.make_directory_all(dir) != nil {
		fmt.printfln("selftest FAILED: cannot create output directory")
		os.exit(1)
	}

	d: Download
	d.dir = strings.clone(dir)
	d.url = strings.clone(url)
	d.limit_bytes = limit_bytes
	_worker(&d)

	ok := false
	for {
		ev, had := download_pop(&d)
		if !had {
			break
		}
		switch ev.kind {
		case .Progress:
			fmt.printfln("progress %5.1f%%  %s", ev.percent, ev.text)
		case .Done:
			fmt.printfln("DONE     %s", ev.text)
			ok = true
		case .Failed:
			fmt.printfln("FAILED   %s", ev.text)
		case .Meta, .Stage, .Log:
			fmt.printfln("event    %v  %s", ev.kind, ev.text)
		}
		delete(ev.text)
	}

	if !ok {
		os.exit(1)
	}
}
