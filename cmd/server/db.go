package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
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

// --- Stats (TimescaleDB) ---

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
VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
`

func insertStats(ctx context.Context, pool *pgxpool.Pool, row *StatsRow) error {
	corePcts, _ := json.Marshal(row.CPU.CorePcts)
	gpuStats, _ := json.Marshal(row.GPUs)
	ts := row.Ts
	if ts.IsZero() {
		ts = time.Now().UTC()
	}
	_, err := pool.Exec(ctx, insertSQL,
		ts, row.Token, row.CPU.TotalPct, string(corePcts),
		int64(row.Mem.TotalBytes), int64(row.Mem.UsedBytes), row.Mem.UsedPct,
		int64(row.Disk.TotalBytes), int64(row.Disk.UsedBytes), row.Disk.UsedPct,
		string(gpuStats),
	)
	return err
}

// --- FleetEnquiry (shared DB) ---
// Table name matches your Prisma model. Override with FLEET_TABLE env if you use @@map.

func fleetTable() string {
	return envOr("FLEET_TABLE", "FleetEnquiry")
}

func validateAndRegister(ctx context.Context, pool *pgxpool.Pool, token string) error {
	table := fleetTable()
	var enquiryID, status string
	var expiresAt time.Time

	err := pool.QueryRow(ctx,
		fmt.Sprintf(`SELECT "enquiryId", status, "expiresAt" FROM "%s" WHERE token = $1`, table),
		token,
	).Scan(&enquiryID, &status, &expiresAt)
	if err == pgx.ErrNoRows {
		return fmt.Errorf("invalid token")
	}
	if err != nil {
		return fmt.Errorf("db lookup: %w", err)
	}
	if status == "EXPIRED" {
		return fmt.Errorf("token expired")
	}
	if time.Now().After(expiresAt) {
		pool.Exec(ctx, fmt.Sprintf(`UPDATE "%s" SET status = 'EXPIRED' WHERE "enquiryId" = $1`, table), enquiryID)
		return fmt.Errorf("token expired")
	}
	_, err = pool.Exec(ctx,
		fmt.Sprintf(`UPDATE "%s" SET status = 'CONNECTED', "isSWinstalled" = true WHERE "enquiryId" = $1`, table),
		enquiryID,
	)
	return err
}

func saveHardwareConfig(ctx context.Context, pool *pgxpool.Pool, token string, raw []byte) error {
	var m map[string]interface{}
	if err := json.Unmarshal(raw, &m); err != nil {
		return fmt.Errorf("invalid config json: %w", err)
	}
	delete(m, "type")
	delete(m, "token")
	configJSON, err := json.Marshal(m)
	if err != nil {
		return err
	}
	_, err = pool.Exec(ctx,
		fmt.Sprintf(`UPDATE "%s" SET config = $1::jsonb WHERE token = $2`, fleetTable()),
		string(configJSON), token,
	)
	return err
}
