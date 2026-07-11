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

options = { avds: [], sets: {}, gets: [] }

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Read or set config.ini values across AVDs (all by default). Changes take
    effect on the AVD's next cold boot.

    Examples:
      #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} --set hw.multi_display_window=no
      #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} --avd a33a --set hw.multi_display_window=yes
      #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} --get hw.multi_display_window --get hw.lcd.width

    Usage: #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} [--avd NAME]... (--set KEY=VALUE | --get KEY)...
  USAGE

  parser.on("--set KEY=VALUE", "Set a config.ini key (repeatable)") do |pair|
    key, value = pair.split("=", 2)
    abort "Invalid --set #{pair.inspect}; expected KEY=VALUE" if key.nil? || key.empty? || value.nil?
    options[:sets][key] = value
  end
  parser.on("--get KEY", "Show a config.ini key (repeatable)") do |key|
    options[:gets] << key
  end
  parser.on("--avd NAME", "Limit to the named AVD (repeatable, default: all AVDs)") do |name|
    options[:avds] << name
  end
  parser.on("--avd-home PATH", "Override the AVD home directory") do |path|
    options[:avd_home] = File.expand_path(path)
  end
end.parse!

abort "Nothing to do: pass --set and/or --get" if options[:sets].empty? && options[:gets].empty?

avd_home = options[:avd_home] || ENV["ANDROID_AVD_HOME"] || File.expand_path("~/.android/avd")
abort "AVD home not found: #{avd_home}" unless Dir.exist?(avd_home)

matched = []

Dir.glob(File.join(avd_home, "*.ini")).sort.each do |ini_path|
  name = File.basename(ini_path, ".ini")
  next unless options[:avds].empty? || options[:avds].include?(name)

  matched << name
  avd_dir = read_ini(ini_path)["path"] || File.join(avd_home, "#{name}.avd")
  config_path = File.join(avd_dir, "config.ini")
  unless File.exist?(config_path)
    puts "#{name}: skipped (missing #{config_path})"
    next
  end

  config = read_ini(config_path)

  options[:gets].each do |key|
    puts "#{name}: #{key}=#{config[key] || "(unset)"}"
  end

  changes = options[:sets].reject { |key, value| config[key] == value }
  changes.each do |key, value|
    puts "#{name}: #{key}: #{config[key] || "(unset)"} -> #{value}"
  end
  unchanged = options[:sets].size - changes.size
  puts "#{name}: #{unchanged} value(s) already set" if unchanged.positive?
  set_config_values(config_path, changes) unless changes.empty?
end

if matched.empty?
  abort options[:avds].empty? ? "No AVDs found in #{avd_home}" : "No AVDs matched #{options[:avds].join(", ")}"
end

missing = options[:avds] - matched
abort "No AVD named: #{missing.join(", ")}" unless missing.empty?
