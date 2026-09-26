# lil passwords

A lil clone of Apple Passwords for macOS. It includes a local CLI (`lilpw`) and an MCP server so agents can use your passwords.

> Early days: this is a scaffold. Follow along in the [Linear project](https://linear.app/851/project/lil-passwords-ceedf3416b9d).

- **Platform:** macOS 13 Ventura or later, Swift 6, AppKit
- **Storage:** an end-to-end encrypted vault that stays on your Mac. The MVP is fully local: no accounts, no server, no iCloud.
- **Agents:** `lilpw` and `lilpw mcp` give local agents access to your passwords while the vault is unlocked. You can turn this off, and every access is logged.

## Layout

| Path | What |
| --- | --- |
| `App/` | Lil Passwords.app (AppKit) |
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

Builds are unsigned by default. To sign with your team, create `Config/Local.xcconfig`, which is gitignored:

```
DEVELOPMENT_TEAM = YOURTEAMID
CODE_SIGN_IDENTITY = Apple Development
```

## License

MIT
