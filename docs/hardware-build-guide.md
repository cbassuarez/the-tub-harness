# THE TUB — Hardware Build Guide

Status: **In Progress**
Last updated: 2026-04-06

## What's Done

- [x] Central Teensy 4.0 on breadboard, reading 5 inputs (3-pos selector, 2 latched, 1 momentary)
- [x] Teensy firmware: debounced input, mode 0-10 truth table, `M<mode>,J<0|1>\n` USB serial protocol
- [x] `HardwareInputController.swift`: auto-discovers `/dev/cu.usbmodem*`, parses protocol, calls `setMode`/`pulseJolt`/`setJoltHeld`
- [x] Integrated into ContentView with "Panel" status pill
- [x] Momentary (JOLT) button uses NC contact block — firmware inverts jolt logic
- [x] Teensy firmware: RS-485 master polling (Serial1 + MAX485 DE pin 7), polls 3 pedestals, forwards telemetry to USB, accepts commands from Mac
- [x] `HardwareInputController.swift`: parses pedestal telemetry `P<addr>,B,T,H`, publishes `pedestals` dict, can send halo/NeoPixel commands downstream
- [ ] **NEXT**: Wire MAX485 transceiver to Teensy (pins 0, 1, 7), loopback test, then first pedestal

### Known Issues
- Teensy sometimes drops back to bootloader (HID mode). Close Teensy Loader, unplug/replug, let it boot without pressing the program button.
- Buttons require firm press on bench — normal, will improve once panel-mounted in 22mm holes.

### Hardware Reference
- **Selector switch**: GCX1262-120L (3-position, maintained, illuminated). Comes with 2x ECX1040 (green, NO) + 2x ECX1030 (red, NC). Only the two green NO blocks are installed.
- **Latched pushbuttons**: GCX1193-24L (push-on/push-off, illuminated). Each uses ECX1042 (brown, NO push-push) contact block.
- **Momentary pushbutton**: Uses NC contact block (jolt logic inverted in firmware).
- **Contact block terminal mapping** (from AutomationDirect GCX spec sheet): terminals **3 & 4** = NO contact, terminals **1 & 2** = NC contact, **X1 & X2** = indicator lamp. Wire signal to one of the contact pair, ground to the other.

### Pin Assignments (Current)
| Teensy Pin | Function |
|-----------|----------|
| 2 | 3-pos switch LEFT NO contact |
| 3 | 3-pos switch RIGHT NO contact |
| 4 | Latched button 1 |
| 5 | Latched button 2 |
| 6 | Momentary / JOLT (NC, inverted in firmware) |

---

## Build Phases

The build order is: **power first, then backbone (RS-485), then one pedestal end-to-end, then replicate, then lighting, then PATLITE.**

Test each phase before moving to the next.

---

### Phase 1: 24V Power Distribution

**Goal**: Reliable 24V rail powering everything from a single PSU.

**Parts**:
- 24V DC power supply (barrel-to-terminal or screw-terminal PSU)
- Distribution block (DIN rail terminal block or bus bar)
- Fuse block (Blue Sea or similar) for branch protection
- 18-16 AWG wire for 24V runs

**Steps**:

1. Mount the 24V PSU. Connect AC mains input (with appropriate cord/plug). Verify 24V output with a multimeter before connecting anything.
2. Wire PSU output to the distribution block. This is your 24V bus.
3. Plan branch circuits from the distribution block:
   - Pedestal 1 trunk (24V+ and GND)
   - Pedestal 2 trunk (24V+ and GND)
   - Pedestal 3 trunk (24V+ and GND)
   - Tub internal lighting (FCOB SPI strips)
   - PATLITE (via fused branch)
4. Do NOT connect any loads yet — just verify 24V is present at each branch endpoint with a multimeter.

**Safety**:
- 24V DC won't shock you, but a short can melt wires and start fires. Fuse every branch.
- Use ferrules on stranded wire going into screw terminals.
- Keep AC mains wiring separate from DC wiring. The only AC is PSU input.

