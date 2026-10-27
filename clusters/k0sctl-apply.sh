#!/bin/bash
# Rolls the Kubernetes audit log (docs/kubernetes-audit.md) out on the control plane nodes of the clusters, one node at a time,
# the way the GOMEMLIMIT drop-in was (issue #203): NOT with `k0sctl apply`, which restarts the controllers all at once and has
# cut the clusters before (issue #70).
#
# For each node: upload the policy and the systemd drop-in, create /var/lib/k0s-audit, add the five audit-* flags to
# /etc/k0s/k0s.yaml (the original is kept as k0s.yaml.pre-audit), restart k0scontroller on THAT node, and wait until the node is
# Ready, the API server runs with the flags and the audit file is written. Then it waits, checks that no container went into a
# restart loop, and goes to the next node. A node that does not come back in 5 minutes is put back as it was, and the script stops.
# A node that already has the flags but another policy only gets the new policy (the API server reads it when it starts).
#
#   clusters/audit-rollout.sh                    svc, core, then control (asks before each cluster)
#   clusters/audit-rollout.sh --clusters svc     only these clusters, in this order
#   clusters/audit-rollout.sh --dry-run          reads only: shows what would be done on every node
#   clusters/audit-rollout.sh --yes              no question (not for a first run)
#
# Run it from a terminal that has the SSH key of the nodes and the kubectl contexts svc, core and control. The log is kept in
# /tmp/k8s-audit-rollout-<date>.log.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD

CLUSTERS=(svc core control)
YES=0
DRY=0
while [ $# -gt 0 ]; do
  case $1 in
    --clusters) IFS=, read -r -a CLUSTERS <<< "$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

LOG=/tmp/k8s-audit-rollout-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
echo "log: $LOG"

SETTLE=60          # seconds to wait after a node is back, before the next one
MAX_NEW_RESTARTS=6 # container restarts allowed in a cluster during the rollout of ONE node (cilium-operator does one or two)
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)
say() { echo "[$(date +%T)] $*"; }
die() { say "STOP: $*"; exit 1; }
ssh_() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "root@$ip" "$@"; }
confirm() { # confirm "question"
  [ "$YES" = "1" ] && return 0
  read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ] || [ "$a" = "yes" ]
}
restarts() { # total restart count of every container of a cluster
  kubectl --context "$1" get pods -A -o json --request-timeout=20s | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(sum(c.get('restartCount', 0) for p in d['items'] for c in (p['status'].get('containerStatuses') or [])))"
}
cluster_healthy() {
  local ctx=$1
  [ "$(kubectl --context "$ctx" get nodes --no-headers --request-timeout=10s | awk '$2!="Ready"' | wc -l)" = "0" ] \
    && kubectl --context "$ctx" get --raw /readyz --request-timeout=10s >/dev/null
}

# Git is the source of truth: what is uploaded must be what is merged
git fetch -q origin main || die "git fetch failed"
for f in clusters/audit-policy.yaml clusters/k0scontroller-audit-dir.conf; do
  git diff --quiet origin/main -- "$f" || die "$f differs from origin/main: merge it first (and pull)"
done

