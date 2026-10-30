# zv-own differential oracle

seed 1, 6000 programs generated; 0 dropped as invalid (0 did not compile, 0 panicked for a reason that is not a memory error); 6000 used.

Ground truth: 3275 programs fault, 2725 do not.

A silent miss is a program that faults in Debug while zv-own says `clean` and the function's footer counts nothing it did not decide. A counted miss is the same with something undecided (the COUNTED verdict, or for an older zv-own a footer count); an assumed-only miss is `clean` with only an assumption in the footer (a call through a function pointer or to code outside the packs, a linear value handed to memory it does not follow). Silent rate = silent / faulting; false-positive rate = false positives / non-faulting. `plain` is the pack of the project alone (std's containers from the table in src/own/spec.zig); `std` is the pack with the std bodies (ZV_AIR_STD=1).

## Overall

| mode | faulting | true finding | silent miss | counted miss (COUNTED verdict or undecided) | assumed only (clean, but a call or a value it does not follow) | unproven (faulting) | non-faulting | false positive | true clean | unproven (clean) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain | 3275 | 2211 | 637 (19.5%) | 263 | 164 | 0 | 2725 | 128 (4.7%) | 2597 | 0 |
| std | 3275 | 2211 | 273 (8.3%) | 690 | 101 | 0 | 2725 | 128 (4.7%) | 2597 | 0 |

A program counts toward every construct it contains, so a rate in the tables below is the rate of programs that use the construct, not of the construct alone; the single-motif table is the clean attribution.

### By motif, programs of exactly one motif

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| m_buf | 116 | 65 | 6 (9.2%) | 0 (0 assumed) | 0 (0.0%) | 59 | 6 (9.2%) | 0 (0 assumed) | 0 (0.0%) | 59 |
| m_realloc | 106 | 44 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 44 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 44 |
| m_list | 90 | 6 | 0 (0.0%) | 0 (0 assumed) | 16 (19.0%) | 6 | 0 (0.0%) | 0 (0 assumed) | 16 (19.0%) | 6 |
| m_list_copy | 104 | 49 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 49 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 49 |
| m_elems | 119 | 45 | 45 (100.0%) | 0 (0 assumed) | 0 (0.0%) | 0 | 0 (0.0%) | 45 (0 assumed) | 0 (0.0%) | 0 |
| m_map | 113 | 36 | 27 (75.0%) | 0 (0 assumed) | 0 (0.0%) | 9 | 12 (33.3%) | 15 (0 assumed) | 0 (0.0%) | 9 |
| m_amap | 113 | 39 | 17 (43.6%) | 0 (0 assumed) | 0 (0.0%) | 22 | 8 (20.5%) | 9 (0 assumed) | 0 (0.0%) | 22 |
| m_skey | 115 | 43 | 43 (100.0%) | 0 (0 assumed) | 0 (0.0%) | 0 | 0 (0.0%) | 43 (0 assumed) | 0 (0.0%) | 0 |
| m_struct | 118 | 67 | 0 (0.0%) | 26 (0 assumed) | 0 (0.0%) | 41 | 0 (0.0%) | 26 (0 assumed) | 0 (0.0%) | 41 |
| m_bag | 101 | 18 | 0 (0.0%) | 8 (0 assumed) | 15 (18.1%) | 10 | 0 (0.0%) | 8 (0 assumed) | 15 (18.1%) | 10 |
| m_opt | 89 | 33 | 7 (21.2%) | 5 (0 assumed) | 0 (0.0%) | 21 | 7 (21.2%) | 5 (0 assumed) | 0 (0.0%) | 21 |
| m_union | 102 | 20 | 9 (45.0%) | 0 (0 assumed) | 0 (0.0%) | 11 | 9 (45.0%) | 0 (0 assumed) | 0 (0.0%) | 11 |
| m_err | 97 | 33 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 33 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 33 |
| m_helper | 94 | 46 | 3 (6.5%) | 5 (0 assumed) | 0 (0.0%) | 38 | 3 (6.5%) | 5 (0 assumed) | 0 (0.0%) | 38 |
| m_global | 103 | 50 | 21 (42.0%) | 19 (0 assumed) | 0 (0.0%) | 10 | 21 (42.0%) | 19 (0 assumed) | 0 (0.0%) | 10 |
| m_fnptr | 105 | 29 | 0 (0.0%) | 29 (29 assumed) | 0 (0.0%) | 0 | 0 (0.0%) | 29 (29 assumed) | 0 (0.0%) | 0 |
| m_arena | 97 | 35 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 35 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 35 |
| m_linear | 108 | 53 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 53 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 53 |
| m_pool | 99 | 29 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 29 | 0 (0.0%) | 0 (0 assumed) | 0 (0.0%) | 29 |
| m_node | 94 | 47 | 42 (89.4%) | 0 (0 assumed) | 0 (0.0%) | 5 | 42 (89.4%) | 0 (0 assumed) | 0 (0.0%) | 5 |

