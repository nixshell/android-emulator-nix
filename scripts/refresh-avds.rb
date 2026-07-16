#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p ruby

require "optparse"
require "shellwords"

def read_ini(path)
  File.readlines(path, chomp: true).each_with_object({}) do |line, values|
    next if line.strip.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    next unless key && value

    values[key.strip] = value.strip
  end
end

def package_from_sysdir(sysdir)
  sysdir.sub(%r{/+\z}, "").tr("/", ";")
end

IMAGE_PATH_KEYS = [
  "kernel.path",
  "disk.ramdisk.path",
  "disk.systemPartition.initPath",
  "disk.vendorPartition.initPath",
].freeze

def recorded_image_paths(hardware_path)
  read_ini(hardware_path).select do |key, value|
    value.start_with?("/") && (IMAGE_PATH_KEYS.include?(key) || value.include?("system-images/"))
  end.values
end

def stale_recorded_path?(path, current_real)
  return true unless File.exist?(path)

  File.realpath(File.dirname(path)) != current_real
rescue Errno::ENOENT
  true
end

FULL_COMPARE_LIMIT = 16 * 1024 * 1024

def dirs_equivalent?(a, b)
  entries = Dir.children(a).sort
  return false unless entries == Dir.children(b).sort

  entries.all? do |entry|
    path_a = File.join(a, entry)
    path_b = File.join(b, entry)
    if File.directory?(path_a) || File.directory?(path_b)
      File.directory?(path_a) && File.directory?(path_b) && dirs_equivalent?(path_a, path_b)
    elsif File.size(path_a) != File.size(path_b)
      false
    elsif File.size(path_a) <= FULL_COMPARE_LIMIT
      File.binread(path_a) == File.binread(path_b)
    else
      true
    end
  end
end

def same_image_elsewhere?(recorded, current_real)
  old_dirs = recorded.map do |path|
    File.realpath(File.dirname(path))
  rescue Errno::ENOENT
    return false
  end
  old_dirs.uniq.all? { |old_dir| dirs_equivalent?(old_dir, current_real) }
end

PRESERVED_CONFIG_KEYS = [
  "disk.dataPartition.size",
  "hw.multi_display_window",
  "environment.width",
  "environment.height",
].freeze
PRESERVED_CONFIG_PREFIXES = ["hw.display", "hw.lcd."].freeze

def preserved_config(config)
  config.select do |key, _|
    PRESERVED_CONFIG_KEYS.include?(key) || PRESERVED_CONFIG_PREFIXES.any? { |prefix| key.start_with?(prefix) }
  end
end

def sdcard_argument(config)
  value = config["sdcard.size"]
  return nil unless value

  compact = value.gsub(/\s+/, "").sub(/B\z/i, "")
  compact.match?(/\A\d+[KMG]\z/i) ? compact : nil
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

def recreate_avd(name, package, device, sdcard)
  command = ["avdmanager", "create", "avd", "--force", "--name", name, "--package", package]
  command += ["--device", device] if device
  command += ["--sdcard", sdcard] if sdcard
  output = IO.popen(command, "r+", err: [:child, :out]) do |io|
    io.puts "no"
    io.close_write
    io.read
  end
  raise "Command failed: #{command.shelljoin}\n#{output}" unless $?.success?
end

options = { apply: false, only: [] }

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Find AVDs whose data was built from a system image that is no longer the
    one provided by the current dev shell, and recreate them against the
    current image. Recreating wipes the AVD's userdata and snapshots.

    Run inside a dev shell (needs ANDROID_SDK_ROOT and avdmanager on PATH).
    Runs as a dry run by default: nothing is changed without --apply.

    Usage: #{File.basename(__FILE__)} [options]
  USAGE

  parser.on("--apply", "Recreate stale AVDs (wipes their data)") do
    options[:apply] = true
  end
  parser.on("--only NAME", "Limit to the named AVD (repeatable)") do |name|
    options[:only] << name
  end
  parser.on("--avd-home PATH", "Override the AVD home directory") do |path|
    options[:avd_home] = File.expand_path(path)
  end
