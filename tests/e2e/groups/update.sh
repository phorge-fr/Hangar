# Changing a live object: the change must reach Incus without recreating anything.

group_update() {
  ensure_tenant "$TA" medium owner-a@example.org || return
  local a="t-$TA"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  ensure_instance "$TA" vm1 deb "  cpu: 2
  memoryMiB: 1536
  diskGiB: 12" || return
  local inc="instance.instance.incus.m.crossplane.io"

  section "update: Tenant"
  K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"displayName":"E2E renamed"}}' >/dev/null
  wait_until 150 "description" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus project get $a user.x; LC_ALL=C incus project show $a' | grep -c 'E2E renamed') -ge 1 ]]"
  match "displayName becomes the project description" 'E2E renamed' "$(INCUS project show "$a")"
  K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"plan":"large"}}' >/dev/null
  wait_until 180 "large limits" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus project get $a limits.instances') == 6 ]]"
  check_plan_limits "$a" large
  eq "the tenant stays Ready through the change" True "$(cond tenants.phorge.fr "$TA" phorge-system Ready)"
  eq "the running VM was not touched" Running "$(INCUS list vm1 --project "$a" -f csv -c s | tr 'a-z' 'A-Z' | sed 's/RUNNING/Running/')"
  K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"plan":"medium"}}' >/dev/null
  wait_until 180 "medium limits" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus project get $a limits.instances') == 3 ]]"
  check_plan_limits "$a" medium

  # The owner is a tuple, which cannot be edited: the change is either applied or refused up front.
  # What must not happen is a Tenant that reads Ready while the old owner is still admin.
  local s out; s=$(K get environmentconfig phorge -o jsonpath='{.data.openfgaStoreId}')
  out=$(K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"owner":"new-owner@example.org"}}' 2>&1)
  if [[ $? -ne 0 ]]; then match "changing the owner is refused up front" 'owner cannot change' "$out"
  else
    if wait_until 180 "owner tuple" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n phorge-system get relationshiptuple.tuple.openfga.m.crossplane.io t-$TA-owner -o jsonpath='{.metadata.annotations.crossplane\\.io/external-name}') == '$s/user:new-owner@example.org/admin/project:$a' ]]"; then
      pass "changing the owner replaces the tuple"
    else fail "changing the owner replaces the tuple (the old owner is still admin)" "tenant Ready=$(cond tenants.phorge.fr "$TA" phorge-system Ready) Synced=$(cond tenants.phorge.fr "$TA" phorge-system Synced); tuple: $(cond_msg relationshiptuple.tuple.openfga.m.crossplane.io "t-$TA-owner" phorge-system Synced | cut -c1-200)"; fi
    K -n phorge-system patch tenants.phorge.fr "$TA" --type merge -p '{"spec":{"owner":"owner-a@example.org"}}' >/dev/null 2>&1
  fi

  section "update: Image"
  local fp; fp=$(sget images.phorge.fr "$a" deb '{.status.fingerprint}')
  K -n "$a" patch images.phorge.fr deb --type merge -p '{"spec":{"aliases":["e2e-deb","e2e-extra"]}}' >/dev/null
  # `incus image list` shows only the first alias and "(N more)": read the alias list instead
  if wait_until 150 "alias" bash -c "ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus image alias list --project $a -f csv' | grep -q e2e-extra"; then pass "a new alias reaches the Incus image"
  else fail "a new alias reaches the Incus image" "$(cond_msg images.phorge.fr deb "$a" Synced)"; fi
  eq "the image kept its fingerprint (not re-pulled)" "$fp" "$(sget images.phorge.fr "$a" deb '{.status.fingerprint}')"

  section "update: Instance, live"
  local before; before=$(INCUS config get vm1 volatile.uuid --project "$a")
  K -n "$a" patch instances.phorge.fr vm1 --type merge -p '{"spec":{"cpu":3,"memoryMiB":2048}}' >/dev/null
  wait_until 150 "cpu" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus config get vm1 limits.cpu --project $a') == 3 ]]"
  eq "cpu change reaches Incus" 3 "$(INCUS config get vm1 limits.cpu --project "$a")"
  eq "memory change reaches Incus" 2048MiB "$(INCUS config get vm1 limits.memory --project "$a")"
  eq "it is the same VM (same uuid), not a recreation" "$before" "$(INCUS config get vm1 volatile.uuid --project "$a")"
  K -n "$a" patch instances.phorge.fr vm1 --type merge -p '{"spec":{"diskGiB":14}}' >/dev/null
  wait_until 150 "disk" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus config device get vm1 root size --project $a') == 14GiB ]]"
  eq "growing the disk reaches Incus" 14GiB "$(INCUS config device get vm1 root size --project "$a")"
  K -n "$a" patch instances.phorge.fr vm1 --type merge -p '{"spec":{"sshPublicKeys":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE2eUpdatedKeyOnly e2e-new"]}}' >/dev/null
  wait_until 150 "key" bash -c "ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus config get vm1 cloud-init.user-data --project $a' | grep -q UpdatedKeyOnly"
  match "changing the ssh keys rewrites the cloud-init user data" 'UpdatedKeyOnly' "$(INCUS config get vm1 cloud-init.user-data --project "$a")"
  nomatch "and drops the old key" "e2e-$RUN_ID" "$(INCUS config get vm1 cloud-init.user-data --project "$a")"
  eq "the instance is still Ready after all of it" True "$(cond instances.phorge.fr vm1 "$a" Ready)"

  section "update: stop and start"
  K -n "$a" patch instances.phorge.fr vm1 --type merge -p '{"spec":{"running":false}}' >/dev/null
  wait_until 180 "stopped" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm1 -o jsonpath='{.status.state}') == Stopped ]]"
  eq "running: false stops the VM" Stopped "$(sget instances.phorge.fr "$a" vm1 '{.status.state}')"
  eq "and Incus agrees" STOPPED "$(INCUS list vm1 --project "$a" -f csv -c s)"
  eq "the VM is still Ready (stopped is a valid state)" True "$(cond instances.phorge.fr vm1 "$a" Ready)"
  K -n "$a" patch instances.phorge.fr vm1 --type merge -p '{"spec":{"running":true}}' >/dev/null
  wait_until 240 "running" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm1 -o jsonpath='{.status.state}') == Running ]]"
  eq "running: true starts it again" Running "$(sget instances.phorge.fr "$a" vm1 '{.status.state}')"
  wait_until 240 "ip" bash -c "[[ -n \$(kubectl --context $E2E_CONTEXT -n $a get instances.phorge.fr vm1 -o jsonpath='{.status.ipv4}') ]]"
  match "status.ipv4 is back in the tenant's subnet" "^$(net_prefix "$TA" | sed 's/\./\\./g')\\." "$(sget instances.phorge.fr "$a" vm1 '{.status.ipv4}')"
  eq "same VM after the cycle" "$before" "$(INCUS config get vm1 volatile.uuid --project "$a")"
}
