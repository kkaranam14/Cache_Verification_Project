# 4-Way Set-Associative Cache Design and Verification

A SystemVerilog project implementing and verifying a blocking 4-way, 2KB set-associative cache with write-back/write-allocate policy, byte-write support, dirty eviction handling, and tree-based pseudo-LRU replacement.

The verification environment is a class-based non-UVM SystemVerilog testbench with generator, driver, monitor, scoreboard, reference memory, memory model, directed tests, and random traffic.

---

## Project Summary

This project verifies a small blocking cache that processes one request at a time.
For each request, the cache performs tag lookup, hit/miss detection, possible dirty write-back, refill from memory, and response generation.

The testbench checks cache correctness using a byte-addressable golden reference memory. Reads from the DUT are compared against the reference memory, while writes update the reference model using the same byte-strobe behavior as the cache.

---

## Files

| File           | Description                                                                                                  |
| -------------- | ------------------------------------------------------------------------------------------------------------ |
| `Design.sv`    | RTL for the blocking 4-way set-associative cache                                                             |
| `testbench.sv` | Interface, transaction, generator, driver, monitor, scoreboard, environment, memory model, and top testbench |

---

## Cache Features

* 2KB total cache capacity
* 32-byte cache line size
* 16 sets, 4 ways
* 32-bit request-side data interface
* Write-back policy
* Write-allocate policy
* Byte write-strobe support
* Dirty-bit based eviction handling
* Tree-based pseudo-LRU replacement
* Blocking cache operation with one in-flight request at a time

---

## Design Organization

The cache RTL is organized into the following sections:

* Cache configuration and address breakdown
* Cache storage arrays for data, tag, valid, dirty, and pseudo-LRU bits
* Request registers to hold the active transaction
* Address decode logic for tag, set index, and cache-line offset
* Helper functions for word select, byte merge, and LRU update
* Hit detection, invalid-way search, and victim selection
* Request-side, memory-side, and debug output logic
* Sequential FSM for lookup, write-back, refill, and response handling

---

## Verification Environment

Uses a lightweight non-UVM testbench for readable and portable verification.

| Component    | Purpose                                                                  |
| ------------ | ------------------------------------------------------------------------ |
| Transaction  | Represents one high-level cache request                                  |
| Generator    | Creates directed and random read/write transactions                      |
| Driver       | Drives each transaction onto the DUT request interface.                  |
| Monitor      | Passively observes DUT activity and forwards completed transactions      |
| Scoreboard   | Checks DUT reads/writes against a byte-addressable reference memory      |
| Memory Model | Provides predictable full-line responses for cache refill and write-back |
| Environment  | Connects and runs all class-based testbench components                   |

---

## Testing Strategy

The testbench includes both directed and random testing.

Directed tests verify specific cache behaviors. Random read/write traffic improves address and byte-strobe coverage and helps expose corner-case bugs.

Main tests include:

* Cold read miss followed by read hit
* Write followed by read from the same address
* Partial byte write using byte strobes
* Same-set fills to exercise set associativity
* Replacement behavior using pseudo-LRU victim selection
* Dirty eviction and recovery after write-back
* Random read/write traffic across initialized memory

---

## Coverage-Style Counters

The testbench includes lightweight coverage-style counters using DUT debug pulses.

These counters confirm that the following scenarios were exercised:

* Cache hits
* Cache misses
* Dirty evictions

These are simple event counters, not full SystemVerilog functional coverage.

---

## EDA Playground Run

The project was tested on EDA Playground using the following setup:

* **Language:** SystemVerilog/Verilog
* **Tool:** Siemens Questa 2025.2
* **UVM/OVM:** None
* **Other libraries:** None

The design compiled and simulated successfully. The testbench completed directed and random cache transactions, and the scoreboard reported zero mismatches.

---

## Expected Final Output

```text
[SB] Errors = 0
[SB] PASS
[TB] ALL TESTS PASSED
```

