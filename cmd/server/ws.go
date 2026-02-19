package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
	"github.com/jackc/pgx/v5/pgxpool"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 1024,
	CheckOrigin:    func(r *http.Request) bool { return true },
}

func makeWSHandler(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.URL.Query().Get("token")
		if token == "" {
			http.Error(w, "missing token", http.StatusUnauthorized)
			return
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			fmt.Printf("ws upgrade error: %v\n", err)
			return
		}
		defer conn.Close()

		remoteAddr := r.RemoteAddr
		fmt.Printf("agent connected  token=%s addr=%s\n", token, remoteAddr)

		conn.SetReadLimit(64 * 1024) // 64 KB max message
		conn.SetReadDeadline(time.Now().Add(30 * time.Second))
		conn.SetPongHandler(func(string) error {
			conn.SetReadDeadline(time.Now().Add(30 * time.Second))
			return nil
		})

		// Ping the agent every 10s to detect dead connections
		go func() {
			ticker := time.NewTicker(10 * time.Second)
			defer ticker.Stop()
			for range ticker.C {
				if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(5*time.Second)); err != nil {
					return
				}
			}
		}()

		for {
			_, msg, err := conn.ReadMessage()
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
					fmt.Printf("agent disconnected unexpectedly  token=%s: %v\n", token, err)
				} else {
					fmt.Printf("agent disconnected  token=%s\n", token)
				}
				return
			}

			conn.SetReadDeadline(time.Now().Add(30 * time.Second))

			var row StatsRow
			if err := json.Unmarshal(msg, &row); err != nil {
				fmt.Printf("bad payload from token=%s: %v\n", token, err)
				continue
			}
			// Always use the server's received token (trust the connection, not the payload token)
			row.Token = token

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			if err := insertStats(ctx, pool, &row); err != nil {
				fmt.Printf("db insert error token=%s: %v\n", token, err)
			}
			cancel()
		}
	}
}
