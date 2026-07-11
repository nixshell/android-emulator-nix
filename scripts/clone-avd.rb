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

def rewrite_ini_values(path, values)
  lines = File.readlines(path, chomp: true).map do |line|
    key = line.split("=", 2).first&.strip
    values.key?(key) ? "#{key}=#{values[key]}" : line
  end
  File.write(path, lines.join("\n") + "\n")
end

CLONE_NAME_KEYS = ["AvdId", "avd.ini.displayname", "avd.name"].freeze
EPHEMERAL_ENTRIES = ["snapshots", "hardware-qemu.ini", "tmpAdbCmds"].freeze

options = {}

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Clone an AVD, including its current userdata, so two emulators can run
    the same state side by side (e.g. before/after a refactoring). Snapshots
    and lock files are not carried over: snapshots record absolute paths into
    the source directory, and stale locks block booting.

    Usage: #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} --avd SOURCE --name NEW_NAME [--force]
  USAGE

  parser.on("--avd NAME", "Source AVD name") do |value|
    options[:avd] = value
  end
  parser.on("--name NAME", "Name of the new AVD") do |value|
    options[:name] = value
  end
  parser.on("--force", "Overwrite an existing AVD with the new name") do
    options[:force] = true
  end
  parser.on("--avd-home PATH", "Override the AVD home directory") do |value|
    options[:avd_home] = File.expand_path(value)
  end
end.parse!

abort "--avd is required" unless options[:avd]
abort "--name is required" unless options[:name]
unless options[:name].match?(/\A[\w.-]+\z/)
  abort "Invalid --name #{options[:name].inspect}; use letters, digits, '.', '_' or '-'"
end
abort "--name must differ from --avd" if options[:name] == options[:avd]

avd_home = options[:avd_home] || ENV["ANDROID_AVD_HOME"] || File.expand_path("~/.android/avd")
source_ini = File.join(avd_home, "#{options[:avd]}.ini")
abort "Missing AVD ini: #{source_ini}" unless File.exist?(source_ini)

source_dir = read_ini(source_ini)["path"] || File.join(avd_home, "#{options[:avd]}.avd")
abort "Missing AVD directory: #{source_dir}" unless Dir.exist?(source_dir)

target_ini = File.join(avd_home, "#{options[:name]}.ini")
target_dir = File.join(avd_home, "#{options[:name]}.avd")
[target_ini, target_dir].each do |path|
  next unless File.exist?(path)
  abort "Already exists: #{path} (use --force to overwrite)" unless options[:force]

  FileUtils.rm_rf(path)
end

running_locks = Dir.glob(File.join(source_dir, "*.lock"))
unless running_locks.empty?
  warn "Warning: #{options[:avd]} has lock files (#{running_locks.map { |lock| File.basename(lock) }.join(", ")}); " \
       "clone with the emulator stopped for a consistent copy."
end

FileUtils.cp_r(source_dir, target_dir)
EPHEMERAL_ENTRIES.each { |entry| FileUtils.rm_rf(File.join(target_dir, entry)) }
Dir.glob(File.join(target_dir, "*.lock")).each { |lock| FileUtils.rm_rf(lock) }

ini_values = read_ini(source_ini)
ini_values["path"] = target_dir
ini_values["path.rel"] = "avd/#{options[:name]}.avd"
File.write(target_ini, ini_values.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n")

config_path = File.join(target_dir, "config.ini")
if File.exist?(config_path)
  present = read_ini(config_path).keys & CLONE_NAME_KEYS
  rewrite_ini_values(config_path, present.to_h { |key| [key, options[:name]] })
end

puts "Cloned #{options[:avd]} -> #{options[:name]} (#{target_dir})"
puts "Run both: emulator -avd #{options[:avd]} -port 5554 & emulator -avd #{options[:name]} -port 5556 &"
