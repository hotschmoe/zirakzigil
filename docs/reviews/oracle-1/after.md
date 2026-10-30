# zv-own differential oracle

seed 1, 6000 programs generated; 0 dropped as invalid (0 did not compile, 0 panicked for a reason that is not a memory error); 6000 used.

Ground truth: 3275 programs fault, 2725 do not.

A silent miss is a program that faults in Debug while zv-own says `clean` and the function's footer counts nothing it did not decide. A counted miss is the same with something counted. Silent rate = silent / faulting; false-positive rate = false positives / non-faulting. `plain` is the pack of the project alone (std's containers from the table in src/own/spec.zig); `std` is the pack with the std bodies (ZV_AIR_STD=1).

## Overall

| mode | faulting | true finding | silent miss | counted miss | unproven (faulting) | non-faulting | false positive | true clean | unproven (clean) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain | 3275 | 2211 | 118 (3.6%) | 946 | 0 | 2725 | 128 (4.7%) | 2597 | 0 |
| std | 3275 | 2211 | 120 (3.7%) | 944 | 0 | 2725 | 128 (4.7%) | 2597 | 0 |

A program counts toward every construct it contains, so a rate in the tables below is the rate of programs that use the construct, not of the construct alone; the single-motif table is the clean attribution.

### By motif, programs of exactly one motif

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| m_buf | 116 | 65 | 6 (9.2%) | 0 | 0 (0.0%) | 59 | 6 (9.2%) | 0 | 0 (0.0%) | 59 |
| m_realloc | 106 | 44 | 0 (0.0%) | 0 | 0 (0.0%) | 44 | 0 (0.0%) | 0 | 0 (0.0%) | 44 |
| m_list | 90 | 6 | 0 (0.0%) | 0 | 16 (19.0%) | 6 | 0 (0.0%) | 0 | 16 (19.0%) | 6 |
| m_list_copy | 104 | 49 | 0 (0.0%) | 0 | 0 (0.0%) | 49 | 0 (0.0%) | 0 | 0 (0.0%) | 49 |
| m_elems | 119 | 45 | 0 (0.0%) | 45 | 0 (0.0%) | 0 | 0 (0.0%) | 45 | 0 (0.0%) | 0 |
| m_map | 113 | 36 | 0 (0.0%) | 27 | 0 (0.0%) | 9 | 0 (0.0%) | 27 | 0 (0.0%) | 9 |
| m_amap | 113 | 39 | 0 (0.0%) | 17 | 0 (0.0%) | 22 | 0 (0.0%) | 17 | 0 (0.0%) | 22 |
| m_skey | 115 | 43 | 0 (0.0%) | 43 | 0 (0.0%) | 0 | 0 (0.0%) | 43 | 0 (0.0%) | 0 |
| m_struct | 118 | 67 | 0 (0.0%) | 26 | 0 (0.0%) | 41 | 0 (0.0%) | 26 | 0 (0.0%) | 41 |
| m_bag | 101 | 18 | 0 (0.0%) | 8 | 15 (18.1%) | 10 | 0 (0.0%) | 8 | 15 (18.1%) | 10 |
| m_opt | 89 | 33 | 0 (0.0%) | 12 | 0 (0.0%) | 21 | 0 (0.0%) | 12 | 0 (0.0%) | 21 |
| m_union | 102 | 20 | 0 (0.0%) | 9 | 0 (0.0%) | 11 | 0 (0.0%) | 9 | 0 (0.0%) | 11 |
| m_err | 97 | 33 | 0 (0.0%) | 0 | 0 (0.0%) | 33 | 0 (0.0%) | 0 | 0 (0.0%) | 33 |
| m_helper | 94 | 46 | 0 (0.0%) | 8 | 0 (0.0%) | 38 | 0 (0.0%) | 8 | 0 (0.0%) | 38 |
| m_global | 103 | 50 | 11 (22.0%) | 29 | 0 (0.0%) | 10 | 11 (22.0%) | 29 | 0 (0.0%) | 10 |
| m_fnptr | 105 | 29 | 0 (0.0%) | 29 | 0 (0.0%) | 0 | 0 (0.0%) | 29 | 0 (0.0%) | 0 |
| m_arena | 97 | 35 | 0 (0.0%) | 0 | 0 (0.0%) | 35 | 0 (0.0%) | 0 | 0 (0.0%) | 35 |
| m_linear | 108 | 53 | 0 (0.0%) | 0 | 0 (0.0%) | 53 | 0 (0.0%) | 0 | 0 (0.0%) | 53 |
| m_pool | 99 | 29 | 0 (0.0%) | 0 | 0 (0.0%) | 29 | 0 (0.0%) | 0 | 0 (0.0%) | 29 |
| m_node | 94 | 47 | 42 (89.4%) | 0 | 0 (0.0%) | 5 | 42 (89.4%) | 0 | 0 (0.0%) | 5 |

