# A Tenant against the real clusters: what it composes in Kubernetes, Incus and OpenFGA.

# The limits of every tenant, the same numbers as composition-tenant.yml, the API (internal/quota) and docs/reference/phorge-api-kinds.md.
# There is no choice of plan: spec.plan is deprecated, still accepted, and changes nothing.
# The project limit of the disk is 128 GiB plus 512 MiB for each of the 2 VMs: Incus counts the state of a VM (500 MiB) on top of its root disk.
LIMITS_VMS=2 LIMITS_CPU=2 LIMITS_MEM=4GiB LIMITS_DISK=132096MiB LIMITS_NETS=2

check_limits() { # <project> [what]
  local p=$1 w=${2:+ ($2)}
  eq "$p limits.instances$w" "$LIMITS_VMS" "$(INCUS project get "$p" limits.instances)"
  eq "$p limits.virtual-machines$w" "$LIMITS_VMS" "$(INCUS project get "$p" limits.virtual-machines)"
  eq "$p limits.cpu$w" "$LIMITS_CPU" "$(INCUS project get "$p" limits.cpu)"
  eq "$p limits.memory$w" "$LIMITS_MEM" "$(INCUS project get "$p" limits.memory)"
  eq "$p limits.disk$w" "$LIMITS_DISK" "$(INCUS project get "$p" limits.disk)"
  eq "$p limits.networks$w" "$LIMITS_NETS" "$(INCUS project get "$p" limits.networks)"
}

# the owner is user of the project in the Incus store (sees it, opens a terminal, changes nothing) and admin of the tenant in the API store
owner_tuple() { echo "$(K get environmentconfig phorge -o jsonpath='{.data.openfgaStoreId}')/user:$1/user/project:t-$2"; }
owner_api_tuple() { echo "$(K get environmentconfig phorge -o jsonpath='{.data.phorgeStoreId}')/user:$1/admin/tenant:$2"; }

