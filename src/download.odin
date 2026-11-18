package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import "naming"

// Runs yt-dlp in a worker thread and streams line-based events to the UI.
//
// yt-dlp is invoked with -o "%(id)s.%(ext)s" so the file it writes is always
// an ASCII video id; the human-readable filename is built by `naming` and the
// file is renamed once yt-dlp exits cleanly. Nothing unicode ever reaches a
// command line, and no regex/sanitising is delegated to yt-dlp.

Event_Kind :: enum {
	Meta,
	Progress,
	Stage,
	Log,
	Done,
	Failed,
}

Event :: struct {
	kind:    Event_Kind,
	percent: f32,
	text:    string, // owned
}

Download :: struct {
	mu:         sync.Mutex,
	events:     [dynamic]Event,
	running:    bool,
	cancelled:  bool,
	child:      os.Process,
	has_child:  bool,
	thread:     ^thread.Thread,
	dir:        string, // owned
	url:        string, // owned
	video_id:   string, // owned
	channel:    string, // owned
	title:      string, // owned
	last_error: string, // owned
	limit_bytes: int, // --limit-rate value; 0 = unlimited
}

MAX_EVENTS :: 256

download_start :: proc(d: ^Download, dir, url: string, limit_bytes: int) -> bool {
	sync.lock(&d.mu)
	if d.running {
		sync.unlock(&d.mu)
		return false
	}
	d.running = true
	d.cancelled = false
	d.limit_bytes = limit_bytes
	sync.unlock(&d.mu)

	delete(d.dir)
	delete(d.url)
	d.dir = strings.clone(dir)
	d.url = strings.clone(url)

	if d.thread != nil {
		thread.destroy(d.thread)
		d.thread = nil
	}
	d.thread = thread.create_and_start_with_data(d, _thread_entry)
	return true
}

download_is_running :: proc(d: ^Download) -> bool {
	sync.lock(&d.mu)
	defer sync.unlock(&d.mu)
	return d.running
}

download_cancel :: proc(d: ^Download) {
	sync.lock(&d.mu)
	d.cancelled = true
	child := d.child
	has_child := d.has_child
	sync.unlock(&d.mu)

	if has_child {
		_ = os.process_kill(child)
	}
}

download_pop :: proc(d: ^Download) -> (Event, bool) {
	sync.lock(&d.mu)
	defer sync.unlock(&d.mu)
	if len(d.events) == 0 {
		return Event{}, false
	}
	ev := d.events[0]
	ordered_remove(&d.events, 0)
	return ev, true
}

_push :: proc(d: ^Download, ev: Event) {
	sync.lock(&d.mu)
	defer sync.unlock(&d.mu)

	// Collapse progress updates: only the newest one matters.
	if ev.kind == .Progress {
		for i := len(d.events) - 1; i >= 0; i -= 1 {
			if d.events[i].kind == .Progress {
				delete(d.events[i].text)
				d.events[i] = ev
				return
			}
		}
	}

	if len(d.events) >= MAX_EVENTS {
		old := d.events[0]
		ordered_remove(&d.events, 0)
		delete(old.text)
	}
	append(&d.events, ev)
}

_fail :: proc(d: ^Download, msg: string) {
	_push(d, Event{kind = .Failed, text = strings.clone(msg)})
	sync.lock(&d.mu)
	d.running = false
	sync.unlock(&d.mu)
}

_finish_ok :: proc(d: ^Download, msg: string) {
	_push(d, Event{kind = .Done, text = fmt.aprintf("%s", msg)})
	sync.lock(&d.mu)
	d.running = false
	sync.unlock(&d.mu)
}

_thread_entry :: proc(data: rawptr) {
	_worker(cast(^Download)data)
}