### By motif, any program containing it

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| m_buf | 541 | 398 | 13 (3.3%) | 35 | 4 (2.8%) | 350 | 14 (3.5%) | 34 | 4 (2.8%) | 350 |
| m_realloc | 576 | 351 | 6 (1.7%) | 33 | 2 (0.9%) | 312 | 7 (2.0%) | 32 | 2 (0.9%) | 312 |
| m_list | 548 | 237 | 4 (1.7%) | 35 | 80 (25.7%) | 198 | 0 (0.0%) | 39 | 80 (25.7%) | 198 |
| m_list_copy | 548 | 347 | 5 (1.4%) | 44 | 6 (3.0%) | 298 | 5 (1.4%) | 44 | 6 (3.0%) | 298 |
| m_elems | 579 | 343 | 0 (0.0%) | 197 | 8 (3.4%) | 146 | 0 (0.0%) | 197 | 8 (3.4%) | 146 |
| m_map | 581 | 349 | 0 (0.0%) | 155 | 8 (3.4%) | 194 | 0 (0.0%) | 155 | 8 (3.4%) | 194 |
| m_amap | 547 | 333 | 0 (0.0%) | 104 | 5 (2.3%) | 229 | 0 (0.0%) | 104 | 5 (2.3%) | 229 |
| m_skey | 569 | 335 | 0 (0.0%) | 206 | 9 (3.8%) | 129 | 0 (0.0%) | 206 | 9 (3.8%) | 129 |
| m_struct | 626 | 438 | 7 (1.6%) | 128 | 7 (3.7%) | 303 | 7 (1.6%) | 128 | 7 (3.7%) | 303 |
| m_bag | 569 | 265 | 2 (0.8%) | 89 | 54 (17.8%) | 174 | 3 (1.1%) | 88 | 54 (17.8%) | 174 |
| m_opt | 549 | 340 | 12 (3.5%) | 112 | 7 (3.3%) | 216 | 12 (3.5%) | 112 | 7 (3.3%) | 216 |
| m_union | 520 | 259 | 8 (3.1%) | 75 | 6 (2.3%) | 176 | 8 (3.1%) | 75 | 6 (2.3%) | 176 |
| m_err | 536 | 286 | 7 (2.4%) | 42 | 9 (3.6%) | 237 | 7 (2.4%) | 42 | 9 (3.6%) | 237 |
| m_helper | 514 | 343 | 7 (2.0%) | 72 | 5 (2.9%) | 264 | 7 (2.0%) | 72 | 5 (2.9%) | 264 |
| m_global | 538 | 338 | 20 (5.9%) | 151 | 6 (3.0%) | 167 | 20 (5.9%) | 151 | 6 (3.0%) | 167 |
| m_fnptr | 544 | 275 | 0 (0.0%) | 149 | 8 (3.0%) | 126 | 0 (0.0%) | 149 | 8 (3.0%) | 126 |
| m_arena | 574 | 349 | 0 (0.0%) | 49 | 10 (4.4%) | 300 | 7 (2.0%) | 42 | 10 (4.4%) | 300 |
| m_linear | 505 | 338 | 5 (1.5%) | 34 | 4 (2.4%) | 299 | 5 (1.5%) | 34 | 4 (2.4%) | 299 |
| m_pool | 534 | 310 | 2 (0.6%) | 47 | 9 (4.0%) | 261 | 2 (0.6%) | 47 | 9 (4.0%) | 261 |
| m_node | 529 | 367 | 89 (24.3%) | 93 | 4 (2.5%) | 185 | 90 (24.5%) | 92 | 4 (2.5%) | 185 |