### By motif, any program containing it

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| m_buf | 541 | 398 | 30 (7.5%) | 18 (8 assumed) | 4 (2.8%) | 350 | 21 (5.3%) | 27 (4 assumed) | 4 (2.8%) | 350 |
| m_realloc | 576 | 351 | 23 (6.6%) | 16 (6 assumed) | 2 (0.9%) | 312 | 15 (4.3%) | 24 (3 assumed) | 2 (0.9%) | 312 |
| m_list | 548 | 237 | 22 (9.3%) | 17 (6 assumed) | 80 (25.7%) | 198 | 5 (2.1%) | 34 (3 assumed) | 80 (25.7%) | 198 |
| m_list_copy | 548 | 347 | 25 (7.2%) | 24 (9 assumed) | 6 (3.0%) | 298 | 13 (3.7%) | 36 (4 assumed) | 6 (3.0%) | 298 |
| m_elems | 579 | 343 | 159 (46.4%) | 38 (16 assumed) | 8 (3.4%) | 146 | 0 (0.0%) | 197 (0 assumed) | 8 (3.4%) | 146 |
| m_map | 581 | 349 | 112 (32.1%) | 43 (22 assumed) | 8 (3.4%) | 194 | 36 (10.3%) | 119 (9 assumed) | 8 (3.4%) | 194 |
| m_amap | 547 | 333 | 80 (24.0%) | 24 (7 assumed) | 5 (2.3%) | 229 | 28 (8.4%) | 76 (4 assumed) | 5 (2.3%) | 229 |
| m_skey | 569 | 335 | 162 (48.4%) | 44 (21 assumed) | 9 (3.8%) | 129 | 0 (0.0%) | 206 (0 assumed) | 9 (3.8%) | 129 |
| m_struct | 626 | 438 | 34 (7.8%) | 101 (5 assumed) | 7 (3.7%) | 303 | 19 (4.3%) | 116 (3 assumed) | 7 (3.7%) | 303 |
| m_bag | 569 | 265 | 14 (5.3%) | 77 (6 assumed) | 54 (17.8%) | 174 | 8 (3.0%) | 83 (4 assumed) | 54 (17.8%) | 174 |
| m_opt | 549 | 340 | 71 (20.9%) | 53 (15 assumed) | 7 (3.3%) | 216 | 40 (11.8%) | 84 (10 assumed) | 7 (3.3%) | 216 |
| m_union | 520 | 259 | 64 (24.7%) | 19 (5 assumed) | 6 (2.3%) | 176 | 41 (15.8%) | 42 (3 assumed) | 6 (2.3%) | 176 |
| m_err | 536 | 286 | 31 (10.8%) | 18 (7 assumed) | 9 (3.6%) | 237 | 11 (3.8%) | 38 (6 assumed) | 9 (3.6%) | 237 |
| m_helper | 514 | 343 | 48 (14.0%) | 31 (7 assumed) | 5 (2.9%) | 264 | 24 (7.0%) | 55 (5 assumed) | 5 (2.9%) | 264 |
| m_global | 538 | 338 | 86 (25.4%) | 85 (9 assumed) | 6 (3.0%) | 167 | 62 (18.3%) | 109 (5 assumed) | 6 (3.0%) | 167 |
| m_fnptr | 544 | 275 | 0 (0.0%) | 149 (134 assumed) | 8 (3.0%) | 126 | 0 (0.0%) | 149 (101 assumed) | 8 (3.0%) | 126 |
| m_arena | 574 | 349 | 0 (0.0%) | 49 (36 assumed) | 10 (4.4%) | 300 | 14 (4.0%) | 35 (6 assumed) | 10 (4.4%) | 300 |
| m_linear | 505 | 338 | 22 (6.5%) | 17 (3 assumed) | 4 (2.4%) | 299 | 8 (2.4%) | 31 (3 assumed) | 4 (2.4%) | 299 |
| m_pool | 534 | 310 | 28 (9.0%) | 21 (5 assumed) | 9 (4.0%) | 261 | 7 (2.3%) | 42 (5 assumed) | 9 (4.0%) | 261 |
| m_node | 529 | 367 | 145 (39.5%) | 37 (21 assumed) | 4 (2.5%) | 185 | 123 (33.5%) | 59 (13 assumed) | 4 (2.5%) | 185 |

