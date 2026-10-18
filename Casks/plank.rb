cask "plank" do
  version :latest
  sha256 :no_check

  url "https://github.com/imkerberos/Plank/releases/latest/download/Plank-latest-macos-universal.dmg"
  name "Plank"
  desc "XFCE-style panel and Dock replacement for macOS"
  homepage "https://github.com/imkerberos/Plank"

  depends_on macos: :sonoma

  app "Plank.app"
end
