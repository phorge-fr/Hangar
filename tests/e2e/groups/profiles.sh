# The Profile kind: a size the user makes in their tenant, next to s, m and l.

group_profiles() {
  section "profiles: a profile the user makes"
  ensure_tenant "$TA" medium owner-a@example.org || return
  local a="t-$TA"
  ensure_profile "$TA" web 1 1024 12 || return
  eq "Synced=True" True "$(cond profiles.phorge.fr web "$a" Synced)"
  eq "status.problems is empty" "" "$(sget profiles.phorge.fr "$a" web '{.status.problems}')"
  eq "the profile exists in the tenant's Incus project, next to the three of the tenant" "default l m s web" "$(INCUS profile list --project "$a" -f csv -c n | sort | tr '\n' ' ' | sed 's/ $//')"
  eq "it gives 1 vCPU" 1 "$(INCUS profile get web limits.cpu --project "$a")"
  eq "and 1024 MiB" 1024MiB "$(INCUS profile get web limits.memory --project "$a")"
  eq "and a 12 GiB root disk" 12GiB "$(INCUS profile device get web root size --project "$a")"
  eq "on the remote pool" remote "$(INCUS profile device get web root pool --project "$a")"
  match "its description says what it comes to when none is given" '1 vCPU, 1024 MiB RAM, 12 GiB disk' "$(INCUS profile show web --project "$a")"
  eq "it has no network device: that is the instance's" "" "$(INCUS profile device list web --project "$a" | grep -vx root)"
  eq "the Incus profile is Ready next to its Usage" "True True" "$(cond profile.profile.incus.m.crossplane.io web "$a" Ready) $(cond usages.protection.crossplane.io profile-web-keeps-namespace "$a" Ready)"
  eq "the profiles of the tenant are untouched" "1 2 4" "$(INCUS profile get s limits.cpu --project "$a") $(INCUS profile get m limits.cpu --project "$a") $(INCUS profile get l limits.cpu --project "$a")"

  section "profiles: changed in place"
  K -n "$a" patch profiles.phorge.fr web --type merge -p '{"spec":{"cpu":2,"description":"for the web servers"}}' >/dev/null
  wait_until 150 "cpu 2" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus profile get web limits.cpu --project $a') == 2 ]]"
  eq "a new cpu is applied in place" 2 "$(INCUS profile get web limits.cpu --project "$a")"
  has "and so is the description" "for the web servers" "$(INCUS profile show web --project "$a")"
  eq "and the profile stays Ready" True "$(cond profiles.phorge.fr web "$a" Ready)"
  K -n "$a" patch profiles.phorge.fr web --type merge -p '{"spec":{"cpu":1}}' >/dev/null
  wait_until 150 "cpu 1" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus profile get web limits.cpu --project $a') == 1 ]]"

  section "profiles: an instance from it"
  ensure_image "$TA" deb "$IMG_DEBIAN" e2e-deb || return
  ensure_instance "$TA" pvm deb "  profile: web
  running: false" || return
  eq "the VM uses the profile" web "$(INCUS list pvm --project "$a" -f csv -c P)"
  eq "and gets 1 vCPU from it" 1 "$(INCUS config get pvm limits.cpu --project "$a" --expanded)"
  eq "and 1024 MiB" 1024MiB "$(INCUS config get pvm limits.memory --project "$a" --expanded)"
  eq "and the 12 GiB root disk" 12GiB "$(INCUS config show pvm --project "$a" --expanded | awk '/^  root:/{f=1} f && /size:/{print $2; exit}')"
  eq "the instance's Usage on the profile is Ready" True "$(cond usages.protection.crossplane.io pvm-uses-profile "$a" Ready)"
  local out; out=$(K -n "$a" delete profiles.phorge.fr web --wait=false 2>&1)
  match "deleting a profile that an instance has is refused, and says which" 'in-use by.*Instance/pvm' "$out"
  eq "the profile is still there" web "$(sget profiles.phorge.fr "$a" web '{.metadata.name}')"
  eq "and so is the Incus profile" web "$(INCUS profile list --project "$a" -f csv -c n | grep -x web)"
  K -n "$a" delete instances.phorge.fr pvm --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "the VM is deleted in the foreground" gone instances.phorge.fr pvm "$a"
  if wait_until 180 "profile gone" gone profiles.phorge.fr web "$a"; then pass "the refused deletion is replayed: the profile is gone once the VM is gone"
  else fail "the refused deletion is replayed once the VM is gone" "still there after 180 s: $(K -n "$a" get usages.protection.crossplane.io -o name | tr '\n' ' ')"; fi
  wait_until 120 "profile gone from Incus" bash -c "! ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus profile list --project $a -f csv -c n' | grep -qx web"
  eq "and from Incus" "default l m s" "$(INCUS profile list --project "$a" -f csv -c n | sort | tr '\n' ' ' | sed 's/ $//')"

  section "profiles: a name that is taken, a profile that does not exist"
  cat <<YAML | K apply --dry-run=server -f - 2>&1 | grep -q 'every tenant has' && pass "s, m, l and default cannot be made again" || fail "s, m, l and default cannot be made again"
apiVersion: phorge.fr/v1alpha1
kind: Profile
metadata: {name: s, namespace: $a}
spec: {cpu: 1, memoryMiB: 1024, diskGiB: 10}
YAML
  eq "the profile s of the tenant is untouched" 2GiB "$(INCUS profile get s limits.memory --project "$a")"

  section "profiles: a profile above the plan is a definition, the instance is what the plan refuses"
  ensure_profile "$TA" huge 4 16384 300 || return
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: toobig, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, network: net, profile: huge, running: false}
YAML
  sleep 60
  eq "an instance whose profile is above the plan is never Ready" "" "$(cond instances.phorge.fr toobig "$a" Ready | grep -x True)"
  match "and Incus says which limit" 'limits' "$(mr_msgs "$a" toobig)"
  K -n "$a" delete instances.phorge.fr toobig --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  K -n "$a" delete profiles.phorge.fr huge --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  check "the profile is deleted in the foreground" gone profiles.phorge.fr huge "$a"
}