### By construct

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| alloc | 4233 | 2489 | 416 (16.7%) | 381 (150 assumed) | 58 (3.3%) | 1692 | 172 (6.9%) | 625 (101 assumed) | 58 (3.3%) | 1692 |
| dupe | 709 | 459 | 169 (36.8%) | 48 (22 assumed) | 9 (3.6%) | 242 | 6 (1.3%) | 211 (0 assumed) | 9 (3.6%) | 242 |
| print | 111 | 82 | 2 (2.4%) | 3 (2 assumed) | 0 (0.0%) | 77 | 0 (0.0%) | 5 (1 assumed) | 0 (0.0%) | 77 |
| free | 5460 | 3076 | 637 (20.7%) | 417 (164 assumed) | 91 (3.8%) | 2022 | 273 (8.9%) | 781 (101 assumed) | 91 (3.8%) | 2022 |
| realloc | 576 | 351 | 23 (6.6%) | 16 (6 assumed) | 2 (0.9%) | 312 | 15 (4.3%) | 24 (3 assumed) | 2 (0.9%) | 312 |
| create | 529 | 367 | 145 (39.5%) | 37 (21 assumed) | 4 (2.5%) | 185 | 123 (33.5%) | 59 (13 assumed) | 4 (2.5%) | 185 |
| list | 2167 | 1152 | 208 (18.1%) | 153 (46 assumed) | 127 (12.5%) | 791 | 30 (2.6%) | 331 (14 assumed) | 127 (12.5%) | 791 |
| list_view | 817 | 442 | 45 (10.2%) | 36 (10 assumed) | 101 (26.9%) | 361 | 26 (5.9%) | 55 (8 assumed) | 101 (26.9%) | 361 |
| list_elem_ptr | 191 | 129 | 3 (2.3%) | 2 (1 assumed) | 30 (48.4%) | 124 | 1 (0.8%) | 4 (1 assumed) | 30 (48.4%) | 124 |
| list_copy | 548 | 347 | 25 (7.2%) | 24 (9 assumed) | 6 (3.0%) | 298 | 13 (3.7%) | 36 (4 assumed) | 6 (3.0%) | 298 |
| to_owned | 553 | 238 | 16 (6.7%) | 51 (3 assumed) | 25 (7.9%) | 171 | 0 (0.0%) | 67 (0 assumed) | 25 (7.9%) | 171 |
| map | 1110 | 651 | 255 (39.2%) | 85 (42 assumed) | 17 (3.7%) | 311 | 36 (5.5%) | 304 (9 assumed) | 17 (3.7%) | 311 |
| map_ptr | 201 | 169 | 52 (30.8%) | 15 (10 assumed) | 1 (3.1%) | 102 | 2 (1.2%) | 65 (0 assumed) | 1 (3.1%) | 102 |
| map_remove | 307 | 196 | 66 (33.7%) | 21 (12 assumed) | 2 (1.8%) | 109 | 0 (0.0%) | 87 (0 assumed) | 2 (1.8%) | 109 |
| amap | 547 | 333 | 80 (24.0%) | 24 (7 assumed) | 5 (2.3%) | 229 | 28 (8.4%) | 76 (4 assumed) | 5 (2.3%) | 229 |
| skey | 569 | 335 | 162 (48.4%) | 44 (21 assumed) | 9 (3.8%) | 129 | 0 (0.0%) | 206 (0 assumed) | 9 (3.8%) | 129 |
| struct_field | 1259 | 717 | 48 (6.7%) | 184 (23 assumed) | 60 (11.1%) | 485 | 33 (4.6%) | 199 (7 assumed) | 60 (11.1%) | 485 |
| struct_copy | 686 | 485 | 25 (5.2%) | 83 (9 assumed) | 6 (3.0%) | 377 | 13 (2.7%) | 95 (4 assumed) | 6 (3.0%) | 377 |
| struct_val_param | 106 | 106 | 0 (0.0%) | 33 (0 assumed) | 0 (-) | 73 | 0 (0.0%) | 33 (0 assumed) | 0 (-) | 73 |
| struct_ptr_param | 79 | 79 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 79 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 79 |
| opt_val | 744 | 464 | 78 (16.8%) | 119 (19 assumed) | 9 (3.2%) | 267 | 44 (9.5%) | 153 (12 assumed) | 9 (3.2%) | 267 |
| opt_ptr | 520 | 286 | 43 (15.0%) | 111 (14 assumed) | 9 (3.8%) | 132 | 19 (6.6%) | 135 (8 assumed) | 9 (3.8%) | 132 |
| union_tag | 520 | 259 | 64 (24.7%) | 19 (5 assumed) | 6 (2.3%) | 176 | 41 (15.8%) | 42 (3 assumed) | 6 (2.3%) | 176 |
| errdefer_ | 290 | 158 | 18 (11.4%) | 10 (5 assumed) | 5 (3.8%) | 130 | 8 (5.1%) | 20 (4 assumed) | 5 (3.8%) | 130 |
| catch_free | 179 | 83 | 12 (14.5%) | 7 (4 assumed) | 3 (3.1%) | 64 | 2 (2.4%) | 17 (4 assumed) | 3 (3.1%) | 64 |
| catch_fallback | 30 | 30 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 30 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 30 |
| err_return | 371 | 185 | 23 (12.4%) | 13 (5 assumed) | 7 (3.8%) | 149 | 10 (5.4%) | 26 (4 assumed) | 7 (3.8%) | 149 |
| loop | 2309 | 1383 | 507 (36.7%) | 159 (72 assumed) | 32 (3.5%) | 717 | 138 (10.0%) | 528 (20 assumed) | 32 (3.5%) | 717 |
| helper_val | 215 | 156 | 26 (16.7%) | 5 (2 assumed) | 1 (1.7%) | 125 | 17 (10.9%) | 14 (1 assumed) | 1 (1.7%) | 125 |
| helper_ptr | 324 | 212 | 23 (10.8%) | 26 (5 assumed) | 4 (3.6%) | 163 | 8 (3.8%) | 41 (4 assumed) | 4 (3.6%) | 163 |
| alias_params | 111 | 80 | 8 (10.0%) | 3 (1 assumed) | 0 (0.0%) | 69 | 6 (7.5%) | 5 (1 assumed) | 0 (0.0%) | 69 |
| global | 538 | 338 | 86 (25.4%) | 85 (9 assumed) | 6 (3.0%) | 167 | 62 (18.3%) | 109 (5 assumed) | 6 (3.0%) | 167 |
| fnptr | 544 | 275 | 0 (0.0%) | 149 (134 assumed) | 8 (3.0%) | 126 | 0 (0.0%) | 149 (101 assumed) | 8 (3.0%) | 126 |
| fn_field | 213 | 106 | 0 (0.0%) | 58 (53 assumed) | 0 (0.0%) | 48 | 0 (0.0%) | 58 (40 assumed) | 0 (0.0%) | 48 |
| arena | 574 | 349 | 0 (0.0%) | 49 (36 assumed) | 10 (4.4%) | 300 | 14 (4.0%) | 35 (6 assumed) | 10 (4.4%) | 300 |
| arena_dupe | 55 | 55 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 55 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 55 |
| linear | 505 | 338 | 22 (6.5%) | 17 (3 assumed) | 4 (2.4%) | 299 | 8 (2.4%) | 31 (3 assumed) | 4 (2.4%) | 299 |
| linear_copy | 21 | 21 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 21 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 21 |
| linear_slice | 105 | 67 | 5 (7.5%) | 1 (0 assumed) | 2 (5.3%) | 61 | 2 (3.0%) | 4 (0 assumed) | 2 (5.3%) | 61 |
| pool | 534 | 310 | 28 (9.0%) | 21 (5 assumed) | 9 (4.0%) | 261 | 7 (2.3%) | 42 (5 assumed) | 9 (4.0%) | 261 |
| branch | 1090 | 600 | 115 (19.2%) | 101 (74 assumed) | 12 (2.4%) | 384 | 56 (9.3%) | 160 (55 assumed) | 12 (2.4%) | 384 |
| defer_ | 410 | 199 | 16 (8.0%) | 11 (3 assumed) | 38 (18.0%) | 172 | 8 (4.0%) | 19 (2 assumed) | 38 (18.0%) | 172 |
| alias | 899 | 749 | 93 (12.4%) | 31 (17 assumed) | 6 (4.0%) | 625 | 43 (5.7%) | 81 (9 assumed) | 6 (4.0%) | 625 |
| subslice | 275 | 169 | 20 (11.8%) | 9 (5 assumed) | 30 (28.3%) | 140 | 17 (10.1%) | 12 (3 assumed) | 30 (28.3%) | 140 |