group_tenant() {
  section "tenant: what a Tenant composes"
  ensure_tenant "$TA" owner-a@example.org || return
  local p="t-$TA" k
  eq "status.namespace" "$p" "$(sget tenants.phorge.fr phorge-system "$TA" '{.status.namespace}')"
  eq "status.incusProject" "$p" "$(sget tenants.phorge.fr phorge-system "$TA" '{.status.incusProject}')"
  eq "Synced=True" True "$(cond tenants.phorge.fr "$TA" phorge-system Synced)"
  eq "the Kubernetes namespace exists with the tenant label" "$TA" "$(K get ns "$p" -o jsonpath='{.metadata.labels.phorge\.fr/tenant}')"
  eq "the Incus project exists" "$p" "$(INCUS project list -f csv -c n | grep -x "$p")"
  check_limits "$p" "no plan given"

  section "tenant: the project is deny-by-default"
  declare -A WANT=([restricted]=true [features.images]=true [features.profiles]=true [features.networks]=true
    [features.storage.volumes]=true [limits.containers]=0 [restricted.cluster.target]=block
    [restricted.containers.interception]=block [restricted.containers.lowlevel]=block
    [restricted.containers.nesting]=block [restricted.containers.privilege]=isolated
    [restricted.virtual-machines.lowlevel]=block [restricted.virtual-machines.nesting]=allow
    [restricted.devices.disk]=managed [restricted.devices.nic]=managed [restricted.devices.gpu]=block
    [restricted.devices.infiniband]=block [restricted.devices.pci]=block [restricted.devices.proxy]=block
    [restricted.devices.unix-block]=block [restricted.devices.unix-char]=block
    [restricted.devices.unix-hotplug]=block [restricted.devices.usb]=block
    [restricted.storage-pools.access]=remote [restricted.networks.uplinks]=UPLINK
    [restricted.snapshots]=allow [restricted.backups]=allow)
  for k in "${!WANT[@]}"; do eq "$p $k" "${WANT[$k]}" "$(INCUS project get "$p" "$k")"; done
  eq "restricted.networks.subnets is left unset (blocked)" "" "$(INCUS project get "$p" restricted.networks.subnets)"

  section "tenant: a project and three sizes, and no network"
  # A tenant is its project and the profiles s, m and l. The network is the user's to deploy (group networks).
  eq "the project holds no network" "" "$(INCUS network list --project "$p" -f csv -c n)"
  eq "the project has the profiles s, m, l and its own empty default" "default l m s" "$(INCUS profile list --project "$p" -f csv -c n | sort | tr '\n' ' ' | sed 's/ $//')"
  eq "there is no 'phorge' profile any more" "" "$(INCUS profile list --project "$p" -f csv -c n | grep -x phorge)"
  local sz cpu mem disk
  for sz in "s 1 2GiB 64GiB" "m 2 4GiB 128GiB" "l 4 8GiB 256GiB"; do
    set -- $sz; cpu=$2; mem=$3; disk=$4
    eq "profile $1: limits.cpu" "$cpu" "$(INCUS profile get "$1" limits.cpu --project "$p")"
    eq "profile $1: limits.memory" "$mem" "$(INCUS profile get "$1" limits.memory --project "$p")"
    eq "profile $1: root disk size" "$disk" "$(INCUS profile device get "$1" root size --project "$p")"
    eq "profile $1: root disk is on the 'remote' pool" remote "$(INCUS profile device get "$1" root pool --project "$p")"
    eq "profile $1: root disk is mounted on /" / "$(INCUS profile device get "$1" root path --project "$p")"
    eq "profile $1: it carries no network device" "" "$(INCUS profile device list "$1" --project "$p" | grep -vx root)"
    eq "profile $1 is Ready in Crossplane" True "$(cond profile.profile.incus.m.crossplane.io "t-$TA-$1" phorge-system Ready)"
  done
  eq "the empty default profile has no device" "" "$(INCUS profile device list default --project "$p")"
  eq "no Network resource was composed for the tenant" 0 "$(K get networks.network.incus.m.crossplane.io -A -o name 2>/dev/null | grep -c "t-$TA")"

  section "tenant: owner and composed resources"
  eq "the owner tuple is Ready" True "$(cond relationshiptuple.tuple.openfga.m.crossplane.io "t-$TA-owner" phorge-system Ready)"
  eq "the owner is user of the project in the Incus store: it opens a terminal and changes nothing" "$(owner_tuple owner-a@example.org "$TA")" \
     "$(sget relationshiptuple.tuple.openfga.m.crossplane.io phorge-system "t-$TA-owner" '{.metadata.annotations.crossplane\.io/external-name}')"
  eq "and admin of the tenant in the Phorge API store, which the API checks" "$(owner_api_tuple owner-a@example.org "$TA")" \
     "$(sget relationshiptuple.tuple.openfga.m.crossplane.io phorge-system "t-$TA-owner-api" '{.metadata.annotations.crossplane\.io/external-name}')"
  local mr n=0; for mr in object.kubernetes.m.crossplane.io/t-$TA project.project.incus.m.crossplane.io/t-$TA profile.profile.incus.m.crossplane.io/t-$TA-s profile.profile.incus.m.crossplane.io/t-$TA-m profile.profile.incus.m.crossplane.io/t-$TA-l; do
    K -n phorge-system get "$mr" >/dev/null 2>&1 && n=$((n+1)); done
  eq "the 5 other composed resources exist next to the tuples (namespace, project, three profiles)" 5 "$n"
  eq "and nothing else is composed: 7 managed resources in all" 7 "$(K get managed -A -o json | jq "[.items[] | select(.metadata.name | test(\"^t-$TA(-|\$)\"))] | length")"

  section "tenant: the deprecated plan is accepted and changes nothing"
  match "an unknown plan is still refused on update (the enum is kept)" 'spec.plan' "$(K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"plan":"xl"}}' 2>&1)"
  eq "a tenant created without a plan reads the default of the XRD" small "$(sget tenants.phorge.fr phorge-system "$TA" '{.spec.plan}')"
  ensure_tenant "$TB" owner-b@example.org large && check_limits "t-$TB" "created with plan large"
  eq "tenant B has its own profiles, as A has" "default l m s" "$(INCUS profile list --project "t-$TB" -f csv -c n | sort | tr '\n' ' ' | sed 's/ $//')"
  eq "and no network" "" "$(INCUS network list --project "t-$TB" -f csv -c n)"
  eq "the profiles of tenant B are the same as A's, whatever the plan" "$(INCUS profile get s limits.cpu --project "$p")/$(INCUS profile get m limits.memory --project "$p")/$(INCUS profile device get l root size --project "$p")" \
     "$(INCUS profile get s limits.cpu --project "t-$TB")/$(INCUS profile get m limits.memory --project "t-$TB")/$(INCUS profile device get l root size --project "t-$TB")"
  if K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"plan":"medium"}}' >/dev/null 2>&1; then pass "a plan can still be patched on a live tenant"; else fail "a plan can still be patched on a live tenant"; fi
  sleep 20
  check_limits "$p" "after patching the plan to medium"
  eq "the tenant stays Ready" True "$(cond tenants.phorge.fr "$TA" phorge-system Ready)"
  K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"plan":"small"}}' >/dev/null 2>&1

  section "tenant: two networks are allowed, the third is refused by Incus"
  # limits.networks is 2 for every tenant. The real Network kind is used and the refusal is read from the managed resource, as the
  # networks group does. Nothing is left behind: the three Networks are deleted at the end.
  ensure_network "$TA" lim1 || return
  ensure_network "$TA" lim2 || return
  eq "two networks of the tenant exist in Incus" 2 "$(INCUS network list --project "$p" -f csv -c n | grep -cx 'lim[12]')"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Network
