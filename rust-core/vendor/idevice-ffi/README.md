# Bindings for idevice

These bindings will try their best to stay up to date with the Rust library.
While jkcoxson is the only contributor, they will be maintained on a best-effort
basis.

## Local changes

- Build as an `rlib` so LocalStore's static library can re-export the C symbols
  without also producing an unused iOS `cdylib`.
- Gate the TCP and usbmuxd provider constructors with their existing Cargo
  features. LocalStore uses the RSD adapter directly and enables neither
  desktop transport.
- Split pairing-file/tunnel support from the mDNS pairing-host feature so the
  app does not link the unused `mdns-sd` implementation.
