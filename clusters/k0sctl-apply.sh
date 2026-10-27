#!/bin/bash
# `k0sctl apply` for ONE cluster, with the guard rails and the measures that the issues #70 and #203 call for.
#
#   clusters/k0sctl-apply.sh <svc|core|control> [--dry-run] [--yes]
#
# It always uses k0sctl (the tool of this repository), with the config of clusters/<cluster>/setup/k0s-cluster.yml, the SOPS
# way of its README. What it adds around it:
#   1. Git is the source of truth: the config and every file it uploads must be the ones of origin/main.
#   2. The date of the uploaded files is set to the date of their last commit. k0sctl compares the modification date of each file
#      of `files:` with the remote one and marks the host "for upgrade" (stop, reinstall and start the k0s service) when they
#      differ; the date of a file in a Git checkout is the date of the checkout, so without this every fresh checkout restarts
#      every controller. After one apply the remote files carry the date of the local ones and the next apply changes nothing.
#   3. `--concurrency 1`: one host at a time (the default is 30 hosts at once).
#   4. A dry run is shown first, and nothing starts without your yes.
#   5. During the apply: the API of the cluster and one public address are probed every second.
#   6. After: the windows where they failed, the containers that restarted, and for each node the state of the API server (new
#      process, audit flags, audit file, GOMEMLIMIT) are printed.
# The decrypted config is a temporary 0600 copy next to the real one (k0sctl needs the paths of `files:` relative to it), removed
# at the end: the tracked file is not touched, so there is no re-encryption and no diff.
#
# Run from a terminal that has the SSH key of the nodes and the kubectl context of the cluster. The log is
# /tmp/k0sctl-apply-<cluster>-<date>.log.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
cluster=${1:-}; shift || true
YES=0; DRY=0
for a in "$@"; do case $a in --yes) YES=1 ;; --dry-run) DRY=1 ;; *) echo "unknown option $a"; exit 1 ;; esac; done
case $cluster in
  svc) PUBLIC=git.phorge.fr ;; core) PUBLIC=auth.phorge.fr ;; control) PUBLIC=api.phorge.fr ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
setup=clusters/$cluster/setup; cfg=$setup/k0s-cluster.yml; tmpcfg=$setup/.k0s-cluster.apply.yml
LOG=/tmp/k0sctl-apply-$cluster-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG") 2>&1
say() { echo "[$(date +%T)] $*"; }
die() { say "STOP: $*"; exit 1; }
confirm() { [ "$YES" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = yes ]; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)
ssh_() { local ip=$1; shift; ssh "${SSH_OPTS[@]}" "root@$ip" "$@"; }
say "cluster $cluster, log $LOG"

[ -x ./k0sctl ] || die "./k0sctl (the binary) is not there"
set -a; # shellcheck disable=SC1091
source ./.env; set +a
export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-$REPO/age.agekey} DISABLE_TELEMETRY=true

# 1. Git is the source of truth
git fetch -q origin main || die "git fetch failed"
notmain() { # a dry run only reads, so it may look at unmerged files; an apply may not
  if [ "$DRY" = 1 ]; then say "WARNING: $1 differs from origin/main (fine for a dry run, not for the apply)"; else die "$1 differs from origin/main: merge and pull first"; fi
}
git diff --quiet origin/main -- "$cfg" || notmain "$cfg"

cleanup() { rm -f "$tmpcfg"; [ -n "${PIDS:-}" ] && kill $PIDS 2>/dev/null; true; }
trap cleanup EXIT INT TERM
sops -d "$cfg" > "$tmpcfg" || die "sops cannot decrypt $cfg (a hand edit of a plain line breaks the SOPS MAC: clusters/sops-reseal.sh)"
chmod 600 "$tmpcfg"

