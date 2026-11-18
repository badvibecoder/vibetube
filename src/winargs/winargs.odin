package winargs

import "core:strings"

// Builds a Windows command line from argv.
//
// Windows hands a process one string, not an array, so the child re-splits it
// using CommandLineToArgvW rules. A path with a space ("C:\My Music") must be
// quoted and its backslashes escaped, or yt-dlp receives two arguments and
// silently downloads to the wrong place. Odin's os.process_start builds this
// string internally; we need our own so we can also pass CREATE_NO_WINDOW.

build :: proc(args: []string) -> string {
	buf: [dynamic]u8
	defer delete(buf)

	for arg, i in args {
		if i > 0 {
			append(&buf, ' ')
		}
		_append_arg(&buf, arg)
	}
	return strings.clone(string(buf[:]))
}

_append_arg :: proc(buf: ^[dynamic]u8, arg: string) {
	needs_quotes := len(arg) == 0
	if !needs_quotes {
		for i in 0 ..< len(arg) {
			c := arg[i]
			if c == ' ' || c == '\t' || c == '"' {
				needs_quotes = true
				break
			}
		}
	}

	if !needs_quotes {
		for i in 0 ..< len(arg) {
			append(buf, arg[i])
		}
		return
	}

	append(buf, '"')
	backslashes := 0
	for i in 0 ..< len(arg) {
		c := arg[i]
		if c == '\\' {
			backslashes += 1
			continue
		}
		if c == '"' {
			// Backslashes immediately before a quote are doubled, then the
			// quote itself is escaped.
			for _ in 0 ..< backslashes * 2 + 1 {
				append(buf, '\\')
			}
			append(buf, '"')
			backslashes = 0
			continue
		}
		for _ in 0 ..< backslashes {
			append(buf, '\\')
		}
		backslashes = 0
		append(buf, c)
	}
	// Backslashes immediately before the closing quote are doubled.
	for _ in 0 ..< backslashes * 2 {
		append(buf, '\\')
	}
	append(buf, '"')
}
