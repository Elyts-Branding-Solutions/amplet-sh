package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func dbDSN() string {
	return fmt.Sprintf(
		"host=%s port=%s dbname=%s user=%s password=%s search_path=%s sslmode=disable",
		envOr("DB_HOST", "localhost"),
		envOr("DB_PORT", "5432"),
		envOr("DB_NAME", "amplet-hms"),
		envOr("DB_USER", "aveey"),
		envOr("DB_PASSWORD", ""),
		envOr("DB_SCHEMA", "public"),
	)
}

func openDB() (*pgxpool.Pool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dbDSN())
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return pool, nil
}

const schema = `
CREATE TABLE IF NOT EXISTS node_stats (
	time        TIMESTAMPTZ      NOT NULL,
	token       TEXT             NOT NULL,
	cpu_total   DOUBLE PRECISION,
	cpu_cores   JSONB,
	mem_total   BIGINT,
	mem_used    BIGINT,
	mem_pct     DOUBLE PRECISION,
	disk_total  BIGINT,
	disk_used   BIGINT,
	disk_pct    DOUBLE PRECISION,
	gpu_stats   JSONB
);
SELECT create_hypertable('node_stats', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_node_stats_token_time ON node_stats (token, time DESC);
`

func migrateDB(pool *pgxpool.Pool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_, err := pool.Exec(ctx, schema)
	return err
}

// StatsRow mirrors the WebSocket payload from the agent.
type StatsRow struct {
	Token string    `json:"token"`
	Ts    time.Time `json:"ts"`
	CPU   struct {
		TotalPct float64   `json:"totalPct"`
		CorePcts []float64 `json:"corePcts"`
	} `json:"cpu"`
	Mem struct {
		TotalBytes uint64  `json:"totalBytes"`
		UsedBytes  uint64  `json:"usedBytes"`
		UsedPct    float64 `json:"usedPct"`
	} `json:"mem"`
	Disk struct {
		TotalBytes uint64  `json:"totalBytes"`
		UsedBytes  uint64  `json:"usedBytes"`
		UsedPct    float64 `json:"usedPct"`
	} `json:"disk"`
	GPUs []struct {
		Index      int     `json:"index"`
		UsagePct   float64 `json:"usagePct"`
		TempC      float64 `json:"tempC"`
		MemUsedMB  uint64  `json:"memUsedMB"`
		MemTotalMB uint64  `json:"memTotalMB"`
	} `json:"gpus"`
}

const insertSQL = `
INSERT INTO node_stats
	(time, token, cpu_total, cpu_cores, mem_total, mem_used, mem_pct, disk_total, disk_used, disk_pct, gpu_stats)
VALUES
	($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
`

func insertStats(ctx context.Context, pool *pgxpool.Pool, row *StatsRow) error {
	corePcts, err := json.Marshal(row.CPU.CorePcts)
	if err != nil {
		return err
	}
	gpuStats, err := json.Marshal(row.GPUs)
	if err != nil {
		return err
	}

	ts := row.Ts
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	_, err = pool.Exec(ctx, insertSQL,
		ts,
		row.Token,
		row.CPU.TotalPct,
		string(corePcts),
		int64(row.Mem.TotalBytes),
		int64(row.Mem.UsedBytes),
		row.Mem.UsedPct,
		int64(row.Disk.TotalBytes),
		int64(row.Disk.UsedBytes),
		row.Disk.UsedPct,
		string(gpuStats),
	)
	return err
}
