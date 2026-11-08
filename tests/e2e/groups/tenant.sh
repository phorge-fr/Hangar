# A Tenant against the real clusters: what it composes in Kubernetes, Incus and OpenFGA.

# plan -> instances, cpu, memory, disk, networks (the table of composition-tenant.yml / docs)
declare -A PLAN_VMS=([small]=2 [medium]=4 [large]=6)
declare -A PLAN_CPU=([small]=2 [medium]=4 [large]=8)
declare -A PLAN_MEM=([small]=4GiB [medium]=8GiB [large]=16GiB)
declare -A PLAN_DISK=([small]=128GiB [medium]=256GiB [large]=512GiB)
declare -A PLAN_NETS=([small]=1 [medium]=2 [large]=3)

check_plan_limits() { # <project> <plan>
  local p=$1 plan=$2 k
  eq "$p limits.instances ($plan)" "${PLAN_VMS[$plan]}" "$(INCUS project get "$p" limits.instances)"
  eq "$p limits.virtual-machines ($plan)" "${PLAN_VMS[$plan]}" "$(INCUS project get "$p" limits.virtual-machines)"
  eq "$p limits.cpu ($plan)" "${PLAN_CPU[$plan]}" "$(INCUS project get "$p" limits.cpu)"
  eq "$p limits.memory ($plan)" "${PLAN_MEM[$plan]}" "$(INCUS project get "$p" limits.memory)"
  eq "$p limits.disk ($plan)" "${PLAN_DISK[$plan]}" "$(INCUS project get "$p" limits.disk)"
  eq "$p limits.networks ($plan)" "${PLAN_NETS[$plan]}" "$(INCUS project get "$p" limits.networks)"
}

# the owner is user of the project in the Incus store (sees it, opens a terminal, changes nothing) and admin of the tenant in the API store
owner_tuple() { echo "$(K get environmentconfig phorge -o jsonpath='{.data.openfgaStoreId}')/user:$1/user/project:t-$2"; }
owner_api_tuple() { echo "$(K get environmentconfig phorge -o jsonpath='{.data.phorgeStoreId}')/user:$1/admin/tenant:$2"; }

group_tenant() {
  section "tenant: what a Tenant composes"
  ensure_tenant "$TA" medium owner-a@example.org || return
  local p="t-$TA" k
  eq "status.namespace" "$p" "$(sget tenants.phorge.fr phorge-system "$TA" '{.status.namespace}')"
  eq "status.incusProject" "$p" "$(sget tenants.phorge.fr phorge-system "$TA" '{.status.incusProject}')"
  eq "Synced=True" True "$(cond tenants.phorge.fr "$TA" phorge-system Synced)"
  eq "the Kubernetes namespace exists with the tenant label" "$TA" "$(K get ns "$p" -o jsonpath='{.metadata.labels.phorge\.fr/tenant}')"
  eq "the Incus project exists" "$p" "$(INCUS project list -f csv -c n | grep -x "$p")"
  check_plan_limits "$p" medium

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

  section "tenant: updates the XRD refuses"
  match "an unknown plan is refused on update" 'spec.plan' "$(K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"plan":"xl"}}' 2>&1)"

  section "tenant: the other plan and the edge cases"
  ensure_tenant "$TB" small owner-b@example.org && check_plan_limits "t-$TB" small
  eq "tenant B has its own profiles, as A has" "default l m s" "$(INCUS profile list --project "t-$TB" -f csv -c n | sort | tr '\n' ' ' | sed 's/ $//')"
  eq "and no network" "" "$(INCUS network list --project "t-$TB" -f csv -c n)"
  ensure_tenant "$TE" small 'E2E+Tag.x@Example.org' && {
    eq "28-character tenant name: project exists" "t-$TE" "$(INCUS project list -f csv -c n | grep -x "t-$TE")"
    eq "owner email with uppercase and '+' goes into the tuple unchanged" "$(owner_tuple 'E2E+Tag.x@Example.org' "$TE")" \
       "$(sget relationshiptuple.tuple.openfga.m.crossplane.io phorge-system "t-$TE-owner" '{.metadata.annotations.crossplane\.io/external-name}')"
  }
}
