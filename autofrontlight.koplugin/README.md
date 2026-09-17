# Auto Frontlight for current KOReader

A standalone replacement for KOReader's former **Auto frontlight** plugin for
Kindle devices with an ambient-light sensor, including the Kindle Voyage. It
uses the Voyage's full raw sensor reading and KOReader's current `UIManager`
timer API.

## What it does

The plugin reads the raw `alsLux` value and converts it to frontlight brightness
with a smooth logarithmic curve. The recommended curve uses brightness 12 in
complete darkness and gradually falls to 0 at a raw light reading of 10,000.
This produces many more usable steps than KOReader's standard five sensor
buckets.

Under **Adaptive brightness curve** you can change:

- brightness in complete darkness;
- brightness in daylight (0 turns the light off); and
- the raw reading considered bright daylight.

If you change the frontlight manually, that choice is preserved until the
calculated automatic brightness changes. If direct raw-sensor access fails, the
plugin automatically falls back to the older five-level method.

## Install on Kindle

1. Extract the ZIP.
2. Copy the entire `autofrontlight.koplugin` folder to:
   `/mnt/us/koreader/plugins/`
3. Restart KOReader.
4. Open **Tools → More tools → Auto frontlight → Enable ambient-light
   control**.

The default check interval is 60 seconds. A shorter interval responds faster
but wakes the scheduler more frequently.

When the Kindle resumes from sleep, the plugin adjusts the frontlight
immediately and checks again one second later in case the ambient-light sensor
needed a moment to refresh. It then returns to the selected check interval.

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
