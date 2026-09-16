# Auto Frontlight for current KOReader

A standalone port of KOReader's former **Auto frontlight** plugin for Kindle
devices with an ambient-light sensor, including the Kindle Voyage. It replaces
the removed BackgroundRunner dependency with KOReader's current `UIManager`
timer API.

## What it does

KOReader converts the Voyage sensor reading into levels 0–4:

- 0 (darkest): brightness 10
- 1 (dim): brightness 7
- 2 (indoor light): brightness 4
- 3 (bright): brightness 2
- 4 (very bright): brightness 0/off

These recommended values can all be changed under **Brightness by ambient
level**. Setting any level to 0 turns the frontlight off. If you change the
frontlight manually, that choice is preserved until the sensor moves into a
different ambient-light level.

## Install on Kindle

1. Extract the ZIP.
2. Copy the entire `autofrontlight.koplugin` folder to:
   `/mnt/us/koreader/plugins/`
3. Restart KOReader.
4. Open **Tools → More tools → Auto frontlight → Enable ambient-light
   control**.

The default check interval is 60 seconds. A shorter interval responds faster
but wakes the scheduler more frequently.

## Important

In **Auto night mode**, leave **Frontlight off during day** disabled. That solar
setting and this sensor plugin both control the frontlight and can conflict.
Automatic Night Mode itself can remain enabled.

If the menu does not appear, confirm that the extracted path is exactly:
`koreader/plugins/autofrontlight.koplugin/main.lua` (not a folder nested twice).
Then fully restart KOReader; enabling a plugin does not load it immediately.

## Compatibility

Built against the current KOReader plugin APIs as of September 2026. The plugin
loads on Kindle devices without relying on KOReader's sensor-capability flag,
because that flag can be missing on some builds. Use **Compatibility
information** in the plugin menu to see the flag and live sensor result.

## License and attribution

This is a modified port of the former `autofrontlight.koplugin` shipped by the
KOReader project. KOReader is licensed under AGPL-3.0; this port is distributed
under the same license. See `COPYING`.
