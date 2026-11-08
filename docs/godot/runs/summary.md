| Scenario | local response (key -> own screen) | server-visible response (key -> confirmation) | corrections | max error, px | server rejects / accepts | final client-vs-server error, px |
|---|---|---|---|---|---|---|
| T1_walk_noemu_pred | min 0 / avg 0 / max 0 ms (n=1) | min 42 / avg 42 / max 42 ms (n=1) | 0 | 0.00 | 0 / 1 | 0.000 |
| T2_lag100_nopred | - | min 234 / avg 239 / max 242 ms (n=3) | 3 | 22.67 | 0 / 3 | 0.000 |
| T3_lag100_pred | min 0 / avg 0 / max 0 ms (n=3) | min 234 / avg 245 / max 251 ms (n=3) | 0 | 0.00 | 0 / 3 | 0.000 |
| T4_lag175loss4_pred | min 0 / avg 0 / max 0 ms (n=5) | min 358 / avg 395 / max 418 ms (n=5) | 0 | 0.00 | 3 / 5 | 0.000 |
| T5_lag175loss4_cheat | min 0 / avg 0 / max 0 ms (n=5) | min 408 / avg 415 / max 425 ms (n=4) | 5 | 209.88 | 1 / 4 | 0.000 |
| T6_lag100_wall | min 0 / avg 0 / max 0 ms (n=2) | min 251 / avg 251 / max 251 ms (n=2) | 0 | 0.00 | 0 / 2 | 0.000 |
