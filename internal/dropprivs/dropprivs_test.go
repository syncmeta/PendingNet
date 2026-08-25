package dropprivs

import (
	"reflect"
	"testing"
)

func TestStripFlagSpaceSeparated(t *testing.T) {
	got := StripFlag([]string{"daemon", "-drop-to-uid", "501", "-listen", "127.0.0.1:7777"}, "drop-to-uid")
	want := []string{"daemon", "-listen", "127.0.0.1:7777"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestStripFlagEquals(t *testing.T) {
	got := StripFlag([]string{"daemon", "--drop-to-uid=501", "-secret-stdin"}, "drop-to-uid")
	want := []string{"daemon", "-secret-stdin"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q want %q", got, want)
	}
}

// 除了那个开关，别的一个字都不能少 —— 少一个 -db 统计就写去别的地方了。
func TestStripFlagKeepsEverythingElse(t *testing.T) {
	args := []string{
		"daemon", "-clash-api", "127.0.0.1:9090", "-listen", "127.0.0.1:7777",
		"-db", "/Users/tester/Library/Application Support/sbtally/sbtally.db",
		"-ruleset-dir", "", "-secret-stdin",
	}
	got := StripFlag(args, "drop-to-uid")
	if !reflect.DeepEqual(got, args) {
		t.Fatalf("没有那个开关时不该改动任何东西：got %q", got)
	}
}

// 名字只是撞了前缀的另一个 flag 不能被误伤。
func TestStripFlagDoesNotMatchPrefixes(t *testing.T) {
	args := []string{"daemon", "-drop-to-uid-but-not-really", "x"}
	got := StripFlag(args, "drop-to-uid")
	if !reflect.DeepEqual(got, args) {
		t.Fatalf("误伤了同前缀的 flag：got %q", got)
	}
}

func TestStripFlagBothForms(t *testing.T) {
	got := StripFlag(
		[]string{"daemon", "-drop-to-uid", "501", "-drop-to-gid=20", "-secret-stdin"},
		"drop-to-gid")
	want := []string{"daemon", "-drop-to-uid", "501", "-secret-stdin"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q want %q", got, want)
	}
}
