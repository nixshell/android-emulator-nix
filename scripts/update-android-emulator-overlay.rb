#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p "ruby.withPackages (ps: with ps; [ nokogiri ])"

require "json"
require "nokogiri"
require "open-uri"
require "optparse"
require "time"

SOURCE_URL = "https://dl.google.com/android/repository/repository2-3.xml"
SOURCE_BASE_URL = "https://dl.google.com/android/repository/"
DEFAULT_OVERLAY_OUTPUT = File.expand_path("../android-emulator-overlay.json", __dir__)
DEFAULT_REPORT_OUTPUT = File.expand_path("../android-emulator-availability.json", __dir__)

TYPE_ALIASES = {
  "generic:genericDetailsType" => "ns5:genericDetailsType",
}.freeze

CHANNEL_PRIORITY = {
  "stable" => 0,
  "beta" => 1,
  "dev" => 2,
  "canary" => 3,
}.freeze

ARCHIVE_OS_PRIORITY = {
  "linux" => 0,
  "macosx" => 1,
  "windows" => 2,
  "all" => 3,
}.freeze

ARCHIVE_ARCH_PRIORITY = {
  "x64" => 0,
  "aarch64" => 1,
  "all" => 2,
}.freeze

def text(node)
  node&.text
end

def read_json(path)
  return {} unless File.exist?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  warn "Failed to parse #{path}: #{e.message}"
  {}
end

def version_key(version)
  version.split(".").map { |part| Integer(part, 10) }
end

def sort_versions(versions)
  versions.sort_by { |version| version_key(version) }.reverse
end

def format_revision(revision_node)
  revision_node.element_children.map(&:text).join(".")
end

def to_json_collector(node)
  return {} unless node

  json = {}
  index = 0
  node.element_children.each do |child|
    if child.children.length == 1 && child.children.first.text?
      json["#{child.name}:#{index}"] ||= child.content
      index += 1
      next
    end

    json["#{child.name}:#{index}"] ||= to_json_collector(child)
    index += 1
  end

  element_attributes = {}
  node.attribute_nodes.each do |attr|
    element_attributes[attr.name == "type" ? "xsi:type" : attr.name] ||= TYPE_ALIASES.fetch(attr.value, attr.value)
  end

  json["element-attributes"] = element_attributes unless element_attributes.empty?
  json
end

def package_archives(package)
  package.css("> archives > archive").map do |archive|
    host_os = text(archive.at_css("> host-os")) || "all"
    host_arch = text(archive.at_css("> host-arch")) || "all"
    url = text(archive.at_css("> complete > url"))
    checksum = archive.at_css("> complete > checksum")

    {
      "arch" => host_arch,
      "os" => host_os,
      "sha1" => text(checksum),
      "size" => Integer(text(archive.at_css("> complete > size")), 10),
      "url" => url.start_with?("http") ? url : "#{SOURCE_BASE_URL}#{url}",
    }
  end.sort_by do |archive|
    [
      ARCHIVE_OS_PRIORITY.fetch(archive["os"], 99),
      ARCHIVE_ARCH_PRIORITY.fetch(archive["arch"], 99),
      archive["url"],
    ]
  end
end

def channel_labels(doc)
  doc.css("channel").each_with_object({}) do |channel, labels|
    labels[channel["id"]] = channel.text.strip
  end
end

def build_available_versions(doc)
  channels = channel_labels(doc)

  by_revision = doc.css('remotePackage[path="emulator"]').each_with_object({}) do |package, acc|
    revision = format_revision(package.at_css("> revision"))
    channel_id = package.at_css("> channelRef")&.[]("ref")
    channel_name = channels[channel_id] || "unknown"
    metadata = {
      "channel" => {
        "id" => channel_id,
        "name" => channel_name,
      },
      "displayName" => text(package.at_css("> display-name")),
      "license" => package.at_css("> uses-license")&.[]("ref"),
      "revision" => revision,
      "revision-details" => to_json_collector(package.at_css("> revision")),
      "type-details" => to_json_collector(package.at_css("> type-details")),
      "archives" => package_archives(package),
    }
    existing = acc[revision]

    if existing.nil? || CHANNEL_PRIORITY.fetch(channel_name, 99) < CHANNEL_PRIORITY.fetch(existing.dig("channel", "name"), 99)
      acc[revision] = metadata
    end
  end

  sort_versions(by_revision.keys).each_with_object({}) do |revision, acc|
    metadata = by_revision.fetch(revision)
    acc[revision] = metadata
  end
end

