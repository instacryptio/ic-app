# CHANGELOG

**v0.1.3 - 09-23-2026**

- Bumped [icfx](https://github.com/instacryptio/icfx/releases) to v0.1.7
- Bumped [flugo](https://github.com/hkdb/flugo/releases) to v0.2.5
- A failed signature now asks "Do you still want to decrypt it?" before anything is written, for local decrypts and received shares alike; a share is consumed only if kept
- Unknown senders and failed signatures are reported distinctly in the result dialog


**v0.1.2 - 09-18-2026**

- Bumped flugo to v0.2.2 (macOS codesign fix which fixes hw key)


**v0.1.1 - 09-15-2026**

- Bumped flugo to v0.2.1 (macOS & AppImage fixes)
- Android build workflow fix


**v0.1.0 - 09-12-2026**

- Initial commit
- Finalized Github actions
- Minor cleanups
- Bumped flugo to v0.1.13
- Bumped icfx to v0.1.6
- Added instacryptio/go-libfido2 for cross-platform builds
- Signed Android builds + AAB