end.parse!

sdk_root = ENV["ANDROID_SDK_ROOT"]
abort "ANDROID_SDK_ROOT is not set; run inside a dev shell" if sdk_root.nil? || sdk_root.empty?

avd_home = options[:avd_home] || ENV["ANDROID_AVD_HOME"] || File.expand_path("~/.android/avd")
abort "AVD home not found: #{avd_home}" unless Dir.exist?(avd_home)

rows = []
stale = []

Dir.glob(File.join(avd_home, "*.ini")).sort.each do |ini_path|
  name = File.basename(ini_path, ".ini")
  next unless options[:only].empty? || options[:only].include?(name)

  avd_dir = read_ini(ini_path)["path"] || File.join(avd_home, "#{name}.avd")
  config_path = File.join(avd_dir, "config.ini")
  unless File.exist?(config_path)
    rows << [name, "broken: missing #{config_path}"]
    next
  end

  config = read_ini(config_path)
  sysdir = config["image.sysdir.1"]
  unless sysdir
    rows << [name, "broken: no image.sysdir.1 in config.ini"]
    next
  end

  if sysdir.start_with?("/")
    rows << [name, "custom image outside the SDK (#{sysdir}); not managed here"]
    next
  end

  package = package_from_sysdir(sysdir)
  current_dir = File.join(sdk_root, sysdir)
  unless Dir.exist?(current_dir)
    rows << [name, "image not in this shell (#{package})"]
    next
  end

  current_real = File.realpath(current_dir)
  hardware_path = File.join(avd_dir, "hardware-qemu.ini")
  seeded = File.exist?(File.join(avd_dir, "system-qemu.img"))
  seeded_note = seeded ? "; has local system-qemu.img (recreation removes it)" : ""

  unless File.exist?(hardware_path)
    rows << [name, "ok (never booted)#{seeded_note}"]
    next
  end

  recorded = recorded_image_paths(hardware_path)
  if recorded.empty?
    rows << [name, "ok (no image paths recorded)#{seeded_note}"]
    next
  end

  if recorded.any? { |path| stale_recorded_path?(path, current_real) }
    if same_image_elsewhere?(recorded, current_real)
      rows << [name, "ok (same image content at a new store path)#{seeded_note}"]
      next
    end

    rows << [name, "STALE: booted from a previous image#{seeded_note}"]
    stale << {
      name: name,
      package: package,
      device: config["hw.device.name"],
      sdcard: sdcard_argument(config),
      preserved: preserved_config(config),
    }
  else
    rows << [name, "ok (matches current image)#{seeded_note}"]
  end
end

if rows.empty?
  puts options[:only].empty? ? "No AVDs found in #{avd_home}" : "No AVDs matched #{options[:only].join(", ")}"
  exit
end

width = rows.map { |name, _| name.length }.max
rows.each do |name, line|
  puts "#{name.ljust(width)}  #{line}"
end

puts
if stale.empty?
  puts "Nothing to refresh."
elsif options[:apply]
  stale.each do |avd|
    recreate_avd(avd[:name], avd[:package], avd[:device], avd[:sdcard])
    kept = avd[:preserved]
    new_dir = read_ini(File.join(avd_home, "#{avd[:name]}.ini"))["path"] || File.join(avd_home, "#{avd[:name]}.avd")
    config_path = File.join(new_dir, "config.ini")
    set_config_values(config_path, kept) if !kept.empty? && File.exist?(config_path)
    details = [avd[:package]]
    details << "device #{avd[:device]}" if avd[:device]
    details << "sdcard #{avd[:sdcard]}" if avd[:sdcard]
    details += kept.map { |key, value| "kept #{key}=#{value}" }
    puts "Recreated #{avd[:name]} (#{details.join(", ")})"
  end
else
  script_name = File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")
  puts "Dry run: #{stale.length} stale AVD(s). Run '#{script_name} --apply' to recreate them (wipes their data)."
end
