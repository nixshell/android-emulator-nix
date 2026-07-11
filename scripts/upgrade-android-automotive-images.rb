#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p "ruby.withPackages (ps: with ps; [ nokogiri ])"

require "json"
require "nokogiri"
require "open-uri"
require "optparse"

SOURCE_URL = "https://dl.google.com/android/repository/sys-img/android-automotive/sys-img2-3.xml"
DEFAULT_IMAGES_PATH = File.expand_path("../android-automotive-images.json", __dir__)
EMULATOR_OVERLAY_PATH = File.expand_path("../android-emulator-overlay.json", __dir__)
DEFAULT_CHANNELS = %w[stable beta].freeze

def text(node)
  node ? node.text : nil
end

def normalize_license(license)
  normalized = license.dup
  normalized.gsub!(/([^\n])\n([^\n])/m, '\1 \2')
  normalized.gsub!(/ +/, " ")
  normalized.strip!
  normalized
end

def get_licenses(doc)
  licenses = {}
  doc.css('license[type="text"]').each do |license_node|
    license_id = license_node["id"]
    next unless license_id

    licenses[license_id] ||= []
    licenses[license_id] |= [normalize_license(text(license_node))]
  end
  licenses
end

def to_json_collector(doc)
  return {} unless doc

  json = {}
  index = 0
  doc.element_children.each do |node|
    if node.children.length == 1 && node.children.first.text?
      json["#{node.name}:#{index}"] ||= node.content
      index += 1
      next
    end

    json["#{node.name}:#{index}"] ||= to_json_collector(node)
    index += 1
  end

  element_attributes = {}
  doc.attribute_nodes.each do |attr|
    if attr.name == "type"
      type = attr.value.split(":", 2).last
      case attr.value
      when "sys-img:sysImgDetailsType"
        element_attributes["xsi:type"] ||= "ns12:#{type}"
      else
        element_attributes[attr.name] ||= attr.value
      end
    else
      element_attributes[attr.name] ||= attr.value
    end
  end

  json["element-attributes"] = element_attributes unless element_attributes.empty?
  json
end

def package_archives(package)
  package.css("> archives > archive").map do |archive|
    host_os = text(archive.at_css("> host-os")) || "all"
    host_arch = text(archive.at_css("> host-arch")) || "all"
    url = text(archive.at_css("> complete > url"))

    {
      "os" => host_os,
      "arch" => host_arch,
      "size" => Integer(text(archive.at_css("> complete > size"))),
      "sha1" => text(archive.at_css("> complete > checksum")),
      "url" => url.start_with?("http") ? url : "https://dl.google.com/android/repository/sys-img/android-automotive/#{url}",
    }
  end
end

def deep_sort(value)
  case value
  when Hash
    value.keys.sort.each_with_object({}) do |key, acc|
      acc[key] = deep_sort(value[key])
    end
  when Array
    value.map { |item| deep_sort(item) }
  else
    value
  end
end

def build_image_entry(package)
  path = package["path"]
  _, _, image_type, abi = path.split(";")
  type_details_node = package.at_css("> type-details")
  api = text(type_details_node.at_css("> api-level"))
  revision = [api, image_type, abi].join("-")

  entry = {
    "name" => "system-image-#{revision}",
    "path" => path.tr(";", "/"),
    "revision" => revision,
    "displayName" => text(package.at_css("> display-name")),
    "type-details" => to_json_collector(type_details_node),
    "revision-details" => to_json_collector(package.at_css("> revision")),
    "archives" => package_archives(package),
  }
  uses_license = package.at_css("> uses-license")
  entry["license"] = uses_license["ref"] if uses_license
  entry["obsolete"] = package["obsolete"] if package["obsolete"]
  dependencies_node = package.at_css("> dependencies")
  entry["dependencies"] = to_json_collector(dependencies_node) if dependencies_node
  entry
end

def key_matches?(filters, api, image_type, abi)
  return true if filters.empty?

  key = [api, image_type, abi]
  filters.any? do |filter|
    segments = filter.split("/")
    segments == key.first(segments.length)
  end
end

def revision_tuple(package)
  revision_node = package.at_css("> revision")
  %w[major minor micro].map do |part|
    (text(revision_node && revision_node.at_css("> #{part}")) || 0).to_i
  end
end

def format_revision(revision)
  revision[1].zero? && revision[2].zero? ? "r#{revision[0]}" : "r#{revision.join(".")}"
end

def pinned_revision_tuple(entry)
  entry.fetch("archives", []).each do |archive|
    match = archive["url"].to_s.match(/_r0*(\d+)\.zip\z/)
    return [Integer(match[1], 10), 0, 0] if match
  end
  details = entry["revision-details"] || {}
  [details["major:0"], details["minor:1"], details["micro:2"]].map(&:to_i)
end

def archive_shas(archives)
  archives.map { |archive| archive["sha1"] }.sort
end

def emulator_min_revision(package)
  node = package.at_css('> dependencies > dependency[path="emulator"] > min-revision')
  return nil unless node

  %w[major minor micro].map { |part| text(node.at_css("> #{part}")) }.compact.join(".")
end

options = {
  apply: false,
  dev_all: false,
  dev_images: [],
  only: [],
  images_path: DEFAULT_IMAGES_PATH,
}

