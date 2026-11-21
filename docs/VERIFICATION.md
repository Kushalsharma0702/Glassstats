# Verification

The test suite covers CPU counter deltas and wraparound, memory accounting, network rate and baseline resets, host CPU and RAM, process identification, and real TCP and UDP sockets. The runtime smoke check validates application behavior with live samples and prints average process CPU usage and peak resident memory.

## Local release verification

The build ran on Apple Silicon with macOS 26.6, Swift 6.3.3, and the macOS 26.5 SDK. The Universal app and embedded extension contain arm64 and x86_64 slices. The extracted ZIP passed strict code-signature verification and SHA-256 verification.

The 0.2.0 suite passed ten tests, including four real TCP/UDP loopback combinations, a confirmed SIGTERM sent only to a disposable listener, an actual HTTP request to a test-owned Unix socket, and inactive sampler scheduling. The GUI smoke check exercised the borderless clear panel, real telemetry, configured card visibility and sampling demand, Settings, Ports, and Docker.

| 0.2.0 mode | CPU usage relative to one core | Observation |
| --- | ---: | ---: |
| Standard dashboard | 4.26% | 60.0 seconds |
| Low Power dashboard | 0.96% | 15.3 seconds |
| Menu bar only | 0.23% | 10.6 seconds |

Peak resident memory was 132.9 MB. The preceding 0.1.0 check measured 3.08% for the dashboard and 1.51% for menu-bar-only. These measurements include the app process and vary with visibility, enabled modules, and workload.

The 0.2.0 revision follows the supplied desktop screenshot. Its light and dark documentation images render the dashboard offscreen with live measurements and alpha transparency. The installed Docker Engine was unreachable during verification. The available-container state was exercised through an Engine API fixture over a local Unix socket.

## Release checks still to run

The local archive uses an ad-hoc signature. Developer ID signing, notarization, and live desktop widget delivery with a signed App Group need a release signing identity. The Intel and older macOS builds also need a runtime pass on those systems. In a GUI session, check these interactions in addition to the automated smoke test.

- Toggle the dashboard from the menu bar and global shortcut, move and resize it, then relaunch to check restoration.
- Move the dashboard across displays. Disconnect a display and check that the dashboard returns to a connected screen.
- Check dark and light appearances, increased contrast, reduced motion and reduced transparency. Navigate the buttons and inspectors using VoiceOver and the keyboard.
- On a macOS 14 or 15 machine, exercise the material fallback. On macOS 26, inspect Liquid Glass against both light and dark wallpapers.
- Add widgets to the desktop in a signed App Group build. Check refresh, stale readings, and links after quitting and relaunching GlassStats.
- Measure idle and dashboard-visible usage on both architectures. Use Instruments Time Profiler or Activity Monitor when available.
