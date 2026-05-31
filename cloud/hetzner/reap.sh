#!/bin/bash
# Fleet teardown / guardrail. Two modes:
#   reap.sh              -> 48h-only safety sweep: delete fleet boxes older than 48h
#                           (well past receptor's ~1-8h, so it NEVER cuts a live cell;
#                           catches orphans from a coordinator crash). Safe to cron.
#   reap.sh --all        -> destroy EVERY fleet box now (emergency "stop the bleeding").
#   reap.sh --run <id>   -> destroy all boxes for one run-id.
# Identifies fleet boxes by the label fleet=odepe set by fleet.py.
set -euo pipefail
MODE="${1:-safety}"

list() { hcloud server list --selector "$1" -o json; }

case "$MODE" in
  --all)
    names=$(hcloud server list --selector fleet=odepe -o columns=name | tail -n +2)
    [ -z "$names" ] && { echo "no fleet boxes."; exit 0; }
    echo "destroying ALL fleet boxes:"; echo "$names"
    echo "$names" | xargs -r -n1 hcloud server delete
    ;;
  --run)
    rid="${2:?need run-id}"
    names=$(hcloud server list --selector "fleet=odepe,run=$rid" -o columns=name | tail -n +2)
    [ -z "$names" ] && { echo "no boxes for run=$rid."; exit 0; }
    echo "$names" | xargs -r -n1 hcloud server delete
    ;;
  safety|*)
    # delete only boxes older than 48h
    now=$(date -u +%s)
    hcloud server list --selector fleet=odepe -o json \
      | python3 -c '
import json,sys,datetime
now=datetime.datetime.now(datetime.timezone.utc)
for s in json.load(sys.stdin):
    c=datetime.datetime.fromisoformat(s["created"].replace("Z","+00:00"))
    age_h=(now-c).total_seconds()/3600
    if age_h>48: print(s["name"])
' | tee /tmp/reap_old.txt | xargs -r -n1 hcloud server delete
    n=$(wc -l < /tmp/reap_old.txt 2>/dev/null || echo 0)
    echo "safety sweep: deleted $n box(es) older than 48h."
    ;;
esac
echo "remaining fleet boxes:"
hcloud server list --selector fleet=odepe -o columns=name,type,age
