## Nightly performance: **fail**

Baseline `5ba6764825c0`, candidate `8bfb7a800d1f`. Machine disk: {"iops": 23209, "mib_s": 90.7}.

- **Error** in baseline round 1: c1/b1/c8 bench-load failed
- **Error** in baseline round 1: c1/b64/c8 bench-load failed
- **Error** in baseline round 1: c2/b1/c8 bench-load failed
- **Error** in baseline round 1: c3/b1/c8 bench-load failed
- **Error** in baseline round 1: c3_adds/b1/c8 bench-load failed
- **Error** in baseline round 1: c4/b1/c8 bench-load failed
- **Error** in baseline round 1: c4/b64/c8 bench-load failed
- **Error** in baseline round 1: c5/b1024/c8 bench-load failed
- **Error** in baseline round 1: c7/b1/c8 bench-load failed
- **Error** in candidate round 1: botpike/b1/c12 bench-load failed
- **Error** in candidate round 2: botpike/b1/c12 bench-load failed
- **Error** in baseline round 2: c1/b1/c8 bench-load failed
- **Error** in baseline round 2: c1/b64/c8 bench-load failed
- **Error** in baseline round 2: c2/b1/c8 bench-load failed
- **Error** in baseline round 2: c3/b1/c8 bench-load failed
- **Error** in baseline round 2: c3_adds/b1/c8 bench-load failed
- **Error** in baseline round 2: c4/b1/c8 bench-load failed
- **Error** in baseline round 2: c4/b64/c8 bench-load failed
- **Error** in baseline round 2: c5/b1024/c8 bench-load failed
- **Error** in baseline round 2: c7/b1/c8 bench-load failed
- **Error** in baseline round 3: c1/b1/c8 bench-load failed
- **Error** in baseline round 3: c1/b64/c8 bench-load failed
- **Error** in baseline round 3: c2/b1/c8 bench-load failed
- **Error** in baseline round 3: c3/b1/c8 bench-load failed
- **Error** in baseline round 3: c3_adds/b1/c8 bench-load failed
- **Error** in baseline round 3: c4/b1/c8 bench-load failed
- **Error** in baseline round 3: c4/b64/c8 bench-load failed
- **Error** in baseline round 3: c5/b1024/c8 bench-load failed
- **Error** in baseline round 3: c7/b1/c8 bench-load failed
- **Error** in candidate round 3: botpike/b1/c12 bench-load failed

| Status | Metric | Baseline | Candidate | Worse by (median) | Per round | Threshold |
|---|---|---|---|---|---|---|
| pass | micro declared_views.as_of_middle_ns | 2.39919e+08 | 2.36611e+08 | -1.4% | -7.2%, -1.4%, +3.4% | 10% |
| pass | micro declared_views.latest_ns | 9.94284e+07 | 1.00884e+08 | -2.9% | -6.1%, -2.9%, +7.1% | 10% |
| pass | micro documents.decode_ns_per_document | 10045 | 10124 | +2.2% | +2.2%, -0.6%, +3.5% | 10% |
| pass | micro documents.encode_ns_per_document | 246145 | 248303 | +1.2% | -1.2%, +1.2%, +4.7% | 10% |
