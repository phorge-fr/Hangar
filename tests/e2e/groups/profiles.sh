# The Profile kind: a size the user makes in their tenant, next to s, m and l.

group_profiles() {
  section "profiles: a profile the user makes"
  ensure_tenant "$TA" owner-a@example.org || return
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

  # The settings of an instance that are not about the network: secure boot and the SSH keys. Never nesting: the project blocks
  # security.nesting on a profile (restricted.containers.nesting: block, a profile has no instance type), measured: "Container
  # nesting is forbidden". The keys only have the shape of keys: the VMs stay stopped.
  local k1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE2eUpdatedKeyOnly' k2='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 laptop@home'
  section "profiles: the settings of an instance"
  ensure_profile "$TA" dev 1 1024 12 "  secureBoot: false
  sshPublicKeys: ['$k1']" || return
  eq "the profile has security.secureboot" false "$(INCUS profile get dev security.secureboot --project "$a")"
  has "and the key in its cloud-init user data" "$k1" "$(INCUS profile get dev cloud-init.user-data --project "$a")"
  match "which is a #cloud-config document" '^#cloud-config' "$(INCUS profile get dev cloud-init.user-data --project "$a")"
  eq "it has no nesting: that is the instance's" "" "$(INCUS profile get dev security.nesting --project "$a")"
  eq "a profile with settings still has no network device: that is the instance's" "" "$(INCUS profile device list dev --project "$a" | grep -vx root)"
  eq "the profiles of the tenant have none of them" "" "$(INCUS profile get s security.secureboot --project "$a")$(INCUS profile get m security.nesting --project "$a")$(INCUS profile get l cloud-init.user-data --project "$a")"

  # A tenant has 2 VMs in all and 2 vCPU, and the vm1 of the other groups may be one of them: the instances of this section come one at a
  # time, each one deleted before the next.
  ensure_instance "$TA" own deb "  profile: dev
  running: false
  nesting: true
  secureBoot: true
  sshPublicKeys: ['$k2']" || return
  eq "an instance that says its own secure boot wins over the profile's" true "$(INCUS config get own security.secureboot --project "$a" --expanded)"
  has "and its own keys, which replace the profile's" "laptop@home" "$(INCUS config get own cloud-init.user-data --project "$a" --expanded)"
  nomatch "the profile's key is not among them" 'UpdatedKeyOnly' "$(INCUS config get own cloud-init.user-data --project "$a" --expanded)"
  eq "its own nesting is in Incus: a VM may have it, the profile may not" true "$(INCUS config get own security.nesting --project "$a" --expanded)"
  eq "status: secure boot" true "$(sget instances.phorge.fr "$a" own '{.status.secureBoot}')"
  eq "status: keys" "$k2" "$(sget instances.phorge.fr "$a" own '{.status.sshPublicKeys[*]}')"
  eq "status: nesting" true "$(sget instances.phorge.fr "$a" own '{.status.nesting}')"
  # an instance that has said its value, and then takes it back, follows the profile again
  K -n "$a" patch instances.phorge.fr own --type merge -p '{"spec":{"secureBoot":null}}' >/dev/null
  wait_until 150 "own secure boot dropped" bash -c "[[ -z \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus config get own security.secureboot --project $a') ]]"
  eq "an instance that takes its value back follows the profile" false "$(INCUS config get own security.secureboot --project "$a" --expanded)"
  eq "and its status says it" false "$(sget instances.phorge.fr "$a" own '{.status.secureBoot}')"
  # a change of the profile reaches the instances that did not say: Incus resolves the profile, the instances are not touched
  K -n "$a" patch profiles.phorge.fr dev --type merge -p '{"spec":{"secureBoot":true}}' >/dev/null
  wait_until 150 "profile secure boot true" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus profile get dev security.secureboot --project $a') == true ]]"
  eq "a profile changed in place changes its setting in Incus" true "$(INCUS profile get dev security.secureboot --project "$a")"
  eq "the one that took its value back follows" true "$(INCUS config get own security.secureboot --project "$a" --expanded)"
  K -n "$a" delete instances.phorge.fr own --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "the instance with its own settings is deleted" gone instances.phorge.fr own "$a"
  K -n "$a" patch profiles.phorge.fr dev --type merge -p '{"spec":{"secureBoot":false}}' >/dev/null
  wait_until 150 "profile secure boot false" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus profile get dev security.secureboot --project $a') == false ]]"

  ensure_instance "$TA" nokey deb "  profile: dev
  running: false
  sshPublicKeys: []" || return
  nomatch "an instance that says an empty list has none of the profile's keys" 'UpdatedKeyOnly' "$(INCUS config get nokey cloud-init.user-data --project "$a" --expanded)"
  eq "and its secure boot is still the profile's" false "$(INCUS config get nokey security.secureboot --project "$a" --expanded)"
  eq "status: no keys" "" "$(sget instances.phorge.fr "$a" nokey '{.status.sshPublicKeys[*]}')"
  K -n "$a" delete instances.phorge.fr nokey --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "the instance with an empty list of keys is deleted" gone instances.phorge.fr nokey "$a"

  ensure_instance "$TA" sin deb "  profile: dev
  running: false" || return
  eq "an instance that says nothing has neither secure boot nor keys of its own in Incus" "" "$(INCUS config get sin security.secureboot --project "$a")$(INCUS config get sin cloud-init.user-data --project "$a")"
  eq "it has the profile's secure boot" false "$(INCUS config get sin security.secureboot --project "$a" --expanded)"
  has "and its keys" "$k1" "$(INCUS config get sin cloud-init.user-data --project "$a" --expanded)"
  eq "status says the same: secure boot" false "$(sget instances.phorge.fr "$a" sin '{.status.secureBoot}')"
  eq "and keys" "$k1" "$(sget instances.phorge.fr "$a" sin '{.status.sshPublicKeys[*]}')"
  eq "the instance's own spec holds neither of them" "" "$(sget instances.phorge.fr "$a" sin '{.spec.secureBoot}{.spec.sshPublicKeys}')"
  eq "nesting is the instance's own, off by default" "false false" "$(INCUS config get sin security.nesting --project "$a" --expanded) $(sget instances.phorge.fr "$a" sin '{.status.nesting}')"
  K -n "$a" patch profiles.phorge.fr dev --type merge -p '{"spec":{"secureBoot":true}}' >/dev/null
  wait_until 150 "profile secure boot true" bash -c "[[ \$(ssh -o BatchMode=yes root@$INCUS_HOST 'LC_ALL=C incus profile get dev security.secureboot --project $a') == true ]]"
  eq "the instance that did not say follows a change of the profile" true "$(INCUS config get sin security.secureboot --project "$a" --expanded)"
  K -n "$a" delete instances.phorge.fr sin --cascade=foreground --wait=true --timeout=300s >/dev/null 2>&1
  check "the instance that says nothing is deleted" gone instances.phorge.fr sin "$a"
  K -n "$a" delete profiles.phorge.fr dev --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  # the Usage of the last instance is released a few seconds after the instance is gone: the first deletion is refused and
  # Crossplane replays it by itself, so the profile has to be waited for
  check "the profile with settings is deleted once its instances are gone" wait_until 180 "profile dev gone" gone profiles.phorge.fr dev "$a"

  section "profiles: a name that is taken, a profile that does not exist"
  cat <<YAML | K apply --dry-run=server -f - 2>&1 | grep -q 'every tenant has' && pass "s, m, l and default cannot be made again" || fail "s, m, l and default cannot be made again"
apiVersion: phorge.fr/v1alpha1
kind: Profile
metadata: {name: s, namespace: $a}
spec: {cpu: 1, memoryMiB: 1024, diskGiB: 10}
YAML
  eq "the profile s of the tenant is untouched" 2GiB "$(INCUS profile get s limits.memory --project "$a")"

  section "profiles: a profile above the limits is a definition, the instance is what the limits refuse"
  ensure_profile "$TA" huge 4 16384 300 || return
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Instance
metadata: {name: toobig, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec: {imageRef: {name: deb}, network: net, profile: huge, running: false}
YAML
  sleep 60
  eq "an instance whose profile is above the limits is never Ready" "" "$(cond instances.phorge.fr toobig "$a" Ready | grep -x True)"
  match "and Incus says which limit" 'limits' "$(mr_msgs "$a" toobig)"
  K -n "$a" delete instances.phorge.fr toobig --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  K -n "$a" delete profiles.phorge.fr huge --cascade=foreground --wait=true --timeout=200s >/dev/null 2>&1
  # same wait as above: the refused deletion is replayed once the Usage of the instance is released
  check "the profile is deleted in the foreground" wait_until 180 "profile huge gone" gone profiles.phorge.fr huge "$a"
}
