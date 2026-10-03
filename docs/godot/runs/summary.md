| Scenario | local response (key -> own screen) | server-visible response (key -> confirmation) | corrections | max error, px | server rejects / accepts | final client-vs-server error, px |
|---|---|---|---|---|---|---|
| T1_walk_noemu_pred | min 0 / avg 0 / max 0 ms (n=1) | min 25 / avg 25 / max 25 ms (n=1) | 0 | 0.00 | 0 / 1 | 0.000 |
| T2_lag100_nopred | - | min 242 / avg 242 / max 242 ms (n=3) | 3 | 22.67 | 0 / 3 | 0.000 |
| T3_lag100_pred | min 0 / avg 0 / max 0 ms (n=3) | min 234 / avg 236 / max 242 ms (n=3) | 0 | 0.00 | 0 / 3 | 0.000 |
| T4_lag175loss4_pred | min 0 / avg 0 / max 0 ms (n=5) | min 358 / avg 392 / max 417 ms (n=5) | 0 | 0.00 | 3 / 5 | 0.000 |
| T5_lag175loss4_cheat | min 0 / avg 0 / max 0 ms (n=5) | min 383 / avg 402 / max 435 ms (n=4) | 6 | 206.27 | 1 / 4 | 0.000 |
| T6_lag100_wall | min 0 / avg 0 / max 0 ms (n=2) | min 242 / avg 250 / max 258 ms (n=2) | 0 | 0.00 | 0 / 2 | 0.000 |
