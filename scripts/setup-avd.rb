#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p ruby

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

def command_available?(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
    File.executable?(File.join(directory, name))
  end
end

def create_avd(name, profile)
  command = [
    "avdmanager",
    "create",
    "avd",
    "--name",
    name,
    "--device",
    profile.fetch(:seed_device),
    "--package",
    profile.fetch(:package),
  ]

  output = IO.popen(command, "r+", err: [:child, :out]) do |io|
    io.puts "no"
    io.close_write
    io.read
  end
  abort "AVD creation failed:\n#{output}" unless $?.success?

  puts output unless output.empty?
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

profile_path =
  if ARGV.first == "--profile"
    ARGV.shift
    value = ARGV.shift
    abort "--profile requires a path" unless value
    File.expand_path(value)
  else
    File.expand_path("../profiles/automotive-1920x1080-160dpi/profile.rb", __dir__)
  end

profile = load_setup_profile(profile_path)
profile_name = profile.fetch(:name)

script_name = File.basename(__FILE__, ".rb").sub(/\A[0-9a-z]{32}-/, "")
usage = <<~USAGE
  Set up one AVD using the #{profile_name} profile. Creates the AVD
  when missing; an existing AVD is updated only when it already uses the same
  Android system-image package. Never recreates an AVD or wipes userdata.

  Usage: #{script_name} NAME
USAGE

if ARGV == ["--help"] || ARGV == ["-h"]
  puts usage
  exit
end
abort usage unless ARGV.length == 1

name = ARGV.fetch(0)
unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
  abort "Invalid AVD name #{name.inspect}; use letters, digits, '.', '_' or '-'"
end

sdk_root = ENV["ANDROID_SDK_ROOT"]
abort "ANDROID_SDK_ROOT is not set; run inside the Android dev shell" if sdk_root.nil? || sdk_root.empty?

avd_home = ENV["ANDROID_AVD_HOME"] || File.expand_path("~/.android/avd")
abort "AVD home not found: #{avd_home}" unless Dir.exist?(avd_home)
abort "avdmanager is not on PATH; run inside the Android dev shell" unless command_available?("avdmanager")
abort "set-display-preset is not on PATH; run inside the Android dev shell" unless command_available?("set-display-preset")

package = profile.fetch(:package)
image_sysdir = "#{package.tr(";", "/")}/"
image_path = File.join(sdk_root, image_sysdir)
abort "System image is not installed in this shell: #{package}" unless Dir.exist?(image_path)

ini_path = File.join(avd_home, "#{name}.ini")
default_avd_dir = File.join(avd_home, "#{name}.avd")

if File.exist?(ini_path)
  avd_dir = read_ini(ini_path)["path"] || default_avd_dir
  config_path = File.join(avd_dir, "config.ini")
  abort "Existing AVD is broken: missing #{config_path}" unless File.exist?(config_path)

  config = read_ini(config_path)
  existing_sysdir = config["image.sysdir.1"]
  abort "Existing AVD has no image.sysdir.1: #{config_path}" unless existing_sysdir

  existing_package = existing_sysdir.start_with?("/") ? existing_sysdir : package_from_sysdir(existing_sysdir)
  unless existing_package == package
    abort <<~ERROR
      Refusing to repurpose existing AVD #{name.inspect}.
      Expected image: #{package}
      Existing image: #{existing_package}
    ERROR
  end

  puts "Using existing AVD #{name} (userdata will be preserved)"
else
  abort "Refusing to overwrite orphaned AVD directory: #{default_avd_dir}" if Dir.exist?(default_avd_dir)

  puts "Creating AVD #{name} from #{package}"
  create_avd(name, profile)
  abort "avdmanager did not create #{ini_path}" unless File.exist?(ini_path)
end

puts "Applying setup profile #{profile_name}"
apply_command = profile.fetch(:apply_command)
abort "Profile command failed: #{apply_command.join(" ")}" unless system(*apply_command, "--avd", name)

avd_dir = read_ini(ini_path)["path"] || default_avd_dir
config_path = File.join(avd_dir, "config.ini")
config = read_ini(config_path)

device = profile.fetch(:device)
expected_config = {
  "hw.device.name" => device.fetch(:id),
  "hw.device.manufacturer" => device.fetch(:manufacturer),
}.merge(profile.fetch(:avd_config))

errors = expected_config.filter_map do |key, expected|
  actual = config[key]
  "#{key}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

unless package_from_sysdir(config.fetch("image.sysdir.1", "")) == package
  errors << "image.sysdir.1 no longer points to #{package}"
end

abort "AVD verification failed:\n  #{errors.join("\n  ")}" unless errors.empty?

puts
puts "AVD #{name} is ready"
puts "Setup profile: #{profile_name}"
puts "System image: #{package}"
puts "Launch:"
puts "  emulator -no-snapshot-load -verbose -show-kernel -gpu host -avd #{name}"
