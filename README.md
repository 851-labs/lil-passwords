# lil passwords

A lil clone of Apple Passwords for macOS. It includes a local CLI (`lilpw`) and an MCP server so agents can use your passwords.

> Early days: this is a scaffold. Follow along in the [Linear project](https://linear.app/851/project/lil-passwords-ceedf3416b9d).

- **Platform:** macOS 13 Ventura or later, Swift 6, AppKit
- **Storage:** an end-to-end encrypted vault that stays on your Mac. The MVP is fully local: no accounts, no server, no iCloud.
- **Agents:** `lilpw` and `lilpw mcp` give local agents access to your passwords while the vault is unlocked. You can turn this off, and every access is logged.

## Layout

| Path | What |
| --- | --- |
| `App/` | lil passwords.app (AppKit) |
| `Agent/` | `LilPasswordsAgent`, the login-item helper that owns the unlocked vault and serves XPC |
| `CLI/` | `lilpw`, the command-line tool and MCP server |
| `Packages/LilPasswordsKit/` | Shared core: model, vault, crypto, TOTP, generator |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec, the source of truth for `LilPasswords.xcodeproj` |

## Building

Requirements: Xcode 16+ and XcodeGen (`brew install xcodegen`).

```sh
make project   # regenerate LilPasswords.xcodeproj after changing project.yml
make build     # build the app, helper, and CLI (unsigned)
make test      # run LilPasswordsKit tests
make format    # swift-format
```

Builds are ad-hoc signed by default, so anyone can build (CI does this too). lil passwords ships under Alexandru Turcanu's Apple Developer team (`WH4QW9ND3J`, set in `Config/Base.xcconfig`). To sign with a real certificate, create the gitignored `Config/Local.xcconfig`:

```
CODE_SIGN_IDENTITY = Apple Development
// Contributors on another team can also override:
// DEVELOPMENT_TEAM = YOURTEAMID
```

Release signing (Developer ID) and notarization are covered in `docs/releasing.md`.

## License

MIT
