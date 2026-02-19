package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

const (
	statsInterval = 5 * time.Second
	minBackoff    = 2 * time.Second
	maxBackoff    = 60 * time.Second
	stableAfter   = 30 * time.Second // reset backoff if session lived this long
)

func runAgent() {
	token := readToken()
	if token == "" {
		fmt.Fprintln(os.Stderr, "amplet: no token found at /etc/amplet/token")
		os.Exit(1)
	}

	serverURL := readServerURL()
	if serverURL == "" {
		fmt.Fprintln(os.Stderr, "amplet: no server URL — set AMPLET_SERVER_URL or check /etc/amplet/config")
		os.Exit(1)
	}
	fmt.Printf("amplet agent starting — server: %s\n", serverURL)

	ctx, cancel := context.WithCancel(context.Background())
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; cancel() }()

	connectLoop(ctx, serverURL, token)
}

func connectLoop(ctx context.Context, serverURL, token string) {
	backoff := minBackoff
	for {
		if ctx.Err() != nil {
			return
		}

		start := time.Now()
		err := runSession(ctx, serverURL, token)
		if ctx.Err() != nil {
			return
		}

		// Reset backoff if the session was stable long enough
		if time.Since(start) >= stableAfter {
			backoff = minBackoff
		}

		fmt.Printf("session ended (%v) — reconnecting in %v\n", err, backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}

		if backoff < maxBackoff {
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
		}
	}
}

func runSession(ctx context.Context, rawURL, token string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("bad server URL: %w", err)
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	}
	u.Path = "/ws/agent"
	q := u.Query()
	q.Set("token", token)
	u.RawQuery = q.Encode()

	conn, _, err := websocket.DefaultDialer.DialContext(ctx, u.String(), nil)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()
	fmt.Println("connected to server")

	ticker := time.NewTicker(statsInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			conn.WriteMessage(websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseNormalClosure, "agent shutting down"))
			return nil
		case <-ticker.C:
			msg, err := collectStats(token)
			if err != nil {
				fmt.Fprintf(os.Stderr, "stats: %v\n", err)
				continue
			}
			data, err := json.Marshal(msg)
			if err != nil {
				continue
			}
			if err := conn.WriteMessage(websocket.TextMessage, data); err != nil {
				return fmt.Errorf("write: %w", err)
			}
		}
	}
}

func readToken() string {
	f, err := os.Open("/etc/amplet/token")
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "AMPLET_TOKEN=") {
			return strings.TrimPrefix(line, "AMPLET_TOKEN=")
		}
	}
	return ""
}

func readServerURL() string {
	if v := os.Getenv("AMPLET_SERVER_URL"); v != "" {
		return v
	}
	f, err := os.Open("/etc/amplet/config")
	if err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			if strings.HasPrefix(line, "AMPLET_SERVER_URL=") {
				return strings.TrimPrefix(line, "AMPLET_SERVER_URL=")
			}
		}
	}
	return ""
}
