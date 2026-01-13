#!/bin/bash
source /opt/config/config.env
source /opt/utils/utils.sh

find "$LOG_DIR" -type f -name "cpucheck_*.log" -mtime +7 -delete || true

check_cpu() {
  log "DEBUG" "Checking CPU usage across all nodes..."
  alert=0
  max_usage=0
  max_node=""
  total_count=0

  while read -r node cpu mem; do
    usage=${cpu%\%}
    total_count=$((total_count+1))

    if [ "$usage" -ge "$CPU_THRESHOLD" ]; then
      log "WARNING" "Node $node is above threshold: ${usage}%"
      alert=1
    else
      log "INFO" "Node $node is healthy: ${usage}%"
    fi

    if [ "$usage" -gt "$max_usage" ]; then
      max_usage=$usage
      max_node=$node
    fi
  done < <(kubectl top nodes --no-headers | awk '{print $1, $3, $5}')

  echo "$max_node" > /opt/state/max_node
  echo "$max_usage" > /opt/state/max_usage

  if [ $alert -eq 0 ]; then
    log "INFO" "All $total_count nodes healthy. Highest usage=$max_usage% on $max_node"
  else
    log "ERROR" "High CPU detected. Worst=$max_usage% on $max_node"
  fi
  return $alert
}

if retry_with_config check_cpu $RETRY_COUNT $RETRY_INTERVAL; then
  exit 0
else
  if can_alert $COOLDOWN_PERIOD; then
    NODE=$(cat /opt/state/max_node)
    USAGE=$(cat /opt/state/max_usage)
    send_email "$NODE" "$USAGE"
    log "INFO" "Email sent (Node=$NODE, Usage=$USAGE%)"
  fi
  exit 0
fi
