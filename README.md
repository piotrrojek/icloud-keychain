# icloud-keychain

CLI tool to manage macOS Keychain items with optional iCloud sync. Written in Zig.

## Install

```bash
brew tap piotrrojek/tap
brew install piotrrojek/tap/icloud-keychain
```

Or download the `.pkg` from [Releases](https://github.com/piotrrojek/icloud-keychain/releases).

## Usage

```
icloud-keychain set [--sync] <service> <account> <password>
icloud-keychain get <service> <account>
icloud-keychain delete <service> <account>
icloud-keychain list [service-filter]
```

`--sync` enables iCloud Keychain sync (requires entitlements). Without it, secrets are stored in the local login keychain.

## Zsh autocomplete

The Homebrew install and the `.pkg` installer both drop a zsh completion file into a standard `site-functions` directory. Service and account names are completed live from `icloud-keychain list` — try `icloud-keychain get <TAB>`.

By default, only entries whose service name contains a `/` are offered (e.g. `dotfiles/github-token`). To include system keychain entries too:

```zsh
zstyle ':icloud-keychain:include-system' enabled yes
```

If completion doesn't activate after install, make sure your shell loads completions (`autoload -Uz compinit && compinit`) and that the Homebrew completions path is on `fpath`.

## Tutorial

Full walkthrough: [Building an iCloud Keychain CLI in Zig](https://piotrrojek.io/blog/icloud-keychain-cli-zig/)

## License

MIT
