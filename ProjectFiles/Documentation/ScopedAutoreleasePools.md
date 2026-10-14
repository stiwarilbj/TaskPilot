# Scoped pools for temporary processing objects

[Apple's memory guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html)
describes draining autoreleased objects within synchronous batches rather than
waiting for an enclosing pool. Profiling identified two applicable paths:

- Canonical Accessibility control/window encoding drains Foundation's bridged
  containers and data after each JSON encoding. Returned Swift strings remain
  retained, including the final signature and its ancestry/window contents.
- Vision request execution and word-box conversion run in one worker-local pool.
  It drains before the continuation publishes Swift matches. It encloses no
  suspension; existing cancellation, lease checks and worker drainage remain.

The unchanged PNG encoder showed no accumulated heap in a 120-iteration
synthetic fixture, so no pool was added there. No desktop was captured or
controlled, and no permission, prompt, model or interface changes were made.

## Profiling evidence

Three fresh-process comparisons used Swift 6.3.3 on Apple Silicon, optimized
benchmark builds, warmup, and `malloc_zone_statistics` across allocation zones.
All inputs were generated labels and offscreen pixels, without user content.

| Fixture | Before | Scoped |
| --- | --- | --- |
| 12 signatures, 640 synthetic controls each | 40,825,424 bytes accumulated after warmup | 16 bytes accumulated |
| 20 synchronous Vision batches | 495,296 bytes released at the enclosing pool's end in each run | No bytes left for that enclosing drain |

Control output-length checksums matched at 4,217,160; Vision checksums matched
at 30,080. Native regressions additionally inspect retained labels, geometry,
recognition text, confidence and coordinates after producing pools drain, and
exercise worker cancellation. Existing consistency and AX-read regressions pass.

These samples measure allocated heap at batch boundaries, not whole-process
peak RSS or allocator-reserved pages. The control benchmark compiles the actual
production signature function. The Vision fixture mirrors synchronous request
options and word conversion, isolating that batch from async scheduling. This
does not establish an app-wide RAM or task-latency improvement. Live desktop
accuracy validation remains incomplete.

## Reproduce the synthetic comparison

Run from the repository root. These developer-only commands do not launch
TaskPilot, access Accessibility, capture a screen, or contact a provider.

```sh
mkdir -p ProjectFiles/.taskpilot-build
git show 8f072954661a3120783477fd9be7392334e0cc79:ProjectFiles/Sources/OrbitAgent/Agent/Automation/ObservationConsistency.swift > ProjectFiles/.taskpilot-build/ObservationConsistency-pre-autorelease.swift
swiftc -O ProjectFiles/.taskpilot-build/ObservationConsistency-pre-autorelease.swift ProjectFiles/Tests/Benchmarks/AutoreleaseBatches/main.swift -o ProjectFiles/.taskpilot-build/autorelease-batches-baseline
swiftc -O ProjectFiles/Sources/OrbitAgent/Agent/Automation/ObservationConsistency.swift ProjectFiles/Tests/Benchmarks/AutoreleaseBatches/main.swift -o ProjectFiles/.taskpilot-build/autorelease-batches
ProjectFiles/.taskpilot-build/autorelease-batches-baseline controls unscoped
ProjectFiles/.taskpilot-build/autorelease-batches controls unscoped
ProjectFiles/.taskpilot-build/autorelease-batches vision unscoped
ProjectFiles/.taskpilot-build/autorelease-batches vision scoped
```

Repeat each comparison in fresh processes. Memory thresholds are deliberately
not test assertions: framework caches and allocator behavior vary by OS.
