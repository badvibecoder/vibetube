package main

import win32 "core:sys/windows"

// Native Windows folder picker (IFileOpenDialog with FOS_PICKFOLDERS).
// Returns an owned UTF-8 string and true when the user picked a folder.
pick_folder :: proc() -> (path: string, ok: bool) {
	pfd: ^win32.IFileOpenDialog = nil
	hr := win32.CoCreateInstance(
		win32.CLSID_FileOpenDialog,
		nil,
		win32.CLSCTX_INPROC_SERVER,
		win32.IID_IFileOpenDialog,
		cast(^win32.LPVOID)&pfd,
	)
	if hr != 0 || pfd == nil {
		return "", false
	}
	defer _release(cast(^win32.IUnknown)pfd)

	dialog := cast(^win32.IFileDialog)pfd

	opts: win32.FILEOPENDIALOGOPTIONS
	if dialog.Vtbl.GetOptions(dialog, &opts) != 0 {
		return "", false
	}
	opts |= win32.FOS_PICKFOLDERS | win32.FOS_FORCEFILESYSTEM | win32.FOS_PATHMUSTEXIST
	if dialog.Vtbl.SetOptions(dialog, opts) != 0 {
		return "", false
	}
	_ = dialog.Vtbl.SetTitle(dialog, cast(win32.LPCWSTR)"Choose where to save downloads")

	if dialog.Vtbl.Show(dialog, nil) != 0 {
		return "", false
	}

	item: ^win32.IShellItem = nil
	if dialog.Vtbl.GetResult(dialog, &item) != 0 || item == nil {
		return "", false
	}
	defer _release(cast(^win32.IUnknown)item)

	name: win32.LPWSTR
	if item.Vtbl.GetDisplayName(item, .FILESYSPATH, &name) != 0 || name == nil {
		return "", false
	}
	defer win32.CoTaskMemFree(name)

	ws := cast([^]u16)name
	n := 0
	for ws[n] != 0 {
		n += 1
	}
	if n == 0 {
		return "", false
	}
	s, _ := win32.utf16_to_utf8_alloc(ws[:n], context.allocator)
	return s, true
}

_release :: proc(p: ^win32.IUnknown) {
	if p != nil {
		p.Release(p)
	}
}
