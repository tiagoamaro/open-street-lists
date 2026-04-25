#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts Google Takeout Maps JSON exports (GeoJSON FeatureCollections) into
# the open-street-lists format.
#
# The script is resumable: if OUTPUT_FILE already exists, items whose
# google_maps_url is already present are skipped. New items are appended and
# the file is written after each list so progress is not lost on interruption.
#
# Usage:
#   ruby bin/import_takeout_json.rb [TAKEOUT_DIR] [OUTPUT_FILE]
#
# Defaults:
#   TAKEOUT_DIR  — ./Takeout
#   OUTPUT_FILE  — ./lists.json

require 'json'
require 'securerandom'
require 'time'
require 'set'

COLORS = %w[
  #3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6
  #ec4899 #06b6d4 #84cc16 #f97316 #6b7280
].freeze

# ── JSON ──────────────────────────────────────────────────────────────────────

# Converts a single GeoJSON feature to an item hash (string-keyed), or nil if unusable.
# Returns nil if the feature's URL is already in +known_urls+.
#
# @param feature    [Hash]
# @param known_urls [Set<String>]
# @return [Hash, nil]
def convert_json_feature(feature, known_urls)
  coords = feature.dig('geometry', 'coordinates') || []
  lng, lat = coords.map(&:to_f)
  return nil if lat.nil? || lng.nil? || (lat.zero? && lng.zero?)

  props    = feature['properties'] || {}
  location = props['location']     || {}

  url = props['google_maps_url'] || "https://maps.google.com/?q=#{lat},#{lng}"
  return nil if known_urls.include?(url)

  {
    'id'              => SecureRandom.uuid,
    'name'            => location['name'] || props['Title'] || 'Unknown',
    'lat'             => lat,
    'lng'             => lng,
    'notes'           => location['address'] || '',
    'google_maps_url' => url,
    'created_at'      => props['date'] || Time.now.utc.iso8601
  }
end

# Converts a Takeout JSON file (GeoJSON FeatureCollection).
# New items are appended to +existing_list+ when provided; otherwise a new list
# hash (string-keyed) is returned. Returns nil when nothing new was found.
#
# @param path          [String]
# @param color         [String]
# @param known_urls    [Set<String>]
# @param existing_list [Hash, nil]
# @return [Hash, nil]
def convert_json_file(path, color, known_urls, existing_list)
  data = JSON.parse(File.read(path, encoding: 'utf-8'))
  return nil unless data['type'] == 'FeatureCollection'

  new_items = (data['features'] || []).filter_map { |f| convert_json_feature(f, known_urls) }
  return nil if new_items.empty?

  new_items.each { |i| known_urls << i['google_maps_url'] }

  if existing_list
    existing_list['items'].concat(new_items)
    return existing_list
  end

  {
    'id'      => SecureRandom.uuid,
    'name'    => File.basename(path, '.json'),
    'icon'    => '📍',
    'color'   => color,
    'visible' => true,
    'items'   => new_items
  }
rescue JSON::ParserError => e
  warn "  Skipping #{path}: #{e.message}"
  nil
end

# ── Main ──────────────────────────────────────────────────────────────────────

takeout_dir = ARGV[0] || './Takeout'
output_path = ARGV[1] || './lists.json'

unless Dir.exist?(takeout_dir)
  warn "Error: directory '#{takeout_dir}' not found."
  exit 1
end

json_files = Dir.glob(File.join(takeout_dir, '**', '*.json')).sort

if json_files.empty?
  warn "No JSON files found in '#{takeout_dir}'."
  exit 1
end

output = begin
  File.exist?(output_path) ? JSON.parse(File.read(output_path, encoding: 'utf-8')) : { 'version' => 1, 'lists' => [] }
rescue JSON::ParserError
  { 'version' => 1, 'lists' => [] }
end

lists_by_name = output['lists'].each_with_object({}) { |l, h| h[l['name']] = l }

known_urls = Set.new
output['lists'].each { |l| (l['items'] || []).each { |i| known_urls << i['google_maps_url'] } }

color_index = output['lists'].length

puts "Processing #{json_files.length} JSON file(s):\n\n"

json_files.each do |path|
  list_name = File.basename(path, '.json')
  print "  [JSON] #{File.basename(path)}… "

  existing     = lists_by_name[list_name]
  before_count = existing ? existing['items'].length : 0
  list         = convert_json_file(path, COLORS[color_index % COLORS.length], known_urls, existing)

  if list
    added = list['items'].length - before_count
    puts "#{added} new place(s) (#{list['items'].length} total)"
    unless existing
      output['lists'] << list
      lists_by_name[list_name] = list
      color_index += 1
    end
    File.write(output_path, JSON.pretty_generate(output))
  else
    puts 'skipped (no new features)'
  end
end

total = output['lists'].sum { |l| (l['items'] || []).length }
puts "\nDone. #{output['lists'].length} list(s), #{total} place(s) total → #{output_path}"