metadata: {name: lim3, namespace: $p, labels: {$LABEL: "$RUN_ID"}}
spec: {description: over the limit}
YAML
  wait_until 120 "lim3 synced=False" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $p get networks.phorge.fr lim3 -o jsonpath='{.status.conditions[?(@.type==\"Synced\")].status}') == False ]]"
  eq "the third network is never Ready" "" "$(cond networks.phorge.fr lim3 "$p" Ready | grep -x True)"
  match "and Incus says the networks limit is reached" 'Networks limit has been reached' "$(mr_msgs "$p" lim3)"
  eq "nothing was created in Incus for it" "" "$(INCUS network list --project "$p" -f csv -c n | grep -x lim3)"
  K -n "$p" delete networks.phorge.fr lim3 lim2 lim1 --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "the three Network resources are deleted" gone networks.phorge.fr lim3 "$p"
  wait_until 120 "networks gone from Incus" bash -c "[[ -z \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus network list --project $p -f csv -c n') ]]"
  eq "and the project holds no network again" "" "$(INCUS network list --project "$p" -f csv -c n)"

  section "tenant: the edge cases"
  ensure_tenant "$TE" 'E2E+Tag.x@Example.org' medium && {
    eq "28-character tenant name: project exists" "t-$TE" "$(INCUS project list -f csv -c n | grep -x "t-$TE")"
    check_limits "t-$TE" "created with plan medium"
    eq "the plan is kept as written in the object" medium "$(sget tenants.phorge.fr phorge-system "$TE" '{.spec.plan}')"
    eq "owner email with uppercase and '+' goes into the tuple unchanged" "$(owner_tuple 'E2E+Tag.x@Example.org' "$TE")" \
       "$(sget relationshiptuple.tuple.openfga.m.crossplane.io phorge-system "t-$TE-owner" '{.metadata.annotations.crossplane\.io/external-name}')"
  }
}
