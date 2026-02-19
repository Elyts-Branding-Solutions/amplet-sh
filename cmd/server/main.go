package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	db, err := openDB()
	if err != nil {
		fmt.Fprintf(os.Stderr, "db connect: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	if err := migrateDB(db); err != nil {
		fmt.Fprintf(os.Stderr, "db migrate: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("database ready")

	mux := http.NewServeMux()
	mux.HandleFunc("/ws/agent", makeWSHandler(db))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	addr := ":" + envOr("PORT", "8080")
	fmt.Printf("amplet server listening on %s\n", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Fprintf(os.Stderr, "server: %v\n", err)
		os.Exit(1)
	}
}
