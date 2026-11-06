# Stats upstream

This directory vendors the source of [exelban/stats](https://github.com/exelban/stats)
at commit `d51378c2238d1c4148792a914b220d6ca1eca466`.

The CPU, RAM, Net, Disk, GPU, Battery, and Kit framework targets are built as
dependencies of OneClick. Keep the upstream `LICENSE` file when updating this
snapshot.

## Host compatibility patch

`Kit/module/module.swift` stores module state in the host application's standard
defaults. The upstream app points this property at its WidgetKit app group and
force-unwraps a Stats-specific `TeamId` Info.plist key; OneClick does not embed
that widget extension or entitlement.

`OneClickHostAssets.xcassets` is a host-only copy of the upstream `devices`
asset namespace required by `SystemKit`. The support/donation images are not
compiled into OneClick, which also avoids colliding with OneClick's own GitHub
asset name.

`Kit/module/window.swift` adds `setPreviewVisible(_:)` so the host can explicitly
select settings or preview while reusing the module's existing view instance.

`Kit/helpers.swift` looks up the host's `Stats.strings` table before falling back
to the upstream `Localizable` table. OneClick copies the upstream translations
for its five supported locales into its resources without mixing their keys
with the host catalog.

`Kit/constants.swift` keeps the widgets' drawing canvas at 22 points.
`Kit/module/widget.swift` centers that canvas in a padded, autoresizing status
item container and updates combined widget positions and item widths together.
This avoids edge collisions and height-dependent baselines on taller menu bars.
Mini, Memory and Speed widgets measure their displayed strings so percentages,
memory values and speed units can grow without clipping.