roll_node() { # roll_node <context> <node name> <ip>
  local ctx=$1 name=$2 ip=$3 reload=0
  say "$ctx/$name ($ip)"
  cluster_healthy "$ctx" || { say "  the cluster is not healthy"; return 1; }
  if ssh_ "$ip" 'pgrep -a kube-apiserver | grep -q audit-log-path'; then
    if [ "$(ssh_ "$ip" 'md5sum /etc/k0s/audit-policy.yaml' | cut -c1-32)" = "$(md5sum "$REPO/clusters/audit-policy.yaml" | cut -c1-32)" ]; then
      say "  already has the audit flags and this policy: nothing to do"; return 0
    fi
    reload=1; say "  has the flags, another policy: the policy is replaced and the API server restarted"
  fi
  if [ "$reload" = "0" ]; then
    [ "$(ssh_ "$ip" 'grep -c "^      default-watch-cache-size: \"20\"$" /etc/k0s/k0s.yaml')" = "1" ] || { say "  the config anchor is not there exactly once"; return 1; }
  fi
  if [ "$DRY" = "1" ]; then say "  (dry run) would $([ $reload = 1 ] && echo 'replace the policy' || echo 'add the flags') and restart k0scontroller here"; return 0; fi

  # files and directory (idempotent)
  scp -q "${SSH_OPTS[@]}" "$REPO/clusters/audit-policy.yaml" "root@$ip:/etc/k0s/audit-policy.yaml.new" || { say "  policy upload failed"; return 1; }
  scp -q "${SSH_OPTS[@]}" "$REPO/clusters/k0scontroller-audit-dir.conf" "root@$ip:/etc/systemd/system/k0scontroller.service.d/audit-dir.conf" || { say "  drop-in upload failed"; return 1; }
  ssh_ "$ip" 'chmod 0644 /etc/systemd/system/k0scontroller.service.d/audit-dir.conf /etc/k0s/audit-policy.yaml.new
              install -d -o kube-apiserver -g kube-apiserver -m 0750 /var/lib/k0s-audit
              [ -f /etc/k0s/audit-policy.yaml ] && cp -p /etc/k0s/audit-policy.yaml /etc/k0s/audit-policy.yaml.prev
              mv /etc/k0s/audit-policy.yaml.new /etc/k0s/audit-policy.yaml; chmod 0644 /etc/k0s/audit-policy.yaml' || { say "  files failed"; return 1; }

  if [ "$reload" = "0" ]; then
    ssh_ "$ip" 'cp -p /etc/k0s/k0s.yaml /etc/k0s/k0s.yaml.pre-audit && cat /etc/k0s/k0s.yaml' > "/tmp/k0s-$name.cur" || { say "  could not read the config"; return 1; }
    python3 - "/tmp/k0s-$name.cur" "/tmp/k0s-$name.new" <<'PY' || { say "  config edit failed"; return 1; }
import sys
cur = open(sys.argv[1]).read()
anchor = '      default-watch-cache-size: "20"\n'
assert cur.count(anchor) == 1, "anchor not found once"
add = ('      audit-policy-file: /etc/k0s/audit-policy.yaml\n'
       '      audit-log-path: /var/lib/k0s-audit/audit.log\n'
       '      audit-log-maxsize: "100"\n'
       '      audit-log-maxbackup: "3"\n'
       '      audit-log-maxage: "3"\n')
open(sys.argv[2], "w").write(cur.replace(anchor, anchor + add, 1))
PY
    echo "  config diff:"; diff "/tmp/k0s-$name.cur" "/tmp/k0s-$name.new" | sed 's/^/    /'
    scp -q "${SSH_OPTS[@]}" "/tmp/k0s-$name.new" "root@$ip:/etc/k0s/k0s.yaml" || { say "  config upload failed"; return 1; }
    rm -f "/tmp/k0s-$name.cur" "/tmp/k0s-$name.new"
  fi

  local before_pid ready flags file now_pid i ok=0
  before_pid=$(ssh_ "$ip" 'pgrep -f "^/var/lib/k0s/bin/kube-apiserver" | head -1')
  say "  restarting k0scontroller on $name"
  ssh_ "$ip" 'systemctl daemon-reload && systemctl restart k0scontroller' || say "  (the restart command returned an error, waiting anyway)"
  for i in $(seq 1 60); do
    sleep 5
    ready=$(kubectl --context "$ctx" get node "$name" --request-timeout=5s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    flags=$(ssh_ "$ip" 'pgrep -a kube-apiserver | grep -c audit-log-path' 2>/dev/null)
    file=$(ssh_ "$ip" 'test -s /var/lib/k0s-audit/audit.log && echo yes' 2>/dev/null)
    now_pid=$(ssh_ "$ip" 'pgrep -f "^/var/lib/k0s/bin/kube-apiserver" | head -1' 2>/dev/null)
    if [ "$ready" = "True" ] && [ "$flags" = "1" ] && [ "$file" = "yes" ] && [ -n "$now_pid" ] && [ "$now_pid" != "$before_pid" ]; then ok=1; break; fi
  done
  if [ "$ok" != "1" ]; then
    say "  FAILED after 5 minutes (ready=$ready flags=$flags file=$file): putting $name back as it was"
    if [ "$reload" = "1" ]; then ssh_ "$ip" 'cp -p /etc/k0s/audit-policy.yaml.prev /etc/k0s/audit-policy.yaml && systemctl restart k0scontroller'
    else ssh_ "$ip" 'cp -p /etc/k0s/k0s.yaml.pre-audit /etc/k0s/k0s.yaml && systemctl restart k0scontroller'; fi
    return 2
  fi
  say "  back after $((i * 5)) s: node Ready, API server with the audit flags, audit file written"
  ssh_ "$ip" 'ls -l /var/lib/k0s-audit/ | tail -n +2 | sed "s/^/    /"'
  return 0
}

# What the user sees first
say "clusters: ${CLUSTERS[*]}$([ "$DRY" = "1" ] && echo '  (DRY RUN: nothing is changed)')"
for c in "${CLUSTERS[@]}"; do
  kubectl --context "$c" get nodes >/dev/null 2>&1 || die "no kubectl context '$c'"
  cluster_healthy "$c" || die "cluster $c is not healthy"
done
[ "$DRY" = "1" ] || confirm "Restart k0scontroller node by node on: ${CLUSTERS[*]}?" || die "cancelled"

for c in "${CLUSTERS[@]}"; do
  say "===== cluster $c"
  mapfile -t ADDRS < <(grep -E '^\s+address: ' "clusters/$c/setup/k0s-cluster.yml" | awk '{print $2}')
  [ "${#ADDRS[@]}" -ge 1 ] || die "no node address in clusters/$c/setup/k0s-cluster.yml"
  if [ "$DRY" = "0" ]; then
    [ "$c" = "control" ] && { confirm "control: is NO end-to-end test of the API running right now?" || die "cancelled"; }
    confirm "Start with $c (${#ADDRS[@]} nodes, one at a time)?" || die "cancelled"
  fi
  base=$(restarts "$c")
  for ip in "${ADDRS[@]}"; do
    name=$(kubectl --context "$c" get nodes -o jsonpath="{range .items[*]}{.metadata.name}{' '}{.status.addresses[?(@.type=='InternalIP')].address}{'\n'}{end}" | awk -v ip="$ip" '$2==ip {print $1}')
    [ -n "$name" ] || die "no node of $c has the address $ip"
    roll_node "$c" "$name" "$ip"; rc=$?
    [ $rc = 0 ] || die "node $name of $c: rc=$rc. The nodes done before it keep the audit; $name was put back as it was if it failed. See $LOG"
    [ "$DRY" = "1" ] && continue
    say "  waiting ${SETTLE}s for the cluster to settle"; sleep "$SETTLE"
    cluster_healthy "$c" || die "cluster $c is not healthy after $name"
    now=$(restarts "$c"); delta=$((now - base)); base=$now
    say "  container restarts in $c during this node: $delta"
    [ "$delta" -le "$MAX_NEW_RESTARTS" ] || die "$delta containers restarted in $c (more than $MAX_NEW_RESTARTS): looks like the symptom of issue #70, stopping here. Look at: kubectl --context $c get pods -A | grep -v Running"
  done
  say "cluster $c done"
  [ "$DRY" = "1" ] || [ "$c" = "${CLUSTERS[-1]}" ] || confirm "Go on to the next cluster?" || die "stopped by you after $c"
done

say "all done: $([ "$DRY" = "1" ] && echo 'dry run, nothing changed' || echo 'the audit is on')"
echo "Check, in Grafana (Explore, Loki): {job=\"k8s-audit\"} has lines for every cluster and node, and the dashboard \"Kubernetes audit\" fills in."
