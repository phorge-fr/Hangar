# Membership: the OpenFGA tuples it writes. ApiKey: a person's access token, which writes none.
#
# - A Membership writes two tuples: "viewer" on the project in the Incus store (iaas), because the Incus
#   UI is read-only, and the real role on tenant:<name> in the Phorge API store (phorge-api).
# - The tuples are checked through the RelationshipTuple managed resources (Ready, and their external name,
#   <store>/<user>/<relation>/<object>). With FGA_URL and FGA_TOKEN set (OpenFGA reachable from here) they are
#   also read back from OpenFGA itself and real `check` calls are made.
#     kubectl --context core -n openfga port-forward svc/openfga 18080:8080 &
#     export FGA_URL=http://127.0.0.1:18080 FGA_TOKEN=<one of the preshared keys of the openfga-secrets Secret>

RT=relationshiptuple.tuple.openfga.m.crossplane.io

tuple_name() { sget $RT "$1" "$2" '{.metadata.annotations.crossplane\.io/external-name}'; }
iaas_store() { K get environmentconfig phorge -o jsonpath='{.data.openfgaStoreId}'; }
api_store()  { K get environmentconfig phorge -o jsonpath='{.data.phorgeStoreId}'; }
fga() { curl -fsS -m 10 -H "Authorization: Bearer $FGA_TOKEN" -H 'content-type: application/json' "$FGA_URL/stores/$1/$2" -d "$3"; }
fga_has() { # <store> <user> <relation> <object>: the tuple exists in OpenFGA
  fga "$1" read "{\"tuple_key\":{\"user\":\"$2\",\"relation\":\"$3\",\"object\":\"$4\"}}" | jq -e '.tuples|length>0' >/dev/null
}
fga_check() { fga "$1" check "{\"tuple_key\":{\"user\":\"$2\",\"relation\":\"$3\",\"object\":\"$4\"}}" | jq -r .allowed; }
# the managed tuples of a Membership are named after a hash of its subject
mhash() { printf '%s:%s' "$1" "$2" | sha1sum | cut -c1-12; }

mship() { # <ns> <name> <kind> <subject> <role>
  cat <<YAML | K apply -f - 2>&1
apiVersion: phorge.fr/v1alpha1
kind: Membership
metadata: {name: $2, namespace: $1, labels: {$LABEL: "$RUN_ID"}}
spec: {subject: {kind: $3, name: "$4"}, role: $5}
YAML
}
apikey() { # <name> <scopes, comma separated> [expiresAt]: a key of a throw-away owner, in phorge-keys
  cat <<YAML | K apply -f - 2>&1
apiVersion: phorge.fr/v1alpha1
kind: ApiKey
metadata: {name: $1, namespace: phorge-keys, labels: {$LABEL: "$RUN_ID"}}
spec:
  hash: "$(printf '%s' "$RUN_ID$1" | sha256sum | cut -d' ' -f1)"
  scopes: [$2]
${3:+  expiresAt: "$3"}
  owner: e2e-owner@example.org
YAML
}
count_tuples() { K -n "$1" get $RT -o name 2>/dev/null | grep -c "/$2"; }
# tuples_gone <ns> <prefix> <desc>: a deleted XR is gone before the tuples composed for it (in the default
# deletion mode), so wait for them and say how long they outlived it.
tuples_gone() {
  local t0=$SECONDS
  if wait_until 240 "$3" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $1 get $RT -o name | grep -c '/$2') == 0 ]]"; then
    pass "$3"; (( SECONDS-t0 > 6 )) && note "the tuples outlived their deleted XR by about $((SECONDS-t0)) s: XR gone does not mean tuples gone"
  else fail "$3" "still there after 240 s: $(K -n "$1" get $RT -o name | grep "/$2" | tr '\n' ' ')"; fi
}

