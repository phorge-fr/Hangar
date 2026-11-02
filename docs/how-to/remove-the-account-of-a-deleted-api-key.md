---
type: how-to
audience: administrator cleaning up after deleted API keys
verified: 2026-11-02
---

# Remove the account of a deleted API key

Deleting an `ApiKey` removes its token, its Secret and its tuples, but the service account `apikey-<name>` stays in Authentik without any credential: the identity that Crossplane uses cannot delete users (see [the reference](../reference/phorge-api-kinds.md#apikey)). It does no harm, and an administrator removes it when it is worth the clean-up.

## List the leftovers

The accounts of the keys, with the number of tokens each one holds. An account with `tokens=0` is a leftover, unless its `ApiKey` still exists.

```bash
kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c '
from authentik.core.models import User, Token
for u in User.objects.filter(username__startswith="apikey-").order_by("username"):
    print(u.username, u.type, "tokens=%d" % Token.objects.filter(user=u).count())
'
```

## Remove one

1. Check that the key is really gone: the command must answer `NotFound`.

   ```bash
   kubectl --context control -n phorge-keys get apikeys.phorge.fr <name>
   ```

2. Delete the account. It refuses an account that still has a token, or that is not a service account.

   ```bash
   kubectl --context core -n authentik exec deploy/authentik-server -- ak shell -c '
   from authentik.core.models import User, Token
   u = User.objects.get(username="apikey-<name>", type="service_account")
   assert not Token.objects.filter(user=u).exists(), "the account still has a token"
   u.delete()
   print("deleted", "apikey-<name>")
   '
   ```

An `ApiKey` created later with the same name would be refused by Authentik while the account exists, and stays `Ready=False`. Remove the account first, or pick another name.
