# Investigation B — Wall-time aggregate

**Comparable cells**: 2293 (both new and old produced wall times)

## Top-line

- **Total new wall time**: 3891979s = **1081.1 CPU-hours**
- **Total old wall time**: 9993957s = **2776.1 CPU-hours**
- **Wall-time saved**: 6101978s = **1695.0 CPU-hours** (61.1% of old total)
- **Aggregate speedup ratio**: 2.57× (vs median 1.11×)

Note: aggregate speedup (sum old / sum new) is the right metric for 'did the rerun
actually save the cluster time?' Median misleads because most cells were already fast.

## Where the savings come from

| speedup bucket | n cells | total saved (CPU-hr) |
|----------------|--------:|---------------------:|
| long-tail (≥5×) | 155 | +1558.7 |
| moderate (1.5–5×) | 315 | +239.7 |
| flat (0.7–1.5×) | 1568 | +9.3 |
| slower (<0.7×) | 255 | -112.8 |

The long-tail bucket (155 cells) accounts for 92% of total savings.

## Per-run aggregate

| run | n | new total (hr) | old total (hr) | saved (hr) | ratio |
|-----|--:|---------------:|---------------:|-----------:|------:|
| odepe_v2_nopolish | 1146 | 619.1 | 528.7 | -90.4 | 0.85× |
| odepe_v2_polish | 1147 | 462.0 | 2247.4 | +1785.4 | 4.86× |

## Top 10 highest-speedup buckets

| system | run | noise | n | new tot | old tot | speedup |
|--------|-----|-------|--:|--------:|--------:|--------:|
| crauste | odepe_v2_polish | 0 | 9 | 9.6h | 169.7h | 17.7× |
| hiv | odepe_v2_polish | 0 | 10 | 7.7h | 116.6h | 15.1× |
| crauste | odepe_v2_polish | 1em6 | 10 | 13.9h | 186.0h | 13.4× |
| hiv | odepe_v2_polish | 1em8 | 10 | 9.4h | 121.4h | 12.9× |
| crauste | odepe_v2_polish | 1em2 | 10 | 14.4h | 180.6h | 12.6× |
| hiv | odepe_v2_polish | 1em4 | 10 | 10.3h | 126.8h | 12.3× |
| hiv | odepe_v2_polish | 1em6 | 10 | 9.5h | 115.2h | 12.1× |
| sirt_treatment | odepe_v2_polish | 1em6 | 10 | 4.0h | 41.6h | 10.5× |
| sirt_treatment | odepe_v2_polish | 0 | 10 | 2.7h | 26.0h | 9.6× |
| crauste | odepe_v2_polish | 1em8 | 10 | 17.3h | 156.3h | 9.0× |

## Top 10 biggest absolute savings

| system | run | noise | n | new tot | old tot | saved | speedup |
|--------|-----|-------|--:|--------:|--------:|------:|--------:|
| crauste | odepe_v2_polish | 1em6 | 10 | 13.9h | 186.0h | +172.1h | 13.4× |
| crauste | odepe_v2_polish | 1em2 | 10 | 14.4h | 180.6h | +166.2h | 12.6× |
| crauste | odepe_v2_polish | 0 | 9 | 9.6h | 169.7h | +160.1h | 17.7× |
| crauste | odepe_v2_polish | 1em8 | 10 | 17.3h | 156.3h | +139.1h | 9.0× |
| hiv | odepe_v2_polish | 1em4 | 10 | 10.3h | 126.8h | +116.4h | 12.3× |
| hiv | odepe_v2_polish | 1em8 | 10 | 9.4h | 121.4h | +112.0h | 12.9× |
| hiv | odepe_v2_polish | 0 | 10 | 7.7h | 116.6h | +108.9h | 15.1× |
| hiv | odepe_v2_polish | 1em6 | 10 | 9.5h | 115.2h | +105.7h | 12.1× |
| crauste | odepe_v2_polish | 1em4 | 10 | 13.2h | 99.3h | +86.1h | 7.5× |
| hiv | odepe_v2_polish | 1em2 | 10 | 12.1h | 81.7h | +69.6h | 6.8× |

## Slowdowns (buckets where new is slower than old)

| system | run | noise | n | new tot | old tot | saved | speedup |
|--------|-----|-------|--:|--------:|--------:|------:|--------:|
| biohydrogenation | odepe_v2_nopolish | 0 | 9 | 21.8h | 10.9h | -10.9h | 0.50× |
| biohydrogenation | odepe_v2_nopolish | 1em4 | 10 | 14.9h | 8.5h | -6.4h | 0.57× |
| biohydrogenation | odepe_v2_nopolish | 1em6 | 10 | 17.7h | 12.0h | -5.7h | 0.68× |
| biohydrogenation | odepe_v2_nopolish | 1em2 | 10 | 13.8h | 8.5h | -5.3h | 0.62× |
| cstr | odepe_v2_nopolish | 0 | 10 | 22.0h | 17.1h | -4.9h | 0.78× |
| cstr | odepe_v2_nopolish | 1em6 | 10 | 20.3h | 15.9h | -4.4h | 0.78× |
| repressilator | odepe_v2_nopolish | 1em6 | 10 | 8.6h | 4.5h | -4.1h | 0.52× |
| repressilator | odepe_v2_nopolish | 1em4 | 10 | 8.1h | 4.1h | -4.1h | 0.50× |
| repressilator | odepe_v2_nopolish | 0 | 10 | 8.1h | 4.1h | -4.0h | 0.51× |
| crauste | odepe_v2_nopolish | 1em2 | 9 | 17.6h | 13.7h | -3.9h | 0.78× |
