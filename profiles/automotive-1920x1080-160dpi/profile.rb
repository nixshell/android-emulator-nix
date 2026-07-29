# frozen_string_literal: true

# Complete setup definition consumed by the generic setup-avd and
# set-display-preset commands.
AVD_SETUP_PROFILE = {
  name: "automotive-1920x1080-160dpi",
  package: "system-images;android-33;android-automotive;x86_64",
  seed_device: "automotive_1080p_landscape",
  device_profile: File.expand_path("device.xml", __dir__),
  device: {
    id: "automotive_1920x1080_160dpi",
    manufacturer: "Local",
  }.freeze,
  apply_command: ["set-display-preset"].freeze,
  avd_config: {
    "environment.width" => "1920",
    "environment.height" => "1080",
    "hw.lcd.width" => "1920",
    "hw.lcd.height" => "1080",
    "hw.lcd.density" => "160",
    "hw.display1.width" => "1920",
    "hw.display1.height" => "1080",
    "hw.display1.density" => "160",
    "hw.display1.flag" => "1035",
    "hw.display1.xOffset" => "0",
    "hw.display1.yOffset" => "0",
    "hw.display2.width" => "3840",
    "hw.display2.height" => "1100",
    "hw.display2.density" => "213",
    "hw.display2.flag" => "0",
  }.freeze,
}.freeze
