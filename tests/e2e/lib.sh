# Helpers shared by the e2e groups. Sourced by run.sh, never run on its own.
#
# The suite runs against the real `control` cluster and the real Incus cluster: it creates tenants
# named e2e-<run id>-* and removes them at the end. Nothing it creates is reused by a later run, nothing outside e2e-* is touched.

E2E_CONTEXT=${E2E_CONTEXT:-control}
INCUS_HOST=${INCUS_HOST:-10.10.0.1}
RUN_ID=${RUN_ID:-$(printf '%05d' $((RANDOM % 100000)))}
LABEL="e2e.phorge.fr/run"
IMG_DEBIAN=${IMG_DEBIAN:-debian/13/cloud}
IMG_ALPINE=${IMG_ALPINE:-alpine/3.22/cloud}

# One tenant per role.
TA="e2e-$RUN_ID-a"   # medium: instances, images, access, network
TB="e2e-$RUN_ID-b"   # small: quota and cross-tenant isolation
TE="e2e-$RUN_ID-abcdefghijklmnopqr"  # 28 characters, the longest name allowed
TD="e2e-$RUN_ID-d"   # deleted while it holds a running VM
TX="e2e-$RUN_ID-x"   # a fifth network, to compare subnets

shopt -s lastpipe   # so `printf ... | accept` counts in this shell, not in a subshell
PASS=0; FAIL=0; SKIP=0; FAILED=()
TRACK_TENANTS=(); TRACK_NS=(); TRACK_XR=()   # TRACK_XR: "kind namespace name"
if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; Z=$'\e[0m'; else R=; G=; Y=; B=; Z=; fi

