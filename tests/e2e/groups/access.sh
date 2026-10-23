# Membership and ApiKey: the OpenFGA tuples they write. The tuples are checked through the
# RelationshipTuple managed resources (Ready, and their external name, which is
# <store>/<user>/<relation>/<object>), so no OpenFGA credential is needed.
#
# With FGA_URL and FGA_TOKEN set (OpenFGA reachable from here), the same tuples are also read back
# from OpenFGA itself and a few `check` calls prove what Incus will really enforce.

RT=relationshiptuple.tuple.openfga.m.crossplane.io

tuple_name() { sget $RT "$1" "$2" '{.metadata.annotations.crossplane\.io/external-name}'; }
iaas_store() { K get environmentconfig phorge -o jsonpath='{.data.openfgaStoreId}'; }
api_store()  { K get environmentconfig phorge -o jsonpath='{.data.phorgeStoreId}'; }
fga() { curl -fsS -m 10 -H "Authorization: Bearer $FGA_TOKEN" -H 'content-type: application/json' "$FGA_URL/stores/$1/$2" -d "$3"; }

mship() { # <ns> <name> <kind> <subject> <role>
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: Membership
metadata: {name: $2, namespace: $1, labels: {$LABEL: "$RUN_ID"}}
spec: {subject: {kind: $3, name: "$4"}, role: $5}
YAML
}
apikey() { # <ns> <name> <scopes, comma separated>
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: ApiKey
metadata: {name: $2, namespace: $1, labels: {$LABEL: "$RUN_ID"}}
spec:
  hash: "$(printf '%s' "$RUN_ID$2" | sha256sum | cut -d' ' -f1)"
  scopes: [$3]
  createdBy: e2e@example.org
YAML
}
count_tuples() { K -n "$1" get $RT -o name 2>/dev/null | grep -c "/$2"; }
# tuples_gone <ns> <prefix> <desc>: the XR is deleted before the tuples composed for it, so wait for them
# and say how long they outlived it.
tuples_gone() {
  local t0=$SECONDS
  if wait_until 240 "$3" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $1 get $RT -o name | grep -c '/$2') == 0 ]]"; then
    pass "$3"; (( SECONDS-t0 > 6 )) && note "the tuples outlived their deleted XR by about $((SECONDS-t0)) s: XR gone does not mean tuples gone"
  else fail "$3" "still there after 240 s: $(K -n "$1" get $RT -o name | grep "/$2" | tr '\n' ' ')"; fi
}

