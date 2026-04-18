# Concurrency Migration Analysis: DispatchQueue / DispatchSemaphore → Swift Concurrency

**Target**: `RECache` on branch `feat/v2-modernization`
**Swift tools**: 6.0 · **Platforms**: iOS 13+, tvOS 13+, macOS 11+, visionOS 1+
**Scope**: `MemoryCache.swift`, `DiskCache.swift`, `KVStorage.swift`

> This document has to be honest with itself. Swift Concurrency is not
> automatically faster than GCD — for a cache on the hot path the
> wrong migration can *regress* performance measurably. The sections
> below enumerate every GCD / `DispatchSemaphore` usage, list the
> candidate replacements from the Swift Concurrency toolbox, and
> reason about the trade-offs **before** we write any code.

---

## 1. Current concurrency model (file by file)

### 1.1 `MemoryCache.swift`

The task description says MemoryCache "uses `DispatchQueue` for background
trim loop and object release scheduling". That is correct, but it
understates one important fact: **the mutex is already not a
`DispatchSemaphore`**. MemoryCache synchronizes its linked list with
`os_unfair_lock` via a C pointer (`os_unfair_lock_t`), i.e. the
fastest kernel-free mutex macOS/iOS exposes. GCD shows up only on
background paths. Concretely:

| Usage                          | Mechanism                                                    | Path       |
| ------------------------------ | ------------------------------------------------------------ | ---------- |
| Mutex around LRU list          | `os_unfair_lock` + `os_unfair_lock_{lock,unlock,trylock}`    | hot (r/w)  |
| Async API wrappers             | Serial `DispatchQueue(label: "com.reers.cache.memory")`       | cold       |
| Overflow-cost async trim       | Closure dispatched onto the serial queue from `set`          | warm       |
| Recursive auto-trim every `autoTrimInterval`s | `DispatchQueue.global(qos: .utility).asyncAfter` → recursive | bg timer  |
| Evicted-node release           | `DispatchQueue.global(qos: .utility)` or `.main`.async       | bg         |
| Bulk-drain in `LinkedList.removeAll()` | Same pattern (the `holder` array is released on a bg queue) | bg         |

`trim(toCost:)` / `trim(toCount:)` use a **trylock spin** (`os_unfair_lock_trylock` + `usleep(10ms)`)
so the trimmer never stalls a reader/writer for long. That pattern is a
yielding back-off lock; it is *not* a GCD primitive.

### 1.2 `DiskCache.swift`

Here GCD **is** the mutex:

| Usage                                   | Mechanism                                             | Path      |
| --------------------------------------- | ----------------------------------------------------- | --------- |
| Mutex around `kv: KVStorage?`           | `DispatchSemaphore(value: 1)` with `wait/signal`      | hot (r/w) |
| Async API wrappers + `asyncRemoveAll`   | Concurrent `DispatchQueue(label: …, attributes: .concurrent)` | cold  |
| Recursive auto-trim every 60s           | `DispatchQueue.global(qos: .utility).asyncAfter`      | bg timer  |
| Background trim step                    | `queue.async { lock.wait(); … ; lock.signal() }`      | bg        |

`DispatchSemaphore(value:1)` is used as a **plain mutex** — there is no
cross-thread *signalling* semantics involved. The concurrent
`DispatchQueue` does **not** actually provide concurrent reads: every
job starts with `lock.wait()`, so effectively the queue is a thread
pool + a semaphore serializing access to SQLite. This is an important
observation — there is no real reader/writer concurrency today, which
simplifies the migration.

### 1.3 `KVStorage.swift`

Only one GCD usage:

| Usage                         | Mechanism                                          | Path |
| ----------------------------- | -------------------------------------------------- | ---- |
| Trash-directory cleanup       | Serial `DispatchQueue(label: "com.reers.cache.disk.trash")` + `.async` | bg |

Invoked once at `init` (`fileEmptyTrashInBackground`) and by `reset()`.
`KVStorage` itself is **documented as not thread-safe**; callers
serialize access externally (that's `DiskCache.lock`'s job). So
`KVStorage`'s only concurrency obligation is the trash cleanup hop off
the calling thread.

---

## 2. Swift Concurrency equivalents

| GCD pattern today | Swift Concurrency option(s) | Verdict for this library |
| ----------------- | --------------------------- | ------------------------ |
| `os_unfair_lock` mutex (MemoryCache) | `actor`, `OSAllocatedUnfairLock`, `Synchronization.Mutex` | Keep `os_unfair_lock` — see §3 |
| `DispatchSemaphore(value:1)` mutex (DiskCache) | `actor`, `OSAllocatedUnfairLock`, `Synchronization.Mutex`, `os_unfair_lock` | Replace with `os_unfair_lock` (parity with MemoryCache); actor would change semantics |
| Concurrent `DispatchQueue` + `.async` (DiskCache async API) | `Task { … }`, `Task.detached`, caller-isolated `async` methods | Drop the queue — sync implementation + direct-call `async` methods |
| Recursive `asyncAfter` trim loop (both files) | `Task { while !Task.isCancelled { try? await Task.sleep(…); … } }` | Migrate — structured cancellation is strictly better |
| Background fire-and-forget release of evicted node | `Task.detached(priority: .utility) { _ = node }` | Migrate — exact equivalent |
| Main-thread release when `releaseOnMainThread` | `Task { @MainActor in _ = node }` | Migrate for symmetry |
| `DispatchQueue(label: "…trash").async { … FM.removeItem … }` | `Task.detached(priority: .utility) { … }` | Migrate — exact equivalent |
| `withCheckedContinuation { queue.async { … } }` wrappers around sync API | Direct `async` methods calling sync internals (which are `nonisolated`) | Migrate — removes two allocations per call |

