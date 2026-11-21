# Architecture

| Location | Responsibility |
| --- | --- |
| `Sources/DarwinMetrics` | Small C bridge to Mach, route-interface counters, libproc, and SQLite. |
| `Sources/GlassStatsCore` | Sendable models, the monitoring-provider protocol, system metrics, bounded history, and the sampling engine. |
| `Sources/GlassStats` | AppKit application and windows, status item, SwiftUI dashboard, inspectors, settings, and alerts. |
| `Sources/WidgetSnapshot` | Codable contract for the aggregate snapshot in the optional App Group. |
| `Sources/GlassStatsWidget` | WidgetKit configurations, snapshot display, timelines, and links into the application. |
| `Scripts` | Testing and native app/extension packaging. |

One application task requests samples from `TelemetryEngine`. The engine schedules each metric against a monotonic clock and calls a separate provider actor, so Mach and libproc work stays off the UI thread. Views and the status item observe the same snapshots. The app publishes a new revision when the engine collects data or applies a monitoring change. When hidden, the dashboard releases its SwiftUI view and preserves the panel frame. The dashboard draws compact paths with Canvas. The Activity window uses Swift Charts. Process sampling runs while the process inspector is visible. On-demand port refresh joins the next scheduler pass. Sampling demand comes from visible cards, selected menu metrics, the active inspector, alerts, and enabled history or widget consumers. The scheduler sleeps until the next due reading or an explicit wake event. Menu-bar-only mode and Low Power slow readings. Low Power also hides dashboard sparklines. Wake events reset CPU, interface, and process baselines.

CPU is computed from per-core tick deltas including 32-bit rollover. Aggregate CPU weights cores by their observed tick totals. Per-process CPU uses user plus system time relative to one logical core and may exceed 100%. PID plus process start time identifies a process across samples. Used memory estimates private pages less purgeable memory, plus wired and compressed pages. Available memory subtracts that estimate from physical RAM. Memory pressure uses a dispatch memory-pressure source.

Network rate compares 64-bit interface counters against monotonic elapsed time. Session totals sum valid deltas on the primary interface while sampling runs. A changed interface, decreasing counter, or wake resets the rate baseline. The interface name follows System Configuration. Both download and upload are sampled from that interface.

The socket inspector reads file descriptor and socket metadata via libproc. It shows TCP LISTEN sockets and UDP sockets with a local port. Shared descriptors may appear once for each owning process. Process exit, process identity changes, ownership and operating system policy can affect visibility. Port rows are local metadata. Confirmed close actions require an eligible same-user development executable, match the current socket and PID start time, and send SIGTERM. A separate bounded task reads Docker container metadata over a local Unix socket when a Docker view is visible. [Apple libproc source](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c)

Chart history uses timestamped bounded buffers. Optional SQLite persistence retains downsampled aggregates in `~/Library/Application Support/GlassStats/History.sqlite`. Retention is applied on load and on writes while enabled. Turning off persistence stops new writes. Clear Local History removes the stored samples. The application stores preferences in UserDefaults.

The app writes an atomic aggregate JSON snapshot at most once every five minutes to the configured App Group. Widgets read that snapshot and use WidgetKit timeline scheduling. The application requests updates subject to system budgets. Old readings expire from the widget timeline after 20 minutes. [Apple App Group containers](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) · [WidgetKit timelines](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/)
