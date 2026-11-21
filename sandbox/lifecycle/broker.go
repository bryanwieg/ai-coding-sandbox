package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

type brokerConfig struct {
	dir     string
	control string
	startup time.Duration
	idle    time.Duration
	margin  time.Duration
	drain   time.Duration
}

func defaultBrokerConfig() brokerConfig {
	return brokerConfig{
		dir:     brokerDir,
		control: controlSocket,
		startup: startupWindow,
		idle:    idleWindow,
		margin:  joinMargin,
		drain:   drainLimit,
	}
}

type subscription struct {
	member
	conn net.Conn
	pool string
}

type broker struct {
	ctx  context.Context
	cfg  brokerConfig
	mu   sync.Mutex
	wake chan struct{}

	state    state
	deadline time.Time
	joined   []subscription // admission order, including duplicate names
}

// The caller holds mu for state transitions, admission, and departure.
func (b *broker) changed() {
	select {
	case b.wake <- struct{}{}:
	default:
	}
}

func (b *broker) transition(next state, deadline time.Time) {
	if next != b.state {
		fmt.Fprintln(os.Stderr, "sandbox-lifecycle:", next)
	}
	b.state = next
	b.deadline = deadline
	b.changed()
}

func (b *broker) drain(now time.Time) {
	if b.state == stateDraining || b.ctx.Err() != nil {
		return
	}
	end := now.Add(b.cfg.drain)
	b.transition(stateDraining, end)
	writeBy := now.Add(joinTimeout)
	if end.Before(writeBy) {
		writeBy = end
	}
	for _, m := range b.joined {
		m.conn.SetWriteDeadline(writeBy)
		m.conn.Write([]byte{msgStop})
	}
}

func (b *broker) expire(now time.Time) {
	if !b.deadline.IsZero() && !now.Before(b.deadline) {
		b.drain(now)
	}
}

func (b *broker) admit(conn net.Conn, spec socketSpec, name string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := time.Now()
	b.expire(now)
	count := 0
	for _, m := range b.joined {
		if m.pool == spec.subdir {
			count++
		}
	}
	if b.state == stateDraining || !slices.Contains(spec.names, name) || count >= spec.pool {
		return false
	}
	if _, err := conn.Write([]byte{msgAdmit}); err != nil {
		return false
	}
	m := members[name]
	b.joined = append(b.joined, subscription{m, conn, spec.subdir})
	fmt.Fprintln(os.Stderr, "sandbox-lifecycle: join", name)
	switch {
	case m.role == roleAgent:
		b.transition(stateActive, time.Time{})
	case b.state == stateStarting && spec.subdir == "services":
		b.transition(stateStarting, now.Add(b.cfg.startup))
	default:
		b.changed()
	}
	return true
}

func (b *broker) leave(conn net.Conn) {
	b.mu.Lock()
	defer b.mu.Unlock()
	i := slices.IndexFunc(b.joined, func(m subscription) bool { return m.conn == conn })
	m := b.joined[i]
	b.joined = slices.Delete(b.joined, i, i+1)
	fmt.Fprintln(os.Stderr, "sandbox-lifecycle: leave", m.name)
	if b.state == stateActive && m.role == roleAgent &&
		!slices.ContainsFunc(b.joined, func(other subscription) bool { return other.role == roleAgent }) {
		b.transition(stateIdle, time.Now().Add(b.cfg.idle))
	} else {
		b.changed()
	}
}

func readJoin(reader *bufio.Reader) (string, error) {
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return "", err
	}
	return parseJoin(string(line[:len(line)-1]))
}

func (b *broker) handleMember(conn net.Conn, spec socketSpec, pending <-chan struct{}) {
	conn.SetReadDeadline(time.Now().Add(joinTimeout))
	reader := bufio.NewReaderSize(conn, maxJoinLine)
	name, err := readJoin(reader)
	conn.SetWriteDeadline(time.Now().Add(joinTimeout))
	if err != nil || !b.admit(conn, spec, name) {
		conn.Write([]byte{msgRefuse})
		<-pending
		return
	}
	<-pending
	conn.SetReadDeadline(time.Time{})
	reader.ReadByte() // Also consumes any byte buffered alongside the join.
	b.leave(conn)
}

func listenSocket(path string, mode os.FileMode) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, mode); err != nil {
		listener.Close()
		return nil, err
	}
	return listener, nil
}

// A nil spec identifies the broker's private control listener.
func (b *broker) accept(listener net.Listener, spec *socketSpec, workers *sync.WaitGroup) {
	var pending chan struct{}
	if spec != nil {
		pending = make(chan struct{}, spec.pool)
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			fmt.Fprintln(os.Stderr, "sandbox-lifecycle: accept:", err)
			select {
			case <-b.ctx.Done():
				return
			case <-time.After(retryInterval):
				continue
			}
		}
		if pending != nil {
			select {
			case pending <- struct{}{}:
			default:
				conn.Close()
				continue
			}
		}
		workers.Go(func() {
			defer conn.Close()
			stop := context.AfterFunc(b.ctx, func() { conn.Close() })
			defer stop()
			if spec == nil {
				b.handleControl(conn)
			} else {
				b.handleMember(conn, *spec, pending)
			}
		})
	}
}

// serve accepts members until the group drains. Canceling ctx closes all
// connections without a stop message so members can rejoin a replacement.
func serve(ctx context.Context, cfg brokerConfig) error {
	ctx, cancel := context.WithCancel(ctx)
	b := &broker{ctx: ctx, cfg: cfg, wake: make(chan struct{}, 1)}
	listeners := make(map[net.Listener]*socketSpec)
	var workers sync.WaitGroup
	defer func() {
		cancel()
		for l := range listeners {
			l.Close() // Unix listeners unlink their socket on close.
		}
		workers.Wait()
	}()

	for _, spec := range sockets {
		dir := filepath.Join(cfg.dir, spec.subdir)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		l, err := listenSocket(filepath.Join(dir, "lifecycle.sock"), 0o666)
		if err != nil {
			return err
		}
		listeners[l] = &spec
	}
	control, err := listenSocket(cfg.control, 0o600)
	if err != nil {
		return err
	}
	listeners[control] = nil

	b.state = stateStarting
	b.deadline = time.Now().Add(cfg.startup)
	fmt.Fprintln(os.Stderr, "sandbox-lifecycle:", b.state)
	for l, spec := range listeners {
		workers.Go(func() { b.accept(l, spec, &workers) })
	}

	for ctx.Err() == nil {
		b.mu.Lock()
		now := time.Now()
		b.expire(now)
		deadline := b.deadline
		if b.state == stateDraining && (len(b.joined) == 0 || !now.Before(deadline)) {
			if len(b.joined) > 0 {
				var names []string
				for _, m := range b.joined {
					names = append(names, m.name)
				}
				fmt.Fprintln(os.Stderr, "sandbox-lifecycle: did not stop in time:", strings.Join(names, " "))
			}
			b.mu.Unlock()
			return nil
		}
		b.mu.Unlock()

		var expires <-chan time.Time
		if !deadline.IsZero() {
			expires = time.After(time.Until(deadline))
		}
		select {
		case <-ctx.Done():
		case <-b.wake:
		case <-expires:
		}
	}
	return nil
}
