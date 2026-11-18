package naming

import "core:testing"

// Per-thread scratch buffer so the returned string is not a local stack slice.
// The test runner executes tests in parallel, so a plain global would be
// shared between concurrent tests and produce garbage.
@(thread_local)
_test_buf: [512]u8

_name :: proc(channel, title: string) -> string {
	return build_filename(_test_buf[:], channel, title)
}

@(test)
real_metadata :: proc(t: ^testing.T) {
	got := _name(
		"Rock & Roll Hall of Fame",
		`2021 Remaster "While My Guitar Gently Weeps" Prince, Tom Petty & More | Rock Hall 2004 Induction`,
	)
	want := "Rock_Roll_Hall_of_Fame_2021_Remaster_While_My_Guitar_Gently_Weeps_Prince_Tom_Petty_More_Rock_Hall_2004_Induction_160k.mp3"
	testing.expect_value(t, got, want)
}

@(test)
accents_transliterate :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("Café Tacvba", "Adiós"), "Cafe_Tacvba_Adios_160k.mp3")
	testing.expect_value(t, _name("Strasse", "Große Freiheit"), "Strasse_Grosse_Freiheit_160k.mp3")
	testing.expect_value(t, _name("Øya", "Été"), "Oya_Ete_160k.mp3")
}

@(test)
non_ascii_dropped :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("【公式】米津玄師", "Lemon MV"), "Lemon_MV_160k.mp3")
}

@(test)
all_junk_falls_back :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("日本語チャンネル", "日本語"), "unknown_160k.mp3")
	testing.expect_value(t, _name("", ""), "unknown_160k.mp3")
	testing.expect_value(t, _name("***", "???"), "unknown_160k.mp3")
}

@(test)
empty_channel_no_leading_separator :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("", "Beastie Boys - Sabotage (Official Music Video)"), "Beastie_Boys_-_Sabotage_Official_Music_Video_160k.mp3")
}

@(test)
separators_collapse :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("a  &  b", "c!!!d"), "a_b_c_d_160k.mp3")
}

@(test)
allowed_characters_survive :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("a-b_c", "1-2_3"), "a-b_c_1-2_3_160k.mp3")
}

@(test)
emoji_dropped :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("SONG 🎵🔥", "fire"), "SONG_fire_160k.mp3")
}

@(test)
trailing_punctuation_trimmed :: proc(t: ^testing.T) {
	testing.expect_value(t, _name("chan", "Title!!!"), "chan_Title_160k.mp3")
}

@(test)
long_input_truncated :: proc(t: ^testing.T) {
	long_title: [400]u8
	for i in 0 ..< len(long_title) {
		long_title[i] = 'a'
	}
	got := _name("chan", string(long_title[:]))
	testing.expect(t, len(got) <= FILENAME_MAX, "filename must fit FILENAME_MAX")
	testing.expect(t, len(got) > 100, "filename should still be long")
	testing.expect(t, got[len(got) - len(SUFFIX):] == SUFFIX, "suffix must be intact")
	testing.expect(t, got[len(got) - len(SUFFIX) - 1] != '_', "no separator before the suffix")
}

@(test)
only_ascii_alnum_underscore_hyphen :: proc(t: ^testing.T) {
	inputs := [?][2]string{
		{"Rock & Roll Hall of Fame", `2021 Remaster "While My Guitar Gently Weeps" Prince, Tom Petty & More | Rock Hall 2004 Induction`},
		{"Café Tacvba", "Adiós (En Vivo) [4K]"},
		{"【公式】米津玄師", "Lemon MV"},
		{"a.b.c", "d/e\\f:g*h?i\"j<k>l|m"},
		{"日本語", "中文 🎵"},
	}
	for pair in inputs {
		got := _name(pair[0], pair[1])
		for c in got {
			ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
			testing.expect(t, ok, "filename contains a character outside [A-Za-z0-9_-] plus the extension dot")
		}
	}
}