### By construct

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| alloc | 4233 | 2489 | 60 (2.4%) | 737 | 58 (3.3%) | 1692 | 61 (2.5%) | 736 | 58 (3.3%) | 1692 |
| dupe | 709 | 459 | 3 (0.7%) | 214 | 9 (3.6%) | 242 | 3 (0.7%) | 214 | 9 (3.6%) | 242 |
| print | 111 | 82 | 0 (0.0%) | 5 | 0 (0.0%) | 77 | 0 (0.0%) | 5 | 0 (0.0%) | 77 |
| free | 5460 | 3076 | 118 (3.8%) | 936 | 91 (3.8%) | 2022 | 120 (3.9%) | 934 | 91 (3.8%) | 2022 |
| realloc | 576 | 351 | 6 (1.7%) | 33 | 2 (0.9%) | 312 | 7 (2.0%) | 32 | 2 (0.9%) | 312 |
| create | 529 | 367 | 89 (24.3%) | 93 | 4 (2.5%) | 185 | 90 (24.5%) | 92 | 4 (2.5%) | 185 |
| list | 2167 | 1152 | 11 (1.0%) | 350 | 127 (12.5%) | 791 | 8 (0.7%) | 353 | 127 (12.5%) | 791 |
| list_view | 817 | 442 | 5 (1.1%) | 76 | 101 (26.9%) | 361 | 3 (0.7%) | 78 | 101 (26.9%) | 361 |
| list_elem_ptr | 191 | 129 | 0 (0.0%) | 5 | 30 (48.4%) | 124 | 0 (0.0%) | 5 | 30 (48.4%) | 124 |
| list_copy | 548 | 347 | 5 (1.4%) | 44 | 6 (3.0%) | 298 | 5 (1.4%) | 44 | 6 (3.0%) | 298 |
| to_owned | 553 | 238 | 2 (0.8%) | 65 | 25 (7.9%) | 171 | 0 (0.0%) | 67 | 25 (7.9%) | 171 |
| map | 1110 | 651 | 0 (0.0%) | 340 | 17 (3.7%) | 311 | 0 (0.0%) | 340 | 17 (3.7%) | 311 |
| map_ptr | 201 | 169 | 0 (0.0%) | 67 | 1 (3.1%) | 102 | 0 (0.0%) | 67 | 1 (3.1%) | 102 |
| map_remove | 307 | 196 | 0 (0.0%) | 87 | 2 (1.8%) | 109 | 0 (0.0%) | 87 | 2 (1.8%) | 109 |
| amap | 547 | 333 | 0 (0.0%) | 104 | 5 (2.3%) | 229 | 0 (0.0%) | 104 | 5 (2.3%) | 229 |
| skey | 569 | 335 | 0 (0.0%) | 206 | 9 (3.8%) | 129 | 0 (0.0%) | 206 | 9 (3.8%) | 129 |
| struct_field | 1259 | 717 | 9 (1.3%) | 223 | 60 (11.1%) | 485 | 16 (2.2%) | 216 | 60 (11.1%) | 485 |
| struct_copy | 686 | 485 | 5 (1.0%) | 103 | 6 (3.0%) | 377 | 5 (1.0%) | 103 | 6 (3.0%) | 377 |
| struct_val_param | 106 | 106 | 0 (0.0%) | 33 | 0 (-) | 73 | 0 (0.0%) | 33 | 0 (-) | 73 |
| struct_ptr_param | 79 | 79 | 0 (0.0%) | 0 | 0 (-) | 79 | 0 (0.0%) | 0 | 0 (-) | 79 |
| opt_val | 744 | 464 | 12 (2.6%) | 185 | 9 (3.2%) | 267 | 12 (2.6%) | 185 | 9 (3.2%) | 267 |
| opt_ptr | 520 | 286 | 10 (3.5%) | 144 | 9 (3.8%) | 132 | 10 (3.5%) | 144 | 9 (3.8%) | 132 |
| union_tag | 520 | 259 | 8 (3.1%) | 75 | 6 (2.3%) | 176 | 8 (3.1%) | 75 | 6 (2.3%) | 176 |
| errdefer_ | 290 | 158 | 3 (1.9%) | 25 | 5 (3.8%) | 130 | 3 (1.9%) | 25 | 5 (3.8%) | 130 |
| catch_free | 179 | 83 | 2 (2.4%) | 17 | 3 (3.1%) | 64 | 2 (2.4%) | 17 | 3 (3.1%) | 64 |
| catch_fallback | 30 | 30 | 0 (0.0%) | 0 | 0 (-) | 30 | 0 (0.0%) | 0 | 0 (-) | 30 |
| err_return | 371 | 185 | 5 (2.7%) | 31 | 7 (3.8%) | 149 | 5 (2.7%) | 31 | 7 (3.8%) | 149 |
| loop | 2309 | 1383 | 63 (4.6%) | 603 | 32 (3.5%) | 717 | 62 (4.5%) | 604 | 32 (3.5%) | 717 |
| helper_val | 215 | 156 | 1 (0.6%) | 30 | 1 (1.7%) | 125 | 1 (0.6%) | 30 | 1 (1.7%) | 125 |
| helper_ptr | 324 | 212 | 6 (2.8%) | 43 | 4 (3.6%) | 163 | 6 (2.8%) | 43 | 4 (3.6%) | 163 |
| alias_params | 111 | 80 | 5 (6.3%) | 6 | 0 (0.0%) | 69 | 5 (6.3%) | 6 | 0 (0.0%) | 69 |
| global | 538 | 338 | 20 (5.9%) | 151 | 6 (3.0%) | 167 | 20 (5.9%) | 151 | 6 (3.0%) | 167 |
| fnptr | 544 | 275 | 0 (0.0%) | 149 | 8 (3.0%) | 126 | 0 (0.0%) | 149 | 8 (3.0%) | 126 |
| fn_field | 213 | 106 | 0 (0.0%) | 58 | 0 (0.0%) | 48 | 0 (0.0%) | 58 | 0 (0.0%) | 48 |
| arena | 574 | 349 | 0 (0.0%) | 49 | 10 (4.4%) | 300 | 7 (2.0%) | 42 | 10 (4.4%) | 300 |
| arena_dupe | 55 | 55 | 0 (0.0%) | 0 | 0 (-) | 55 | 0 (0.0%) | 0 | 0 (-) | 55 |
| linear | 505 | 338 | 5 (1.5%) | 34 | 4 (2.4%) | 299 | 5 (1.5%) | 34 | 4 (2.4%) | 299 |
| linear_copy | 21 | 21 | 0 (0.0%) | 0 | 0 (-) | 21 | 0 (0.0%) | 0 | 0 (-) | 21 |
| linear_slice | 105 | 67 | 1 (1.5%) | 5 | 2 (5.3%) | 61 | 1 (1.5%) | 5 | 2 (5.3%) | 61 |
| pool | 534 | 310 | 2 (0.6%) | 47 | 9 (4.0%) | 261 | 2 (0.6%) | 47 | 9 (4.0%) | 261 |
| branch | 1090 | 600 | 10 (1.7%) | 206 | 12 (2.4%) | 384 | 10 (1.7%) | 206 | 12 (2.4%) | 384 |
| defer_ | 410 | 199 | 6 (3.0%) | 21 | 38 (18.0%) | 172 | 4 (2.0%) | 23 | 38 (18.0%) | 172 |
| alias | 899 | 749 | 11 (1.5%) | 113 | 6 (4.0%) | 625 | 12 (1.6%) | 112 | 6 (4.0%) | 625 |
| subslice | 275 | 169 | 12 (7.1%) | 17 | 30 (28.3%) | 140 | 11 (6.5%) | 18 | 30 (28.3%) | 140 |

