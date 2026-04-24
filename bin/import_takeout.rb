#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts Google Takeout Maps exports into the open-street-lists format.
# Handles both JSON (GeoJSON FeatureCollections) and CSV (saved lists) files.
#
# CSV files with place-URL entries are geocoded via Nominatim (1 req/sec).
# Pass --no-geocode to skip geocoding and only import entries whose
# coordinates can be extracted directly from the URL.
#
# Usage:
#   ruby bin/import_takeout.rb [TAKEOUT_DIR] [OUTPUT_FILE] [--no-geocode]
#
# Defaults:
#   TAKEOUT_DIR  — ./Takeout
#   OUTPUT_FILE  — ./lists.json

require 'json'
require 'csv'
require 'net/http'
require 'uri'
require 'cgi'
require 'securerandom'

COLORS = %w[
  #3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6
  #ec4899 #06b6d4 #84cc16 #f97316 #6b7280
].freeze

GENERIC_TITLES = %w[dropped\ pin alfinete\ inserido].freeze

# ── Geocoding ────────────────────────────────────────────────────────────────

# Queries Nominatim for the first result matching +query+.
# Respects the 1-request-per-second usage policy with a built-in sleep.
#
# @param query [String]
# @return [Array(Float, Float), nil] [lat, lng] or nil
def geocode(query)
  sleep 1.1 # Nominatim ToS: max 1 req/sec

  uri = URI('https://nominatim.openstreetmap.org/search')
  uri.query = URI.encode_www_form(q: query, format: 'json', limit: 1, addressdetails: 0)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = 'open-street-lists/1.0 (github.com/tiagoamaro/open-street-lists)'
  req['Accept']     = 'application/json'

  results = JSON.parse(http.request(req).body)
  return nil if results.empty?

  [results[0]['lat'].to_f, results[0]['lon'].to_f]
rescue StandardError => e
  warn "    geocode failed for #{query.inspect}: #{e.message}"
  nil
end

# Extracts [lat, lng] from a Google Maps search URL containing coordinates,
# e.g. https://www.google.com/maps/search/-22.8745815,-42.3365044
#
# @param url [String]
# @return [Array(Float, Float), nil]
def coords_from_search_url(url)
  m = url.match(%r{/maps/search/(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)})
  return nil unless m

  lat, lng = m[1].to_f, m[2].to_f
  (lat.zero? && lng.zero?) ? nil : [lat, lng]
end

# Extracts a human-readable place name from a Google Maps place URL,
# e.g. https://www.google.com/maps/place/Zoo+Berlin/data=...  →  "Zoo Berlin"
#
# @param url [String]
# @return [String, nil]
def name_from_place_url(url)
  m = url.match(%r{/maps/place/([^/]+)})
  return nil unless m && m[1].length > 0

  CGI.unescape(m[1].gsub('+', ' ')).strip.then { |n| n.empty? ? nil : n }
end

# ── JSON ─────────────────────────────────────────────────────────────────────

# Converts a single GeoJSON feature to an item hash, or nil if unusable.
#
# @param feature [Hash]
# @return [Hash, nil]
def convert_json_feature(feature)
  coords = feature.dig('geometry', 'coordinates') || []
  lng, lat = coords.map(&:to_f)
  return nil if lat.nil? || lng.nil? || (lat.zero? && lng.zero?)

  props    = feature['properties'] || {}
  location = props['location']     || {}

  { id: SecureRandom.uuid,
    name:            location['name'] || props['Title'] || 'Unknown',
    lat:             lat,
    lng:             lng,
    notes:           location['address'] || '',
    google_maps_url: props['google_maps_url'] || "https://maps.google.com/?q=#{lat},#{lng}" }
end

# Converts a Takeout JSON file (GeoJSON FeatureCollection) to a list hash.
#
# @param path  [String]
# @param color [String]
# @return [Hash, nil]
def convert_json_file(path, color)
  data = JSON.parse(File.read(path, encoding: 'utf-8'))
  return nil unless data['type'] == 'FeatureCollection'

  items = (data['features'] || []).filter_map { |f| convert_json_feature(f) }
  return nil if items.empty?

  { id: SecureRandom.uuid, name: File.basename(path, '.json'),
    icon: '📍', color: color, visible: true, items: items }