### By step that is a mistake when the paths line up (what the generator aimed at; the faulting column is what really faulted)

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bug_uaf | 24 | 24 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 24 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 24 |
| bug_double_free | 129 | 129 | 72 (55.8%) | 13 (9 assumed) | 0 (-) | 44 | 0 (0.0%) | 85 (0 assumed) | 0 (-) | 44 |
| bug_alias_uaf | 117 | 117 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 117 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 117 |
| bug_alias_free | 59 | 59 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 59 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 59 |
| bug_invalid_free | 39 | 39 | 14 (35.9%) | 3 (3 assumed) | 0 (-) | 22 | 14 (35.9%) | 3 (1 assumed) | 0 (-) | 22 |
| bug_cond_free | 56 | 56 | 18 (32.1%) | 2 (2 assumed) | 0 (-) | 36 | 13 (23.2%) | 7 (1 assumed) | 0 (-) | 36 |
| bug_loop_free | 15 | 15 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 15 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 15 |
| bug_defer_free | 74 | 74 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 74 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 74 |
| bug_helper_reuse | 128 | 128 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 128 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 128 |
| bug_helper_twice | 43 | 43 | 0 (0.0%) | 19 (0 assumed) | 0 (-) | 24 | 0 (0.0%) | 19 (0 assumed) | 0 (-) | 24 |
| bug_helper_alias | 58 | 58 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 58 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 58 |
| bug_realloc_stale | 81 | 81 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 81 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 81 |
| bug_realloc_old_free | 159 | 159 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 159 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 159 |
| bug_list_stale | 201 | 105 | 4 (3.8%) | 2 (1 assumed) | 78 (81.3%) | 99 | 0 (0.0%) | 6 (1 assumed) | 78 (81.3%) | 99 |
| bug_list_copy | 229 | 229 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 229 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 229 |
| bug_elem_double | 139 | 139 | 81 (58.3%) | 16 (7 assumed) | 0 (-) | 42 | 0 (0.0%) | 97 (0 assumed) | 0 (-) | 42 |
| bug_elem_stale | 57 | 57 | 33 (57.9%) | 6 (3 assumed) | 0 (-) | 18 | 0 (0.0%) | 39 (0 assumed) | 0 (-) | 18 |
| bug_elem_pop | 33 | 33 | 23 (69.7%) | 2 (2 assumed) | 0 (-) | 8 | 0 (0.0%) | 25 (0 assumed) | 0 (-) | 8 |
| bug_map_stale | 398 | 327 | 73 (22.3%) | 20 (13 assumed) | 2 (2.8%) | 234 | 18 (5.5%) | 75 (3 assumed) | 2 (2.8%) | 234 |
| bug_map_double | 161 | 161 | 64 (39.8%) | 18 (8 assumed) | 0 (-) | 79 | 35 (21.7%) | 47 (6 assumed) | 0 (-) | 79 |
| bug_map_uaf | 25 | 25 | 15 (60.0%) | 3 (1 assumed) | 0 (-) | 7 | 11 (44.0%) | 7 (1 assumed) | 0 (-) | 7 |
| bug_skey_literal | 129 | 129 | 88 (68.2%) | 10 (6 assumed) | 0 (-) | 31 | 0 (0.0%) | 98 (0 assumed) | 0 (-) | 31 |
| bug_struct_copy | 206 | 206 | 0 (0.0%) | 63 (0 assumed) | 0 (-) | 143 | 0 (0.0%) | 63 (0 assumed) | 0 (-) | 143 |
| bug_struct_field | 118 | 118 | 0 (0.0%) | 30 (0 assumed) | 0 (-) | 88 | 0 (0.0%) | 30 (0 assumed) | 0 (-) | 88 |
| bug_opt_stale | 121 | 121 | 26 (21.5%) | 5 (2 assumed) | 0 (-) | 90 | 22 (18.2%) | 9 (1 assumed) | 0 (-) | 90 |
| bug_opt_double | 75 | 75 | 0 (0.0%) | 24 (0 assumed) | 0 (-) | 51 | 0 (0.0%) | 24 (0 assumed) | 0 (-) | 51 |
| bug_union_double | 40 | 40 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 40 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 40 |
| bug_union_uaf | 34 | 34 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 34 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 34 |
| bug_union_tag | 91 | 56 | 30 (53.6%) | 5 (1 assumed) | 1 (2.9%) | 21 | 21 (37.5%) | 14 (1 assumed) | 1 (2.9%) | 21 |
| bug_errdefer_double | 37 | 37 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 37 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 37 |
| bug_catch_double | 34 | 34 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 34 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 34 |
| bug_catch_fallback | 30 | 30 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 30 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 30 |
| bug_global_stale | 49 | 49 | 31 (63.3%) | 4 (1 assumed) | 0 (-) | 14 | 24 (49.0%) | 11 (0 assumed) | 0 (-) | 14 |
| bug_global_double | 159 | 159 | 27 (17.0%) | 67 (2 assumed) | 0 (-) | 65 | 25 (15.7%) | 69 (1 assumed) | 0 (-) | 65 |
| bug_fnptr_free | 154 | 153 | 0 (0.0%) | 114 (109 assumed) | 0 (0.0%) | 39 | 0 (0.0%) | 114 (88 assumed) | 0 (0.0%) | 39 |
| bug_arena_uaf | 160 | 160 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 160 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 160 |
| bug_arena_foreign_free | 55 | 55 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 55 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 55 |
| bug_linear_twice | 93 | 93 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 93 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 93 |
| bug_linear_leak | 93 | 93 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 93 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 93 |
| bug_linear_copy | 21 | 21 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 21 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 21 |
| bug_linear_slice | 17 | 17 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 17 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 17 |
| bug_pool_stale | 145 | 144 | 0 (0.0%) | 0 (0 assumed) | 1 (100.0%) | 144 | 0 (0.0%) | 0 (0 assumed) | 1 (100.0%) | 144 |
| bug_pool_double | 49 | 49 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 49 | 0 (0.0%) | 0 (0 assumed) | 0 (-) | 49 |
| bug_node_uaf | 136 | 136 | 88 (64.7%) | 18 (12 assumed) | 0 (-) | 30 | 76 (55.9%) | 30 (6 assumed) | 0 (-) | 30 |
| bug_node_double | 127 | 127 | 43 (33.9%) | 8 (4 assumed) | 0 (-) | 76 | 40 (31.5%) | 11 (2 assumed) | 0 (-) | 76 |
| bug_bag_stale | 76 | 26 | 0 (0.0%) | 0 (0 assumed) | 50 (100.0%) | 26 | 0 (0.0%) | 0 (0 assumed) | 50 (100.0%) | 26 |
| bug_bag_copy | 95 | 95 | 0 (0.0%) | 32 (0 assumed) | 0 (-) | 63 | 0 (0.0%) | 32 (0 assumed) | 0 (-) | 63 |