---

### Phase 2: Central Teensy RS-485 Backbone

**Goal**: Central Teensy can send and receive RS-485 messages on a shared bus.

**Parts**:
- MAX485 or MAX3485 transceiver module (TTL to RS-485)
- Twisted pair wire for the RS-485 bus (A/B lines)
- 120-ohm termination resistors (one at each end of the bus)
- Optional: shield/drain wire

**Wiring** (Central Teensy side):
| Teensy Pin | MAX485 Pin | Function |
|-----------|-----------|----------|
| Serial1 TX (pin 1) | DI | Data In (Teensy transmits) |
| Serial1 RX (pin 0) | RO | Receiver Out (Teensy receives) |
| Pin 7 (or any digital) | DE + RE (tied together) | TX enable (HIGH=transmit, LOW=receive) |

**RS-485 Bus**:
- A and B lines run from the central Teensy transceiver out to each pedestal trunk, daisy-chained.
- 120-ohm termination resistor across A/B at the central Teensy end and at the last pedestal.
- Optional bias resistors (470-1K) pulling A high and B low for idle state.

**Firmware changes to `tub_panel.ino`**:
- Add Serial1 initialization for RS-485 (9600 or 115200 baud)
- Add TX enable pin control (set HIGH before transmitting, LOW after)
- Implement master polling protocol:
  - Central Teensy polls each pedestal by address: `P<addr>?\n`
  - Pedestal responds: `P<addr>,B<0|1>,T<tof_mm>,H<halo_ack>\n`
  - Central Teensy sends commands: `P<addr>,H<pwm>,L<pattern>\n` (halo brightness, LED pattern)
- Forward pedestal telemetry to USB serial for the Mac app

**Testing**:
- Wire a single MAX485 module to the central Teensy.
- Loopback test: tie DI to RO, transmit and verify you receive the same bytes.
- Then connect to the first pedestal (Phase 3) for real two-device testing.

**App changes** (`HardwareInputController.swift`):
- Extend protocol to parse pedestal telemetry lines (e.g., `P1,B0,T45,H255`)
- Add `onPedestalUpdate` callback or published properties for pedestal state

---

### Phase 3: First Pedestal (End-to-End Prototype)

**Goal**: One complete pedestal — powered, sensing, lit, talking RS-485 — proving the full pattern before replicating.

**Parts (per pedestal)**:
- QT Py RP2040
- 24V to 5V buck converter module
- MAX485 or MAX3485 transceiver module
- VL6180X Time-of-Flight sensor (I2C)
- Logic-level N-channel MOSFET (e.g., IRLZ44N or IRL540N) for 24V halo LED
- 10K gate resistor
- RGBW NeoPixel strip/ring
- 24V white halo LED
- AutomationDirect button/switch (same contact block pattern as central panel)

**Power wiring**:
1. Trunk brings 24V+ and GND to the pedestal top.
2. 24V+ direct to halo LED (anode side, drain side through MOSFET to GND).
3. 24V+ and GND to buck converter input. Buck output (5V) powers QT Py, NeoPixels, ToF sensor, and MAX485.

**QT Py RP2040 wiring**:
| QT Py Pin | Connection | Notes |
|-----------|-----------|-------|
| 5V | Buck converter 5V out | Power |
| GND | Common ground (shared with 24V GND) | Critical: must share ground with Teensy |
| TX | MAX485 DI | RS-485 transmit |
| RX | MAX485 RO | RS-485 receive |
| Digital pin (e.g., A0) | MAX485 DE+RE | TX enable |
| SDA | VL6180X SDA | I2C data |
| SCL | VL6180X SCL | I2C clock |
| Digital pin (e.g., A1) | MOSFET gate (via 10K resistor) | Halo LED PWM control |
| Digital pin (e.g., A2) | NeoPixel data in | RGBW LED strip |
| Digital pin (e.g., A3) | Button/switch contact | With internal pull-up, to GND |

