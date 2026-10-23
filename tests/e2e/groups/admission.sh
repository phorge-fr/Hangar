# What the XRDs accept and refuse, by server-side dry run: nothing is stored, no controller reacts,
# so this group is fast and touches neither Incus nor OpenFGA.

_t() { # name, then spec lines (already indented)
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Tenant\nmetadata: {name: %s, namespace: phorge-system}\nspec:\n%s\n' "$1" "$2"
}
_i() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Image\nmetadata: {name: x, namespace: default}\nspec:\n%s\n' "$1"; }
_n() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec:\n  imageRef: {name: i}\n%s\n' "${1:-}"; }
_m() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Membership\nmetadata: {name: x, namespace: default}\nspec:\n%s\n' "$1"; }
_k() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: ApiKey\nmetadata: {name: x, namespace: default}\nspec:\n%s\n' "$1"; }
H64=$(printf 'a%.0s' {1..64})

group_admission() {
  section "admission: Tenant"
  local ok='  owner: a@b.fr'
  _t demo "$ok" | accept "minimal tenant"
  _t demo "$ok
  plan: large
  displayName: Demo" | accept "tenant with every field"
  _t a1 "$ok" | accept "2 characters is the shortest name allowed"
  _t demo "  plan: small" | reject "no owner" 'spec.owner'
  _t demo "  owner: alice" | reject "owner that is not an email" 'spec.owner'
  _t demo "  owner: 'a b@c.fr'" | reject "owner with a space" 'spec.owner'
  _t demo "$ok
  plan: xl" | reject "unknown plan" 'spec.plan'
  _t demo "$ok
  displayName: $(printf 'x%.0s' {1..101})" | reject "displayName over 100 characters" 'displayName'
  _t "a" "$ok" | reject "1 character name" 'must be 2 to 28'
  _t "1abc" "$ok" | reject "name starting with a digit" 'must be 2 to 28'
  _t "$(printf 'a%.0s' {1..29})" "$ok" | reject "29 characters name" 'must be 2 to 28'
  _t "$(printf 'a%.0s' {1..28})" "$ok" | accept "28 characters name"
  _t "Demo" "$ok" | reject "uppercase name" 'RFC 1123|must be'
  _t demo "$ok" | defaulted "plan defaults to small" '.spec.plan' small

  section "admission: Image"
  _i "  source: {name: debian/13/cloud}" | accept "image with a name only"
  _i "  source: {name: debian/13/cloud}" | defaulted "remote defaults to images" '.spec.source.remote' images
  _i "  source: {name: debian/13/cloud}" | defaulted "type defaults to virtual-machine" '.spec.source.type' virtual-machine
  _i "  source: {name: debian/13/cloud}" | defaulted "architecture defaults to x86_64" '.spec.source.architecture' x86_64
  _i "  source: {name: debian/13/cloud}" | defaulted "aliases default to empty" '.spec.aliases | length' 0
  _i "  aliases: [a]" | reject "no source" 'spec.source'
  _i "  source: {remote: images}" | reject "source without a name" 'source.name'
  _i "  source: {name: ''}" | reject "empty source name" 'source.name'
  _i "  source: {name: debian/13/cloud, type: container}" | reject "container image" 'source.type'

  section "admission: Instance"
  _n | accept "instance with an imageRef only"
  _n | defaulted "cpu defaults to 1" '.spec.cpu' 1
  _n | defaulted "memory defaults to 1024 MiB" '.spec.memoryMiB' 1024
  _n | defaulted "disk defaults to 10 GiB" '.spec.diskGiB' 10
  _n | defaulted "running defaults to true" '.spec.running' true
  _n | defaulted "nesting defaults to false" '.spec.nesting' false
  _n | defaulted "sshPublicKeys default to empty" '.spec.sshPublicKeys | length' 0
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec: {}\n' | reject "no imageRef" 'imageRef'
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec:\n  imageRef: {name: ""}\n' | reject "empty imageRef name" 'imageRef'
  _n "  cpu: 0" | reject "cpu 0" 'spec.cpu'
  _n "  cpu: 17" | reject "cpu 17" 'spec.cpu'
  _n "  cpu: 16" | accept "cpu 16"
  _n "  memoryMiB: 255" | reject "memory 255 MiB" 'memoryMiB'
  _n "  memoryMiB: 65537" | reject "memory 65537 MiB" 'memoryMiB'
  _n "  memoryMiB: 65536" | accept "memory 65536 MiB"
  _n "  diskGiB: 0" | reject "disk 0" 'diskGiB'
  _n "  diskGiB: 501" | reject "disk 501" 'diskGiB'
  _n "  diskGiB: 500" | accept "disk 500"
  _n "  sshPublicKeys: [a, b]" | accept "several ssh keys"

  section "admission: Membership"
  _m "  subject: {kind: User, name: a@b.fr}
  role: viewer" | accept "user viewer"
  _m "  subject: {kind: Group, name: devs}
  role: admin" | accept "group admin (a group name is not an email)"
  local r; for r in admin operator user viewer; do
    _m "  subject: {kind: User, name: a@b.fr}
  role: $r" | accept "role $r"
  done
  _m "  subject: {kind: User, name: alice}
  role: viewer" | reject "user that is not an email" 'identified by its email'
  _m "  subject: {kind: Robot, name: a@b.fr}
  role: viewer" | reject "unknown subject kind" 'subject.kind'
  _m "  subject: {kind: User, name: a@b.fr}
  role: owner" | reject "unknown role" 'spec.role'
  _m "  subject: {kind: User, name: a@b.fr}" | reject "no role" 'spec.role'
  _m "  role: viewer" | reject "no subject" 'spec.subject'
  _m "  subject: {kind: Group, name: ''}
  role: viewer" | reject "empty group name" 'subject.name'

  section "admission: ApiKey"
  _k "  hash: $H64
  scopes: [instances:read]" | accept "key with one scope"
  _k "  hash: $H64
  scopes: [tenant:read, instances:read, instances:write, images:read, images:write, memberships:read, memberships:write]" | accept "key with all 7 scopes"
  _k "  hash: $H64
  scopes: [instances:read]
  displayName: ci
  expiresAt: 2030-01-01T00:00:00Z
  createdBy: a@b.fr" | accept "key with every field"
  _k "  hash: abc
  scopes: [instances:read]" | reject "short hash" 'spec.hash'
  _k "  hash: ${H64^^}
  scopes: [instances:read]" | reject "uppercase hash" 'spec.hash'
  _k "  hash: ${H64}0
  scopes: [instances:read]" | reject "65 characters hash" 'spec.hash'
  _k "  scopes: [instances:read]" | reject "no hash" 'spec.hash'
  _k "  hash: $H64" | reject "no scopes" 'spec.scopes'
  _k "  hash: $H64
  scopes: []" | reject "empty scopes" 'spec.scopes'
  _k "  hash: $H64
  scopes: [instances:delete]" | reject "unknown scope" 'spec.scopes'
  _k "  hash: $H64
  scopes: [instances:read, instances:read]" | reject "the same scope twice" 'Duplicate|duplicate'
  _k "  hash: $H64
  scopes: [instances:read]
  expiresAt: tomorrow" | reject "malformed expiresAt" 'expiresAt'
  _k "  hash: $H64
  scopes: [instances:read]
  displayName: $(printf 'x%.0s' {1..101})" | reject "displayName over 100 characters" 'displayName'
}
