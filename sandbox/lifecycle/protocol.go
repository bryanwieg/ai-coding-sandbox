package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

const (
	startupWindow  = 120 * time.Second
	idleWindow     = 2 * time.Second
	joinMargin     = 5 * time.Second
	drainLimit     = 25 * time.Second
	rejoinWindow   = 30 * time.Second
	admissionRetry = 10 * time.Second
	retryInterval  = 250 * time.Millisecond
	joinTimeout    = 2 * time.Second
	hardExitMargin = 2 * time.Second

	brokerDir     = "/run/sandbox-lifecycle"
	clientSocket  = brokerDir + "/lifecycle.sock"
	controlSocket = "/tmp/sandbox-lifecycle-control.sock"

	msgAdmit    = 'A'
	msgRefuse   = 'R'
	msgStop     = 'S'
	maxJoinLine = 64
	exitRefused = 75
	exitUsage   = 2

	controlReady  = "ready"
	controlStatus = "status"
	controlStop   = "stop"
)

type role int

const (
	roleAgent role = iota
	roleService
)

type member struct {
	name  string
	role  role
	grace time.Duration
}

var members = map[string]member{
	"claude":       {"claude", roleAgent, 10 * time.Second},
	"codex":        {"codex", roleAgent, 10 * time.Second},
	"egress-proxy": {"egress-proxy", roleService, 5 * time.Second},
	"publish":      {"publish", roleService, 5 * time.Second},
	"ssh-agent":    {"ssh-agent", roleService, 5 * time.Second},
	"docker":       {"docker", roleService, 22 * time.Second},
}

// Each pool listens at brokerDir/<subdir>/lifecycle.sock.
type socketSpec struct {
	subdir string
	names  []string
	pool   int
}

var sockets = []socketSpec{
	{"agents", []string{"claude", "codex"}, 64},
	{"services", []string{"egress-proxy", "publish", "ssh-agent"}, 16},
	{"daemon", []string{"docker"}, 4},
}

type state int

const (
	stateStarting state = iota
	stateActive
	stateIdle
	stateDraining
)

func (s state) String() string {
	return [...]string{"starting", "active", "idle", "draining"}[s]
}

func formatJoin(name string) string {
	return "join " + name + "\n"
}

var joinName = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// parseJoin takes the contents of one line, after the reader consumes its LF.
func parseJoin(line string) (string, error) {
	name, ok := strings.CutPrefix(line, "join ")
	if !ok || !joinName.MatchString(name) {
		return "", errors.New("invalid join line")
	}
	return name, nil
}

// A status snapshot lists members in join order within each role.
type status struct {
	state            state
	joinable         bool
	remaining        time.Duration
	agents, services []string
}

func (s status) format() string {
	joinable := "no"
	if s.joinable {
		joinable = "yes"
	}
	seconds := int64(s.remaining / time.Second)
	if s.remaining%time.Second > 0 {
		seconds++
	}
	return fmt.Sprintf("state=%s\njoinable=%s\nremaining=%d\nagents=%s\nservices=%s\n",
		s.state, joinable, seconds, strings.Join(s.agents, " "), strings.Join(s.services, " "))
}
