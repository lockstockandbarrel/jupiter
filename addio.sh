#!/bin/bash

# Script: slurm-cgroup-monitor.sh
# Description: Display CPU, Memory, and I/O usage for a Slurm job using cgroup v1
# Requirements: Running inside a Slurm job, cgroup v1 with cpu, memory, blkio

set -euo pipefail

# Get the current Slurm job ID
JOB_ID="${SLURM_JOB_ID:-}"
if [ -z "$JOB_ID" ]; then
    echo "Error: SLURM_JOB_ID not found. Are you running inside a Slurm job?"
    exit 1
fi

CGROUP_BASE="/sys/fs/cgroup"
CPU_PATH=""
MEMORY_PATH=""
BLKIO_PATH=""

# Find cgroup paths for cpu, memory, and blkio
for controller in cpu memory blkio; do
    CGROUP_DIR="$CGROUP_BASE/$controller"
    if [ ! -d "$CGROUP_DIR" ]; then
        echo "Warning: $controller cgroup not mounted at $CGROUP_DIR. Skipping $controller stats."
        continue
    fi

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
        echo "Warning: Could not find $controller cgroup for job $JOB_ID. Skipping."
        continue
    fi

    case "$controller" in
        cpu)    CPU_PATH="$CGROUP_JOB_PATH" ;;
        memory) MEMORY_PATH="$CGROUP_JOB_PATH" ;;
        blkio)  BLKIO_PATH="$CGROUP_JOB_PATH" ;;
    esac
done

# Validate required paths
if [ -z "$CPU_PATH" ] && [ -z "$MEMORY_PATH" ] && [ -z "$BLKIO_PATH" ]; then
    echo "Error: No cgroup controllers found. Check Slurm cgroup configuration."
    exit 1
fi

echo "Slurm Job $JOB_ID Resource Usage (cgroup v1)"
echo "========================================"
[ -n "$CPU_PATH" ]    && echo "CPU:    $CPU_PATH"
[ -n "$MEMORY_PATH" ] && echo "Memory: $MEMORY_PATH"
[ -n "$BLKIO_PATH" ]  && echo "I/O:    $BLKIO_PATH"
echo

# === CPU Usage ===
get_cpu_usage() {
    if [ -z "$CPU_PATH" ]; then
        echo "CPU: [Not available]"
        return
    fi

    local usage_file="$CPU_PATH/cpuacct.usage"
    local stat_file="$CPU_PATH/cpuacct.stat"
    local shares_file="$CPU_PATH/cpu.shares"
    local quota_file="$CPU_PATH/cpu.cfs_quota_us"
    local period_file="$CPU_PATH/cpu.cfs_period_us"

    local total_sec="0"
    if [ -f "$usage_file" ]; then
        local ns=$(cat "$usage_file")
        total_sec=$(echo "scale=3; $ns / 1000000000" | bc -l 2>/dev/null || echo "0")
    fi

    local shares=1024
    [ -f "$shares_file" ] && shares=$(cat "$shares_file")

    local quota=-1 period=100000
    [ -f "$quota_file" ] && quota=$(cat "$quota_file")
    [ -f "$period_file" ] && period=$(cat "$period_file")

    local cpu_limit="unlimited"
    if [ "$quota" -gt 0 ]; then
        cpu_limit=$(echo "scale=2; $quota / $period" | bc -l)
    fi

    echo "CPU Usage (total): ${total_sec}s"
    echo "CPU Shares: $shares"
    echo "CPU Limit (CFS): $cpu_limit vCPUs"
}