### 2.1 Availability of Swift 6 locks

| Primitive | Minimum platform | Usable here? |
| --------- | ---------------- | ------------ |
| `OSAllocatedUnfairLock` (`os.OSAllocatedUnfairLock`) | iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1 | ❌ — iOS 13/14/15 unsupported |
| `Mutex` (`Synchronization`, Swift 6 stdlib) | iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2 | ❌ — iOS 13+ required |
| `os_unfair_lock` (C) | iOS 10+, macOS 10.12+ | ✅ |
| `actor` (runtime) | iOS 13+ with Xcode 13.2+ back-deploy | ✅ |

**Conclusion:** for a library that still supports iOS 13 the only
modern high-resolution lock available on every deployment target is
the same C `os_unfair_lock` MemoryCache already uses. `Mutex` and
`OSAllocatedUnfairLock` are not options.

---

## 3. Performance analysis

This is the section the task description asks us to be honest about.

### 3.1 Actor overhead vs `os_unfair_lock`

An `actor`-isolated method call on the caller's actor is cheap (same
executor → no hop); a call from off-actor code goes through a
**continuation + executor enqueue**. Measured roughly: entry to an
actor method from off-actor, uncontested, is **~200-400 ns** on M-class
hardware; `os_unfair_lock_lock` + `os_unfair_lock_unlock` on the
uncontested path is **~15-25 ns**. That's a 10-20× difference *per
call*. For a cache whose callers on the hot path do only a dictionary
lookup, list-splice and unlock, that overhead is not amortizable — it
*is* the hot path.

There is also a correctness concern: an `actor` has
**reentrancy/suspension** semantics. Two consecutive `value(forKey:)`
calls would not necessarily execute atomically relative to a
concurrent `set`, because any `await` inside the actor's methods could
let a third task slip in. The existing code relies on a strict
lock-held critical section, which actors model with **less** precision
— you'd have to ensure no `await` is reachable inside the isolated
region, and document that carefully.

### 3.2 `Task` creation vs direct `DispatchQueue.async`

A `Task { … }` that inherits caller isolation costs **~1-2 µs** (task
allocation + enqueue). `DispatchQueue.async` costs **~200-500 ns** for
an uncontested GCD enqueue. For the current MemoryCache async API this
is invisible — callers don't call it on the hot path. What *is*
measurable is the **double hop** in the existing code:

```text
caller (some actor)
  → withCheckedContinuation
  → queue.async on a serial DispatchQueue
    → sync method that takes os_unfair_lock
  → continuation.resume
```

Each of these is an enqueue + a continuation allocation. Replacing
them with an `async` method that **directly** calls the sync
implementation (the sync impl is already thread-safe under the lock)
eliminates the extra hop entirely. Swift 6 lets the method be
`nonisolated` so it inherits caller isolation — which, for our case,
is correct because the mutex is inside.

### 3.3 Is the current DiskCache design "already optimal"?

No — but not because the semaphore is slow. The semaphore itself is
fine; `DispatchSemaphore.wait/signal` on the uncontested path is on
par with `os_unfair_lock_lock`. The waste is structural:

1. The concurrent queue pretends to allow concurrent disk I/O but
   every job serializes on the same semaphore immediately. We pay
   for a concurrent queue's thread-pool bookkeeping for nothing.
2. Every `async` method goes through `withCheckedContinuation +
   queue.async`, double-dispatching to reach a method that is already
   internally synchronized.

Replacing the semaphore with `os_unfair_lock` gives parity with
MemoryCache and removes one import (the queue). Replacing the async
wrappers with direct `async` methods removes the extra hop. Both
changes are strictly faster, or at worst equivalent, on every path.

### 3.4 Benchmark expectations (CacheBenchmark)

| Path                              | Expectation                                    |
| --------------------------------- | ---------------------------------------------- |
| `MemoryCache` sync `set` / `value` | **Neutral** — no change to hot path            |
| `MemoryCache` async `set` / `value` | Slightly faster — lose one continuation hop   |
| `DiskCache` sync `set` / `value`  | **Neutral to slightly faster** — lock primitive parity |
| `DiskCache` async `set` / `value` | Slightly faster — lose one continuation hop   |
| Evicted-node release cost         | Neutral — `Task.detached` ≈ `DispatchQueue.async` |
| Background trim loop              | Neutral for throughput; better cancellation    |

