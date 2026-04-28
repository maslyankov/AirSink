# Homebrew cask

`airsink.rb` is the source of truth for the Homebrew installation path.

## Distributing as a tap

Brew taps live in repos named `homebrew-<tap>`. To publish:

1. Create a new public repo: `maslyankov/homebrew-airsink`
2. Copy `airsink.rb` from this directory into the new repo at `Casks/airsink.rb`
3. After each release, replace `sha256 :no_check` with the DMG checksum the
   release workflow prints, and bump `version`

Users then install with:

```sh
brew tap maslyankov/airsink
brew install --cask airsink
```

## One-off install (no tap)

```sh
brew install --cask https://raw.githubusercontent.com/maslyankov/AirSink/main/Casks/airsink.rb
```
