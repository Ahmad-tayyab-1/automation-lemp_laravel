#!/usr/bin/env bash
# benchmark.sh ROUNDS: on a native_lemp server with /opt/deployer (Ansible) and /opt/deployer-bash, deploys
# the same new project with three tools, then redeploys it, removes it, and repeats with the order rotated:
#   A  /opt/deployer/deploy.sh             deploy.sh + Ansible          (site bench-a.test)
#   B  bench/deploy-bash-minimal.sh        the minimal bash script      (site bench-b.test)
#   C  /opt/deployer-bash/deploy.sh        deploy.sh + the bash engine  (site bench-c.test)
# Results: /root/bench/results.csv, one log per run, step timings (A: profile_tasks in the log,
# C: *.timings). The server's other sites are polled every second all along.
set -uo pipefail
ROUNDS=${1:-3}
REPO=${REPO:-git@bitbucket.org:mianahmad3/jpgtoword.net.git}
BRANCH=${BRANCH:-release/v1.1.8}
KEY=${KEY:-/root/.ssh/jpgtoword.net_deploy}
WATCH=${WATCH:-"jpgtoword.net standardformcalculator.com"}
BB=/opt/deployer-bash/bench
OUT=/root/bench; mkdir -p "$OUT"; rm -f "$OUT"/*.log "$OUT"/*.timings; : > "$OUT/results.csv"
site() { jq --arg s "$1" --arg r "$REPO" --arg b "$BRANCH" --arg k "$KEY" \
  '.sites[$s] = {repo: $r, aliases: [], run_migrations: false, deploy_key: $k, branch: $b, traffic: "medium", php_version: "8.2"}'; }
cp /opt/deployer/sites.json "$OUT/sites-a.json.before"; cp /opt/deployer-bash/sites.json "$OUT/sites-c.json.before"
site bench-a.test < "$OUT/sites-a.json.before" > /opt/deployer/sites.json
site bench-c.test < "$OUT/sites-c.json.before" > /opt/deployer-bash/sites.json

rm -f "$OUT/stop" "$OUT/watch.log"
( while [ ! -f "$OUT/stop" ]; do
    for d in $WATCH; do echo "$d $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: $d" http://127.0.0.1/)"; done >> "$OUT/watch.log"
    sleep 1
  done ) &

run() {   # run TOOL KIND ROUND CMD...: times CMD and appends a CSV line
  local tool=$1 kind=$2 round=$3; shift 3
  local log="$OUT/$tool-$kind-$round.log" s e rc t
  export ENGINE_TIMINGS_FILE="$OUT/$tool-$kind-$round.timings"
  s=$(date +%s.%N); "$@" > "$log" 2>&1; rc=$?; e=$(date +%s.%N)
  t=$(awk -v a="$e" -v b="$s" 'BEGIN{printf "%.1f", a-b}')
  echo "$round,$tool,$kind,$t,$rc" | tee -a "$OUT/results.csv"
}
COMMON=(--target this --setup native_lemp --branch "$BRANCH" --traffic medium --php 8.2 --env local --tls none --skip-repo-check -y)
A() { cd /opt/deployer && ANSIBLE_CALLBACKS_ENABLED=ansible.posix.profile_tasks ./deploy.sh "${COMMON[@]}" --site bench-a.test --db-mode "$1"; }
B() { "$BB/deploy-bash-minimal.sh" --site bench-b.test --repo "$REPO" --branch "$BRANCH" --key "$KEY" --traffic medium --php 8.2 --db-mode "$1"; }
C() { cd /opt/deployer-bash && ./deploy.sh "${COMMON[@]}" --site bench-c.test --db-mode "$1"; }

orders=("A B C" "B C A" "C A B")
for r in $(seq "$ROUNDS"); do
  order=${orders[$(( (r - 1) % 3 ))]}
  for t in $order; do run "$t" new "$r" "$t" seed; done
  for t in $order; do run "$t" redeploy "$r" "$t" none; done
  for d in bench-a.test bench-b.test bench-c.test; do "$BB/cleanup-site.sh" "$d"; done
done

touch "$OUT/stop"; wait
cp "$OUT/sites-a.json.before" /opt/deployer/sites.json; cp "$OUT/sites-c.json.before" /opt/deployer-bash/sites.json
echo "watch:"; awk '{print $1, $2}' "$OUT/watch.log" | sort | uniq -c