group_access() {
  ensure_tenant "$TA" medium owner-a@example.org || return
  local a="t-$TA" s ps h; s=$(iaas_store); ps=$(api_store)
  local obj="project:$a" tobj="tenant:$TA"
  local fga_on=0; [[ -n ${FGA_URL:-} && -n ${FGA_TOKEN:-} ]] && fga_on=1

  section "access: the owner"
  eq "owner: viewer of the project in the Incus store (read-only)" "$s/user:owner-a@example.org/viewer/$obj" "$(tuple_name phorge-system "t-$TA-owner")"
  eq "owner: admin of the tenant in the Phorge API store" "$ps/user:owner-a@example.org/admin/$tobj" "$(tuple_name phorge-system "t-$TA-owner-api")"
  out=$(mship "$a" me User owner-a@example.org operator); sleep 30
  eq "a Membership for the owner is not Ready" "" "$(cond memberships.phorge.fr me "$a" Ready | grep -x True)"
  match "and says the owner already has the admin role" 'is the owner of tenant' "$(cond_msg memberships.phorge.fr me "$a" Synced)"
  K -n "$a" delete memberships.phorge.fr me --wait=true --timeout=60s >/dev/null 2>&1

  section "access: Membership roles"
  local r; for r in admin operator user viewer; do
    mship "$a" "m-$r" User "u-$r@example.org" "$r" >/dev/null
    h=$(mhash User "u-$r@example.org")
    if wait_ready memberships.phorge.fr "$a" "m-$r" 90; then
      pass "Membership $r becomes Ready"
      eq "its Incus tuple is viewer, whatever the role" "$s/user:u-$r@example.org/viewer/$obj" "$(tuple_name "$a" "i-$h")"
      eq "its API tuple is the real role ($r)" "$ps/user:u-$r@example.org/$r/$tobj" "$(tuple_name "$a" "a-$h")"
    else fail "Membership $r becomes Ready" "$(why memberships.phorge.fr "m-$r" "$a")"; fi
  done
  mship "$a" m-group Group devs operator >/dev/null; h=$(mhash Group devs)
  if wait_ready memberships.phorge.fr "$a" m-group 90; then
    eq "a Group subject becomes group:<name>#member (Incus tuple)" "$s/group:devs#member/viewer/$obj" "$(tuple_name "$a" "i-$h")"
    eq "and in the API store, with its role" "$ps/group:devs#member/operator/$tobj" "$(tuple_name "$a" "a-$h")"
  else fail "Membership for a group becomes Ready" "$(why memberships.phorge.fr m-group "$a")"; fi
  mship "$a" m-plus User 'First.Last+tag@Example.org' user >/dev/null; h=$(mhash User 'First.Last+tag@Example.org')
  wait_ready memberships.phorge.fr "$a" m-plus 90 && eq "an email with uppercase and '+' is kept as is" "$ps/user:First.Last+tag@Example.org/user/$tobj" "$(tuple_name "$a" "a-$h")" \
    || fail "Membership with a '+' email becomes Ready" "$(why memberships.phorge.fr m-plus "$a")"

  section "access: one Membership per subject"
  out=$(mship "$a" m-dup User u-admin@example.org viewer); sleep 45
  eq "a second Membership for the same user is not Ready" "" "$(cond memberships.phorge.fr m-dup "$a" Ready | grep -x True)"
  eq "the first one stays Ready" True "$(cond memberships.phorge.fr m-admin "$a" Ready)"
  eq "and keeps its own role in the API store" "$ps/user:u-admin@example.org/admin/$tobj" "$(tuple_name "$a" "a-$(mhash User u-admin@example.org)")"
  K -n "$a" delete memberships.phorge.fr m-dup --wait=true --timeout=120s >/dev/null 2>&1; sleep 15
  eq "deleting the refused one does not touch the first one's tuples" True "$(cond $RT "a-$(mhash User u-admin@example.org)" "$a" Ready)"
  if (( fga_on )); then
    fga_has "$ps" user:u-admin@example.org admin "$tobj" && pass "in OpenFGA, the first Membership's tuple is still there" || fail "in OpenFGA, the first Membership's tuple is still there"
  fi

  section "access: Membership update and deletion"
  # A tuple cannot be edited: changing a role is refused up front (xrd-membership.yml)
  out=$(mship "$a" m-viewer User u-viewer@example.org operator)
  match "changing a role is refused up front (immutable)" 'cannot be edited' "$out"
  eq "and the API tuple still has the old role" "$ps/user:u-viewer@example.org/viewer/$tobj" "$(tuple_name "$a" "a-$(mhash User u-viewer@example.org)")"
  K -n "$a" delete memberships.phorge.fr m-operator --wait=true --timeout=120s >/dev/null 2>&1
  tuples_gone "$a" "[ia]-$(mhash User u-operator@example.org)" "deleting a Membership deletes both its tuples"
  eq "the other memberships keep theirs" 2 "$(count_tuples "$a" "[ia]-$(mhash User u-admin@example.org)")"
  if (( fga_on )); then
    fga_has "$ps" user:u-operator@example.org operator "$tobj" && fail "in OpenFGA, the deleted Membership's API tuple is gone" || pass "in OpenFGA, the deleted Membership's API tuple is gone"
    fga_has "$s" user:u-operator@example.org viewer "$obj" && fail "in OpenFGA, the deleted Membership's Incus tuple is gone" || pass "in OpenFGA, the deleted Membership's Incus tuple is gone"
  fi

  # A key is its owner limited to its scopes: the API checks the scope and asks OpenFGA about the owner, so there is no
  # tuple for a key. These checks are about the object: its status, its immutable fields, its date.
  section "access: ApiKey, a person's key"
  local k1="e2e-$RUN_ID-k1" kold="e2e-$RUN_ID-kold" knew="e2e-$RUN_ID-knew"
  apikey "$k1" instances:read,instances:write >/dev/null
  wait_ready apikeys.phorge.fr phorge-keys "$k1" 120 && pass "an ApiKey becomes Ready" || fail "an ApiKey becomes Ready" "$(why apikeys.phorge.fr "$k1" phorge-keys)"
  eq "status.keyId is the name of the object, the id in the key" "$k1" "$(sget apikeys.phorge.fr phorge-keys "$k1" '{.status.keyId}')"
  eq "it is not expired" false "$(sget apikeys.phorge.fr phorge-keys "$k1" '{.status.expired}')"
  eq "no tuple is written for it, whatever its scopes" 0 "$(K get $RT -A -o name 2>/dev/null | grep -c "$k1")"
  eq "no managed resource carries its name" 0 "$(K get managed -A -o name 2>/dev/null | grep -c "$k1")"
  if out=$(K -n phorge-keys patch apikeys.phorge.fr "$k1" --type merge -p '{"spec":{"owner":"someone-else@example.org"}}' 2>&1); then
    fail "the owner of a key cannot change" "the patch was accepted"
  else match "the owner of a key cannot change" 'cannot change' "$out"; fi
  if out=$(K -n phorge-keys patch apikeys.phorge.fr "$k1" --type merge -p "{\"spec\":{\"hash\":\"$(printf 'c%.0s' {1..64})\"}}" 2>&1); then
    fail "the secret of a key cannot change" "the patch was accepted"
  else match "the secret of a key cannot change" 'cannot change' "$out"; fi
  K -n phorge-keys patch apikeys.phorge.fr "$k1" --type merge -p '{"spec":{"scopes":["instances:read"]}}' >/dev/null 2>&1 \
    && pass "the scopes of a key can change" || fail "the scopes of a key can change" "the patch was refused"
  K -n phorge-keys delete apikeys.phorge.fr "$k1" --wait=true --timeout=60s >/dev/null 2>&1
  eq "a key is gone as soon as it is deleted" "" "$(K -n phorge-keys get apikeys.phorge.fr "$k1" -o name 2>/dev/null)"

  section "access: an expired key"
  apikey "$kold" tenants:read,instances:read 2020-01-01T00:00:00Z >/dev/null
  wait_until 120 "status.expired" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n phorge-keys get apikeys.phorge.fr $kold -o jsonpath='{.status.expired}') == true ]]"
  eq "status.expired is true" true "$(sget apikeys.phorge.fr phorge-keys "$kold" '{.status.expired}')"
  eq "the key is still Ready (nothing is wrong, it just grants nothing)" True "$(cond apikeys.phorge.fr "$kold" phorge-keys Ready)"
  apikey "$knew" tenants:read 2099-01-01T00:00:00Z >/dev/null
  wait_ready apikeys.phorge.fr phorge-keys "$knew" 120
  eq "a key that expires later is not expired" false "$(sget apikeys.phorge.fr phorge-keys "$knew" '{.status.expired}')"

  if (( fga_on )); then
    section "access: what OpenFGA grants"
    eq "owner can view the project in Incus" true "$(fga_check "$s" user:owner-a@example.org can_view "$obj")"
    eq "but cannot edit it there (Incus is read-only)" false "$(fga_check "$s" user:owner-a@example.org can_edit "$obj")"
    eq "nor create instances there" false "$(fga_check "$s" user:owner-a@example.org can_create_instances "$obj")"
    eq "a viewer-or-above member can view" true "$(fga_check "$s" user:u-admin@example.org can_view "$obj")"
    eq "and cannot create instances in Incus either, whatever the role" false "$(fga_check "$s" user:u-admin@example.org can_create_instances "$obj")"
    eq "a stranger cannot view" false "$(fga_check "$s" user:stranger@example.org can_view "$obj")"
    eq "owner can write instances through the API" true "$(fga_check "$ps" user:owner-a@example.org can_write_instances "$tobj")"
    eq "owner can write memberships through the API" true "$(fga_check "$ps" user:owner-a@example.org can_write_memberships "$tobj")"
    eq "an API 'viewer' can read instances" true "$(fga_check "$ps" user:u-viewer@example.org can_read_instances "$tobj")"
    eq "but cannot write them" false "$(fga_check "$ps" user:u-viewer@example.org can_write_instances "$tobj")"
    eq "an API 'operator' (group devs) can write images" true "$(fga_check "$ps" 'group:devs#member' can_write_images "$tobj")"
  else
    skip "reading tuples back from OpenFGA and real checks (set FGA_URL and FGA_TOKEN, see the top of groups/access.sh)"
  fi
}