OptionParser.new do |parser|
  parser.banner = <<~USAGE
    Check pinned Android Automotive system images against Google's repository
    and optionally upgrade them in #{File.basename(DEFAULT_IMAGES_PATH)}.

    Runs as a dry run by default: nothing is written without --apply.
    Image KEY format: API[/TYPE[/ABI]], e.g. "35x", "33/android-automotive",
    "32/android-automotive-playstore/x86_64". Partial keys match all images below them.

    Usage: #{File.basename(__FILE__)} [options]
  USAGE

  parser.on("--apply", "Write available upgrades to the images JSON") do
    options[:apply] = true
  end
  parser.on("--dev", "Consider dev/canary channel packages for all images") do
    options[:dev_all] = true
  end
  parser.on("--dev-image KEY", "Consider dev channel for matching images only (repeatable)") do |key|
    options[:dev_images] << key
  end
  parser.on("--only KEY", "Limit checks and upgrades to matching images (repeatable)") do |key|
    options[:only] << key
  end
  parser.on("--file PATH", "Images JSON to check and update (default: #{DEFAULT_IMAGES_PATH})") do |path|
    options[:images_path] = File.expand_path(path)
  end
end.parse!

data = JSON.parse(File.read(options[:images_path]))
doc = Nokogiri::XML(URI.open(SOURCE_URL, &:read)) { |conf| conf.noblanks }

channels = doc.css("channel").to_h { |node| [node["id"], node.text] }
latest_emulator = begin
  JSON.parse(File.read(EMULATOR_OVERLAY_PATH)).dig("latest", "emulator")
rescue Errno::ENOENT, JSON::ParserError
  nil
end

candidates = Hash.new { |hash, key| hash[key] = [] }
doc.css('remotePackage[path^="system-images;"]').each do |package|
  segments = package["path"].split(";")
  next unless segments.length == 4

  _, _, image_type, abi = segments
  next unless image_type.start_with?("android-automotive")

  api = text(package.at_css("> type-details > api-level"))
  next unless api

  channel_ref = package.at_css("> channelRef")
  channel = channels.fetch(channel_ref && channel_ref["ref"], "stable")
  candidates[[api, image_type, abi]] << {
    channel: channel,
    revision: revision_tuple(package),
    package: package,
  }
end

rows = []
upgrades = []

data.fetch("images").each do |api, types|
  types.each do |image_type, abis|
    abis.each do |abi, entry|
      next unless key_matches?(options[:only], api, image_type, abi)

      key = [api, image_type, abi].join("/")
      group = candidates[[api, image_type, abi]]
      pinned_rev = pinned_revision_tuple(entry)

      if group.empty?
        rows << [key, "#{format_revision(pinned_rev)} — no remote package found (removed upstream?)"]
        next
      end

      dev_allowed = options[:dev_all] ||
        (!options[:dev_images].empty? && key_matches?(options[:dev_images], api, image_type, abi))
      allowed = group.select { |candidate| DEFAULT_CHANNELS.include?(candidate[:channel]) || dev_allowed }
      best = allowed.max_by { |candidate| candidate[:revision] }
      best_any = group.max_by { |candidate| candidate[:revision] }

      pinned_shas = archive_shas(entry.fetch("archives", []))
      pinned_match = group.find { |candidate| archive_shas(package_archives(candidate[:package])) == pinned_shas }
      pinned_rev = pinned_match[:revision] if pinned_match
      pinned_label = format_revision(pinned_rev)
      pinned_label += " (#{pinned_match[:channel]})" if pinned_match

      hint = ""
      if best_any && (best_any[:revision] <=> pinned_rev) > 0 && (best.nil? || (best_any[:revision] <=> best[:revision]) > 0)
        hint = "; #{format_revision(best_any[:revision])} AVAILABLE ON #{best_any[:channel].upcase} (use --dev or --dev-image #{key})"
      end

      upgrade = best && ((best[:revision] <=> pinned_rev) > 0 ||
        (pinned_match.nil? && (best[:revision] <=> pinned_rev) == 0))

      unless upgrade
        rows << [key, "#{pinned_label} up to date#{hint}"]
        next
      end

      warning = ""
      min_emulator = emulator_min_revision(best[:package])
      if latest_emulator && min_emulator && Gem::Version.new(min_emulator) > Gem::Version.new(latest_emulator)
        warning = " [requires emulator >= #{min_emulator}, overlay has #{latest_emulator}]"
      end
      rows << [key, "#{pinned_label} -> #{format_revision(best[:revision])} (#{best[:channel]}) UPGRADE#{warning}#{hint}"]
      upgrades << { api: api, image_type: image_type, abi: abi, package: best[:package] }
    end
  end
end

width = rows.map { |key, _| key.length }.max.to_i
rows.each do |key, line|
  puts "#{key.ljust(width)}  #{line}"
end

unpinned = candidates.keys.reject { |api, image_type, abi| data.dig("images", api, image_type, abi) }
unless unpinned.empty?
  puts
  puts "Available upstream but not pinned (ignored): #{unpinned.map { |key| key.join("/") }.sort.join(", ")}"
end

puts
if upgrades.empty?
  puts "Everything is up to date."
elsif options[:apply]
  remote_licenses = get_licenses(doc)
  upgrades.each do |upgrade|
    entry = build_image_entry(upgrade[:package])
    data["images"][upgrade[:api]][upgrade[:image_type]][upgrade[:abi]] = entry
    license_id = entry["license"]
    next unless license_id && remote_licenses.key?(license_id)

    data["licenses"] ||= {}
    data["licenses"][license_id] ||= []
    data["licenses"][license_id] |= remote_licenses[license_id]
  end
  File.write(options[:images_path], JSON.pretty_generate(deep_sort(data)) + "\n")
  puts "Applied #{upgrades.length} upgrade(s) to #{options[:images_path]}"
else
  puts "Dry run: #{upgrades.length} upgrade(s) available. Re-run with --apply to write them."
end
