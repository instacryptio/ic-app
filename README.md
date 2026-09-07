# Instacrypt App


### 👁️‍🗨️ Summary

A GUI desktop and mobile application for Instacrypt -- A friendlier post-quantum ready encryption assistant.


### 🪶 Features
---

- Post-quantum hybrid encryption (X25519 + ML-KEM-768)
- Digital signatures (ML-DSA-65 / FIPS 204)
- ICFX output formats
- Identity management (multiple identities)
- Contact management with lock (public key) storage
- Group management (user defined groups of contacts)
- OS keychain integration with file-based fallback
- Identity (key + lock + metadata) import/export with passphrase protection
- Lock (public key) sharing - file and animated QR
- Profile backup/restore
- Optional cloud sync (contacts, groups, settings, and identity-key roaming) with TOTP and hardware-key (WebAuthn) 2FA
- Securely sharing files with contacts via Instacrypt Cloud w/ a [paid plan](https://instacrypt.io/pricing).


### 🖥 OS Support
---

- Linux
- macOS
- Windows
- Android (APK + Google Play Store coming soon)
- iOS (Coming soon)


### 🔌 Installation

See [Installation Guide](https://instacrypt.io/docs/installation)


### 📖 Usage
---

See [Documentation](https://instacrypt.io/docs/usage)


### ⚗️ Tech Stack
---

This application was built with [Go](https://go.dev/), the [icfx](https://github.com/instacryptio/icfx/) cryptographic library, and [Flutter](https://flutter.dev) using [flugo](https://github.com/hkdb/flugo). 


## 📜 License
---

[Apache License 2.0](LICENSE) — Copyright 2026 3DF Limited. See [`NOTICE`](NOTICE)
for attribution.


### 🗺️ Future Features
---

- Auto-detect Instacrypt encrypted USB key that stores your identities.


### 💰 Support
---

This application will remain free and open source forever. The overall project hopes to remain sustainable via the Instacrypt Cloud paid plans.

Otherwise, you can support this project simply by giving our repo a star or buying us a coffee:

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/yellow_img.png)](https://www.buymeacoffee.com/3dfosi)

Be sure to mention "Instacrypt" in the "Say something nice..." field so we know what project the coffee is for. 🙏

