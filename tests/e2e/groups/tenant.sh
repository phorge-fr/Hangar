# A Tenant against the real clusters: what it composes in Kubernetes, Incus and OpenFGA.

# plan -> instances, cpu, memory, disk, networks (the table of composition-tenant.yml / docs)
declare -A PLAN_VMS=([small]=1 [medium]=3 [large]=6)
declare -A PLAN_CPU=([small]=2 [medium]=4 [large]=8)
declare -A PLAN_MEM=([small]=4GiB [medium]=8GiB [large]=16GiB)
declare -A PLAN_DISK=([small]=20GiB [medium]=100GiB [large]=250GiB)
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

# the owner is viewer of the project in the Incus store (read-only) and admin of the tenant in the API store
owner_tuple() { echo "$(K get environmentconfig phorge -o jsonpath='{.data.openfgaStoreId}')/user:$1/viewer/project:t-$2"; }
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

  section "tenant: network and profile"
  eq "network 'default' is an OVN network" "default,ovn" "$(INCUS network list --project "$p" -f csv -c n,t | grep '^default,')"
  local cidr; cidr=$(tenant_net "$TA")
  match "ipv4.address is a /24 chosen by Incus" '^[0-9]+\.[0-9]+\.[0-9]+\.1/24$' "$cidr"
  if in_phorge_range "$cidr"; then fail "the subnet $cidr is outside the router's VLANs and the LAN/containers ranges"; else pass "the subnet $cidr is outside the router's VLANs and the LAN/containers ranges"; fi
  eq "no other Incus network uses the same subnet" 1 "$(INCUS network list --all-projects -f csv -c e,n,4 | grep -c ",${cidr}\$\|,${cidr%/*}/")"
  eq "ipv4.nat is on" true "$(INCUS network get default ipv4.nat --project "$p")"
  eq "the network sits on the UPLINK" UPLINK "$(INCUS network get default network --project "$p")"
  local ext; ext=$(INCUS network get default volatile.network.ipv4.address --project "$p")
  match "its OVN router took an external address in 10.11.0.10-250" '^10\.11\.0\.([1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|250)$' "$ext"
  eq "profile 'phorge' exists" phorge "$(INCUS profile list --project "$p" -f csv -c n | grep -x phorge)"
  eq "profile root disk is on the 'remote' pool" remote "$(INCUS profile device get phorge root pool --project "$p")"
  eq "profile root disk is mounted on /" / "$(INCUS profile device get phorge root path --project "$p")"
  eq "profile eth0 is on network 'default'" default "$(INCUS profile device get phorge eth0 network --project "$p")"

  section "tenant: owner and composed resources"
  eq "the owner tuple is Ready" True "$(cond relationshiptuple.tuple.openfga.m.crossplane.io "t-$TA-owner" phorge-system Ready)"
  eq "the owner is viewer of the project in the Incus store: Incus is read-only" "$(owner_tuple owner-a@example.org "$TA")" \
     "$(sget relationshiptuple.tuple.openfga.m.crossplane.io phorge-system "t-$TA-owner" '{.metadata.annotations.crossplane\.io/external-name}')"
  eq "and admin of the tenant in the Phorge API store, which the API checks" "$(owner_api_tuple owner-a@example.org "$TA")" \
     "$(sget relationshiptuple.tuple.openfga.m.crossplane.io phorge-system "t-$TA-owner-api" '{.metadata.annotations.crossplane\.io/external-name}')"
  local mr n=0; for mr in object.kubernetes.m.crossplane.io/t-$TA project.project.incus.m.crossplane.io/t-$TA network.network.incus.m.crossplane.io/t-$TA-default profile.profile.incus.m.crossplane.io/t-$TA-phorge; do
    K -n phorge-system get "$mr" >/dev/null 2>&1 && n=$((n+1)); done
  eq "the 4 other composed resources exist next to the tuples" 4 "$n"

  section "tenant: updates the XRD refuses"
  match "an unknown plan is refused on update" 'spec.plan' "$(K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"plan":"xl"}}' 2>&1)"

  section "tenant: the other plan and the edge cases"
  ensure_tenant "$TB" small owner-b@example.org && check_plan_limits "t-$TB" small
  nomatch "tenant B has a different subnet from A" "^$(net_prefix "$TA")\." "$(tenant_net "$TB")"
  nomatch "tenant B sees none of A's networks (separate projects)" "$(net_prefix "$TA")" "$(INCUS network list --project "t-$TB" -f csv -c n,4)"
  ensure_tenant "$TE" small 'E2E+Tag.x@Example.org' && {
    eq "28-character tenant name: project exists" "t-$TE" "$(INCUS project list -f csv -c n | grep -x "t-$TE")"
    eq "owner email with uppercase and '+' goes into the tuple unchanged" "$(owner_tuple 'E2E+Tag.x@Example.org' "$TE")" \
       "$(sget relationshiptuple.tuple.openfga.m.crossplane.io phorge-system "t-$TE-owner" '{.metadata.annotations.crossplane\.io/external-name}')"
  }

  section "tenant: subnets chosen by Incus, across tenants"
  TRACK_TENANTS+=("$TX")
  tenant_yaml "$TX" x@example.org small | K apply -f - >/dev/null
  wait_ready tenants.phorge.fr phorge-system "$TX" 240 || fail "tenant X reaches Ready" "$(why tenants.phorge.fr "$TX" phorge-system)"
  local t seen="" dup=0 bad=0 c
  for t in "$TA" "$TB" "$TE" "$TX"; do
    c=$(tenant_net "$t"); [[ -z $c ]] && continue
    note "network of ${t#e2e-$RUN_ID-}: $c"
    [[ " $seen " == *" ${c%.*} "* ]] && dup=1; seen="$seen ${c%.*}"
    in_phorge_range "$c" && bad=1
  done
  eq "the networks of the e2e tenants are pairwise distinct" 0 "$dup"
  eq "none of them is in a router VLAN or the LAN/containers ranges" 0 "$bad"
  K -n phorge-system delete tenants.phorge.fr "$TX" --wait=false >/dev/null
}
