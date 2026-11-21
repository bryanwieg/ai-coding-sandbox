package main

import (
	"context"
	"errors"
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

// serve accepts members until the group drains. Canceling ctx closes all
// connections without a stop message so members can rejoin a replacement.
func serve(ctx context.Context, cfg brokerConfig) error {
	return errors.New("not implemented")
}
