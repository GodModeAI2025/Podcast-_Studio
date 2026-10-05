# CLAME — vendored LAME 3.100

* Source: https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz
  (sha256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`)
* Only `include/lame.h` and `libmp3lame/*.{c,h}` are vendored (encoder only, no mpglib
  decoder, no SIMD/NASM paths). `libmp3lame/config.h` and `include/module.modulemap` are
  hand-written for SwiftPM; LAME sources are unmodified.
* Builds for iOS (arm64), macOS (arm64 + x86_64) and Linux (CI / `pstool`).

## License

LAME is licensed under the **GNU LGPL 2.0 or later** (`COPYING.LGPL`, `LICENSE.lame`).
MP3 patents have expired, but the LGPL still applies: when distributing a statically linked
app (App Store), you must enable users to relink against a modified LAME (e.g. by providing
the app's object files on request) or ship LAME as a separate dynamic framework. Clarify this
before release — see `docs/ARCHITECTURE.md`, open point O4.