# the files that k0sctl uploads, relative to the config
mapfile -t SRCS < <(grep -E '^\s+src: ' "$tmpcfg" | awk '{print $2}' | sort -u)
for s in "${SRCS[@]}"; do
  f=$(realpath -m "$setup/$s"); rel=${f#"$REPO"/}
  git diff --quiet origin/main -- "$rel" || notmain "$rel"
  # 2. its date is the one of its last commit
  touch -d "$(git log -1 --format=%cI -- "$rel")" "$f"
done
say "uploaded files: ${SRCS[*]} (dates set to their last commit)"

mapfile -t ADDRS < <(grep -E '^\s+address: ' "$tmpcfg" | awk '{print $2}')
for ip in "${ADDRS[@]}"; do ssh_ "$ip" true || die "no SSH to $ip"; done
[ "$(kubectl --context "$cluster" get nodes --no-headers --request-timeout=10s | awk '$2!="Ready"' | wc -l)" = 0 ] || die "a node is not Ready"
kubectl --context "$cluster" get --raw /readyz --request-timeout=10s >/dev/null || die "the API is not ready"

# 4. the dry run
say "k0sctl dry run (nothing is changed):"
./k0sctl apply --dry-run --concurrency 1 -c "$tmpcfg" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E "will be upgraded|marked for upgrade|dry-run: \* |stop k0s|reinstall|start k0s|restart|upload file|Finished|level=(warning|fatal|error)" | grep -v "set permissions" | cut -c1-190
[ "$DRY" = 1 ] && { say "dry run only: stopped here"; exit 0; }
confirm "Run k0sctl apply on $cluster now? It restarts the controllers one after the other; the API server of each is down for 30 to 90 seconds." || die "cancelled"

# the directory of the audit log has to exist before the API server restarts (the drop-in that creates it is read at that restart)
for ip in "${ADDRS[@]}"; do ssh_ "$ip" 'install -d -o kube-apiserver -g kube-apiserver -m 0750 /var/lib/k0s-audit && cp -n -p /etc/k0s/k0s.yaml /etc/k0s/k0s.yaml.before-k0sctl'; done

# baseline and probes
T=$(mktemp -d)
kubectl --context "$cluster" get pods -A -o json --request-timeout=20s | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps({'%s/%s/%s' % (p['metadata']['namespace'], p['metadata']['name'], c['name']): c.get('restartCount', 0) for p in d['items'] for c in (p['status'].get('containerStatuses') or [])}))" > "$T/before.json"
for ip in "${ADDRS[@]}"; do ssh_ "$ip" 'pgrep -f "^/var/lib/k0s/bin/kube-apiserver" | head -1' > "$T/pid-$ip"; done
( while :; do kubectl --context "$cluster" get --raw /readyz --request-timeout=2s >/dev/null 2>&1 && r=ok || r=fail; echo "$(date +%s) $r"; sleep 1; done ) > "$T/api.log" & PIDS="$!"
( while :; do c=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "https://$PUBLIC/"); [ "$c" != 000 ] && r=ok || r=fail; echo "$(date +%s) $r"; sleep 1; done ) > "$T/public.log" & PIDS="$PIDS $!"

say "k0sctl apply --concurrency 1 (started $(date +%T))"
START=$(date +%s)
./k0sctl apply --concurrency 1 -c "$tmpcfg"; RC=$?
END=$(date +%s)
sleep 20; kill $PIDS 2>/dev/null; PIDS=""
say "k0sctl exited with $RC after $((END - START)) s"

# 6. what happened
python3 - "$T" "$START" "$END" <<'PY'
import sys, json
t, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
import datetime
def windows(path):
    out, cur = [], None
    for l in open(path):
        ts, r = l.split(); ts = int(ts)
        if r == "fail":
            cur = cur or [ts, ts]; cur[1] = ts
        elif cur:
            out.append(cur); cur = None
    if cur: out.append(cur)
    return out
for name, label in (("api", "API of the cluster (/readyz through the control plane address)"), ("public", "public address")):
    w = windows("%s/%s.log" % (t, name))
    n = sum(1 for _ in open("%s/%s.log" % (t, name)))
    print("  %s: %d probes, %d failed windows%s" % (label, n, len(w), "".join("\n     %s for %d s" % (datetime.datetime.fromtimestamp(a).strftime("%H:%M:%S"), b - a + 1) for a, b in w)))
PY
kubectl --context "$cluster" get pods -A -o json --request-timeout=20s | python3 -c "
import sys, json
before = json.load(open('$T/before.json'))
d = json.load(sys.stdin)
up = [(k, v - before.get(k, 0)) for k, v in ((('%s/%s/%s' % (p['metadata']['namespace'], p['metadata']['name'], c['name'])), c.get('restartCount', 0)) for p in d['items'] for c in (p['status'].get('containerStatuses') or [])) if v > before.get(k, 0)]
print('  containers that restarted during the apply: %d' % len(up))
for k, n in up: print('     %s +%d' % (k, n))"
say "nodes:"
for ip in "${ADDRS[@]}"; do
  name=$(kubectl --context "$cluster" get nodes -o jsonpath="{range .items[*]}{.metadata.name}{' '}{.status.addresses[?(@.type=='InternalIP')].address}{'\n'}{end}" | awk -v ip="$ip" '$2==ip {print $1}')
  ready=$(kubectl --context "$cluster" get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  ssh_ "$ip" "p=\$(pgrep -f '^/var/lib/k0s/bin/kube-apiserver' | head -1)
    printf '  %s: Ready=%s | API server %s (before: %s) | audit flags: %s | audit file: %s | policy: %s | GOMEMLIMIT of the API server: %s\n' '$name' '$ready' \"\$p\" '$(cat "$T/pid-$ip")' \"\$(tr '\0' ' ' < /proc/\$p/cmdline | grep -c audit-log-path)\" \"\$(ls -l /var/lib/k0s-audit/audit.log 2>/dev/null | awk '{print \$5\" bytes\"}')\" \"\$(md5sum /etc/k0s/audit-policy.yaml 2>/dev/null | cut -c1-8)\" \"\$(tr '\0' '\n' < /proc/\$p/environ | grep ^GOMEMLIMIT= || echo none)\""
done
echo "  policy in Git: $(md5sum clusters/audit-policy.yaml | cut -c1-8)"
rm -rf "$T"
[ "$RC" = 0 ] || die "k0sctl failed (rc=$RC): see $LOG. The configs of the nodes before the apply are /etc/k0s/k0s.yaml.before-k0sctl"
say "done"
