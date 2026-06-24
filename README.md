# 4-Way Set Associative Cache Design and Verification

A SystemVerilog project implementing and verifying a blocking 4-way, 2KB set-associative cache with write-back/write-allocate policy, tree-based pseudo-LRU replacement, and a class-based non-UVM verification environment.

## Files

- `Design.sv` - blocking 4-way set-associative cache RTL
- `testbench.sv` - interface, transaction, generator, driver, monitor, scoreboard, environment, memory model, and top testbench

## Cache Features

- 2KB cache capacity
- 32-byte cache line
- 16 sets, 4 ways
- 32-bit CPU word interface
- Write-back policy
- Write-allocate policy
- Byte write strobes
- Tree pseudo-LRU replacement
- Blocking operation: one CPU request at a time

## Main Tests

1. Cold read miss followed by read hit
2. Write then read same address
3. Partial byte write using write strobes
4. Same-set fills and replacement
5. Dirty eviction and recovery after write-back
6. Random read/write traffic

# EDA Playground Run

The project was tested on EDA Playground using Siemens Questa 2025.2.
Recommended setup:

Language: SystemVerilog/Verilog
Tool: Siemens Questa 2025.2
Top module: tb_cache_4way
UVM/OVM: None
Other libraries: None

The design compiled and simulated successfully with zero compile/simulation errors. The testbench completed directed and random cache transactions, and the scoreboard reported zero mismatches.

Expected final output:

[SB] Errors = 0

[SB] PASS

[TB] ALL TESTS PASSED
[SB] PASS
[TB] ALL TESTS PASSED
```
