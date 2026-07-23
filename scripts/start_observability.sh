#!/bin/bash
# Start the local observability stack (Prometheus + Grafana + node_exporter + pushgateway).
# All four are user-binaries running on user ports — no Docker, no sudo.
#
# Usage:
#   bash scripts/start_observability.sh           # start in background, write PIDs
#   bash scripts/start_observability.sh stop      # stop everything
#   bash scripts/start_observability.sh status    # check what's running
#
# Access from your laptop:
#   ssh -L 3000:localhost:3000 -L 9090:localhost:9090 abumukh-ldap@<server>
#   then open http://localhost:3000 (Grafana) — login admin/admin

set -euo pipefail
TOOLS=/home/abumukh-ldap/tools
RUN=/home/abumukh-ldap/tools/run
mkdir -p "$RUN"

start() {
    if [[ -f "$RUN/prometheus.pid" ]] && kill -0 "$(cat "$RUN/prometheus.pid")" 2>/dev/null; then
        echo "Prometheus already running (PID $(cat "$RUN/prometheus.pid"))"
    else
        nohup "$TOOLS/prometheus/prometheus" \
            --config.file="$TOOLS/prometheus/prometheus.yml" \
            --storage.tsdb.path="$TOOLS/prometheus/data" \
            --storage.tsdb.retention.time=7d \
            --web.listen-address=:9090 \
            >> "$RUN/prometheus.out" 2>&1 &
        echo $! > "$RUN/prometheus.pid"
        echo "Prometheus started (PID $!) on :9090"
    fi

    if [[ -f "$RUN/node_exporter.pid" ]] && kill -0 "$(cat "$RUN/node_exporter.pid")" 2>/dev/null; then
        echo "node_exporter already running"
    else
        nohup "$TOOLS/node_exporter/node_exporter" \
            --collector.textfile.directory="$TOOLS/prometheus/textfile_collector" \
            --collector.cpu.info \
            --collector.meminfo \
            --collector.netdev \
            --collector.systemd.unit-include='nothing-here' \
            --no-collector.systemd \
            --web.listen-address=:9100 \
            >> "$RUN/node_exporter.out" 2>&1 &
        echo $! > "$RUN/node_exporter.pid"
        echo "node_exporter started (PID $!) on :9100"
    fi

    if [[ -f "$RUN/pushgateway.pid" ]] && kill -0 "$(cat "$RUN/pushgateway.pid")" 2>/dev/null; then
        echo "pushgateway already running"
    else
        nohup "$TOOLS/pushgateway/pushgateway" \
            --web.listen-address=:9091 \
            >> "$RUN/pushgateway.out" 2>&1 &
        echo $! > "$RUN/pushgateway.pid"
        echo "pushgateway started (PID $!) on :9091"
    fi

    if [[ -f "$RUN/grafana.pid" ]] && kill -0 "$(cat "$RUN/grafana.pid")" 2>/dev/null; then
        echo "Grafana already running"
    else
        cd "$TOOLS/grafana"
        nohup ./bin/grafana server \
            --config="$TOOLS/grafana/conf-custom/custom.ini" \
            --homepath="$TOOLS/grafana" \
            >> "$RUN/grafana.out" 2>&1 &
        echo $! > "$RUN/grafana.pid"
        echo "Grafana started (PID $!) on :3000"
    fi

    echo ""
    echo "=== Endpoints (forward via ssh -L) ==="
    echo "Grafana:      http://localhost:3000  (admin/admin)"
    echo "Prometheus:   http://localhost:9090"
    echo "node_exporter: http://localhost:9100/metrics"
    echo "pushgateway:  http://localhost:9091"
}

stop() {
    for svc in grafana pushgateway node_exporter prometheus; do
        if [[ -f "$RUN/$svc.pid" ]]; then
            pid=$(cat "$RUN/$svc.pid")
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
                echo "Stopped $svc (PID $pid)"
            fi
            rm -f "$RUN/$svc.pid"
        fi
    done
}

status() {
    for svc in prometheus node_exporter pushgateway grafana; do
        if [[ -f "$RUN/$svc.pid" ]] && kill -0 "$(cat "$RUN/$svc.pid")" 2>/dev/null; then
            echo "$svc: RUNNING (PID $(cat "$RUN/$svc.pid"))"
        else
            echo "$svc: stopped"
        fi
    done
}

case "${1:-start}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *)      echo "Usage: $0 {start|stop|status}"; exit 1 ;;
esac