K() { kubectl --context "$E2E_CONTEXT" "$@"; }
# incus on a cluster node, over SSH. Arguments are re-quoted so they reach incus untouched.
INCUS() { ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$INCUS_HOST" "LC_ALL=C incus $(printf '%q ' "$@")"; }
# Run a shell snippet inside an instance: vm_sh <project> <instance> '<snippet>'
vm_sh() { INCUS exec "$2" --project "$1" -- sh -c "$3"; }

section() { printf '\n%s== %s%s\n' "$B" "$*" "$Z"; }
pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "${2//$'\n'/$'\n       '}"; return 1; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$Y" "$Z" "$1"; }
# note: an observed behaviour that is documented rather than asserted (a characterisation).
note() { printf '  %sINFO%s %s\n' "$Y" "$Z" "$*"; }

eq()    { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected: $2"$'\n'"actual:   $3"; }
match() { [[ "$3" =~ $2 ]] && pass "$1" || fail "$1" "expected to match: $2"$'\n'"actual: $3"; }
# has: the text contains the string as is (no regex: keys and addresses hold '+' and '.').
has()   { [[ "$3" == *"$2"* ]] && pass "$1" || fail "$1" "expected to contain: $2"$'\n'"actual: $3"; }
nomatch() { [[ ! "$3" =~ $2 ]] && pass "$1" || fail "$1" "expected not to match: $2"$'\n'"actual: $3"; }
# check <desc> <cmd...>: passes when the command exits 0.
check() { local d=$1; shift; local out; if out=$("$@" 2>&1); then pass "$d"; else fail "$d" "$out"; fi; }

# accept / reject: server-side dry run of the YAML on stdin, nothing is stored.
accept() {
  local d=$1 out; out=$(K apply --dry-run=server -f - 2>&1) && pass "accepts: $d" || fail "accepts: $d" "$out"
}
reject() {
  local d=$1 rx=$2 out; if out=$(K apply --dry-run=server -f - 2>&1); then fail "rejects: $d" "was accepted"; else
    [[ "$out" =~ $rx ]] && pass "rejects: $d" || fail "rejects: $d" "refused, but not for the expected reason ($rx):"$'\n'"$out"; fi
}
# defaulted <desc> <jq filter> <expected>: the object after the server applied the XRD defaults.
defaulted() {
  local d=$1 f=$2 want=$3 out; out=$(K apply --dry-run=server -o json -f - 2>&1) || { fail "$d" "$out"; return; }
  eq "$d" "$want" "$(jq -r "$f" <<<"$out")"
}

# wait_until <timeout s> <description> <cmd...>: polls every 3 s, returns 0 as soon as the command does.
wait_until() {
  local t=$1 d=$2; shift 2; local end=$((SECONDS+t))
  while (( SECONDS < end )); do "$@" >/dev/null 2>&1 && return 0; sleep 3; done
  return 1
}

cond() { K ${3:+-n "$3"} get "$1" "$2" -o jsonpath="{.status.conditions[?(@.type==\"$4\")].status}" 2>/dev/null; }
cond_msg() { K ${3:+-n "$3"} get "$1" "$2" -o jsonpath="{.status.conditions[?(@.type==\"$4\")].message}" 2>/dev/null; }
xr_ready() { [[ $(cond "$1" "$2" "$3" Ready) == True ]]; }
gone() { ! K ${3:+-n "$3"} get "$1" "$2" >/dev/null 2>&1; }
# why <kind> <name> <ns>: what a stuck XR reports, for a failure message.
why() { K -n "$3" get "$1" "$2" -o json 2>/dev/null | jq -r '[.status.conditions[]? | select(.status!="True") | "\(.type): \(.reason) \(.message)"] | join("\n")'; }
# mr_msgs <ns> <xr name>: the non-True conditions of every managed resource composed for an XR.
mr_msgs() {
  K -n "$1" get managed -l "crossplane.io/composite=$2" -o json 2>/dev/null | jq -r '[.items[] | .kind as $k | .status.conditions[]? | select(.status!="True") | "\($k) \(.type)=\(.status) \(.message // "")"] | join(" | ")'
}
wait_ready() { # kind ns name timeout
  wait_until "$4" "$3 Ready" xr_ready "$1" "$3" "$2"
}
sget() { K -n "$2" get "$1" "$3" -o jsonpath="$4" 2>/dev/null; }   # sget <kind> <ns> <name> <jsonpath>

tenant_yaml() { # name owner plan [displayName] [namespace]
  cat <<EOF
apiVersion: phorge.fr/v1alpha1
kind: Tenant
metadata:
  name: $1
  namespace: ${5:-phorge-system}
  labels: {$LABEL: "$RUN_ID"}
spec:
  owner: $2
  plan: $3
${4:+  displayName: $4}
EOF
}

# ensure_tenant <name> <plan> [owner]: creates the tenant once and waits for Ready.
ensure_tenant() {
  local n=$1 plan=$2 owner=${3:-e2e@example.org}
  K -n phorge-system get tenants.phorge.fr "$n" >/dev/null 2>&1 && return 0
  TRACK_TENANTS+=("$n")
  local out; out=$(tenant_yaml "$n" "$owner" "$plan" | K apply -f - 2>&1) || { fail "tenant $n is created" "$out"; return 1; }
  if wait_ready tenants.phorge.fr phorge-system "$n" 300; then pass "tenant $n ($plan) reaches Ready"
  else fail "tenant $n reaches Ready" "$(why tenants.phorge.fr "$n" phorge-system)"; return 1; fi
}

# ensure_image <tenant> <name> <incus image> [alias]: pulls the image once, waits for Ready.
ensure_image() {
  local t=$1 n=$2 src=$3 alias=${4:-}
  K -n "t-$t" get images.phorge.fr "$n" >/dev/null 2>&1 && return 0
  local out; out=$(cat <<EOF | K apply -f - 2>&1
apiVersion: phorge.fr/v1alpha1
kind: Image
metadata: {name: $n, namespace: t-$t, labels: {$LABEL: "$RUN_ID"}}
spec:
  source: {name: $src}
${alias:+  aliases: [$alias]}
EOF
) || { fail "image $n in $t is created" "$out"; return 1; }
  if wait_ready images.phorge.fr "t-$t" "$n" 900; then pass "image $src in $t reaches Ready"
  else fail "image $src in $t reaches Ready" "$(why images.phorge.fr "$n" "t-$t")"; return 1; fi
}

# ensure_instance <tenant> <name> <image xr> [extra spec lines]: creates the VM, waits for Ready.
ensure_instance() {
  local t=$1 n=$2 img=$3 extra=${4:-}
  K -n "t-$t" get instances.phorge.fr "$n" >/dev/null 2>&1 && return 0
  local out; out=$(cat <<EOF | K apply -f - 2>&1
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: $n, namespace: t-$t, labels: {$LABEL: "$RUN_ID"}}
spec:
  imageRef: {name: $img}
$extra
EOF
) || { fail "instance $n in $t is created" "$out"; return 1; }
  if wait_ready instances.phorge.fr "t-$t" "$n" 400; then pass "instance $n in $t reaches Ready"
  else fail "instance $n in $t reaches Ready" "$(why instances.phorge.fr "$n" "t-$t")"; return 1; fi
}

# The tenant's OVN network: "10.x.y.1/24", its /24 prefix "10.x.y", and the checks on it.
tenant_net() { INCUS network get default ipv4.address --project "t-$1"; }
net_prefix() { local c; c=$(tenant_net "$1"); echo "${c%.*}"; }
# in_phorge_range <cidr>: the subnet is one of the router's VLANs (or the containers' / LAN ranges).
in_phorge_range() {
  local p="${1%.*}"
  case "$p" in 10.1.0|10.2.0|10.3.0|10.4.0|10.5.0|10.10.0|10.11.0|10.12.0|172.17.0|192.168.1|192.168.2) return 0 ;; esac
  return 1
}

