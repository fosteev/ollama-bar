# The tap lives in this repository rather than a separate homebrew-tap, so the release workflow
# can point it at the archive it just built instead of leaving a checksum to paste by hand:
#
#   brew tap fosteev/ollama-bar https://github.com/fosteev/ollama-bar
#   brew trust --cask fosteev/ollama-bar/ollama-bar
#   brew install --cask ollama-bar
#
# The trust line is Homebrew 6 refusing to load casks from unofficial taps until told to.
#
# `version` and `sha256` below are rewritten by .github/workflows/release.yml on every tag.
cask "ollama-bar" do
  version "0.1.0"
  sha256 "a8a9e369b89641d9fb552779acc65c5fb0d7b9f8341a52b90d2202ebfe3f31df"

  url "https://github.com/fosteev/ollama-bar/releases/download/v#{version}/OllamaBar-#{version}.zip"
  name "ollama-bar"
  desc "Menu bar app that shows what the local Ollama server is doing"
  homepage "https://github.com/fosteev/ollama-bar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "OllamaBar.app"

  # Settings and history are plain files under one directory — nothing in UserDefaults to sweep up.
  zap trash: [
    "~/.ollamabar",
    "~/Library/Saved Application State/com.fosteev.ollamabar.savedState",
  ]

  caveats do
    <<~CAVEATS
      The signature is ad-hoc: there is no Developer ID to notarize with yet, so macOS asks once
      on first launch. Approve it under System Settings → Privacy & Security → Open Anyway.
    CAVEATS
  end
end