**MOSFET halo circuit**:
```
24V+ ──> Halo LED(+) ──> Halo LED(-) ──> MOSFET Drain
                                          MOSFET Source ──> GND
                                          MOSFET Gate <── 10K ──> QT Py pin
```
PWM on the gate controls halo brightness 0-100%.

**QT Py firmware** (CircuitPython or Arduino):
- On boot: initialize UART, I2C, NeoPixels, MOSFET PWM, button input
- Main loop (~50Hz):
  - Read button state (debounce)
  - Read VL6180X distance (mm) and ambient light
  - Listen for RS-485 poll from central Teensy
  - On poll: respond with button state, ToF reading, current halo state
  - On command: update halo PWM, update NeoPixel pattern/color
- Address set by hardcoded constant (1, 2, or 3) or solder jumper

**Testing**:
1. Power the buck converter from 24V, verify 5V output.
2. Flash QT Py with basic blink sketch, confirm it runs on buck power.
3. Wire VL6180X, run I2C scan, read distances.
4. Wire MOSFET + halo LED, test PWM brightness from QT Py.
5. Wire NeoPixels, run test pattern.
6. Wire MAX485, test RS-485 echo with central Teensy.
7. Run full firmware, verify poll/response cycle works.
8. Verify Mac app receives pedestal telemetry.

---

### Phase 4: Replicate Pedestals 2 and 3

**Goal**: All three pedestals on the RS-485 bus, individually addressable.

**Steps**:
1. Build pedestal 2 and 3 identical to pedestal 1.
2. Set address to 2 and 3 respectively.
3. Daisy-chain RS-485: Central Teensy → Pedestal 1 → Pedestal 2 → Pedestal 3. Termination resistor on Teensy end and Pedestal 3 end.
4. Verify central Teensy can poll all three and get individual responses.
5. Verify Mac app shows telemetry for all three pedestals.

---

### Phase 5: Tub Internal Lighting (FCOB SPI)

**Goal**: Three independently addressable FCOB SPI white LED strips inside the tub, with chasing patterns.

**Parts**:
- FCOB SPI LED strips (white, 3 cut sections)
- 24V to 5V buck converter (if controller needs 5V logic)
- SPI-capable controller — can use the central Teensy directly (SPI pins) or a dedicated controller

**Wiring**:
- FCOB SPI strips run on 24V power (from distribution block).
- SPI data/clock from central Teensy (or dedicated controller).
- Each strip section is individually addressable via SPI protocol.

**Firmware**:
- Add SPI initialization to central Teensy firmware.
- Implement lighting patterns: solid, chase, breathe, pulse-on-jolt, mode-reactive.
- Mac app sends lighting commands over USB serial, central Teensy relays to SPI strips.
- Or: central Teensy runs patterns autonomously based on current mode + model output.

**Testing**:
1. Power one strip section from 24V.
2. Connect SPI lines from Teensy, run test pattern.
3. Verify all three sections are independently controllable.
4. Integrate pattern control with mode changes.

---

### Phase 6: PATLITE

**Goal**: Signal tower tiers switch on/off in response to app state.

**Parts**:
- PATLITE tower (already have)
- 24V DIN PSU (or feed from main 24V distribution)
- Blue Sea fuse block (1A fused branch for PATLITE)
- N-channel MOSFETs for each tier (same pattern as halo LEDs)

**Wiring**:
- PATLITE common/power from fused 24V branch.
- Each tier wire switched by a MOSFET controlled from central Teensy.
- Unused flashing/buzzer wires: individually cap with heat shrink.

**Teensy pin allocation** (expand from current 5 pins):
| Teensy Pin | Function |
|-----------|----------|
| 8 | PATLITE tier 1 MOSFET gate |
| 9 | PATLITE tier 2 MOSFET gate |
| 10 | PATLITE tier 3 MOSFET gate |
| (etc.) | Additional tiers as needed |