## Minimized silent misses

### 1. m_elems+bug_elem_double (plain, 29 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: no.

```zig
pub fn p658(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1: std.ArrayList([]u8) = .empty;
    for (0..4) |i| { const s = try mk(a, 3 + i); try v0_1.append(a, s); a.free(s); }
    for (v0_1.items) |s| a.free(s);
    }
}

```

### 2. m_node+bug_node_uaf (plain, 90 programs with this signature, 10 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: yes.

```zig
pub fn p316(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try mkNode(a, 7, null);
    const v0_2 = try mkNode(a, 8, v0_1);
    var v0_3: ?*Node = v0_2; while (v0_3) |c| { a.destroy(c); v0_3 = nextOf(c); }
    }
}

```

### 3. m_skey+bug_skey_literal (plain, 29 programs with this signature, 2 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: no.

```zig
pub fn p410(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1 = std.StringHashMap([]u8).init(a);
    const v0_2 = try a.dupe(u8, "key");
    try v0_1.put(v0_2, try mk(a, 3));
    try v0_1.put(&static_buf, try mk(a, 3));
    { var it = v0_1.iterator(); while (it.next()) |e| { a.free(e.key_ptr.*); a.free(e.value_ptr.*); } }
    }
}

```

### 4. m_skey+bug_double_free (plain, 23 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: no.

