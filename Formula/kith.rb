# Build-from-source Homebrew formula.
#
# Phase A (current) — formula lives in this repo, tap the source directly:
#
#   brew tap supaku/kith https://github.com/supaku/kith
#   brew install kith
#
# Phase B (future) — this formula moves to `supaku/homebrew-tools` and
# becomes a bottled signed/notarized binary pulled from the v*.*.*
# GitHub Release. After that migration, install simplifies to:
#
#   brew tap supaku/tools
#   brew install kith
#
# Until then, Homebrew compiles locally with the user's Swift toolchain
# (Xcode CLI tools or a vanilla Swift install), which sidesteps signing
# entirely.
class Kith < Formula
  desc "macOS CLI bridging Apple Contacts and iMessage for terminal users + AI agents"
  homepage "https://github.com/supaku/kith"
  url "https://github.com/supaku/kith.git",
      tag:      "v0.1.1",
      revision: ""    # filled in by `brew bump-formula-pr` on releases
  license "MIT"
  head "https://github.com/supaku/kith.git", branch: "main"

  depends_on :macos => :sonoma
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build",
           "--disable-sandbox",
           "-c", "release",
           "--arch", Hardware::CPU.arch.to_s
    bin.install ".build/release/kith"
  end

  test do
    assert_match "kith", shell_output("#{bin}/kith version")
    assert_match version.to_s, shell_output("#{bin}/kith version")

    # Manifest must parse as JSON and list the killer command.
    manifest = shell_output("#{bin}/kith tools manifest --style kith")
    assert_match "history", manifest
    assert_match "find", manifest
  end
end
