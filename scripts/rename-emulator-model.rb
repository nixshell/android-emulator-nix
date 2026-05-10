#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p ruby util-linux e2fsprogs android-tools

require "fileutils"
require "json"
require "optparse"
require "shellwords"
require "tempfile"
require "tmpdir"

def run_command(*command, capture: true)
  if capture
    output = IO.popen(command, err: [:child, :out], &:read)
    raise "Command failed: #{command.shelljoin}\n#{output}" unless $?.success?

    output
  else
    success = system(*command)
    raise "Command failed: #{command.shelljoin}" unless success
  end
end

def read_ini(path)
  File.readlines(path, chomp: true).each_with_object({}) do |line, values|
    next if line.strip.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    next unless key && value

    values[key.strip] = value.strip
  end
end

def parse_fdisk_partition(image_path, partition_number)
  fdisk_output = run_command("fdisk", "-l", image_path)
  line = fdisk_output.lines.find do |entry|
    entry.include?("#{image_path}#{partition_number}")
  end
  raise "Could not find partition #{partition_number} in #{image_path}" unless line

  fields = line.split
  {
    start_sector: Integer(fields[1], 10),
    sector_count: Integer(fields[3], 10),
  }
end

def parse_lpdump_partition(super_image_path, partition_name)
  lpdump_output = run_command("lpdump", super_image_path)
  regex = /^  Name: #{Regexp.escape(partition_name)}$.*?^  Extents:$.*?^    0 \.\. \d+ linear super (\d+)$/m
  match = regex.match(lpdump_output)
  raise "Could not find logical partition #{partition_name} in #{super_image_path}" unless match

  layout_regex = /^\s*super:\s+#{match[1]}\s+\.\.\s+(\d+):\s+#{Regexp.escape(partition_name)}(?:\s+\(\d+\s+sectors\))?\s*$/
  layout_line = lpdump_output.lines.find { |line| layout_regex.match(line) }
  raise "Could not find layout for logical partition #{partition_name}" unless layout_line

  layout_match = layout_regex.match(layout_line)
  start_sector = Integer(match[1], 10)
  end_sector = Integer(layout_match[1], 10)
  {
    start_sector: start_sector,
    sector_count: end_sector - start_sector + 1,
  }
end

def replace_model(path, new_model)
  content = File.read(path)
  pattern = /^ro\.product\.product\.model=.*$/
  raise "Could not find ro.product.product.model in #{path}" unless content.match?(pattern)

  updated = content.gsub(pattern, "ro.product.product.model=#{new_model}")
  File.write(path, updated)
end

options = {
  avd_home: File.expand_path(".android/avd", Dir.pwd),
  force_seed: false,
}

OptionParser.new do |parser|
  parser.banner = "Usage: #{File.basename($PROGRAM_NAME)} --avd NAME --model MODEL [options]"

  parser.on("--avd NAME", "AVD name to patch") do |value|
    options[:avd_name] = value
  end

  parser.on("--model NAME", "Model name to write to ro.product.product.model") do |value|
    options[:model] = value
  end

  parser.on("--avd-home PATH", "Override the AVD home directory") do |value|
    options[:avd_home] = File.expand_path(value)
  end

  parser.on("--force-seed", "Replace existing system-qemu.img from the SDK image before patching") do
    options[:force_seed] = true
  end
end.parse!(ARGV)

raise OptionParser::MissingArgument, "--avd" unless options[:avd_name]
raise OptionParser::MissingArgument, "--model" unless options[:model]

avd_ini_path = File.join(options[:avd_home], "#{options[:avd_name]}.ini")
raise "Missing AVD ini: #{avd_ini_path}" unless File.exist?(avd_ini_path)

avd_ini = read_ini(avd_ini_path)
avd_dir = avd_ini["path"]
raise "Missing path= in #{avd_ini_path}" unless avd_dir
raise "Missing AVD directory: #{avd_dir}" unless Dir.exist?(avd_dir)

config_path = File.join(avd_dir, "config.ini")
raise "Missing config.ini: #{config_path}" unless File.exist?(config_path)

config = read_ini(config_path)
image_sysdir = config["image.sysdir.1"]
raise "Missing image.sysdir.1 in #{config_path}" unless image_sysdir

android_sdk_root = ENV["ANDROID_SDK_ROOT"]
raise "ANDROID_SDK_ROOT is not set" if android_sdk_root.nil? || android_sdk_root.empty?

sdk_sysdir = File.join(android_sdk_root, image_sysdir)
sdk_system_image = File.join(sdk_sysdir, "system.img")
raise "Missing SDK system image: #{sdk_system_image}" unless File.exist?(sdk_system_image)

system_qemu_path = File.join(avd_dir, "system-qemu.img")

if options[:force_seed] || !File.exist?(system_qemu_path)
  FileUtils.cp(sdk_system_image, system_qemu_path, preserve: true)
  FileUtils.chmod(0o644, system_qemu_path)
end

super_partition = parse_fdisk_partition(system_qemu_path, 2)

Tempfile.create(["super", ".img"]) do |super_temp|
  super_temp.close
  run_command(
    "dd",
    "if=#{system_qemu_path}",
    "of=#{super_temp.path}",
    "bs=512",
    "skip=#{super_partition[:start_sector]}",
    "count=#{super_partition[:sector_count]}",
    "status=none",
  )

  product_partition = parse_lpdump_partition(super_temp.path, "product")

  Dir.mktmpdir("rename-emulator-model") do |tmpdir|
    run_command("lpunpack", super_temp.path, tmpdir, capture: false)

    product_image_path = File.join(tmpdir, "product.img")
    raise "Failed to extract product.img from #{super_temp.path}" unless File.exist?(product_image_path)

    build_prop_path = File.join(tmpdir, "build.prop")
    run_command("debugfs", "-R", "dump -p /etc/build.prop #{build_prop_path}", product_image_path)
    replace_model(build_prop_path, options[:model])

    selinux_output = run_command("debugfs", "-R", "stat /etc/build.prop", product_image_path)
    selinux_match = selinux_output.match(/security\.selinux \(\d+\) = "([^"]+)"/)
    selinux_label = selinux_match ? selinux_match[1] : "u:object_r:system_file:s0"

    debugfs_script = File.join(tmpdir, "debugfs.cmd")
    File.write(
      debugfs_script,
      [
        "rm /etc/build.prop",
        "write #{build_prop_path} /etc/build.prop",
        "sif /etc/build.prop uid 0",
        "sif /etc/build.prop gid 0",
        "sif /etc/build.prop mode 0100644",
        "ea_set /etc/build.prop security.selinux #{selinux_label}",
      ].join("\n") + "\n",
    )

    run_command("debugfs", "-w", "-f", debugfs_script, product_image_path)

    absolute_product_start = super_partition[:start_sector] + product_partition[:start_sector]
    run_command(
      "dd",
      "if=#{product_image_path}",
      "of=#{system_qemu_path}",
      "bs=512",
      "seek=#{absolute_product_start}",
      "conv=notrunc",
      "status=none",
    )
  end
end

puts JSON.pretty_generate(
  {
    "avd" => options[:avd_name],
    "avdDir" => avd_dir,
    "model" => options[:model],
    "systemImage" => system_qemu_path,
  },
)
