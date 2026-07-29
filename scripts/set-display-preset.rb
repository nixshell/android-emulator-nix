#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p ruby

require "fileutils"
require "optparse"
require "rexml/document"
require "rexml/formatters/pretty"
require "rexml/xpath"

def read_ini(path)
  File.readlines(path, chomp: true).each_with_object({}) do |line, values|
    next if line.strip.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    next unless key && value

    values[key.strip] = value.strip
  end
end

def atomic_write(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  temporary = File.join(File.dirname(path), ".#{File.basename(path)}.tmp-#{Process.pid}")
  mode = File.exist?(path) ? File.stat(path).mode & 0o777 : 0o644
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
    file.write(content)
  end
  File.rename(temporary, path)
ensure
  FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
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
  atomic_write(path, lines.join("\n") + "\n")
end

DEVICE_NAMESPACE = { "d" => "http://schemas.android.com/sdk/devices/8" }.freeze

def device_value(device, element)
  REXML::XPath.first(device, "d:#{element}", DEVICE_NAMESPACE)&.text&.strip
end

def load_device_profile(path)
  abort "Missing device profile: #{path}" unless File.file?(path)

  document = REXML::Document.new(File.read(path))
  devices = REXML::XPath.match(document, "/d:devices/d:device", DEVICE_NAMESPACE)
  abort "Expected exactly one device in #{path}; found #{devices.length}" unless devices.length == 1

  device = devices.fetch(0)
  id = device_value(device, "id")
  manufacturer = device_value(device, "manufacturer")
  abort "Device profile is missing d:id: #{path}" if id.nil? || id.empty?
  abort "Device profile is missing d:manufacturer: #{path}" if manufacturer.nil? || manufacturer.empty?

  [device, id, manufacturer]
rescue REXML::ParseException => error
  abort "Invalid device profile XML #{path}: #{error.message}"
end

def install_device_profile(source_path, android_user_home)
  source_device, id, manufacturer = load_device_profile(source_path)
  target_path = File.join(android_user_home, "devices.xml")

  unless File.exist?(target_path)
    atomic_write(target_path, File.binread(source_path))
    puts "Installed device profile #{id} in #{target_path}"
    return [id, manufacturer]
  end

  target_document = REXML::Document.new(File.read(target_path))
  target_root = target_document.root
  unless target_root&.name == "devices" && target_root.namespace == DEVICE_NAMESPACE.fetch("d")
    abort "Expected an Android devices document in #{target_path}"
  end

  existing = REXML::XPath.match(target_document, "/d:devices/d:device", DEVICE_NAMESPACE).find do |device|
    device_value(device, "id") == id && device_value(device, "manufacturer") == manufacturer
  end

  if existing&.to_s == source_device.to_s
    puts "Device profile #{id} already installed in #{target_path}"
    return [id, manufacturer]
  end

  target_root.delete_element(existing) if existing
  target_root.add_element(source_device.deep_clone)

  backup_path = "#{target_path}.bak-#{Time.now.strftime("%Y%m%d-%H%M%S-%6N")}"
  FileUtils.cp(target_path, backup_path)
  output = String.new
  formatter = REXML::Formatters::Pretty.new(4)
  formatter.compact = true
  formatter.write(target_document, output)
  atomic_write(target_path, output + "\n")
  action = existing ? "Updated" : "Added"
  puts "#{action} device profile #{id} in #{target_path} (backup: #{backup_path})"

  [id, manufacturer]
rescue REXML::ParseException => error
  abort "Invalid Android devices XML #{target_path}: #{error.message}"
end

def load_setup_profile(path)
  abort "Missing setup profile: #{path}" unless File.file?(path)

  load path
  profile = Object.const_get(:AVD_SETUP_PROFILE)
  abort "Setup profile must be a Hash: #{path}" unless profile.is_a?(Hash)

  profile
rescue NameError
  abort "Setup profile did not define AVD_SETUP_PROFILE: #{path}"
end

options = { avds: [] }

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Install a setup profile's custom hardware definition, bind one or more
    AVDs to it, and apply its complete config.ini preset. Changes take effect
    on the AVD's next cold boot.

    Usage: #{File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")} --avd NAME [--avd NAME]...
  USAGE

  parser.on("--avd NAME", "AVD to update (repeatable, required)") do |name|
    options[:avds] << name
  end
  parser.on("--avd-home PATH", "Override the AVD home directory") do |path|
    options[:avd_home] = File.expand_path(path)
  end
  parser.on("--android-user-home PATH", "Override the Android user directory containing devices.xml") do |path|
    options[:android_user_home] = File.expand_path(path)
  end
  parser.on("--profile PATH", "Setup profile script (supplied by the Nix wrapper)") do |path|
    options[:profile] = File.expand_path(path)
  end
end.parse!

abort "--avd is required (repeatable)" if options[:avds].empty?

avd_home = options[:avd_home] || ENV["ANDROID_AVD_HOME"] || File.expand_path("~/.android/avd")
abort "AVD home not found: #{avd_home}" unless Dir.exist?(avd_home)

targets = options[:avds].uniq.map do |name|
  ini_path = File.join(avd_home, "#{name}.ini")
  abort "Missing AVD ini: #{ini_path}" unless File.exist?(ini_path)

  avd_dir = read_ini(ini_path)["path"] || File.join(avd_home, "#{name}.avd")
  config_path = File.join(avd_dir, "config.ini")
  abort "Missing config.ini: #{config_path}" unless File.exist?(config_path)

  [name, config_path]
end

profile_path = options[:profile] ||
               File.expand_path("../profiles/automotive-1920x1080-160dpi/profile.rb", __dir__)
profile = load_setup_profile(profile_path)
android_user_home = options[:android_user_home] ||
                    ENV["ANDROID_USER_HOME"] ||
                    File.expand_path("~/.android")
profile_id, profile_manufacturer = install_device_profile(profile.fetch(:device_profile), android_user_home)

declared_device = profile.fetch(:device)
unless profile_id == declared_device.fetch(:id) && profile_manufacturer == declared_device.fetch(:manufacturer)
  abort "Setup profile device metadata does not match #{profile.fetch(:device_profile)}"
end

profile_config = {
  "hw.device.name" => profile_id,
  "hw.device.manufacturer" => profile_manufacturer,
}.merge(profile.fetch(:avd_config)).freeze

targets.each do |name, config_path|
  config = read_ini(config_path)
  changes = profile_config.reject { |key, value| config[key] == value }
  changes.each do |key, value|
    puts "#{name}: #{key}: #{config[key] || "(unset)"} -> #{value}"
  end
  unchanged = profile_config.size - changes.size
  puts "#{name}: #{unchanged} value(s) already set" if unchanged.positive?
  set_config_values(config_path, changes) unless changes.empty?
end