### By step that is a mistake when the paths line up (what the generator aimed at; the faulting column is what really faulted)

| construct | programs | faulting | plain: silent | counted | false pos | true | std: silent | counted | false pos | true |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| bug_uaf | 24 | 24 | 0 (0.0%) | 0 | 0 (-) | 24 | 0 (0.0%) | 0 | 0 (-) | 24 |
| bug_double_free | 129 | 129 | 0 (0.0%) | 85 | 0 (-) | 44 | 0 (0.0%) | 85 | 0 (-) | 44 |
| bug_alias_uaf | 117 | 117 | 0 (0.0%) | 0 | 0 (-) | 117 | 0 (0.0%) | 0 | 0 (-) | 117 |
| bug_alias_free | 59 | 59 | 0 (0.0%) | 0 | 0 (-) | 59 | 0 (0.0%) | 0 | 0 (-) | 59 |
| bug_invalid_free | 39 | 39 | 10 (25.6%) | 7 | 0 (-) | 22 | 11 (28.2%) | 6 | 0 (-) | 22 |
| bug_cond_free | 56 | 56 | 0 (0.0%) | 20 | 0 (-) | 36 | 0 (0.0%) | 20 | 0 (-) | 36 |
| bug_loop_free | 15 | 15 | 0 (0.0%) | 0 | 0 (-) | 15 | 0 (0.0%) | 0 | 0 (-) | 15 |
| bug_defer_free | 74 | 74 | 0 (0.0%) | 0 | 0 (-) | 74 | 0 (0.0%) | 0 | 0 (-) | 74 |
| bug_helper_reuse | 128 | 128 | 0 (0.0%) | 0 | 0 (-) | 128 | 0 (0.0%) | 0 | 0 (-) | 128 |
| bug_helper_twice | 43 | 43 | 0 (0.0%) | 19 | 0 (-) | 24 | 0 (0.0%) | 19 | 0 (-) | 24 |
| bug_helper_alias | 58 | 58 | 0 (0.0%) | 0 | 0 (-) | 58 | 0 (0.0%) | 0 | 0 (-) | 58 |
| bug_realloc_stale | 81 | 81 | 0 (0.0%) | 0 | 0 (-) | 81 | 0 (0.0%) | 0 | 0 (-) | 81 |
| bug_realloc_old_free | 159 | 159 | 0 (0.0%) | 0 | 0 (-) | 159 | 0 (0.0%) | 0 | 0 (-) | 159 |
| bug_list_stale | 201 | 105 | 2 (1.9%) | 4 | 78 (81.3%) | 99 | 0 (0.0%) | 6 | 78 (81.3%) | 99 |
| bug_list_copy | 229 | 229 | 0 (0.0%) | 0 | 0 (-) | 229 | 0 (0.0%) | 0 | 0 (-) | 229 |
| bug_elem_double | 139 | 139 | 0 (0.0%) | 97 | 0 (-) | 42 | 0 (0.0%) | 97 | 0 (-) | 42 |
| bug_elem_stale | 57 | 57 | 0 (0.0%) | 39 | 0 (-) | 18 | 0 (0.0%) | 39 | 0 (-) | 18 |
| bug_elem_pop | 33 | 33 | 0 (0.0%) | 25 | 0 (-) | 8 | 0 (0.0%) | 25 | 0 (-) | 8 |
| bug_map_stale | 398 | 327 | 0 (0.0%) | 93 | 2 (2.8%) | 234 | 0 (0.0%) | 93 | 2 (2.8%) | 234 |
| bug_map_double | 161 | 161 | 0 (0.0%) | 82 | 0 (-) | 79 | 0 (0.0%) | 82 | 0 (-) | 79 |
| bug_map_uaf | 25 | 25 | 0 (0.0%) | 18 | 0 (-) | 7 | 0 (0.0%) | 18 | 0 (-) | 7 |
| bug_skey_literal | 129 | 129 | 0 (0.0%) | 98 | 0 (-) | 31 | 0 (0.0%) | 98 | 0 (-) | 31 |
| bug_struct_copy | 206 | 206 | 0 (0.0%) | 63 | 0 (-) | 143 | 0 (0.0%) | 63 | 0 (-) | 143 |
| bug_struct_field | 118 | 118 | 0 (0.0%) | 30 | 0 (-) | 88 | 0 (0.0%) | 30 | 0 (-) | 88 |
| bug_opt_stale | 121 | 121 | 0 (0.0%) | 31 | 0 (-) | 90 | 0 (0.0%) | 31 | 0 (-) | 90 |
| bug_opt_double | 75 | 75 | 0 (0.0%) | 24 | 0 (-) | 51 | 0 (0.0%) | 24 | 0 (-) | 51 |
| bug_union_double | 40 | 40 | 0 (0.0%) | 0 | 0 (-) | 40 | 0 (0.0%) | 0 | 0 (-) | 40 |
| bug_union_uaf | 34 | 34 | 0 (0.0%) | 0 | 0 (-) | 34 | 0 (0.0%) | 0 | 0 (-) | 34 |
| bug_union_tag | 91 | 56 | 0 (0.0%) | 35 | 1 (2.9%) | 21 | 0 (0.0%) | 35 | 1 (2.9%) | 21 |
| bug_errdefer_double | 37 | 37 | 0 (0.0%) | 0 | 0 (-) | 37 | 0 (0.0%) | 0 | 0 (-) | 37 |
| bug_catch_double | 34 | 34 | 0 (0.0%) | 0 | 0 (-) | 34 | 0 (0.0%) | 0 | 0 (-) | 34 |
| bug_catch_fallback | 30 | 30 | 0 (0.0%) | 0 | 0 (-) | 30 | 0 (0.0%) | 0 | 0 (-) | 30 |
| bug_global_stale | 49 | 49 | 20 (40.8%) | 15 | 0 (-) | 14 | 20 (40.8%) | 15 | 0 (-) | 14 |
| bug_global_double | 159 | 159 | 0 (0.0%) | 94 | 0 (-) | 65 | 0 (0.0%) | 94 | 0 (-) | 65 |
| bug_fnptr_free | 154 | 153 | 0 (0.0%) | 114 | 0 (0.0%) | 39 | 0 (0.0%) | 114 | 0 (0.0%) | 39 |
| bug_arena_uaf | 160 | 160 | 0 (0.0%) | 0 | 0 (-) | 160 | 0 (0.0%) | 0 | 0 (-) | 160 |
| bug_arena_foreign_free | 55 | 55 | 0 (0.0%) | 0 | 0 (-) | 55 | 0 (0.0%) | 0 | 0 (-) | 55 |
| bug_linear_twice | 93 | 93 | 0 (0.0%) | 0 | 0 (-) | 93 | 0 (0.0%) | 0 | 0 (-) | 93 |
| bug_linear_leak | 93 | 93 | 0 (0.0%) | 0 | 0 (-) | 93 | 0 (0.0%) | 0 | 0 (-) | 93 |
| bug_linear_copy | 21 | 21 | 0 (0.0%) | 0 | 0 (-) | 21 | 0 (0.0%) | 0 | 0 (-) | 21 |
| bug_linear_slice | 17 | 17 | 0 (0.0%) | 0 | 0 (-) | 17 | 0 (0.0%) | 0 | 0 (-) | 17 |
| bug_pool_stale | 145 | 144 | 0 (0.0%) | 0 | 1 (100.0%) | 144 | 0 (0.0%) | 0 | 1 (100.0%) | 144 |
| bug_pool_double | 49 | 49 | 0 (0.0%) | 0 | 0 (-) | 49 | 0 (0.0%) | 0 | 0 (-) | 49 |
| bug_node_uaf | 136 | 136 | 59 (43.4%) | 47 | 0 (-) | 30 | 61 (44.9%) | 45 | 0 (-) | 30 |
| bug_node_double | 127 | 127 | 30 (23.6%) | 21 | 0 (-) | 76 | 29 (22.8%) | 22 | 0 (-) | 76 |
| bug_bag_stale | 76 | 26 | 0 (0.0%) | 0 | 50 (100.0%) | 26 | 0 (0.0%) | 0 | 50 (100.0%) | 26 |
| bug_bag_copy | 95 | 95 | 0 (0.0%) | 32 | 0 (-) | 63 | 0 (0.0%) | 32 | 0 (-) | 63 |

