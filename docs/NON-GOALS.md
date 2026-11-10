# Non-goals

What Nerva does not do today, so that nobody finds out in production. Each line says why, or
which milestone in [docs/PRODUCTION.md](./PRODUCTION.md) may change it. The label is in
[MATURITY.md](./MATURITY.md).

- **No SQL.** Nerva has typed rows, records, documents, declared views and ledgers, reached
  through `nerva api`'s JSON routes or the Zig client. Derived state is declared, not queried
  ([README](../README.md#design-in-one-picture)).
- **No TLS.** A gateway speaks plain HTTP on loopback beside its client, and replicas do not
  encrypt after the handshake. Put TLS or an encrypted private network in front
  ([SECURITY.md](../SECURITY.md)). The gateway's TLS is listed as a non-goal in R4.
- **One shared gateway key.** `NERVA_KEY` is one bearer key per gateway
  ([README](../README.md#limits), "Network"). Every gateway has its own, so rotate them
  independently.
- **No per-user authorization.** A caller with the key may do everything the API does. Decide
  who may call in the process that owns the gateway.
- **No encryption at rest.** Data files are checksummed, not encrypted. Use an encrypted volume.
- **No retention yet.** Commit keys, history and view versions are kept forever, so disk use,
  export and import grow with all history. R7 (Retention) is the milestone.
- **No rolling upgrades yet.** Replicas of different releases ignore each other, so a release
  that changes the format upgrades by export and import with the cluster closed
  ([README](../README.md#upgrading-a-cluster)). R6 (Upgrade) is the milestone.
- **64 client sessions per cluster.** Every gateway, `nerva view`, `export`, `recover` and Zig
  client takes one, and a 65th evicts the least recent
  ([README](../README.md#limits)). A constant of the replica, not a setting.
- **Linux for production.** Production has run only on Linux (io_uring, Direct IO). macOS is for
  development and evaluation.
