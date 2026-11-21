package main

import (
	"io"
	"net"
	"time"
)

// handleControl serves one ready, status or stop request and closes the connection.
func handleControl(conn net.Conn) {
	conn.Close()
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
