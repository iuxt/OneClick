# System Monitor

OneClick includes a lightweight system monitor inspired by
[Stats](https://github.com/exelban/stats). CPU, memory and network speed can be
shown simultaneously as independent menu bar items; disk, GPU and battery
items are optional. Clicking an item opens that module's history and ranking
view. The System Monitor settings page controls each menu bar item, its display
style, and the one-, two- or five-second sampling interval.

## Architecture

- `SystemMetricsSampler` is an actor that owns the previous CPU and network
  counters. Keeping those counters actor-isolated makes rate calculations safe
  while the UI requests automatic and manual refreshes.
- `SystemMonitor` publishes the latest immutable snapshot and a bounded
  60-sample history to SwiftUI on the main actor.
- Disabled modules are not sampled, reducing the monitor's own energy impact.
- CPU and memory use public Mach host statistics. Network totals come from
  `getifaddrs`, disk capacity from volume resource values, battery data from
  IOPowerSources, and GPU utilization from the public IOKit registry data that
  the current hardware exposes.
- Process rankings use `libproc` resource counters without launching shell
  commands. CPU time is calculated between samples; memory uses physical
  footprint. Network details rank active interfaces, and disk details rank
  mounted local volumes by utilization.
- Sampling is local. The monitor makes no network requests and stores no metric
  history on disk.

## Scope and limitations

GPU and battery data is conditional because not every Mac exposes those values.
Network-mounted and synthetic volumes are skipped so an unavailable remote host
cannot stall the menu bar refresh.

Stats also supports SMC temperature sensors and fan control. Those features
need model-specific sensor tables and, for fan writes, a privileged helper.
They are intentionally not part of this sandbox-compatible integration.

The Stats MIT license is bundled as `Resources/Stats-LICENSE.txt`.