rescue JSON::ParserError => e
  warn "  Skipping #{path}: #{e.message}"
  nil
end

# ── CSV ──────────────────────────────────────────────────────────────────────

# Converts a single CSV row to an item hash.
# Tries to extract coordinates from the URL directly; falls back to geocoding.
#
# @param row     [CSV::Row]
# @param geocode [Boolean] whether to call Nominatim for place URLs
# @return [Hash, nil]
def convert_csv_row(row, allow_geocode:)
  title = row['Title']&.strip
  url   = row['URL']&.strip
  note  = row['Note']&.strip || ''

  return nil if url.nil? || url.empty?

  # 1. Coordinates embedded in a search URL
  if (coords = coords_from_search_url(url))
    lat, lng = coords
    name = (title.nil? || title.empty? || GENERIC_TITLES.include?(title.downcase)) ? 'Dropped pin' : title
    return { id: SecureRandom.uuid, name: name, lat: lat, lng: lng,
             notes: note, google_maps_url: url }
  end

  # 2. Place URL — need a name to geocode
  name = (title.nil? || title.empty?) ? name_from_place_url(url) : title
  return nil if name.nil? || name.empty?

  if allow_geocode
    print "    geocoding #{name.inspect}… "
    coords = geocode(name)
    if coords
      lat, lng = coords
      puts "#{lat}, #{lng}"
      return { id: SecureRandom.uuid, name: name, lat: lat, lng: lng,
               notes: note, google_maps_url: url }
    else
      puts 'not found, skipped'
      return nil
    end
  end

  nil # geocoding disabled, skip place URLs without inline coords
end

# Converts a Takeout CSV file to a list hash.
#
# @param path          [String]
# @param color         [String]
# @param allow_geocode [Boolean]
# @return [Hash, nil]
def convert_csv_file(path, color, allow_geocode:)
  rows = CSV.read(path, headers: true, encoding: 'utf-8')
  items = rows.filter_map { |row| convert_csv_row(row, allow_geocode: allow_geocode) }
  return nil if items.empty?

  { id: SecureRandom.uuid, name: File.basename(path, '.csv'),
    icon: '📍', color: color, visible: true, items: items }
rescue CSV::MalformedCSVError => e
  warn "  Skipping #{path}: #{e.message}"
  nil
end

# ── Main ─────────────────────────────────────────────────────────────────────

args         = ARGV.dup
no_geocode   = args.delete('--no-geocode')
takeout_dir  = args[0] || './Takeout'
output_path  = args[1] || './lists.json'
allow_geocode = !no_geocode

unless Dir.exist?(takeout_dir)
  warn "Error: directory '#{takeout_dir}' not found."
  exit 1
end

json_files = Dir.glob(File.join(takeout_dir, '**', '*.json')).sort
csv_files  = Dir.glob(File.join(takeout_dir, '**', '*.csv')).sort
all_files  = json_files + csv_files

if all_files.empty?
  warn "No JSON or CSV files found in '#{takeout_dir}'."
  exit 1
end

if allow_geocode && csv_files.any?
  puts "Note: CSV place entries will be geocoded via Nominatim (1 req/sec)."
  puts "      Pass --no-geocode to skip geocoding (only inline-coord entries imported).\n\n"
end

lists       = []
color_index = 0

puts "Processing #{json_files.length} JSON + #{csv_files.length} CSV file(s):\n\n"

json_files.each do |path|
  print "  [JSON] #{File.basename(path)}… "
  list = convert_json_file(path, COLORS[color_index % COLORS.length])
  if list
    puts "#{list[:items].length} place(s)"
    lists << list
    color_index += 1
  else
    puts 'skipped (no valid features)'
  end
end

csv_files.each do |path|
  puts "  [CSV]  #{File.basename(path)}"
  list = convert_csv_file(path, COLORS[color_index % COLORS.length], allow_geocode: allow_geocode)
  if list
    puts "         → #{list[:items].length} place(s) imported"
    lists << list
    color_index += 1
  else
    puts '         → skipped (no importable rows)'
  end
end

output = { version: 1, lists: lists }
File.write(output_path, JSON.pretty_generate(output))

total = lists.sum { |l| l[:items].length }
puts "\nExported #{lists.length} list(s), #{total} place(s) → #{output_path}"
