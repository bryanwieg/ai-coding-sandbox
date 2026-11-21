package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func ptyIoctl(t *testing.T, f *os.File, op uintptr, value *int32) {
	t.Helper()
	// SyscallConn preserves the master file's nonblocking mode for deadlines.
	raw, err := f.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var errno syscall.Errno
	if err := raw.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, fd, op, uintptr(unsafe.Pointer(value)))
	}); err != nil {
		t.Fatal(err)
	}
	if errno != 0 {
		t.Fatalf("pty ioctl %#x: %v", op, errno)
	}
}

type wrapperPTY struct {
	master *os.File
	reader *bufio.Reader
	cmd    *exec.Cmd
}

func startPTY(t *testing.T, argv ...string) wrapperPTY {
	t.Helper()
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY|syscall.O_NONBLOCK, 0)
	if err != nil {
		t.Skipf("open /dev/ptmx: %v", err)
	}
	t.Cleanup(func() { master.Close() })
	var unlock, number int32
	ptyIoctl(t, master, syscall.TIOCSPTLCK, &unlock)
	ptyIoctl(t, master, syscall.TIOCGPTN, &number)
	slave, err := os.OpenFile(fmt.Sprintf("/dev/pts/%d", number), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer slave.Close()
	dir := t.TempDir()
	l := listenForWrapper(t, dir)
	cmd := wrapperCommand(t, dir, "codex", argv...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.Env = append(cmd.Env, "PS1=job> ", "TERM=dumb", "PROMPT_COMMAND=")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	startWrapper(t, cmd)
	sendWrapper(t, acceptWrapper(t, l, "codex"), msgAdmit)
	return wrapperPTY{master, bufio.NewReader(master), cmd}
}

func (p wrapperPTY) write(t *testing.T, s string) {
	t.Helper()
	if _, err := p.master.WriteString(s); err != nil {
		t.Fatal(err)
	}
}

func (p wrapperPTY) until(t *testing.T, want string) string {
	t.Helper()
	if err := p.master.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	for !bytes.HasSuffix(out.Bytes(), []byte(want)) {
		b, err := p.reader.ReadByte()
		if err != nil {
			t.Fatalf("waiting for %q on pty: %v; read %q", want, err, out.String())
		}
		out.WriteByte(b)
	}
	return out.String()
}

func (p wrapperPTY) foreground(t *testing.T) int32 {
	t.Helper()
	var group int32
	ptyIoctl(t, p.master, syscall.TIOCGPGRP, &group)
	return group
}

func (p wrapperPTY) foregroundJob(t *testing.T, shell int32) int32 {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if group := p.foreground(t); group > 0 && group != shell {
			return group
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("shell never put the job in the foreground")
	return 0
}

func TestAgentJobControl(t *testing.T) {
	p := startPTY(t, "bash", "--norc", "-i")
	p.until(t, "job> ")
	shell := p.foreground(t)
	p.write(t, "sleep 30\n")
	p.foregroundJob(t, shell)
	p.write(t, "\x03")
	p.until(t, "job> ")

	p.write(t, "sleep 30\n")
	job := p.foregroundJob(t, shell)
	p.write(t, "\x1a")
	p.until(t, "Stopped")
	p.until(t, "job> ")
	p.write(t, "fg\n")
	if resumed := p.foregroundJob(t, shell); resumed != job {
		t.Fatalf("fg resumed group %d, want %d", resumed, job)
	}
	p.write(t, "\x03")
	p.until(t, "job> ")
	p.write(t, "exit 7\n")
	wrapperExit(t, p.cmd, 7)
}

func TestAgentTTYInput(t *testing.T) {
	p := startPTY(t, "sh", "-c", "read x; echo got:$x")
	p.write(t, "hello\n")
	p.until(t, "got:hello")
	wrapperExit(t, p.cmd, 0)
}
