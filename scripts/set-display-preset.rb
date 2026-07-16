#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p ruby

require "optparse"

def read_ini(path)
  File.readlines(path, chomp: true).each_with_object({}) do |line, values|
    next if line.strip.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    next unless key && value

    values[key.strip] = value.strip
  end
end

def set_config_values(path, values)
  lines = File.readlines(path, chomp: true)
  values.each do |key, value|
    index = lines.index { |line| line.split("=", 2).first&.strip == key }
    if index
      lines[index] = "#{key}=#{value}"
    else
      lines << "#{key}=#{value}"
    end
  end
  File.write(path, lines.join("\n") + "\n")
end

# The a33/a33b baseline: primary display 1920x1080 @160dpi, second display
# 3840x1100 @213dpi. `avdmanager --device` profiles only seed an initial
# config.ini; they don't guarantee this resolution, and separately-created
# AVDs have drifted from it before (environment.*/hw.lcd.* left at the
# profile default while hw.display1/2.* were edited, or vice versa).
DISPLAY_PRESET = {
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
}.freeze

options = { avds: [] }

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Apply the a33/a33b display preset (primary 1920x1080 @160dpi, second
    display 3840x1100 @213dpi) to one or more AVDs' config.ini. Changes take
    effect on the AVD's next cold boot.

    Usage: #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} --avd NAME [--avd NAME]...
  USAGE

  parser.on("--avd NAME", "AVD to update (repeatable, required)") do |name|
    options[:avds] << name
  end
  parser.on("--avd-home PATH", "Override the AVD home directory") do |path|
    options[:avd_home] = File.expand_path(path)
  end
end.parse!

abort "--avd is required (repeatable)" if options[:avds].empty?

avd_home = options[:avd_home] || ENV["ANDROID_AVD_HOME"] || File.expand_path("~/.android/avd")
abort "AVD home not found: #{avd_home}" unless Dir.exist?(avd_home)

options[:avds].each do |name|
  ini_path = File.join(avd_home, "#{name}.ini")
  abort "Missing AVD ini: #{ini_path}" unless File.exist?(ini_path)

  avd_dir = read_ini(ini_path)["path"] || File.join(avd_home, "#{name}.avd")
  config_path = File.join(avd_dir, "config.ini")
  abort "Missing config.ini: #{config_path}" unless File.exist?(config_path)

  config = read_ini(config_path)
  changes = DISPLAY_PRESET.reject { |key, value| config[key] == value }
  changes.each do |key, value|
    puts "#{name}: #{key}: #{config[key] || "(unset)"} -> #{value}"
  end
  unchanged = DISPLAY_PRESET.size - changes.size
  puts "#{name}: #{unchanged} value(s) already set" if unchanged.positive?
  set_config_values(config_path, changes) unless changes.empty?
end
