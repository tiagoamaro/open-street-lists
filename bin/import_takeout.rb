#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts Google Takeout Maps JSON files into the open-street-lists format.
#
# Usage:
#   ruby bin/import_takeout.rb [TAKEOUT_DIR] [OUTPUT_FILE]
#
# Defaults:
#   TAKEOUT_DIR  — ./Takeout
#   OUTPUT_FILE  — ./lists.json
#
# Each JSON file found under TAKEOUT_DIR becomes one list, named after the
# file. Features with missing or zero coordinates are skipped.

require 'json'
require 'securerandom'

COLORS = %w[
  #3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6
  #ec4899 #06b6d4 #84cc16 #f97316 #6b7280
].freeze

# Converts a single GeoJSON feature to an app item hash, or nil if unusable.
#
# @param feature [Hash] GeoJSON Feature object
# @return [Hash, nil]
def convert_feature(feature)
  coords = feature.dig('geometry', 'coordinates') || []
  lng, lat = coords.map(&:to_f)

  # Skip features with no real coordinates
  return nil if lat.nil? || lng.nil? || (lat.zero? && lng.zero?)

  props    = feature['properties'] || {}
  location = props['location']     || {}

  name            = location['name'] || props['Title'] || 'Unknown'
  google_maps_url = props['google_maps_url'] || "https://maps.google.com/?q=#{lat},#{lng}"
  notes           = location['address'] || ''

  { id: SecureRandom.uuid, name: name, lat: lat, lng: lng, notes: notes, google_maps_url: google_maps_url }
end

# Converts a Takeout JSON file to an app list hash, or nil if it has no valid items.
#
# @param path  [String] path to the JSON file
# @param color [String] hex color for the list markers
# @return [Hash, nil]
def convert_file(path, color)
  raw  = File.read(path, encoding: 'utf-8')
  data = JSON.parse(raw)

  return nil unless data['type'] == 'FeatureCollection'

  items = (data['features'] || []).filter_map { |f| convert_feature(f) }
  return nil if items.empty?

  { id: SecureRandom.uuid, name: File.basename(path, '.json'), icon: '📍', color: color, visible: true, items: items }
rescue JSON::ParserError => e
  warn "  Skipping #{path}: #{e.message}"
  nil
end

# ── Main ─────────────────────────────────────────────────────────────────────

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

puts "Found #{json_files.length} file(s) in #{takeout_dir}:"

lists       = []
color_index = 0

json_files.each do |path|
  list = convert_file(path, COLORS[color_index % COLORS.length])

  if list
    puts "  ✓ #{File.basename(path)} — #{list[:items].length} place(s)"
    lists << list
    color_index += 1
  else
    puts "  – #{File.basename(path)} — skipped (no valid features)"
  end
end

output = { version: 1, lists: lists }
File.write(output_path, JSON.pretty_generate(output))

total_places = lists.sum { |l| l[:items].length }
puts "\nExported #{lists.length} list(s), #{total_places} place(s) → #{output_path}"