## Minimized silent misses

### 1. m_node+bug_node_uaf (plain, 97 programs with this signature, 19 more minimizations reduced to the same function)

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

### 2. m_node+bug_node_double (plain, 57 programs with this signature, 23 more minimizations reduced to the same function)

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

### 3. m_global+bug_global_stale (plain, 36 programs with this signature, 11 more minimizations reduced to the same function)

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

### 4. m_buf+bug_invalid_free (plain, 14 programs with this signature, 1 more minimizations reduced to the same function)

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

### 5. m_node+bug_node_uaf (plain, 23 programs with this signature, 14 more minimizations reduced to the same function)

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

### 6. m_buf+bug_invalid_free (plain, 4 programs with this signature, 3 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: yes.

```zig
pub fn p5077(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try mk(a, 5);
    const v0_2 = v0_1[1..];
    a.free(v0_2);
    }
}

```

### 7. m_buf+bug_invalid_free (plain, 2 programs with this signature, 1 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: yes.

```zig
pub fn p285(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try a.alloc(u8, 4);
    @memset(v0_1, 7);
    const v0_2 = v0_1[1..];
    a.free(v0_2);
    }
}

```

### 8. m_buf+bug_invalid_free (std, 1 programs with this signature, 0 more minimizations reduced to the same function)

Ground truth: `oracle: invalid free (not a block)`. Also silent in the other mode: yes.

```zig
pub fn p4656(a: Allocator, selv: u8) anyerror!void {
    {
    const v0_1 = try a.alloc(u8, 14);
    @memset(v0_1, 7);
    const v0_2 = v0_1[1..];
    a.free(v0_2);
    }
}

```

