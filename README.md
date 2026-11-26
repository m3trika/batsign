# BatSign

A personal build of BatSign, an on-device IPA signer based on Feather.

## Fully Local install setup

Fully Local installs use a private certificate authority (CA) made at build time
(`scripts/make-local-pki.sh`). Its certificates are only valid for
`batsign.backloop.dev`, a name that resolves to `127.0.0.1`. Set it up once:

1. Sign and install `BatSign.ipa` with your own certificate.
2. In BatSign, go to **Settings › Installation › Server & SSL › Export Trust Profile** and save the profile to Files.
3. Install it in **Settings › General › VPN & Device Management**.
4. Turn on **BatSign Local Installer CA** in **Settings › General › About › Certificate Trust Settings**.
5. Tap **Test Trust** in BatSign. It should say PASS.

If an install stays on *Ready*, your DNS is probably blocking `backloop.dev`
(Private Relay, a VPN or an ad-blocker DNS). Allowlist it.

## Building

```
git submodule update --init --recursive
make iphoneos
```

This produces `packages/BatSign.ipa` and needs Xcode 26 or newer. In GitHub Actions,
`release.yml` builds the IPA and adds a SHA-256 checksum and a build provenance
attestation. Set the secrets `BATSIGN_CA_CERT_B64` and `BATSIGN_CA_KEY_B64` to keep
the same CA across builds.

## License

GPL-3.0, see [LICENSE](LICENSE). Based on Feather by claration, Nyasami and llsc12.
It uses Zsign and IDeviceKit by khcrysalis.