```zig
pub fn p527(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1 = std.StringHashMap([]u8).init(a);
    const v0_2 = try a.dupe(u8, "key");
    try v0_1.put(v0_2, try mk(a, 3));
    a.free(v0_2);
    { var it = v0_1.iterator(); while (it.next()) |e| { a.free(e.key_ptr.*); a.free(e.value_ptr.*); } }
    }
}

```

### 5. m_map+bug_map_stale (plain, 22 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: no.

```zig
pub fn p353(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1 = std.AutoHashMap(u8, []u8).init(a);
    try v0_1.put(1, try mk(a, 3));
    const v0_2 = v0_1.getPtr(1).?;
    if (v0_1.fetchRemove(1)) |kv| a.free(kv.value);
    _ = rdp(v0_2);
    }
}

```

### 6. m_node+bug_node_double (plain, 45 programs with this signature, 7 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: yes.

```zig
pub fn p295(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try mkNode(a, 7, null);
    const v0_2 = try mkNode(a, 8, v0_1);
    var v0_3: ?*Node = v0_2; while (v0_3) |c| { v0_3 = nextOf(c); a.destroy(c); }
    a.destroy(v0_1);
    }
}

```

### 7. m_amap+bug_map_double (plain, 20 programs with this signature, 2 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: yes.