vm_ip() { INCUS list "$2" --project "$1" -f csv -c 4 | grep -oE '([0-9]+\.){3}[0-9]+' | head -1; }
vm_up() { vm_sh "$1" "$2" true; }   # the incus agent answers

# Delete everything this run created, children first, then the tenants. Safe to call twice.
cleanup() {
  [[ ${E2E_KEEP:-0} == 1 ]] && { echo "E2E_KEEP=1: leaving $RUN_ID in place"; return; }
  local t k x
  for x in "${TRACK_XR[@]}"; do K delete ${x%% *}.phorge.fr -n "$(cut -d' ' -f2 <<<"$x")" "$(cut -d' ' -f3 <<<"$x")" --wait=false >/dev/null 2>&1; done
  for t in "${TRACK_TENANTS[@]}"; do
    for k in instances apikeys memberships images; do
      K -n "t-$t" delete "$k.phorge.fr" -l "$LABEL=$RUN_ID" --wait=false >/dev/null 2>&1
    done
  done
  for t in "${TRACK_TENANTS[@]}"; do
    wait_until 300 "children of $t" bash -c "K() { kubectl --context $E2E_CONTEXT \"\$@\"; }; [[ -z \$(K -n t-$t get instances.phorge.fr,images.phorge.fr -o name 2>/dev/null) ]]"
    K -n phorge-system delete tenants.phorge.fr "$t" --wait=false >/dev/null 2>&1
  done
  for t in "${TRACK_TENANTS[@]}"; do wait_until 600 "tenant $t gone" gone tenants.phorge.fr "$t" phorge-system || echo "cleanup: tenant $t is still being deleted"; done
  for t in "${TRACK_NS[@]}"; do K delete ns "$t" --wait=false >/dev/null 2>&1; done
  # Kubernetes can report a tenant gone before Incus has dropped its project: wait for Incus too,
  # or the next run's preflight finds the leftovers.
  wait_until 600 "incus projects gone" bash -c "! ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus project list -f csv -c n' | grep -q '^t-e2e-$RUN_ID'" \
    || echo "cleanup: Incus projects of run $RUN_ID still exist: $(INCUS project list -f csv -c n | grep "^t-e2e-$RUN_ID" | tr '\n' ' ')"
}

# Anything a previous run left behind (interrupted, or kept with E2E_KEEP=1).
sweep() {
  local n; for n in $(K -n phorge-system get tenants.phorge.fr -l "$LABEL" -o name 2>/dev/null); do
    echo "sweep: deleting $n"; K -n phorge-system delete "$n" --wait=false >/dev/null 2>&1
  done
  for n in $(K get ns -l "$LABEL" -o name 2>/dev/null); do K delete "$n" --wait=false >/dev/null 2>&1; done
}

preflight() {
  K get crd tenants.phorge.fr >/dev/null 2>&1 || { echo "no Tenant CRD on context $E2E_CONTEXT"; return 1; }
  INCUS version >/dev/null 2>&1 || { echo "cannot run incus on root@$INCUS_HOST"; return 1; }
  return 0
}

summary() {
  printf '\n%s== %d passed, %d failed, %d skipped%s\n' "$B" "$PASS" "$FAIL" "$SKIP" "$Z"
  local f; for f in "${FAILED[@]}"; do printf '  %s- %s%s\n' "$R" "$f" "$Z"; done
  (( FAIL == 0 ))
}
