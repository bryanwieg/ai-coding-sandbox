package main

import (
	"bufio"
	"io"
	"net"
	"time"
)

// handleControl serves one request. The accept loop owns the connection.
func (b *broker) handleControl(conn net.Conn) {
	conn.SetDeadline(time.Now().Add(joinTimeout))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	now := time.Now()
	b.expire(now)
	switch line {
	case controlReady + "\n":
		if b.state == stateDraining {
			io.WriteString(conn, "draining\n")
		} else {
			io.WriteString(conn, "ok\n")
		}
	case controlStatus + "\n":
		s := status{state: b.state}
		if b.state == stateStarting || b.state == stateIdle {
			s.remaining = b.deadline.Sub(now)
		}
		s.joinable = b.state == stateActive || (b.state == stateStarting && s.remaining >= b.cfg.margin)
		for _, m := range b.joined {
			if m.role == roleAgent {
				s.agents = append(s.agents, m.name)
			} else {
				s.services = append(s.services, m.name)
			}
		}
		io.WriteString(conn, s.format())
	case controlStop + "\n":
		io.WriteString(conn, "ok\n")
		b.drain(now)
	}
}

// requestControl sends a command (without its LF) and returns the complete reply.
func requestControl(path, line string) (string, error) {
	conn, err := net.DialTimeout("unix", path, joinTimeout)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(joinTimeout)); err != nil {
		return "", err
	}
	if _, err := io.WriteString(conn, line+"\n"); err != nil {
		return "", err
	}
	reply, err := io.ReadAll(conn)
	return string(reply), err
}