```zig
pub fn p976(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1: std.array_hash_map.Auto(u8, []u8) = .empty;
    try v0_1.put(a, 2, try mk(a, 4));
    if (v0_1.get(2)) |s| a.free(s);
    for (v0_1.values()) |s| a.free(s);
    }
}

```

### 8. m_global+bug_global_stale (plain, 25 programs with this signature, 2 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: yes.

```zig
pub fn p364(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try mk(a, 4);
    stash(v0_1);
    a.free(v0_1);
    _ = rd(g_slice);
    }
}

```

### 9. m_global+bug_global_double (plain, 22 programs with this signature, 2 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: yes.

```zig
pub fn p2535(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try mk(a, 4);
    stash(v0_1);
    dropStashKeep(a);
    a.free(v0_1);
    }
}

```

### 10. m_skey+bug_double_free+bug_skey_literal (plain, 10 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: no.

```zig
pub fn p346(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1 = std.StringHashMap([]u8).init(a);
    const v0_2 = try a.dupe(u8, "key");
    try v0_1.put(&static_buf, try mk(a, 3));
    a.free(v0_2);
    { var it = v0_1.iterator(); while (it.next()) |e| { a.free(e.key_ptr.*); a.free(e.value_ptr.*); } }
    }
}

```

### 11. m_union+bug_union_tag (plain, 20 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: yes.

```zig
pub fn p143(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1: U = if (selv & 1 == 0) .{ .owned = try mk(a, 17) } else .{ .borrowed = &static_buf };
    dropAnyU(a, v0_1);
    }
}

```

### 12. m_elems+bug_elem_pop (plain, 8 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: no.

```zig
pub fn p501(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1: std.ArrayList([]u8) = .empty;
    for (0..4) |i| { try v0_1.append(a, try mk(a, 3 + i)); }
    a.free(v0_1.items[v0_1.items.len - 1]);
    for (v0_1.items) |s| a.free(s);
    }
}

```

### 13. m_elems+bug_elem_stale (plain, 8 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: no.

```zig
pub fn p1883(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1: std.ArrayList([]u8) = .empty;
    for (0..4) |i| { try v0_1.append(a, try mk(a, 3 + i)); }
    const v0_2 = v0_1.items[0];
    for (v0_1.items) |s| a.free(s);
    _ = rd(v0_2);
    }
}

```