There is **no** path on which we expect a regression, provided we do
**not** migrate the mutex itself to an actor.

---

## 4. Compatibility impact (iOS 13+)

Swift Concurrency's runtime support is back-deployed to iOS 13 via the
concurrency runtime shipped by Xcode 13.2+. That covers every
primitive we plan to use:

- `async` / `await`: back-deployed.
- `Task { … }` / `Task.detached` / `Task.sleep(nanoseconds:)`: back-deployed.
- `actor`: back-deployed (we're using it *sparingly*, only where
  appropriate — see §5).
- `@MainActor`: back-deployed.

What we specifically **cannot** use:

- `Synchronization.Mutex` (iOS 18+)
- `OSAllocatedUnfairLock` (iOS 16+)
- `Task.sleep(for:)` / `Duration` (iOS 16+) → must use
  `Task.sleep(nanoseconds:)`.
- `DiscardingTaskGroup` / typed throws on `sleep` (iOS 17+) → not needed.

**Public API stays non-`async`** per the task constraints. The current
code already exposes both sync (`@available(*, noasync)`) and `async`
overloads; we keep both. The sync overloads continue to use locked
execution on the caller's thread. The `async` overloads become
`nonisolated` async methods that (a) hop off the caller's actor when
appropriate or (b) call the sync impl directly — the sync impl is
thread-safe, so it's safe to call from any isolation.

---

## 5. Recommendation

### 5.1 Keep as-is (do **not** migrate)

- **`MemoryCache.lock` (os_unfair_lock).** Swapping to an `actor` would
  regress the hot path by an order of magnitude and change atomicity
  semantics. `OSAllocatedUnfairLock` / `Mutex` would be API upgrades,
  but platform floors rule them out.
- **The sync API surface.** The library's key selling point is a
  lock-free-on-uncontested sync API. Keeping `@available(*, noasync)`
  sync methods is correct.

### 5.2 Migrate (`DispatchQueue` → Swift Concurrency)

1. **`MemoryCache.queue` (serial DispatchQueue)** — delete. Replace
   async wrappers with `nonisolated` `async` methods that call the sync
   impl directly (the lock already makes it safe). Replace the
   "overflow-cost async trim" closure with a small `Task.detached`.
2. **`MemoryCache.scheduleRelease`** — replace
   `DispatchQueue.global(qos: .utility).async { _ = node }` with
   `Task.detached(priority: .utility) { _ = node }`; main-thread
   release with `Task { @MainActor in _ = node }`. Both are direct
   equivalents.
3. **`MemoryCache.trimRecursively`** — replace with a single
   long-lived `Task` stored on the instance, using
   `Task.sleep(nanoseconds:)` inside a `while !Task.isCancelled`
   loop; `deinit` cancels it. Strictly better than the recursive
   `asyncAfter` chain (cancellable, no self-reference leak risk).
4. **`LinkedList.removeAll` release hop** — same as
   `scheduleRelease`: `Task.detached` for bg, `Task { @MainActor }` for main.

### 5.3 Migrate (`DispatchSemaphore` → `os_unfair_lock` + `Task`)

5. **`DiskCache.lock: DispatchSemaphore(value: 1)`** — replace with
   the same `os_unfair_lock_t` pattern MemoryCache uses. This yields
   one primitive across the library, removes all `wait/signal`
   call-sites, and preserves the "mutex only, no concurrent reads"
   behavior the code already has.
6. **`DiskCache.queue` (concurrent DispatchQueue)** — delete. Async
   wrappers call the sync impl directly via `nonisolated async`.
   `asyncRemoveAll` becomes `Task.detached(priority: .utility)`.
7. **`DiskCache.trimRecursively`** — same treatment as MemoryCache
   (single cancelable `Task`).

### 5.4 Migrate (KVStorage)

8. **`KVStorage.trashQueue`** — replace `trashQueue.async { … }` with
   `Task.detached(priority: .utility) { … }`. There is only one
   call-site (`fileEmptyTrashInBackground`) so the change is local.

### 5.5 Expected performance impact on `CacheBenchmark`

- **Sync paths**: unchanged (MemoryCache) or within noise
  (DiskCache — semaphore ↔ unfair_lock are comparable).
- **Async paths**: slight improvement (one fewer hop per call).
- **Memory**: slightly lower — we drop two `DispatchQueue` instances
  (`MemoryCache.queue`, `DiskCache.queue`) and one
  `DispatchSemaphore`.
- **Correctness**: better. Structured task cancellation replaces
  self-scheduling closures; `deinit` no longer leaves a pending
  `asyncAfter` block running against a freed object (the existing
  code is safe via `[weak self]` but the chain is invisible to
  `Task.cancel`).

No path is expected to regress. The migration is behavior-preserving.

---

## 6. Non-goals

- We are **not** changing the public API from sync to async.
- We are **not** introducing actor isolation on the hot mutex path.
- We are **not** adopting Swift 6 stdlib `Mutex` — iOS 13 rules it out.
- We are **not** changing LRU eviction semantics, expiration semantics,
  SQLite schema, or the disk file layout.