# === Memory Usage ===
get_memory_usage() {
    if [ -z "$MEMORY_PATH" ]; then
        echo "Memory: [Not available]"
        return
    fi

    local usage_file="$MEMORY_PATH/memory.usage_in_bytes"
    local limit_file="$MEMORY_PATH/memory.limit_in_bytes"
    local max_file="$MEMORY_PATH/memory.max_usage_in_bytes"

    local usage=0 limit=0 max=0
    [ -f "$usage_file" ] && usage=$(cat "$usage_file")
    [ -f "$limit_file" ] && limit=$(cat "$limit_file")
    [ -f "$max_file" ] && max=$(cat "$max_file")

    format_bytes() {
        local bytes=$1
        if command -v numfmt >/dev/null 2>&1; then
            numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes B"
        else
            local units=("B" "KiB" "MiB" "GiB" "TiB")
            local unit=0
            while [ "$bytes" -ge 1024 ] && [ "$unit" -lt 4 ]; do
                bytes=$((bytes / 1024))
                unit=$((unit + 1))
            done
            echo "$bytes${units[$unit]}"
        fi
    }

    local usage_hr=$(format_bytes "$usage")
    local limit_hr=$(format_bytes "$limit")
    local max_hr=$(format_bytes "$max")
    local pct="0"
    if [ "$limit" -gt 0 ] && [ "$usage" -gt 0 ]; then
        pct=$(echo "scale=1; $usage * 100 / $limit" | bc -l 2>/dev/null || echo "0")
    fi

    echo "Memory Usage: $usage_hr / $limit_hr ($pct%)"
    echo "Peak Memory:  $max_hr"
}

# === I/O Statistics ===
get_io_usage() {
    if [ -z "$BLKIO_PATH" ]; then
        echo "I/O: [blkio controller not available]"
        return
    fi

    local sectors_read=0 sectors_written=0
    local bytes_read=0 bytes_written=0
    local ios_read=0 ios_written=0

    # blkio.throttle.io_service_bytes (preferred: per-device)
    local throttle_file="$BLKIO_PATH/blkio.throttle.io_service_bytes"
    local throttle_ios_file="$BLKIO_PATH/blkio.throttle.io_serviced"

    if [ -f "$throttle_file" ]; then
        bytes_read=$(grep -i 'Read' "$throttle_file" | awk '{sum += $3} END {print sum+0}')
        bytes_written=$(grep -i 'Write' "$throttle_file" | awk '{sum += $3} END {print sum+0}')
    else
        # Fallback: blkio.io_service_bytes (total across all devices)
        local service_file="$BLKIO_PATH/blkio.io_service_bytes"
        if [ -f "$service_file" ]; then
            bytes_read=$(grep -i 'Read' "$service_file" | awk '{sum += $3} END {print sum+0}')
            bytes_written=$(grep -i 'Write' "$service_file" | awk '{sum += $3} END {print sum+0}')
        fi
    fi

    # I/O operations
    if [ -f "$throttle_ios_file" ]; then
        ios_read=$(grep -i 'Read' "$throttle_ios_file" | awk '{sum += $3} END {print sum+0}')
        ios_written=$(grep -i 'Write' "$throttle_ios_file" | awk '{sum += $3} END {print sum+0}')
    else
        local serviced_file="$BLKIO_PATH/blkio.io_serviced"
        if [ -f "$serviced_file" ]; then
            ios_read=$(grep -i 'Read' "$serviced_file" | awk '{sum += $3} END {print sum+0}')
            ios_written=$(grep -i 'Write' "$serviced_file" | awk '{sum += $3} END {print sum+0}')
        fi
    fi

    format_bytes() {
        local bytes=$1
        if command -v numfmt >/dev/null 2>&1; then
            numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes B"
        else
            local units=("B" "KiB" "MiB" "GiB" "TiB")
            local unit=0
            while [ "$bytes" -ge 1024 ] && [ "$unit" -lt 4 ]; do
                bytes=$((bytes / 1024))
                unit=$((unit + 1))
            done
            echo "$bytes${units[$unit]}"
        fi
    }

    local read_hr=$(format_bytes "$bytes_read")
    local write_hr=$(format_bytes "$bytes_written")

    echo "I/O Read:  $read_hr ($ios_read ops)"
    echo "I/O Write: $write_hr ($ios_written ops)"
}

# === Main Output ===
echo "=== CPU ==="
get_cpu_usage
echo

echo "=== Memory ==="
get_memory_usage
echo

echo "=== I/O (blkio) ==="
get_io_usage
echo

echo "Updated: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Tip: Run in a loop: watch -n 5 ./slurm-cgroup-monitor.sh"