**Firmware**:
- Add MOSFET output pin setup.
- Mac app sends PATLITE commands over USB: `L<tier>,<0|1>\n`
- Or: Teensy controls tiers autonomously based on mode/state.

**Testing**:
1. Wire one tier through a MOSFET.
2. Toggle from Teensy, verify tier lights up.
3. Wire remaining tiers.
4. Integrate with app state.

---

### Phase 7: App Integration for Full Telemetry

**Goal**: Mac app has full visibility and control of all hardware.

**Extend USB serial protocol** from Central Teensy:
```
M<mode>,J<0|1>                          # mode + jolt (existing)
P<addr>,B<0|1>,T<tof_mm>,H<pwm>        # pedestal telemetry
L<tier>,<0|1>                           # PATLITE state echo
S<strip>,<pattern_id>                   # tub lighting state echo
```

**App commands TO Teensy** (new, downstream):
```
H<addr>,<pwm>                           # set pedestal halo brightness
N<addr>,<r>,<g>,<b>,<w>,<pattern>       # set pedestal NeoPixel
L<tier>,<0|1>                           # set PATLITE tier
S<strip>,<pattern_id>                   # set tub FCOB pattern
```

**Swift changes**:
- Extend `HardwareInputController` to parse pedestal/PATLITE/lighting lines.
- Add write capability (send commands to Teensy over serial).
- New published properties for pedestal state (ToF readings, button states, halo/NeoPixel status).
- UI: pedestal status panel in ContentView showing ToF distance, connection state per pedestal.

---

## Parts Checklist

| Part | Qty | For |
|------|-----|-----|
| 24V DC PSU | 1 | Main power |
| Distribution block | 1 | 24V bus |
| Blue Sea fuse block | 1 | Branch protection |
| MAX485 transceiver module | 4 | 1 central + 3 pedestals |
| QT Py RP2040 | 3 | Pedestal controllers |
| 24V→5V buck converter | 3-4 | Pedestal power + tub lights |
| VL6180X ToF sensor | 3 | Pedestal sensing |
| Logic N-ch MOSFET (IRLZ44N) | 6-8 | 3 halos + PATLITE tiers |
| 10K resistors | 6-8 | MOSFET gates |
| 120-ohm resistors | 2 | RS-485 termination |
| RGBW NeoPixel strips | 3 | Pedestal lighting |
| 24V white halo LEDs | 3 | Pedestal halos |
| FCOB SPI white strips | 3 sections | Tub internal lighting |
| PATLITE tower | 1 | Signal tower |
| Twisted pair cable | ~20ft | RS-485 bus |
| 18-16 AWG wire | assorted | 24V power runs |
| Ferrules | assorted | Screw terminal connections |
| 4-conductor cable | 3 runs | Pedestal trunks (24V+, GND, A, B) |

---

## Architecture Diagram Reference

```
AC MAINS → 24V PSU → Distribution Block
                          ├── Pedestal 1 trunk (24V+, GND, RS-485 A, RS-485 B)
                          │     └── 24V→5V buck → QT Py RP2040
                          │           ├── Button input
                          │           ├── VL6180X ToF (I2C)
                          │           ├── MOSFET → 24V halo LED
                          │           ├── RGBW NeoPixels (5V)
                          │           └── MAX485 → RS-485 bus
                          │
                          ├── Pedestal 2 trunk (same)
                          ├── Pedestal 3 trunk (same)
                          │
                          ├── Tub FCOB SPI strips (24V, SPI from Teensy)
                          │
                          └── PATLITE (24V, fused, MOSFET-switched tiers)

Central Teensy 4.0
  ├── USB → Mac (mode/jolt + pedestal telemetry + commands)
  ├── 5 digital inputs (selector switch, 2 latched, 1 momentary)
  ├── Serial1 UART → MAX485 → RS-485 bus (master)
  ├── SPI → FCOB tub lighting
  └── Digital outputs → MOSFET gates → PATLITE tiers
```
