#!/usr/bin/env nix-shell
#!nix-shell -i ruby -p "ruby.withPackages (ps: with ps; [ nokogiri ])"

require "json"
require "nokogiri"
require "open-uri"

SOURCE_URL = "https://dl.google.com/android/repository/sys-img/android-automotive/sys-img2-3.xml"
DEFAULT_OUTPUT = File.expand_path("../android-automotive-images.json", __dir__)

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

output_path = ARGV[0] || DEFAULT_OUTPUT

doc = Nokogiri::XML(URI.open(SOURCE_URL, &:read)) { |conf| conf.noblanks }

images = {}
licenses = get_licenses(doc)

doc.css('remotePackage[path^="system-images;"]').each do |package|
  path = package["path"]
  segments = path.split(";")
  next unless segments.length == 4

  _, _, image_type, abi = segments
  next unless image_type.start_with?("android-automotive")

  type_details_node = package.at_css("> type-details")
  api = text(type_details_node.at_css("> api-level"))
  next unless api

  revision = [api, image_type, abi].join("-")
  display_name = text(package.at_css("> display-name"))
  uses_license = package.at_css("> uses-license")
  uses_license = uses_license["ref"] if uses_license
  revision_details = to_json_collector(package.at_css("> revision"))
  type_details = to_json_collector(type_details_node)
  dependencies_node = package.at_css("> dependencies")
  dependencies = to_json_collector(dependencies_node) if dependencies_node

  target = (((images[api] ||= {})[image_type] ||= {})[abi] ||= {})
  target["name"] ||= "system-image-#{revision}"
  target["path"] ||= path.tr(";", "/")
  target["revision"] ||= revision
  target["displayName"] ||= display_name
  target["license"] ||= uses_license if uses_license
  target["obsolete"] ||= package["obsolete"] if package["obsolete"]
  target["type-details"] ||= type_details
  target["revision-details"] ||= revision_details
  target["dependencies"] ||= dependencies if dependencies
  target["archives"] = package_archives(package)
end

payload = deep_sort(
  {
    "images" => images,
    "licenses" => licenses,
  }
)

File.write(output_path, JSON.pretty_generate(payload) + "\n")
puts "Wrote #{output_path}"
