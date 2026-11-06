# System Monitor

OneClick directly integrates the MIT-licensed framework targets from
[Stats](https://github.com/exelban/stats). CPU, memory and network speed can be
shown simultaneously as independent menu bar items; disk, GPU and battery
items are optional. Each item uses Stats' original native status item, reader,
widget and detail panel implementation.

## Architecture

- `Vendor/Stats` contains the pinned upstream source and its original Xcode
  project. `UPSTREAM.md` records the exact upstream commit and the small host
  compatibility patch.
- OneClick builds and embeds Stats' `Kit`, `CPU`, `RAM`, `Net`, `Disk`, `GPU`
  and `Battery` dynamic frameworks.
- `StatsMenuBarModules` owns the upstream module objects and maps OneClick's
  existing visibility switches to Stats' `mount`, `enable`, `disable` and
  `terminate` lifecycle.
- Stats' `NSStatusItem` and `NSPanel` implementations own the independent menu
  bar widgets and their click behavior. They are not recreated with SwiftUI
  `MenuBarExtra` views.
- OneClick's main overview window still uses `SystemMonitor` and
  `SystemMetricsSampler` for its compact combined cards. Its refresh interval
  is independent from the per-module settings exposed by Stats.

## Scope and limitations

GPU, battery, temperature and other hardware data remain conditional because
not every Mac exposes those values. OneClick embeds the six monitoring
frameworks listed above, but does not embed Stats' Sensors module or privileged
SMC helper, so fan control is not part of this integration.

Stats' network module may perform its configured connectivity check. Public-IP
refresh remains disabled by the upstream default unless the user enables an
interval in the module settings.

The Stats MIT license is preserved in `Vendor/Stats/LICENSE` and bundled as
`Resources/Stats-LICENSE.txt`.