group_access() {
  ensure_tenant "$TA" medium owner-a@example.org || return
  local a="t-$TA" s; s=$(iaas_store)
  local obj="project:$a"

  section "access: Membership roles"
  local r; for r in admin operator user viewer; do
    mship "$a" "m-$r" User "u-$r@example.org" "$r"
    if wait_ready memberships.phorge.fr "$a" "m-$r" 90; then
      pass "Membership $r becomes Ready"
      eq "its tuple is $r on the project, in the Incus store" "$s/user:u-$r@example.org/$r/$obj" "$(tuple_name "$a" "m-$r")"
    else fail "Membership $r becomes Ready" "$(why memberships.phorge.fr "m-$r" "$a")"; fi
  done
  mship "$a" m-group Group devs operator
  wait_ready memberships.phorge.fr "$a" m-group 90 && eq "a Group subject becomes group:<name>#member" "$s/group:devs#member/operator/$obj" "$(tuple_name "$a" m-group)" \
    || fail "Membership for a group becomes Ready" "$(why memberships.phorge.fr m-group "$a")"
  mship "$a" m-plus User 'First.Last+tag@Example.org' user
  wait_ready memberships.phorge.fr "$a" m-plus 90 && eq "an email with uppercase and '+' is kept as is" "$s/user:First.Last+tag@Example.org/user/$obj" "$(tuple_name "$a" m-plus)" \
    || fail "Membership with a '+' email becomes Ready" "$(why memberships.phorge.fr m-plus "$a")"
  mship "$a" m-two User u-viewer@example.org operator
  wait_ready memberships.phorge.fr "$a" m-two 90 && eq "the same user can hold a second role" "$s/user:u-viewer@example.org/operator/$obj" "$(tuple_name "$a" m-two)" \
    || fail "second role for the same user becomes Ready" "$(why memberships.phorge.fr m-two "$a")"

  section "access: the same tuple written by two Memberships"
  mship "$a" m-dup User u-admin@example.org admin
  sleep 40
  note "a second Membership for the identical tuple: Ready=$(cond memberships.phorge.fr m-dup "$a" Ready) Synced=$(cond memberships.phorge.fr m-dup "$a" Synced) $(cond_msg memberships.phorge.fr m-dup "$a" Synced | cut -c1-160)"
  K -n "$a" delete memberships.phorge.fr m-dup --wait=true --timeout=120s >/dev/null 2>&1
  sleep 10
  note "after deleting the duplicate, the original tuple is $(cond $RT m-admin "$a" Ready | sed 's/True/still Ready/')"

  section "access: Membership update and deletion"
  # A tuple cannot be edited in OpenFGA: changing a role means deleting one tuple and writing another.
  # Either the change is applied (the tuple follows) or it is refused up front; what must never
  # happen is a role that reads as changed while the old tuple keeps granting the old right.
  local out; out=$(mship "$a" m-viewer User u-viewer@example.org operator 2>&1)
  if [[ $? -ne 0 ]]; then pass "changing a role is refused up front (immutable): $(cut -c1-100 <<<"$out")"
  else
    wait_until 120 "tuple follows the role" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get $RT m-viewer -o jsonpath='{.metadata.annotations.crossplane\\.io/external-name}') == */operator/* ]]"
    match "changing a role really changes the tuple that grants it" '/operator/' "$(tuple_name "$a" m-viewer)"
    if [[ $(tuple_name "$a" m-viewer) != */operator/* ]]; then
      note "Membership m-viewer says Ready=$(cond memberships.phorge.fr m-viewer "$a" Ready) Synced=$(cond memberships.phorge.fr m-viewer "$a" Synced) while its tuple is still '$(tuple_name "$a" m-viewer | cut -d/ -f3)': $(cond_msg $RT m-viewer "$a" Synced | cut -c1-200)"
    fi
  fi
  K -n "$a" delete memberships.phorge.fr m-operator --wait=true --timeout=120s >/dev/null 2>&1
  tuples_gone "$a" m-operator "deleting a Membership deletes its tuple"
  eq "the other memberships keep theirs" 1 "$(count_tuples "$a" m-admin)"

  section "access: ApiKey scopes"
  apikey "$a" k1 instances:read,instances:write
  wait_ready apikeys.phorge.fr "$a" k1 120 && pass "ApiKey with two scopes becomes Ready" || fail "ApiKey with two scopes becomes Ready" "$(why apikeys.phorge.fr k1 "$a")"
  eq "status.keyId is <tenant>.<name>" "$TA.k1" "$(sget apikeys.phorge.fr "$a" k1 '{.status.keyId}')"
  eq "one tuple per scope" 2 "$(count_tuples "$a" k1-)"
  local ps; ps=$(api_store)
  eq "scope instances:read is key_instances_read on tenant:<name>, in the phorge-api store" "$ps/apikey:$TA.k1/key_instances_read/tenant:$TA" "$(tuple_name "$a" k1-instances-read)"
  eq "scope instances:write likewise" "$ps/apikey:$TA.k1/key_instances_write/tenant:$TA" "$(tuple_name "$a" k1-instances-write)"
  apikey "$a" kall tenant:read,instances:read,instances:write,images:read,images:write,memberships:read,memberships:write
  wait_ready apikeys.phorge.fr "$a" kall 180 && eq "a key with all 7 scopes writes 7 tuples" 7 "$(count_tuples "$a" kall-)" \
    || fail "a key with all 7 scopes becomes Ready" "$(why apikeys.phorge.fr kall "$a")"

  section "access: ApiKey scope changes and deletion"
  apikey "$a" k1 instances:read,images:read
  wait_until 150 "tuples follow scopes" bash -c "[[ \$(kubectl --context $E2E_CONTEXT -n $a get $RT -o name | grep -c '/k1-images-read') == 1 && \$(kubectl --context $E2E_CONTEXT -n $a get $RT -o name | grep -c '/k1-instances-write') == 0 ]]"
  eq "adding a scope adds its tuple" 1 "$(count_tuples "$a" k1-images-read)"
  eq "removing a scope removes its tuple (the key loses the right)" 0 "$(count_tuples "$a" k1-instances-write)"
  eq "the scope kept keeps its tuple" 1 "$(count_tuples "$a" k1-instances-read)"
  K -n "$a" delete apikeys.phorge.fr kall --wait=true --timeout=180s >/dev/null 2>&1
  tuples_gone "$a" kall- "deleting a key deletes every tuple"

  section "access: expiry is not enforced here"
  cat <<YAML | K apply -f - >/dev/null
apiVersion: phorge.fr/v1alpha1
kind: ApiKey
metadata: {name: kold, namespace: $a, labels: {$LABEL: "$RUN_ID"}}
spec:
  hash: "$(printf 'old' | sha256sum | cut -d' ' -f1)"
  scopes: [tenant:read]
  expiresAt: 2020-01-01T00:00:00Z
YAML
  sleep 45
  note "a key with expiresAt in 2020 is $(cond apikeys.phorge.fr kold "$a" Ready | sed 's/True/Ready/;s/False/not Ready/') and keeps its tuple: expiry is only data, the API must enforce it"

  section "access: tuples in the Incus model vs the API model"
  note "Membership and the Tenant owner write to the Incus store (iaas) only; the phorge-api store has tenant roles (admin..viewer) that no composition writes, so can_read_* / can_write_* only ever become true through an ApiKey"

  if [[ -n ${FGA_URL:-} && -n ${FGA_TOKEN:-} ]]; then
    section "access: read back from OpenFGA"
    local ok
    ok=$(fga "$s" check "{\"tuple_key\":{\"user\":\"user:owner-a@example.org\",\"relation\":\"admin\",\"object\":\"$obj\"}}" | jq -r .allowed)
    eq "the owner is admin on the project" true "$ok"
    ok=$(fga "$s" check "{\"tuple_key\":{\"user\":\"user:u-viewer@example.org\",\"relation\":\"can_view\",\"object\":\"$obj\"}}" | jq -r .allowed)
    eq "a viewer-or-above can view the project" true "$ok"
    ok=$(fga "$s" check "{\"tuple_key\":{\"user\":\"user:stranger@example.org\",\"relation\":\"can_view\",\"object\":\"$obj\"}}" | jq -r .allowed)
    eq "a stranger cannot" false "$ok"
    ok=$(fga "$ps" check "{\"tuple_key\":{\"user\":\"apikey:$TA.k1\",\"relation\":\"can_read_instances\",\"object\":\"tenant:$TA\"}}" | jq -r .allowed)
    eq "a key with instances:read can read instances" true "$ok"
    ok=$(fga "$ps" check "{\"tuple_key\":{\"user\":\"apikey:$TA.k1\",\"relation\":\"can_write_instances\",\"object\":\"tenant:$TA\"}}" | jq -r .allowed)
    eq "and, after its write scope was removed, cannot write them" false "$ok"
  else
    skip "reading tuples back from OpenFGA (set FGA_URL and FGA_TOKEN to enable)"
  fi
}
