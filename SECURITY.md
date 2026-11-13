# Security

Nerva is alpha ([docs/MATURITY.md](./docs/MATURITY.md)). This page says what its two keys
protect, what they do not, and how to report a vulnerability. Outputs below were recorded from
a build of `main` at commit `4ddd232` (`nerva version` printing `version 0.7.0`, as the version
is bumped at release); the release slice re-records them on the release commit.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on `NervaLog/nerva`: the repository's Security tab,
"Report a vulnerability". Say what you found, the release or commit, and how to reproduce it.
Put nothing about the vulnerability in a public issue.
There is no SLA: this is an alpha with one maintainer.

## The model

Nerva assumes the network around it is private and trusted. Two keys, both shared secrets, sit
on top of that.

**`NERVA_KEY` (a gateway's key).** `nerva api` and `nerva view` need `X-Nerva-Key` on every
request but `GET /healthz`, except that a method the gateway never takes (such as `DELETE`)
is answered `405` before the key is checked ([README, Limits](./README.md#limits)). It is one bearer key per gateway, sent in plain HTTP. It is compared
in constant time (`key_matches`, `src/nerva/http_connection.zig`). Without it, or with another
key:

```
$ curl -i -d '{"entries":[…]}' http://127.0.0.1:8981/v1/commit
HTTP/1.1 401 Unauthorized
{"error":"invalid key","applied":false,"code":"NRV-E0103"}
```

With the right key the same request answered `200 {"status":"committed","op":"3"}`. The key
authorizes nothing finer: whoever holds it may read and write everything the API does. The
gateway's protection is that it listens on loopback only, beside its client; a non-loopback
`--listen` is refused unless `--listen-remote` is given:

```
$ NERVA_KEY=k nerva api --cluster=1 --addresses=3901 --listen=0.0.0.0:8982
error[NRV-E0009]: api: --listen=0.0.0.0:8982 is not loopback; the gateway speaks plain HTTP
```

A gateway without `NERVA_KEY` does not start (`error[NRV-E0008]: api: set NERVA_KEY`).
Rotation, without downtime, is in [README, Limits](./README.md#limits) ("To rotate a gateway
key").

**`NERVA_CLUSTER_KEY` (the cluster key).** Before replicas exchange any message, each proves
that it holds this key (HMAC-SHA256 over both nonces, both replicas and the cluster). It
authenticates replica-to-replica connections only
([README](./README.md#replicas-authenticate-each-other)); it is at least 32 bytes and rotates
with `NERVA_CLUSTER_KEY_NEXT`.

## What a client that reaches a replica can do

Clients do not hold the cluster key. A process that can reach a replica's port can register as a
client and read and write, with no key at all. In the recorded run, a gateway, `nerva export` and
`nerva backup`, each started with no `NERVA_CLUSTER_KEY` in its environment, connected to a
replica and completed. So `NERVA_KEY` protects the gateway's door, not the cluster's. A party
that reaches a replica's port can also:

- **Evict every session.** A cluster holds 64 client sessions and a 65th evicts the least recent
  ([README, Limits](./README.md#limits)), so it can keep evicting every gateway, `nerva view` and
  `export` session.
- **Block an upgrade.** It can declare a view with no catalog document, and `nerva import` then
  refuses the export ([README](./README.md#upgrading-a-cluster)).
- **Skip the gateway's limits:** body size, the memory budget and the key.

Replica ports must be reachable only by the replicas and their gateways. This is by design
today; see [issue #303](https://github.com/NervaLog/nerva/issues/303).

## What is not protected

- **No encryption in transit** after the handshake: replica traffic is neither encrypted nor
  signed, and a gateway's requests, replies and key cross plain HTTP. Run replicas on an
  encrypted private network (WireGuard, or Fly.io's 6PN) and put TLS in front of any gateway a
  caller reaches off its own host ([README, Limits](./README.md#limits), "Network").
- **No encryption at rest.** Data files, exports and backups are checksummed, not encrypted.
  Use an encrypted volume, and treat an export as the data it holds.
- **Exports and backups are world-readable today.** `nerva export`, `nerva backup` and the
  backup's manifest are created with mode 0644, while the data file is 0600 (recorded on
  `4ddd232`; [issue #302](https://github.com/NervaLog/nerva/issues/302)). Until that is fixed,
  write them into a directory with mode 0700, or run the command under `umask 077`.
- **No per-user authorization.** See [docs/NON-GOALS.md](./docs/NON-GOALS.md).
- **A forwarder defeats the loopback rule.** The refusal is advisory ("Gateways beside their
  clients").
- **`--development` is not for production:** it relaxes Direct IO and falls back to a public
  cluster key on loopback (README, "Replicas authenticate each other").

## Where the secrets live

On Linux the packages' environment files hold them: `/etc/nerva/replica-<n>.env`
(`NERVA_CLUSTER_KEY`) and `/etc/nerva/api-<n>.env` (`NERVA_KEY`), made from
`packaging/linux/replica.env.example` and `api.env.example`. Set them `chown root:root` and
`chmod 0600`, and make each with `openssl rand -hex 32`. Nerva never prints either key (a
refusal names the problem, not the key). Anyone who can read an environment file, or the
process's environment, holds the key; rotate after any exposure. The packaged units run
replicas and gateways as the same user, `nerva`, so a gateway on a replica's host can read that
replica's `NERVA_CLUSTER_KEY` from its environment and its data file. Run gateways off the
replicas' hosts, or as another user.

## See also

[docs/INSTALL.md](./docs/INSTALL.md#checking-a-download) (checking a download),
[docs/OPERATING.md](./docs/OPERATING.md#production-checklist) (the production checklist, with keys and
networks) and [docs/API.md](./docs/API.md#conventions) (the gateway's key and transport).
