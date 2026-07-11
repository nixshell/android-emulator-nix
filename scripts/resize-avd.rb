#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p ruby

require "fileutils"
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

WIPE_TARGETS = [
  "userdata-qemu.img",
  "userdata-qemu.img.qcow2",
  "cache.img",
  "cache.img.qcow2",
  "snapshots",
].freeze

options = {}

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Change an AVD's disk sizes in its config.ini. A grown data partition only
    takes effect once its disk image is rebuilt; pass --wipe to delete the
    built userdata/cache images and snapshots so the next boot recreates them
    at the new size. Wiping erases the AVD's data.

    Usage: #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} --avd NAME [--data-size SIZE] [--sdcard-size SIZE] [--wipe]
  USAGE

  parser.on("--avd NAME", "AVD name to resize") do |value|
    options[:avd] = value
  end
  parser.on("--data-size SIZE", "New disk.dataPartition.size, e.g. 16G") do |value|
    options[:data_size] = value
  end
  parser.on("--sdcard-size SIZE", "New sdcard.size, e.g. 1G") do |value|
    options[:sdcard_size] = value
  end
  parser.on("--wipe", "Delete built disk images and snapshots so new sizes take effect") do
    options[:wipe] = true
  end
  parser.on("--avd-home PATH", "Override the AVD home directory") do |value|
    options[:avd_home] = File.expand_path(value)
  end
end.parse!

abort "--avd is required" unless options[:avd]
unless options[:data_size] || options[:sdcard_size] || options[:wipe]
  abort "Nothing to do: pass --data-size, --sdcard-size, and/or --wipe"
end

if options[:data_size] && !options[:data_size].match?(/\A\d+\s*[KMGT]B?\z/i)
  abort "Invalid --data-size #{options[:data_size].inspect}; expected something like 16G"
end
if options[:sdcard_size] && !options[:sdcard_size].match?(/\A\d+\s*[KMGT]B?\z/i)
  abort "Invalid --sdcard-size #{options[:sdcard_size].inspect}; expected something like 1G"
end

avd_home = options[:avd_home] || ENV["ANDROID_AVD_HOME"] || File.expand_path("~/.android/avd")
ini_path = File.join(avd_home, "#{options[:avd]}.ini")
abort "Missing AVD ini: #{ini_path}" unless File.exist?(ini_path)

avd_dir = read_ini(ini_path)["path"] || File.join(avd_home, "#{options[:avd]}.avd")
config_path = File.join(avd_dir, "config.ini")
abort "Missing config.ini: #{config_path}" unless File.exist?(config_path)

config = read_ini(config_path)
changes = {}
changes["disk.dataPartition.size"] = options[:data_size] if options[:data_size]
changes["sdcard.size"] = options[:sdcard_size] if options[:sdcard_size]

changes.each do |key, value|
  puts "#{key}: #{config[key] || "(unset)"} -> #{value}"
end
set_config_values(config_path, changes) unless changes.empty?

if options[:wipe]
  WIPE_TARGETS.each do |target|
    path = File.join(avd_dir, target)
    next unless File.exist?(path)

    FileUtils.rm_rf(path)
    puts "Removed #{path}"
  end
  puts "Wiped: the next boot rebuilds the disk images at the configured sizes."
elsif options[:data_size]
  puts "Existing userdata keeps its old size until wiped: " \
       "re-run with --wipe, or boot once with 'emulator -avd #{options[:avd]} -wipe-data'."
end
