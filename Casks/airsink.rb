cask "airsink" do
  version "0.1.0"
  sha256 :no_check  # Replace with the actual sha256 once a release is cut

  url "https://github.com/maslyankov/AirSink/releases/download/v#{version}/AirSink-#{version}.dmg"
  name "AirSink"
  desc "Windowed AirPlay screen mirroring for iPhone and iPad"
  homepage "https://github.com/maslyankov/AirSink"

  depends_on macos: ">= :ventura"
  depends_on formula: "gstreamer"

  app "AirSink.app"

  zap trash: [
    "~/Library/Preferences/com.maslyankov.airsink.plist",
  ]
end
