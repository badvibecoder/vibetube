package naming

import "core:unicode"

// Filename policy for vibetube.
//
// Everything that is not an ASCII letter, digit, '-' or '_' collapses to a
// single '_'. Non-ASCII runes are transliterated where a sane Latin mapping
// exists (Café -> Cafe), otherwise dropped. The result is pure ASCII and safe
// on every filesystem we care about.

FILENAME_MAX :: 180
SUFFIX :: "_160k.mp3"

// Writes the sanitised form of `s` into `dst` and returns the byte count.
// The output never contains anything outside [A-Za-z0-9_-].
sanitize_into :: proc(dst: []u8, s: string, max_len: int) -> int {
	budget := max_len
	if budget > len(dst) {
		budget = len(dst)
	}
	if budget <= 0 {
		return 0
	}

	n := 0
	pending_sep := false

	for r in s {
		if r < 0x80 {
			c := u8(r)
			keep := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
			if !keep {
				pending_sep = true
				continue
			}
			if pending_sep && n > 0 && n < budget {
				dst[n] = '_'
				n += 1
			}
			pending_sep = false
			if n < budget {
				dst[n] = c
				n += 1
			}
			continue
		}

		a := _accent(r)
		if len(a) == 0 {
			pending_sep = true
			continue
		}
		if pending_sep && n > 0 && n < budget {
			dst[n] = '_'
			n += 1
		}
		pending_sep = false
		for i in 0 ..< len(a) {
			if n >= budget {
				break
			}
			dst[n] = a[i]
			n += 1
		}
	}

	for n > 0 && dst[n - 1] == '_' {
		n -= 1
	}
	return n
}

// Builds "<channel>_<title>_160k.mp3" in `dst` and returns it.
// Falls back to "unknown_160k.mp3" when neither field survives sanitising.
build_filename :: proc(dst: []u8, channel, title: string) -> string {
	tmp: [512]u8
	budget := FILENAME_MAX - len(SUFFIX)

	n := 0

	cn := sanitize_into(tmp[n:], channel, budget)
	n += cn

	if cn > 0 && n < budget {
		tmp[n] = '_'
		n += 1
	}

	tn := sanitize_into(tmp[n:], title, budget - n)
	n += tn

	for n > 0 && tmp[n - 1] == '_' {
		n -= 1
	}

	if n == 0 {
		_put(tmp[:], 0, "unknown")
		n = len("unknown")
	}

	if n + len(SUFFIX) > len(dst) {
		n = len(dst) - len(SUFFIX)
		for n > 0 && tmp[n - 1] == '_' {
			n -= 1
		}
	}

	for i in 0 ..< n {
		dst[i] = tmp[i]
	}
	_put(dst, n, SUFFIX)
	n += len(SUFFIX)

	return string(dst[:n])
}

_put :: proc(dst: []u8, at: int, s: string) -> int {
	i := at
	for k in 0 ..< len(s) {
		if i >= len(dst) {
			break
		}
		dst[i] = s[k]
		i += 1
	}
	return i
}

// Latin-1 / Latin Extended-A to ASCII. Returns "" when there is no mapping.
_accent :: proc(r: rune) -> string {
	lower := unicode.to_lower(r)
	upper := unicode.is_upper(r)

	switch lower {
	case 'à', 'á', 'â', 'ã', 'ä', 'å', 'ā', 'ă', 'ą':
		return upper ? "A" : "a"
	case 'ç', 'ć', 'ĉ', 'ċ', 'č':
		return upper ? "C" : "c"
	case 'ď', 'đ':
		return upper ? "D" : "d"
	case 'è', 'é', 'ê', 'ë', 'ē', 'ĕ', 'ė', 'ę', 'ě':
		return upper ? "E" : "e"
	case 'ğ', 'ĝ', 'ġ', 'ģ':
		return upper ? "G" : "g"
	case 'ì', 'í', 'î', 'ï', 'ī', 'ĭ', 'į', 'ı':
		return upper ? "I" : "i"
	case 'ł', 'ĺ', 'ľ', 'ļ':
		return upper ? "L" : "l"
	case 'ñ', 'ń', 'ň', 'ņ':
		return upper ? "N" : "n"
	case 'ò', 'ó', 'ô', 'õ', 'ö', 'ø', 'ō', 'ŏ', 'ő':
		return upper ? "O" : "o"
	case 'ŕ', 'ř', 'ŗ':
		return upper ? "R" : "r"
	case 'ś', 'ŝ', 'ş', 'š':
		return upper ? "S" : "s"
	case 'ť', 'ţ':
		return upper ? "T" : "t"
	case 'ù', 'ú', 'û', 'ü', 'ū', 'ŭ', 'ů', 'ű', 'ų':
		return upper ? "U" : "u"
	case 'ý', 'ÿ', 'ŷ':
		return upper ? "Y" : "y"
	case 'ź', 'ż', 'ž':
		return upper ? "Z" : "z"
	case 'ß':
		return "ss"
	case 'æ':
		return upper ? "AE" : "ae"
	case 'œ':
		return upper ? "OE" : "oe"
	case 'þ':
		return upper ? "Th" : "th"
	case 'ð':
		return upper ? "D" : "d"
	}
	return ""
}
