# Demos

Public demos of Nerva, built only on its general pieces (`nerva api`, layouts, declared views,
`nerva view`), with no demo-specific code inside Nerva. Python standard library only.

## Seat race (`seats/`)

512 seats, simulated buyers racing for the best ones, and a page where a visitor can:

- **buy** a seat (a read at the version seen, then a write: a lost race answers 409);
- **rewind**: drag through the show's history; the seat map and every view are read as of
  that op (the seat map is itself a declared view);
- **crash** any replica (one at a time, so the cluster keeps quorum), the API or either view
  process; crashed processes come back after 20 s;
- **declare** a view of their own, which answers for the whole show at once.

Two view processes compute sales by section independently; the page compares their hashes at
the same op. "Seats sold twice" counts purchases confirmed for a seat that already had one: it
must stay 0.

```bash
./zig/zig build -Drelease
python3 demo/seats/server.py --nerva zig-out/bin/nerva --data /tmp/seats --port 8000
# open http://127.0.0.1:8000   (--pace 4 sells out four times faster)
```

It needs about 3.5 GiB of disk (three data files) and about 2.6 GiB of memory (three
`--development` replicas). The data directory survives restarts; delete it to start over.
Stopping the server (Ctrl-C or SIGTERM) stops the cluster.

`zig build test:demo` runs it under a minute of random crashes and checks that no seat was sold
twice, every confirmed sale is in the map, the views agree with each other and the map, and
nothing is left running.

`cluster.py` is the supervisor (three replicas, the API, two view processes, crash and restart);
`nerva_http.py` a small client. The canvas demo will reuse both.
