package winargs

import "core:testing"

@(test)
plain_arguments_are_not_quoted :: proc(t: ^testing.T) {
	got := build([]string{"yt-dlp", "-f", "ba/b", "--no-playlist"})
	defer delete(got)
	testing.expect_value(t, got, "yt-dlp -f ba/b --no-playlist")
}

@(test)
path_with_space_is_quoted :: proc(t: ^testing.T) {
	got := build([]string{"-P", `C:\Users\Phil\My Music`})
	defer delete(got)
	testing.expect_value(t, got, `-P "C:\Users\Phil\My Music"`)
}

@(test)
trailing_backslash_in_quoted_arg_is_doubled :: proc(t: ^testing.T) {
	got := build([]string{`C:\My Music\`})
	defer delete(got)
	testing.expect_value(t, got, `"C:\My Music\\"`)
}

@(test)
embedded_quote_is_escaped :: proc(t: ^testing.T) {
	got := build([]string{`say "hi"`})
	defer delete(got)
	testing.expect_value(t, got, `"say \"hi\""`)
}

@(test)
empty_argument_becomes_empty_quotes :: proc(t: ^testing.T) {
	got := build([]string{""})
	defer delete(got)
	testing.expect_value(t, got, `""`)
}

@(test)
url_with_query_untouched :: proc(t: ^testing.T) {
	got := build([]string{"yt-dlp", "https://www.youtube.com/watch?v=dWRCooFKk3c"})
	defer delete(got)
	testing.expect_value(t, got, "yt-dlp https://www.youtube.com/watch?v=dWRCooFKk3c")
}