def package_only_versions(available_versions)
  available_versions.each_with_object({}) do |(revision, metadata), acc|
    acc[revision] = {
      "archives" => metadata["archives"],
      "displayName" => metadata["displayName"],
      "license" => metadata["license"],
      "name" => "emulator",
      "path" => "emulator",
      "revision" => metadata["revision"],
      "revision-details" => metadata["revision-details"],
      "type-details" => metadata["type-details"],
    }
  end
end

def stable_versions(available_versions)
  available_versions.select { |_, metadata| metadata.dig("channel", "name") == "stable" }.keys
end

def newest_version(versions)
  sort_versions(versions).first
end

def normalize_for_compare(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) do |key, acc|
      acc[key] = normalize_for_compare(value[key])
    end
  when Array
    value.map { |item| normalize_for_compare(item) }
  else
    value
  end
end

def select_latest(latest_policy, current_latest, versions, stable)
  ordered_versions = sort_versions(versions)
  newest_stable = newest_version(stable)

  case latest_policy
  when "keep-current"
    return current_latest if current_latest && versions.include?(current_latest)

    newest_stable || ordered_versions.first
  when "stable"
    newest_stable || ordered_versions.first
  when "newest"
    ordered_versions.first
  else
    return latest_policy if versions.include?(latest_policy)

    raise ArgumentError, "Requested latest emulator #{latest_policy.inspect} is not available from #{SOURCE_URL}"
  end
end

options = {
  overlay_output: DEFAULT_OVERLAY_OUTPUT,
  report_output: DEFAULT_REPORT_OUTPUT,
  latest_policy: "keep-current",
}

OptionParser.new do |parser|
  parser.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options]"

  parser.on("--output PATH", "Write the overlay JSON to PATH") do |path|
    options[:overlay_output] = File.expand_path(path)
  end

  parser.on("--report-output PATH", "Write the availability report JSON to PATH") do |path|
    options[:report_output] = File.expand_path(path)
  end

  parser.on(
    "--latest VALUE",
    "Latest emulator policy: keep-current, stable, newest, or an explicit version"
  ) do |value|
    options[:latest_policy] = value
  end
end.parse!(ARGV)

current_overlay = read_json(options[:overlay_output])
current_versions_hash = current_overlay.fetch("packages", {}).fetch("emulator", {})
current_versions = current_versions_hash.keys
current_latest = current_overlay.dig("latest", "emulator")

doc = Nokogiri::XML(URI.open(SOURCE_URL, &:read)) { |config| config.noblanks }
available_versions = build_available_versions(doc)
generated_packages = package_only_versions(available_versions)
generated_versions = generated_packages.keys

selected_latest = select_latest(
  options[:latest_policy],
  current_latest,
  generated_versions,
  stable_versions(available_versions)
)

overlay_payload = {
  "latest" => {
    "emulator" => selected_latest,
  },
  "packages" => {
    "emulator" => generated_packages,
  },
}

new_versions = sort_versions(generated_versions - current_versions)
removed_versions = sort_versions(current_versions - generated_versions)
changed_versions = sort_versions(
  generated_versions & current_versions
).select do |revision|
  normalize_for_compare(current_versions_hash[revision]) != normalize_for_compare(generated_packages[revision])
end

stable = stable_versions(available_versions)
non_stable = available_versions.reject { |_, metadata| metadata.dig("channel", "name") == "stable" }.keys

report_payload = {
  "checkedAt" => Time.now.utc.iso8601,
  "sourceUrl" => SOURCE_URL,
  "overlayPath" => File.basename(options[:overlay_output]),
  "overlayLatestBefore" => current_latest,
  "overlayLatestAfter" => selected_latest,
  "newestStable" => newest_version(stable),
  "newestPreview" => newest_version(non_stable),
  "newVersions" => new_versions,
  "changedVersions" => changed_versions,
  "removedVersions" => removed_versions,
  "availableVersions" => available_versions,
}

File.write(options[:overlay_output], JSON.pretty_generate(overlay_payload) + "\n")
File.write(options[:report_output], JSON.pretty_generate(report_payload) + "\n")

puts "Wrote #{options[:overlay_output]}"
puts "Wrote #{options[:report_output]}"
puts "Overlay latest before: #{current_latest || "(none)"}"
puts "Overlay latest after:  #{selected_latest}"
puts "Newest stable:         #{report_payload["newestStable"] || "(none)"}"
puts "Newest preview:        #{report_payload["newestPreview"] || "(none)"}"
puts "New versions:          #{new_versions.empty? ? "(none)" : new_versions.join(", ")}"
puts "Changed versions:      #{changed_versions.empty? ? "(none)" : changed_versions.join(", ")}"
puts "Removed versions:      #{removed_versions.empty? ? "(none)" : removed_versions.join(", ")}"
