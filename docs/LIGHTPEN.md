# Light pen

NDS4MiSTer accepts the same user-port light pen as the Palm m515 core: an
OPL811-OC open-collector optical sensor and a contact button, both active low.

| User port | Signal |
|-----------|--------|
| `USER_IN[0]` | OPL811-OC output (low while the sensor sees the beam) |
| `USER_IN[1]` | Contact button (low while pressed) |

`USER_OUT` stays all-ones, so both lines are inputs. Nothing connected reads
as released, which leaves mouse and right-stick touch unchanged.

## Behavior

- Use it on a CRT showing the **Touch** screen: the analog output with
  **Independent Outputs** (Analog Screen: Touch), or the digital/VGA output in
  **CRT Mode** with the Touch screen selected. Pulses outside the touchscreen
  are ignored.
- While the button is held, the light pen owns the DS touchscreen. The button
  is sampled once per frame, which debounces it. After a press, the first lit
  frame is skipped so contact bounce cannot place the touch. From then on,
  the first qualified sensor pulse in each frame latches the raster position
  as native 0–255 / 0–191 coordinates and touches the screen. That is the
  top of the pen's spot; later pulses in the same frame are ignored.
- A pulse only counts after the sensor has been active for 15 clocks
  (250 ns), so short spikes from deflection or button crosstalk are rejected.
- Releasing the button stops captures immediately and lifts the pen at the
  next frame. The next press waits for a fresh pulse.
- While the button is held, the touchscreen's darkest pixels are raised to a
  grey floor so the sensor can see the beam over black areas. Lines that
  arrive late from memory, which are otherwise black, get the floor too.
- The touch crosshair is hidden from the first press until the mouse or
  right stick is used again.

## Position correction

The pulse arrives about 11 dots after the beam passes the pen (sensor and
video latency), and the first line that triggers is the top of the pen's
spot, about 6 rows above its centre. The core subtracts 11 dots and adds 6
rows (`LP_X_LAG`, `LP_Y_LEAD` in `rtl/nds_nitro_video_scanout.sv`). These
were measured on a 15 kHz CRT; the dot-based X value is tied to 240p's
10-clock dots. The capture window extends 11 dots past the right edge so the
whole width stays reachable. The top 6 rows report as row 6 or lower,
because nothing above the panel is lit for the sensor to see.

Which line of the spot triggers varies a little from frame to frame, and
moves the trigger point sideways by a few pixels. To steady this, a new X
within 8 pixels of the previous one moves only half way toward it, and a
change of 1 pixel is ignored. Larger moves and the first touch after a press
apply immediately (`LP_JUMP`).

**Display options → Light Pen Level** sets the floor: High (default, about
Palm level 9), Medium (about 7), Low (about 5) or Off. Start at High and lower
it until the image is comfortable but detection is still reliable. The option
uses status bits 2:1. A host built before this option was added always uses
High.

`rtl/tb_nds_lightpen.sv` covers the offsets and edge windows, X smoothing,
crosshair ownership, spike rejection, first pulse per frame, the press
settle frame, release, floor levels including late lines, rejection of
borders and the main screen, and the split analog raster.
