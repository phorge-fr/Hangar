# What the XRDs accept and refuse, by server-side dry run: nothing is stored, no controller reacts,
# so this group is fast and touches neither Incus nor OpenFGA.

_t() { # name, then spec lines (already indented)
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Tenant\nmetadata: {name: %s, namespace: phorge-system}\nspec:\n%s\n' "$1" "$2"
}
_i() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Image\nmetadata: {name: x, namespace: default}\nspec:\n%s\n' "$1"; }
_n() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec:\n  imageRef: {name: i}\n  network: net\n%s\n' "${1:-}"; }
# _c <cpu> <memoryMiB> <diskGiB> [more spec lines]: an instance with a custom size
_c() { _n "  cpu: ${1:-1}
  memoryMiB: ${2:-1024}
  diskGiB: ${3:-10}${4:+
$4}"; }
_p() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Profile\nmetadata: {name: %s, namespace: default}\nspec:\n%s\n' "$1" "${2:-  cpu: 1
  memoryMiB: 1024
  diskGiB: 10}"; }
_w() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Network\nmetadata: {name: %s, namespace: default}\nspec:\n%s\n' "$1" "${2:-  description: x}"; }
_m() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: Membership\nmetadata: {name: x, namespace: default}\nspec:\n%s\n' "$1"; }
_k() { printf 'apiVersion: phorge.fr/v1alpha1\nkind: ApiKey\nmetadata: {name: x, namespace: phorge-keys}\nspec:\n%s\n  owner: %s\n' "$1" "${2-a@b.fr}"; }
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
  _n "  profile: m" | accept "instance with a profile"
  _c | accept "instance with a custom size"
  _c | defaulted "running defaults to true" '.spec.running' true
  _c | defaulted "nesting defaults to false: it is the instance's alone, a profile cannot carry it" '.spec.nesting' false
  # No default for these two: the profile can carry them, and a default written into the object would override it. The
  # composition applies the defaults, status.secureBoot and status.sshPublicKeys say what is in force.
  _c | defaulted "secureBoot has no default: the instance did not say" '.spec.secureBoot // "unset"' unset
  _c | defaulted "sshPublicKeys have no default: the instance did not say" '.spec.sshPublicKeys // "unset"' unset
  _n "  profile: m
  secureBoot: true
  sshPublicKeys: []" | defaulted "what the instance says stays as it is (true, an empty list)" '[.spec.secureBoot, .spec.sshPublicKeys] | tostring' '[true,[]]'
  _n "  profile: m
  secureBoot: false" | defaulted "an instance that says false keeps it" '.spec.secureBoot' false
  _n "  profile: m" | defaulted "a profile leaves cpu unset (the profile decides)" '.spec.cpu // "unset"' unset
  _n "  profile: m" | defaulted "a profile leaves memoryMiB unset" '.spec.memoryMiB // "unset"' unset
  _n "  profile: m" | defaulted "a profile leaves diskGiB unset" '.spec.diskGiB // "unset"' unset
  _n | reject "no size at all" 'cpu, memoryMiB and diskGiB are all required'
  _n "  cpu: 2" | reject "a cpu alone" 'cpu, memoryMiB and diskGiB are all required'
  _n "  cpu: 2
  memoryMiB: 2048" | reject "no disk" 'cpu, memoryMiB and diskGiB are all required'
  _n "  memoryMiB: 2048
  diskGiB: 20" | reject "no cpu" 'cpu, memoryMiB and diskGiB are all required'
  _n "  profile: m
  cpu: 2" | reject "a profile and a cpu" 'not both'
  _n "  profile: m
  memoryMiB: 2048" | reject "a profile and a memory" 'not both'
  _n "  profile: m
  diskGiB: 20" | reject "a profile and a disk" 'not both'
  _n "  profile: ''" | reject "an empty profile name" 'profile'
  _n "  profile: -m" | reject "a profile name that starts with a hyphen" 'profile'
  _n "  profile: $(printf 'a%.0s' {1..64})" | reject "a profile name of 64 characters" 'profile'
  _n "  profile: $(printf 'a%.0s' {1..63})" | accept "a profile name of 63 characters"
  _n "  profile: s" | accept "profile s"
  _n "  profile: l" | accept "profile l"
  _n "  profile: team.small_1" | accept "a profile name with a dot, an underscore and a digit"
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec:\n  imageRef: {name: i}\n  profile: m\n' | reject "no network" 'spec.network'
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec:\n  imageRef: {name: i}\n  network: ""\n  profile: m\n' | reject "an empty network" 'network'
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec:\n  imageRef: {name: i}\n  network: Net\n  profile: m\n' | reject "a network name in uppercase" 'network'
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec: {profile: m, network: net}\n' | reject "no imageRef" 'imageRef'
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: Instance\nmetadata: {name: x, namespace: default}\nspec:\n  imageRef: {name: ""}\n  network: net\n  profile: m\n' | reject "empty imageRef name" 'imageRef'
  _c 0 | reject "cpu 0" 'spec.cpu'
  _c 17 | reject "cpu 17" 'spec.cpu'
  _c 16 | accept "cpu 16"
  _c 1 255 | reject "memory 255 MiB" 'memoryMiB'
  _c 1 65537 | reject "memory 65537 MiB" 'memoryMiB'
  _c 1 65536 | accept "memory 65536 MiB"
  _c 1 1024 0 | reject "disk 0" 'diskGiB'
  _c 1 1024 501 | reject "disk 501" 'diskGiB'
  _c 1 1024 500 | accept "disk 500"
  local k1='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE2eUpdatedKeyOnly' k2='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 laptop@home'
  _n "  profile: s
  sshPublicKeys: ['$k1', '$k2']" | accept "several ssh keys, one with a comment"
  _n "  profile: s
  sshPublicKeys: [a, b]" | reject "ssh keys that are not keys" 'each key must be'
  _n "  profile: s
  sshPublicKeys: [\"$k1\\nruncmd: [reboot]\"]" | reject "an ssh key with a line break (cloud-init injection)" 'each key must be'
  _n "  profile: s
  sshPublicKeys: ['$k1 note: x']" | reject "an ssh key whose comment has a colon" 'each key must be'
  _n "  profile: s
  sshPublicKeys: ['$k1 two words']" | reject "an ssh key with a two word comment" 'each key must be'
  _n "  profile: s
  sshPublicKeys: [$(printf "'$k1', %.0s" {1..20})'$k1']" | reject "21 ssh keys" 'sshPublicKeys'

  section "admission: Profile"
  _p web | accept "a profile with its three values"
  _p web "  description: for the web servers
  cpu: 1
  memoryMiB: 1024
  diskGiB: 10" | accept "a profile with a description"
  _p a | accept "a one character name"
  _p "$(printf 'a%.0s' {1..32})" | accept "a 32 characters name"
  _p "$(printf 'a%.0s' {1..33})" | reject "a 33 characters name" 'must be 1 to 32'
  _p 1web | reject "a name that starts with a digit" 'must be 1 to 32'
  _p Web | reject "a name in uppercase" 'must be 1 to 32|RFC 1123'
  _p web- | reject "a name that ends with a hyphen" 'must be 1 to 32|RFC 1123'
  _p my_web | reject "a name with an underscore" 'must be 1 to 32|RFC 1123'
  local n; for n in s m l default; do _p "$n" | reject "the name $n, which every tenant has" 'every tenant has'; done
  _p web "  memoryMiB: 1024
  diskGiB: 10" | reject "no cpu" 'cpu'
  _p web "  cpu: 1
  diskGiB: 10" | reject "no memory" 'memoryMiB'
  _p web "  cpu: 1
  memoryMiB: 1024" | reject "no disk" 'diskGiB'
  _p web "  cpu: 0
  memoryMiB: 1024
  diskGiB: 10" | reject "cpu 0" 'spec.cpu'
  _p web "  cpu: 17
  memoryMiB: 1024
  diskGiB: 10" | reject "cpu 17" 'spec.cpu'
  _p web "  cpu: 16
  memoryMiB: 65536
  diskGiB: 500" | accept "the biggest profile an instance may be"
  _p web "  cpu: 1
  memoryMiB: 255
  diskGiB: 10" | reject "memory 255 MiB" 'memoryMiB'
  _p web "  cpu: 1
  memoryMiB: 65537
  diskGiB: 10" | reject "memory 65537 MiB" 'memoryMiB'
  _p web "  cpu: 1
  memoryMiB: 1024
  diskGiB: 501" | reject "disk 501" 'diskGiB'
  _p web "  description: $(printf 'x%.0s' {1..201})
  cpu: 1
  memoryMiB: 1024
  diskGiB: 10" | reject "a description over 200 characters" 'description'
  local p3='  cpu: 1
  memoryMiB: 1024
  diskGiB: 10'
  _p web "$p3
  secureBoot: false
  sshPublicKeys: ['$k1', '$k2']" | accept "a profile with secure boot and ssh keys"
  _p web "$p3
  sshPublicKeys: []" | accept "a profile with an empty list of keys"
  _p web "$p3" | defaulted "secureBoot has no default on a profile" '.spec.secureBoot // "unset"' unset
  _p web "$p3" | defaulted "sshPublicKeys have no default on a profile" '.spec.sshPublicKeys // "unset"' unset
  # Nesting is not offered on a profile: the tenant's projects have restricted.containers.nesting: block and a profile has no
  # instance type, so Incus refused security.nesting on a profile ("Container nesting is forbidden", measured). It stays a
  # setting of the Instance, a VM, for which the project allows it. The strict schema refuses the field.
  _p web "$p3
  nesting: true" | reject "nesting on a profile: the project blocks it there, it is the instance's" 'unknown field|nesting'
  _p web "$p3
  secureBoot: 1" | reject "a secureBoot that is not a boolean" 'secureBoot'
  _p web "$p3
  sshPublicKeys: [a, b]" | reject "profile ssh keys that are not keys" 'each key must be'
  _p web "$p3
  sshPublicKeys: [\"$k1\\nruncmd: [reboot]\"]" | reject "a profile ssh key with a line break (cloud-init injection)" 'each key must be'
  _p web "$p3
  sshPublicKeys: ['$k1 note: x']" | reject "a profile ssh key whose comment has a colon" 'each key must be'
  _p web "$p3
  sshPublicKeys: ['$k1 two words']" | reject "a profile ssh key with a two word comment" 'each key must be'
  _p web "$p3
  sshPublicKeys: [$(printf "'$k1', %.0s" {1..20})'$k1']" | reject "21 ssh keys in a profile" 'sshPublicKeys'
  _p web "$p3
  network: net" | reject "a network in a profile: that is the instance's" 'unknown field|network'
  _p web "$p3
  networks: [net]" | reject "networks in a profile" 'unknown field|networks'

  section "admission: Network"
  _w net1 | accept "a network with a description"
  _w net1 "  ipv4: 10.77.1.1/24" | accept "a network with an address"
  _w net1 "  ipv4: 10.77.1.1/16" | accept "a /16"
  _w net1 "  ipv4: 10.77.1.1/29" | accept "a /29"
  _w net1 "  ipv4: 10.77.1.1/15" | reject "a prefix of 15" 'ipv4'
  _w net1 "  ipv4: 10.77.1.1/30" | reject "a prefix of 30" 'ipv4'
  _w net1 "  ipv4: 10.77.1.1" | reject "an address without a prefix" 'ipv4'
  _w net1 "  ipv4: 999.1.1.1/24" | reject "an address that is not one" 'ipv4'
  _w net1 "  ipv4: fd00::1/64" | reject "an IPv6 address" 'ipv4'
  _w net1 "  nat: false" | reject "a nat field: a network is always NATed" 'unknown field|nat'
  _w a | accept "a one character name"
  _w "$(printf 'a%.0s' {1..15})" | accept "a 15 characters name (the longest Incus allows)"
  _w "$(printf 'a%.0s' {1..16})" | reject "a 16 characters name" 'must be 1 to 15'
  _w 1net | reject "a name that starts with a digit" 'must be 1 to 15'
  _w Net | reject "a name in uppercase" 'must be 1 to 15|RFC 1123'
  _w my_net | reject "a name with an underscore" 'must be 1 to 15|RFC 1123'
  _w net1 "  description: $(printf 'x%.0s' {1..201})" | reject "a description over 200 characters" 'description'
  _w net1 "  subnet: 10.0.0.0/24" | reject "a field the kind does not have (the addresses are Incus's)" 'unknown field|subnet'

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
  local E="expiresAt: 2030-01-01T00:00:00Z"
  _k "  $E
  grants: [{tenant: demo, scopes: [instances:read]}]" | accept "key with one grant"
  _k "  $E
  grants: [{tenant: demo, scopes: [tenants:read, tenants:write, instances:read, instances:write, images:read, images:write, networks:read, networks:write, profiles:read, profiles:write, memberships:read, memberships:write]}]" | accept "key with all 12 scopes"
  _k "  $E
  grants: [{tenant: a, scopes: [instances:read]}, {tenant: b, scopes: [images:read]}]
  displayName: ci" | accept "key on two tenants with every field"
  _k "  $E
  grants: [{tenant: demo, scopes: [tenants:create]}]" | reject "tenants:create: no key creates a tenant" 'scopes'
  _k "  $E
  grants: [{tenant: demo, scopes: [tenant:read]}]" | reject "the former scope name tenant:read" 'scopes'
  _k "  $E" | reject "no grants" 'spec.grants'
  _k "  $E
  grants: []" | reject "empty grants" 'spec.grants'
  _k "  $E
  grants: [{tenant: demo, scopes: []}]" | reject "empty scopes" 'scopes'
  _k "  $E
  grants: [{tenant: demo, scopes: [instances:delete]}]" | reject "unknown scope" 'scopes'
  _k "  $E
  grants: [{tenant: demo, scopes: [instances:read, instances:read]}]" | reject "the same scope twice" 'Duplicate|duplicate'
  _k "  $E
  grants: [{tenant: demo, scopes: [images:read]}, {tenant: demo, scopes: [instances:read]}]" | reject "the same tenant twice" 'Duplicate|duplicate'
  _k "  $E
  grants: [{tenant: Demo, scopes: [instances:read]}]" | reject "an invalid tenant name" 'tenant'
  _k "  grants: [{tenant: demo, scopes: [instances:read]}]" | reject "no expiry (a key must expire)" 'spec.expiresAt'
  _k "  expiresAt: tomorrow
  grants: [{tenant: demo, scopes: [instances:read]}]" | reject "malformed expiresAt" 'expiresAt'
  _k "  $E
  grants: [{tenant: demo, scopes: [instances:read]}]
  displayName: $(printf 'x%.0s' {1..101})" | reject "displayName over 100 characters" 'displayName'
  _k "  hash: $H64
  $E
  grants: [{tenant: demo, scopes: [instances:read]}]" | reject "the former hash field, the secret is the token of the service account" 'unknown field|hash'
  printf 'apiVersion: phorge.fr/v1alpha1\nkind: ApiKey\nmetadata: {name: x, namespace: phorge-keys}\nspec:\n  expiresAt: 2030-01-01T00:00:00Z\n  grants: [{tenant: demo, scopes: [instances:read]}]\n' | reject "no owner" 'spec.owner'
  _k "  $E
  grants: [{tenant: demo, scopes: [instances:read]}]" "" | reject "an empty owner" 'spec.owner'
}
