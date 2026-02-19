package main

import (
	"encoding/csv"
	"strings"
	"strconv"
	"time"
	"os/exec"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/mem"
)

// StatsMessage is the payload sent over WebSocket every 5 seconds.
type StatsMessage struct {
	Token string    `json:"token"`
	Ts    time.Time `json:"ts"`
	CPU   CPUStats  `json:"cpu"`
	Mem   MemStats  `json:"mem"`
	Disk  DiskStats `json:"disk"`
	GPUs  []GPUStat `json:"gpus"`
}

type CPUStats struct {
	TotalPct float64   `json:"totalPct"`
	CorePcts []float64 `json:"corePcts"`
}

type MemStats struct {
	TotalBytes uint64  `json:"totalBytes"`
	UsedBytes  uint64  `json:"usedBytes"`
	UsedPct    float64 `json:"usedPct"`
}

type DiskStats struct {
	TotalBytes uint64  `json:"totalBytes"`
	UsedBytes  uint64  `json:"usedBytes"`
	UsedPct    float64 `json:"usedPct"`
}

type GPUStat struct {
	Index      int     `json:"index"`
	UsagePct   float64 `json:"usagePct"`
	TempC      float64 `json:"tempC"`
	MemUsedMB  uint64  `json:"memUsedMB"`
	MemTotalMB uint64  `json:"memTotalMB"`
}

func collectStats(token string) (*StatsMessage, error) {
	s := &StatsMessage{Token: token, Ts: time.Now().UTC()}

	// CPU — 1s sample window per gopsutil convention
	perCore, err := cpu.Percent(time.Second, true)
	if err == nil && len(perCore) > 0 {
		s.CPU.CorePcts = perCore
		var sum float64
		for _, v := range perCore {
			sum += v
		}
		s.CPU.TotalPct = sum / float64(len(perCore))
	}

	// Memory
	vm, err := mem.VirtualMemory()
	if err == nil {
		s.Mem = MemStats{
			TotalBytes: vm.Total,
			UsedBytes:  vm.Used,
			UsedPct:    vm.UsedPercent,
		}
	}

	// Disk (root partition)
	du, err := disk.Usage("/")
	if err == nil {
		s.Disk = DiskStats{
			TotalBytes: du.Total,
			UsedBytes:  du.Used,
			UsedPct:    du.UsedPercent,
		}
	}

	// GPU via nvidia-smi
	s.GPUs = collectGPUStats()

	return s, nil
}

func collectGPUStats() []GPUStat {
	out, err := exec.Command(
		"nvidia-smi",
		"--query-gpu=index,utilization.gpu,temperature.gpu,memory.used,memory.total",
		"--format=csv,noheader,nounits",
	).Output()
	if err != nil {
		return nil
	}

	r := csv.NewReader(strings.NewReader(string(out)))
	r.TrimLeadingSpace = true
	records, err := r.ReadAll()
	if err != nil {
		return nil
	}

	gpus := make([]GPUStat, 0, len(records))
	for _, rec := range records {
		if len(rec) < 5 {
			continue
		}
		idx, _      := strconv.Atoi(strings.TrimSpace(rec[0]))
		usage, _    := strconv.ParseFloat(strings.TrimSpace(rec[1]), 64)
		temp, _     := strconv.ParseFloat(strings.TrimSpace(rec[2]), 64)
		memUsed, _  := strconv.ParseUint(strings.TrimSpace(rec[3]), 10, 64)
		memTotal, _ := strconv.ParseUint(strings.TrimSpace(rec[4]), 10, 64)
		gpus = append(gpus, GPUStat{
			Index:      idx,
			UsagePct:   usage,
			TempC:      temp,
			MemUsedMB:  memUsed,
			MemTotalMB: memTotal,
		})
	}
	return gpus
}