### 14. m_buf+bug_invalid_free (plain, 14 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: yes.

```zig
pub fn p163(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try a.alloc(u8, 8);
    @memset(v0_1, 7);
    const v0_2 = v0_1[1..];
    a.free(v0_2);
    }
}

```

### 15. m_opt+bug_opt_stale (plain, 14 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: yes.

```zig
pub fn p909(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1: ?[]u8 = try mk(a, 17);
    dropOpt(a, v0_1);
    _ = rdOpt(v0_1);
    }
}

```

### 16. m_elems+bug_elem_double (plain, 6 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: no.

```zig
pub fn p3676(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1: std.ArrayList([]u8) = .empty;
    for (0..2) |i| { const s = try mk(a, 3 + i); try v0_1.append(a, s); a.free(s); }
    for (v0_1.items) |s| a.free(s);
    }
}

```

### 17. m_map+bug_map_double (plain, 14 programs with this signature, 2 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: yes.

```zig
pub fn p1095(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1 = std.AutoHashMap(u8, []u8).init(a);
    try v0_1.put(1, try mk(a, 3));
    const v0_3 = v0_1.get(1).?;
    a.free(v0_3);
    { var it = v0_1.valueIterator(); while (it.next()) |q| a.free(q.*); }
    }
}

```

### 18. m_map+bug_map_uaf (plain, 12 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: yes.

```zig
pub fn p238(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1 = std.AutoHashMap(u8, []u8).init(a);
    try v0_1.put(1, try mk(a, 3));
    const v0_3 = v0_1.get(1).?;
    { var it = v0_1.valueIterator(); while (it.next()) |q| a.free(q.*); }
    _ = rd(v0_3);
    }
}

```

### 19. m_amap+bug_map_stale+bug_map_double (plain, 15 programs with this signature, 5 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: yes.

```zig
pub fn p484(a: Allocator, selv: u8) anyerror!void {
    {
    var v0_1: std.array_hash_map.Auto(u8, []u8) = .empty;
    try v0_1.put(a, 2, try mk(a, 4));
    const v0_2 = v0_1.values();
    _ = rdp(&v0_2[0]);
    if (v0_1.get(2)) |s| a.free(s);
    for (v0_1.values()) |s| a.free(s);
    }
}

```

### 20. m_elems+bug_elem_double (plain, 3 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: no.

```zig
pub fn p2521(a: Allocator, selv: u8) anyerror!void {
    {
    var v1_1: std.ArrayList([]u8) = .empty;
    for (0..3) |i| { const s = try mk(a, 3 + i); try v1_1.append(a, s); a.free(s); }
    for (v1_1.items) |s| a.free(s);
    }
}

```

### 21. m_node+bug_node_uaf (std, 11 programs with this signature, 4 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: yes.

```zig
pub fn p1101(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try mkNode(a, 7, null);
    const v0_2 = try mkNode(a, 8, v0_1);
    a.destroy(v0_1);
    _ = rdn(v0_2.next.?);
    }
}

```

### 22. m_helper+bug_cond_free (std, 5 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: double free`. Also silent in the other mode: yes.

```zig
pub fn p7(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try mk(a, 5);
    freeIf(a, v0_1, selv == 0);
    a.free(v0_1);
    }
}

```

### 23. m_opt+bug_opt_stale (std, 3 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: yes.

```zig
pub fn p1421(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1: ?[]u8 = try mk(a, 3);
    dropOpt(a, v0_1);
    _ = rdOpt(v0_1);
    }
}

```

### 24. m_opt+bug_opt_stale (std, 2 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: read of freed memory`. Also silent in the other mode: yes.

```zig
pub fn p227(a: Allocator, selv: u8) anyerror!void {
    {
    const v1_1: ?[]u8 = try mk(a, 5);
    dropOpt(a, v1_1);
    _ = rdOpt(v1_1);
    }
}

```

### 25. m_union+bug_union_tag (std, 2 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: yes.

```zig
pub fn p2917(a: Allocator, selv: u8) anyerror!void {
    {
    const v1_1: U = if (selv & 1 == 0) .{ .owned = try mk(a, 5) } else .{ .borrowed = &static_buf };
    dropAnyU(a, v1_1);
    }
}

```

