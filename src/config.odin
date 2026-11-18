package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win32 "core:sys/windows"

// Per-user configuration, stored at:
//   %LOCALAPPDATA%\vibetube\config.ini
//
// Local (not Roaming) because the values are machine-specific: an absolute
// download path, and a speed limit chosen for this connection.

CONFIG_SUBDIR :: "vibetube"
CONFIG_FILENAME :: "config.ini"
KEY_LAST_DIR :: "paths.last_dir"
KEY_LIMIT_MBIT :: "download.limit_mbit"

DEFAULT_LIMIT_MBIT :: 16.0

Config :: struct {
	dir:        string, // owned, %LOCALAPPDATA%\vibetube
	file:       string, // owned, full path to config.ini
	last_dir:   string, // owned, last download folder
	limit_mbit: f32, // download cap in megabits/sec, 0 = unlimited
	loaded:     bool, // config.ini existed when we started
}

config_load :: proc() -> Config {
	c := Config{}
	c.limit_mbit = DEFAULT_LIMIT_MBIT

	base := _known_folder(win32.FOLDERID_LocalAppData)
	owns_base := true
	if len(base) == 0 {
		base = "."
		owns_base = false
	}
	if owns_base {
		defer delete(base)
	}

	c.dir = fmt.aprintf("%s\\%s", base, CONFIG_SUBDIR)
	_ = os.make_directory_all(c.dir)
	c.file = fmt.aprintf("%s\\%s", c.dir, CONFIG_FILENAME)

	found_dir := false
	found_limit := false

	data, read_err := os.read_entire_file_from_path(c.file, context.allocator)
	if read_err == nil {
		c.loaded = true
		lines := strings.split_lines(string(data))
		for line in lines {
			l := strings.trim_space(line)
			if len(l) == 0 || l[0] == ';' || l[0] == '#' {
				continue
			}
			eq := strings.index_byte(l, '=')
			if eq <= 0 {
				continue
			}
			key := strings.trim_space(l[:eq])
			val := strings.trim_space(l[eq + 1:])
			switch key {
			case KEY_LAST_DIR:
				if len(val) > 0 {
					delete(c.last_dir)
					c.last_dir = strings.clone(val)
					found_dir = true
				}
			case KEY_LIMIT_MBIT:
				if v, ok := strconv.parse_f32(val); ok && v >= 0 {
					c.limit_mbit = v
					found_limit = true
				}
			}
		}
		delete(lines)
		delete(data)
	}

	if len(c.last_dir) == 0 {
		c.last_dir = _default_download_dir()
	}

	// Create the file on first run, and repair it if a key was missing.
	if !c.loaded || !found_dir || !found_limit {
		config_save(&c)
	}

	return c
}

config_save :: proc(c: ^Config) {
	if c == nil || len(c.file) == 0 {
		return
	}
	content := fmt.aprintf(
		"; vibetube configuration - created automatically, safe to edit by hand.\r\n" +
		"; Delete this file to reset everything to defaults.\r\n" +
		"; download.limit_mbit is in megabits per second; 0 means unlimited.\r\n" +
		"\r\n%s=%s\r\n%s=%v\r\n",
		KEY_LAST_DIR,
		c.last_dir,
		KEY_LIMIT_MBIT,
		c.limit_mbit,
	)
	tmp := fmt.aprintf("%s.tmp", c.file)
	if os.write_entire_file(tmp, transmute([]byte)content) == nil {
		_ = os.rename(tmp, c.file)
	}
	delete(tmp)
	delete(content)
}

config_set_last_dir :: proc(c: ^Config, dir: string) {
	if c == nil {
		return
	}
	if c.last_dir == dir {
		return
	}
	delete(c.last_dir)
	c.last_dir = strings.clone(dir)
	config_save(c)
}

config_set_limit :: proc(c: ^Config, mbit: f32) {
	if c == nil {
		return
	}
	if c.limit_mbit == mbit {
		return
	}
	c.limit_mbit = mbit
	config_save(c)
}

_default_download_dir :: proc() -> string {
	base := _known_folder(win32.FOLDERID_Downloads)
	if len(base) == 0 {
		return ""
	}
	defer delete(base)
	return fmt.aprintf("%s\\%s", base, CONFIG_SUBDIR)
}

// Resolves a known folder to a UTF-8 path. Returns "" on failure.
_known_folder :: proc(rfid: win32.GUID) -> string {
	id := rfid
	p: win32.LPWSTR
	if win32.SHGetKnownFolderPath(&id, 0, nil, &p) != 0 || p == nil {
		return ""
	}
	defer win32.CoTaskMemFree(p)

	ws := cast([^]u16)p
	n := 0
	for ws[n] != 0 {
		n += 1
	}
	if n == 0 {
		return ""
	}
	s, _ := win32.utf16_to_utf8_alloc(ws[:n], context.allocator)
	return s
}
