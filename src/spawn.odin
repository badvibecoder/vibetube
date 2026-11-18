package main

import "core:os"
import win32 "core:sys/windows"
import "winargs"

// Starts a child process with CREATE_NO_WINDOW.
//
// os.process_start cannot be used: it hardcodes CREATE_UNICODE_ENVIRONMENT |
// NORMAL_PRIORITY_CLASS, with no way to add flags. A windowed app spawning a
// console program (yt-dlp) without CREATE_NO_WINDOW makes Windows allocate the
// child its own console window - the cmd box that pops up behind the GUI.
//
// stdout and stderr are both redirected to `stdout`, so the child's output
// arrives over the single pipe the caller already reads.

spawn_hidden :: proc(command: []string, stdout: ^os.File) -> (process: os.Process, ok: bool) {
	cmd_line := winargs.build(command)
	defer delete(cmd_line)

	// Heap, not temp_allocator: this runs on the worker thread, where there is
	// no per-frame temp guard to reset the ring.
	cmd_line_w := win32.utf8_to_utf16_alloc(cmd_line, context.allocator)
	defer delete(cmd_line_w)
	if len(cmd_line_w) == 0 {
		return {}, false
	}

	nul := win32.CreateFileW(
		win32.L("NUL"),
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		&win32.SECURITY_ATTRIBUTES {
			nLength        = size_of(win32.SECURITY_ATTRIBUTES),
			bInheritHandle = true,
		},
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if nul == win32.INVALID_HANDLE_VALUE {
		return {}, false
	}
	defer win32.CloseHandle(nul)

	write_handle := win32.HANDLE(os.fd(stdout))

	si := win32.STARTUPINFOW {
		cb          = size_of(win32.STARTUPINFOW),
		dwFlags     = win32.STARTF_USESTDHANDLES | win32.STARTF_USESHOWWINDOW,
		wShowWindow = 0, // SW_HIDE, belts and braces alongside CREATE_NO_WINDOW
		hStdInput   = nul,
		hStdOutput  = write_handle,
		hStdError   = write_handle,
	}

	pi: win32.PROCESS_INFORMATION
	started := win32.CreateProcessW(
		nil,
		cast(cstring16)raw_data(cmd_line_w),
		nil,
		nil,
		true,
		win32.CREATE_UNICODE_ENVIRONMENT | win32.CREATE_NO_WINDOW | win32.NORMAL_PRIORITY_CLASS,
		nil, // inherit this process' environment
		nil,
		&si,
		&pi,
	)
	if !started {
		return {}, false
	}
	if pi.hThread != nil {
		win32.CloseHandle(pi.hThread)
	}

	return os.Process{pid = int(pi.dwProcessId), handle = uintptr(pi.hProcess)}, true
}