_worker :: proc(d: ^Download) {
	dir := d.dir
	url := d.url

	cmd := make([dynamic]string, 0, 24, context.allocator)
	defer delete(cmd)
	append(&cmd, "yt-dlp")
	append(&cmd, "-f", "ba/b")
	append(&cmd, "-x")
	append(&cmd, "--audio-format", "mp3")
	append(&cmd, "--audio-quality", "160K")
	append(&cmd, "--no-playlist")
	append(&cmd, "--newline")
	append(&cmd, "--progress")
	append(&cmd, "--no-simulate")
	append(&cmd, "--print", "META-ID:%(id)s")
	append(&cmd, "--print", "META-CHANNEL:%(channel)s")
	append(&cmd, "--print", "META-TITLE:%(title)s")
	append(&cmd, "-P", dir)
	append(&cmd, "-o", "%(id)s.%(ext)s")

	// Throttling: yt-dlp takes bytes/sec, and its "M" suffix is mebibytes,
	// so a limit of 16 megabits must be passed as 2000000, never as 16M.
	rate_buf: [32]u8
	if d.limit_bytes > 0 {
		rate := fmt.bprintf(rate_buf[:], "%d", d.limit_bytes)
		append(&cmd, "--limit-rate", rate)
	}

	append(&cmd, url)

	r, w, pipe_err := os.pipe()
	if pipe_err != nil {
		_fail(d, "Could not create a pipe for yt-dlp output.")
		return
	}

	// PYTHONUTF8 is set on this process in main, so the child inherits it.
	// spawn_hidden adds CREATE_NO_WINDOW so yt-dlp never flashes a console.
	child, started := spawn_hidden(cmd[:], w)
	os.close(w)
	if !started {
		os.close(r)
		_fail(d, "Could not start yt-dlp. Is it on PATH?")
		return
	}

	sync.lock(&d.mu)
	d.child = child
	d.has_child = true
	sync.unlock(&d.mu)

	buf: [8192]u8
	line: [4096]u8
	line_len := 0

	for {
		n, read_err := os.read(r, buf[:])
		if n > 0 {
			for i in 0 ..< n {
				c := buf[i]
				if c == '\n' {
					_process_line(d, string(line[:line_len]))
					line_len = 0
				} else if c != '\r' {
					if line_len < len(line) {
						line[line_len] = c
						line_len += 1
					}
				}
			}
		}
		if n == 0 || read_err != nil {
			break
		}
	}
	if line_len > 0 {
		_process_line(d, string(line[:line_len]))
	}
	os.close(r)

	sync.lock(&d.mu)
	d.has_child = false
	cancelled := d.cancelled
	sync.unlock(&d.mu)

	state, _ := os.process_wait(child)

	if cancelled {
		_fail(d, "Cancelled.")
		return
	}
	if state.exit_code != 0 {
		sync.lock(&d.mu)
		err_text := d.last_error
		sync.unlock(&d.mu)
		if len(err_text) > 0 {
			_fail(d, strings.concatenate([]string{"yt-dlp failed: ", err_text}))
		} else {
			_fail(d, fmt.aprintf("yt-dlp failed with exit code %d.", state.exit_code))
		}
		return
	}

	sync.lock(&d.mu)
	video_id := d.video_id
	channel := d.channel
	title := d.title
	sync.unlock(&d.mu)

	if len(video_id) == 0 {
		_fail(d, "yt-dlp finished but returned no video id.")
		return
	}

	name_buf: [256]u8
	final := naming.build_filename(name_buf[:], channel, title)

	src := fmt.aprintf("%s\\%s.mp3", dir, video_id)
	dst := fmt.aprintf("%s\\%s", dir, final)
	rename_err := os.rename(src, dst)
	if rename_err != nil {
		_fail(d, fmt.aprintf("Downloaded as %s.mp3, but the rename failed.", video_id))
	} else {
		_finish_ok(d, fmt.aprintf("Saved: %s", final))
	}
	delete(src)
	delete(dst)
}

_process_line :: proc(d: ^Download, line: string) {
	if len(line) == 0 {
		return
	}

	switch {
	case strings.has_prefix(line, "META-ID:"):
		v := strings.trim_space(line[len("META-ID:"):])
		sync.lock(&d.mu)
		delete(d.video_id)
		d.video_id = strings.clone(v)
		sync.unlock(&d.mu)

	case strings.has_prefix(line, "META-CHANNEL:"):
		v := strings.trim_space(line[len("META-CHANNEL:"):])
		sync.lock(&d.mu)
		delete(d.channel)
		d.channel = strings.clone(v)
		sync.unlock(&d.mu)

	case strings.has_prefix(line, "META-TITLE:"):
		v := strings.trim_space(line[len("META-TITLE:"):])
		sync.lock(&d.mu)
		delete(d.title)
		d.title = strings.clone(v)
		sync.unlock(&d.mu)

	case strings.has_prefix(line, "[download]"):
		if pct, ok := _parse_percent(line); ok {
			text := strings.trim_space(line[len("[download]"):])
			_push(d, Event{kind = .Progress, percent = pct, text = strings.clone(text)})
		}

	case strings.has_prefix(line, "[ExtractAudio]"), strings.has_prefix(line, "[ffmpeg]"):
		_push(d, Event{kind = .Stage, text = strings.clone("Converting to mp3...")})

	case strings.has_prefix(line, "ERROR:"):
		err_text := strings.trim_space(line)
		_push(d, Event{kind = .Log, text = strings.clone(err_text)})
		sync.lock(&d.mu)
		delete(d.last_error)
		d.last_error = strings.clone(err_text)
		sync.unlock(&d.mu)
	}
}

_parse_percent :: proc(line: string) -> (value: f32, ok: bool) {
	pi := strings.index_byte(line, '%')
	if pi <= 0 {
		return 0, false
	}
	start := pi
	for start > 0 {
		c := line[start - 1]
		if (c >= '0' && c <= '9') || c == '.' {
			start -= 1
		} else {
			break
		}
	}
	if start == pi {
		return 0, false
	}
	v, parsed := strconv.parse_f32(line[start:pi])
	if !parsed {
		return 0, false
	}
	return v, true
}
