package main

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestParseJoin(t *testing.T) {
	for _, tt := range []struct{ line, want string }{
		{"join a", "a"},
		{"join ssh-agent9", "ssh-agent9"},
		{"join " + strings.Repeat("a", 32), strings.Repeat("a", 32)},
		{"codex", ""},
		{"join Codex", ""},
		{"join 1agent", ""},
		{"join ssh_agent", ""},
		{"join " + strings.Repeat("a", 33), ""},
		{"join codex ", ""},
		{"join  codex", ""},
		{"join codex\r", ""},
		{"join ", ""},
		{"", ""},
	} {
		t.Run(tt.line, func(t *testing.T) {
			got, err := parseJoin(tt.line)
			if got != tt.want || (err != nil) != (tt.want == "") {
				t.Errorf("parseJoin(%q) = %q, %v", tt.line, got, err)
			}
		})
	}
}

func TestFormatJoin(t *testing.T) {
	for name := range members {
		wire := formatJoin(name)
		line, terminated := strings.CutSuffix(wire, "\n")
		got, err := parseJoin(line)
		if !terminated || err != nil || got != name {
			t.Errorf("round trip for %q via %q = %q, %v", name, wire, got, err)
		}
	}
}

func TestStatusFormat(t *testing.T) {
	for _, tt := range []struct {
		s    status
		want string
	}{
		{status{state: stateStarting, joinable: true, remaining: 5001 * time.Millisecond},
			"state=starting\njoinable=yes\nremaining=6\nagents=\nservices=\n"},
		{status{state: stateActive, joinable: true, agents: []string{"codex", "claude", "codex"},
			services: []string{"publish", "docker"}},
			"state=active\njoinable=yes\nremaining=0\nagents=codex claude codex\nservices=publish docker\n"},
		{status{state: stateIdle, remaining: 2 * time.Second},
			"state=idle\njoinable=no\nremaining=2\nagents=\nservices=\n"},
		{status{state: stateDraining, services: []string{"ssh-agent"}},
			"state=draining\njoinable=no\nremaining=0\nagents=\nservices=ssh-agent\n"},
	} {
		if got := tt.s.format(); got != tt.want {
			t.Errorf("format() = %q, want %q", got, tt.want)
		}
	}
}

func TestUsage(t *testing.T) {
	const want = "sandbox-lifecycle: usage: sandbox-lifecycle serve | run NAME -- COMMAND [ARGS...] | ready | status | stop\n"
	for _, args := range [][]string{
		nil, {"unknown"}, {"serve", "extra"}, {"ready", "extra"}, {"status", "extra"}, {"stop", "extra"},
		{"run"}, {"run", "codex"}, {"run", "codex", "--"}, {"run", "codex", "--", ""},
		{"run", "codex", "sh", "-i"}, {"run", "unknown", "--", "sh"},
	} {
		var stdout, stderr bytes.Buffer
		if code := dispatch(args, &stdout, &stderr); code != 2 || stdout.Len() != 0 || stderr.String() != want {
			t.Errorf("dispatch(%q) returned %d, stdout %q, stderr %q", args, code, &stdout, &stderr)
		}
	}
}
