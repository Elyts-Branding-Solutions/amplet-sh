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

		// Validate token + mark as CONNECTED in the main (Next.js) DB
		authCtx, authCancel := context.WithTimeout(context.Background(), 5*time.Second)
		err := validateAndRegister(authCtx, pool, token)
		authCancel()
		if err != nil {
			fmt.Printf("agent rejected  token=%s: %v\n", token, err)
			http.Error(w, err.Error(), http.StatusUnauthorized)
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

		conn.SetReadLimit(64 * 1024)
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

			// Peek at the "type" field to route the message
			var envelope struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(msg, &envelope); err != nil {
				fmt.Printf("bad payload from token=%s: %v\n", token, err)
				continue
			}

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)

			switch envelope.Type {
			case "config":
				// Hardware config sent once on connect — save to FleetEnquiry
				if err := saveHardwareConfig(ctx, pool, token, msg); err != nil {
					fmt.Printf("config save error token=%s: %v\n", token, err)
				} else {
					fmt.Printf("hardware config saved  token=%s\n", token)
				}

			default:
				// "stats" or no type — insert into TimescaleDB
				var row StatsRow
				if err := json.Unmarshal(msg, &row); err != nil {
					fmt.Printf("bad stats payload from token=%s: %v\n", token, err)
					cancel()
					continue
				}
				row.Token = token
				if err := insertStats(ctx, pool, &row); err != nil {
					fmt.Printf("db insert error token=%s: %v\n", token, err)
				}
			}

			cancel()
		}
	}
}
