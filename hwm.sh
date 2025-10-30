#!/bin/bash

# Script: slurm-cgroup-monitor.sh
# Description: Display CPU and Memory usage for the current Slurm job using cgroup v1
# Requirements: Running inside a Slurm job allocation, cgroup v1 enabled

set -euo pipefail

# Get the current Slurm job ID
JOB_ID="${SLURM_JOB_ID:-}"
if [ -z "$JOB_ID" ]; then
    echo "Error: SLURM_JOB_ID not found. Are you running inside a Slurm job?"
    exit 1
fi

# Detect cgroup mount point and construct job cgroup path
CGROUP_BASE="/sys/fs/cgroup"
CPU_PATH=""
MEMORY_PATH=""

# Try to find the job's cgroup under cpu and memory controllers
for controller in cpu memory; do
    CGROUP_DIR="$CGROUP_BASE/$controller"
    if [ ! -d "$CGROUP_DIR" ]; then
        echo "Error: $controller cgroup not mounted at $CGROUP_DIR"
        exit 1
    fi

    # Slurm typically places jobs under: slurm/uid_${UID}/job_${JOB_ID}/
    # But sometimes it's under slurm/job_${JOB_ID}/ or with step info
    POSSIBLE_PATHS=(
        "$CGROUP_DIR/slurm/uid_${UID}/job_${JOB_ID}"
        "$CGROUP_DIR/slurm/job_${JOB_ID}"
        "$CGROUP_DIR/slurm/uid_${UID}/job_${JOB_ID}/step_batch"
        "$CGROUP_DIR/slurm/job_${JOB_ID}/step_batch"
    )

    CGROUP_JOB_PATH=""
    for path in "${POSSIBLE_PATHS[@]}"; do
        if [ -d "$path" ] && [ -f "$path/tasks" ]; then
            CGROUP_JOB_PATH="$path"
            break
        fi
    done

    if [ -z "$CGROUP_JOB_PATH" ]; then
        echo "Error: Could not find $controller cgroup for job $JOB_ID"
        echo "Tried paths:"
        printf '  %s\n' "${POSSIBLE_PATHS[@]}"
        exit 1
    fi

    if [ "$controller" = "cpu" ]; then
        CPU_PATH="$CGROUP_JOB_PATH"
    else
        MEMORY_PATH="$CGROUP_JOB_PATH"
    fi
done

echo "Found cgroup paths for job $JOB_ID:"
echo "  CPU:    $CPU_PATH"
echo "  Memory: $MEMORY_PATH"
echo

# Function to read CPU usage
get_cpu_usage() {
    local cpuacct_usage="$CPU_PATH/cpuacct.usage"
    local cpuacct_stat="$CPU_PATH/cpuacct.stat"
    local cpu_shares="$CPU_PATH/cpu.shares"
    local cfs_quota="$CPU_PATH/cpu.cfs_quota_us"
    local cfs_period="$CPU_PATH/cpu.cfs_period_us"

    local total_usage_ns=0
    local user_sec=0
    local system_sec=0
    local shares=1024
    local quota=-1
    local period=100000

    if [ -f "$cpuacct_usage" ]; then
        total_usage_ns=$(cat "$cpuacct_usage")
        total_usage_sec=$(echo "scale=3; $total_usage_ns / 1000000000" | bc -l 2>/dev/null || echo "0")
    fi

    if [ -f "$cpuacct_stat" ]; then
        user_sec=$(grep '^user ' "$cpuacct_stat" | awk '{print $2/100 "s"}')  # in jiffies -> approx sec
        system_sec=$(grep '^system ' "$cpuacct_stat" | awk '{print $2/100 "s"}')
    fi

    [ -f "$cpu_shares" ] && shares=$(cat "$cpu_shares")
    [ -f "$cpu.cfs_quota_us" ] && quota=$(cat "$cpu.cfs_quota_us")
    [ -f "$cpu.cfs_period_us" ] && period=$(cat "$cpu.cfs_period_us")

    # Calculate effective CPU limit
    local cpu_limit="unlimited"
    if [ "$quota" -gt 0 ]; then
        cpu_limit=$(echo "scale=2; $quota / $period" | bc -l)
    fi

    echo "CPU Usage (from cpuacct.usage): ${total_usage_sec}s total"
    echo "CPU Shares: $shares"
    echo "CPU Quota/Period: ${quota}us / ${period}us -> Limit: $cpu_limit vCPUs"
}

# Function to read memory usage
get_memory_usage() {
    local mem_usage="$MEMORY_PATH/memory.usage_in_bytes"
    local mem_limit="$MEMORY_PATH/memory.limit_in_bytes"
    local mem_max_usage="$MEMORY_PATH/memory.max_usage_in_bytes"
    local mem_stat="$MEMORY_PATH/memory.stat"

    local usage_bytes=0
    local limit_bytes=0
    local max_usage_bytes=0

    [ -f "$mem_usage" ] && usage_bytes=$(cat "$mem_usage")
    [ -f "$mem_limit" ] && limit_bytes=$(cat "$mem_limit")
    [ -f "$mem_max_usage" ] && max_usage_bytes=$(cat "$mem_max_usage")

    # Convert to human-readable
    format_bytes() {
        local bytes=$1
        if command -v numfmt >/dev/null; then
            echo "$(numfmt --to=iec "$bytes")"
        else
            local units=("B" "KiB" "MiB" "GiB" "TiB")
            local unit=0
            while [ "$bytes" -gt 1024 ] && [ "$unit" -lt 4 ]; do
                bytes=$((bytes / 1024))
                unit=$((unit + 1))
            done
            echo "$bytes${units[$unit]}"
        fi
    }

    local usage_hr=$(format_bytes "$usage_bytes")
    local limit_hr=$(format_bytes "$limit_bytes")
    local max_hr=$(format_bytes "$max_usage_bytes")
    local pct="0"
    if [ "$limit_bytes" -gt 0 ] && [ "$usage_bytes" -gt 0 ]; then
        pct=$(echo "scale=1; $usage_bytes * 100 / $limit_bytes" | bc -l 2>/dev/null || echo "0")
    fi

    echo "Memory Usage: $usage_hr / $limit_hr ($pct%)"
    echo "Peak Memory:  $max_hr"
}

# Main output
echo "========================================"
echo "Slurm Job $JOB_ID Resource Usage (cgroup v1)"
echo "========================================"
echo
get_cpu_usage
echo
get_memory_usage
echo
echo "Updated: $(date)"
echo "Note: Run this script periodically to monitor usage over time."
