module github.com/instacryptio/ic-app/backend

go 1.26.6

require (
	github.com/awnumar/memguard v0.23.0
	github.com/hkdb/flugo v0.1.13
	github.com/instacryptio/icfx v0.1.6
)

require (
	al.essio.dev/pkg/shellescape v1.5.1 // indirect
	filippo.io/age v1.3.1 // indirect
	filippo.io/hpke v0.4.0 // indirect
	github.com/AndroidGoLab/jni v0.0.8 // indirect
	github.com/BurntSushi/toml v1.6.0 // indirect
	github.com/awnumar/memcall v0.4.0 // indirect
	github.com/cloudflare/circl v1.6.3 // indirect
	github.com/danieljoos/wincred v1.2.2 // indirect
	github.com/ebfe/scard v0.0.0-20241214075232-7af069cabc25 // indirect
	github.com/fxamacker/cbor/v2 v2.9.2 // indirect
	github.com/godbus/dbus/v5 v5.1.0 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/keybase/go-keychain v0.0.1 // indirect
	github.com/keys-pub/go-libfido2 v1.5.4-0.20251021061633-bf2d0535e75c // indirect
	github.com/makiuchi-d/gozxing v0.1.1 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	github.com/skip2/go-qrcode v0.0.0-20200617195104-da1b6568686e // indirect
	github.com/sstallion/go-hid v0.15.0 // indirect
	github.com/x448/float16 v0.8.4 // indirect
	github.com/zalando/go-keyring v0.2.6 // indirect
	golang.org/x/crypto v0.50.0 // indirect
	golang.org/x/sys v0.43.0 // indirect
	golang.org/x/text v0.36.0 // indirect
	golang.org/x/xerrors v0.0.0-20200804184101-5ec99f83aff1 // indirect
)

// go-libfido2's upstream Windows build links a STALE libfido2 VENDORED in the
// module (missing the touch API newer code calls). Our fork of the exact pinned
// commit (keys-pub master bf2d0535) switches Windows to system libfido2 via
// pkg-config and drops the vendored dir; darwin/linux + the API are untouched.
// Replaces don't propagate from icfx (main-module only), so it lives here;
// ic-cli needs the same at its next release.
replace github.com/keys-pub/go-libfido2 => github.com/instacryptio/go-libfido2 v1.5.4-instacrypt.2
