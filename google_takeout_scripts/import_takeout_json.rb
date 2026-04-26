#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts Google Takeout Maps JSON exports (GeoJSON FeatureCollections) into
# the open-street-lists format.
#
# Coordinate resolution order per feature:
#   1. Inline coords from GeoJSON geometry
#   2. Google Geocoding API  — pass --google-api-key=KEY (most accurate)
#   3. Nominatim             — free fallback, 1 req/sec
#
# Pass --no-geocode to skip steps 2 and 3 (geometry-only entries imported).
#
# The script is resumable: if OUTPUT_FILE already exists, items whose
# google_maps_url is already present are skipped. New items are appended and
# the file is written after each list so progress is not lost on interruption.
#
# Usage:
#   ruby bin/import_takeout_json.rb [TAKEOUT_DIR] [OUTPUT_FILE] [--no-geocode] [--google-api-key=KEY]
#
# Defaults:
#   TAKEOUT_DIR  — ./Takeout
#   OUTPUT_FILE  — ./lists.json

require 'json'
require 'net/http'
require 'uri'
require 'securerandom'
require 'time'
require 'set'

COLORS = %w[
  #3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6
  #ec4899 #06b6d4 #84cc16 #f97316 #6b7280
].freeze

# ── Geocoding ─────────────────────────────────────────────────────────────────

# Queries the Google Geocoding API for the first result matching +name+.
#
# @param name    [String]
# @param api_key [String]
# @return [Array(Float, Float), nil] [lat, lng] or nil
def geocode_with_google(name, api_key)
  uri = URI('https://maps.googleapis.com/maps/api/geocode/json')
  uri.query = URI.encode_www_form(address: name, key: api_key)

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 10
  http.read_timeout = 10

  req = Net::HTTP::Get.new(uri)
  req['Accept'] = 'application/json'

  body    = JSON.parse(http.request(req).body)
  results = body['results'] || []
  return nil if results.empty?

  loc = results[0].dig('geometry', 'location')
  [loc['lat'].to_f, loc['lng'].to_f]
rescue StandardError => e
  warn "    google geocode failed for #{name.inspect}: #{e.message}"
  nil
end

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

# ── JSON ──────────────────────────────────────────────────────────────────────

# Converts a single GeoJSON feature to an item hash (string-keyed), or nil if unusable.
# Returns nil if the feature's URL is already in +known_urls+.
# Falls back to geocoding by name when geometry coords are missing or zero.
#
# @param feature        [Hash]
# @param known_urls     [Set<String>]
# @param allow_geocode  [Boolean]
# @param google_api_key [String, nil]
# @return [Hash, nil]
def convert_json_feature(feature, known_urls, allow_geocode:, google_api_key: nil)
  coords = feature.dig('geometry', 'coordinates') || []
  lng, lat = coords.map(&:to_f)

  props    = feature['properties'] || {}
  location = props['location']     || {}
  name     = location['name'] || props['Title']

  if lat.nil? || lng.nil? || (lat.zero? && lng.zero?)
    return nil unless allow_geocode && name && !name.empty?

    print "    geocoding #{name.inspect}… "
    geocoded = google_api_key ? geocode_with_google(name, google_api_key) : nil
    geocoded ||= geocode(name)

    if geocoded
      lat, lng = geocoded
      puts "#{lat}, #{lng}"
    else
      puts 'not found, skipped'
      return nil
    end
  end

  url = props['google_maps_url'] || "https://maps.google.com/?q=#{lat},#{lng}"
  return nil if known_urls.include?(url)

  {
    'id'              => SecureRandom.uuid,
    'name'            => name || 'Unknown',
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
# @param path           [String]
# @param color          [String]
# @param known_urls     [Set<String>]
# @param existing_list  [Hash, nil]
# @param allow_geocode  [Boolean]
# @param google_api_key [String, nil]
# @return [Hash, nil]
def convert_json_file(path, color, known_urls, existing_list, allow_geocode:, google_api_key: nil)
  data = JSON.parse(File.read(path, encoding: 'utf-8'))
  return nil unless data['type'] == 'FeatureCollection'

  new_items = (data['features'] || []).filter_map do |f|
    convert_json_feature(f, known_urls, allow_geocode: allow_geocode, google_api_key: google_api_key)
  end
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

args = ARGV.dup

if args.include?('--help') || args.include?('-h')
  puts <<~HELP
    Usage:
      ruby bin/import_takeout_json.rb [TAKEOUT_DIR] [OUTPUT_FILE] [OPTIONS]

    Arguments:
      TAKEOUT_DIR              Directory containing Google Takeout JSON files (default: ./Takeout)
      OUTPUT_FILE              Output JSON file path (default: ./lists.json)

    Options:
      --google-api-key=KEY     Use Google Geocoding API for features missing geometry (most accurate)
      --no-geocode             Skip geocoding; only import features with inline geometry coords
      -h, --help               Show this help message

    Coordinate resolution order:
      1. Inline coords from GeoJSON geometry
      2. Google Geocoding API (if --google-api-key is provided)
      3. Nominatim free geocoder (1 req/sec, fallback when no API key)

    The script is resumable: already-imported URLs are skipped automatically.
  HELP
  exit 0
end

no_geocode     = args.delete('--no-geocode')
google_api_key = args.find { |a| a.start_with?('--google-api-key=') }&.split('=', 2)&.last
args.reject! { |a| a.start_with?('--google-api-key=') }
takeout_dir    = args[0] || './Takeout'
output_path    = args[1] || './lists.json'
allow_geocode  = !no_geocode

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

if allow_geocode
  if google_api_key
    puts "Note: Features missing geometry will be geocoded via Google Geocoding API, falling back to Nominatim."
  else
    puts "Note: Features missing geometry will be geocoded via Nominatim (1 req/sec)."
    puts "      Pass --google-api-key=KEY to use Google Geocoding API instead (more accurate)."
  end
  puts "      Pass --no-geocode to skip geocoding (geometry-only features imported)."
  puts "      Already-imported URLs are skipped automatically.\n\n"
end

color_index = output['lists'].length

puts "Processing #{json_files.length} JSON file(s):\n\n"

json_files.each do |path|
  list_name = File.basename(path, '.json')
  print "  [JSON] #{File.basename(path)}… "

  existing     = lists_by_name[list_name]
  before_count = existing ? existing['items'].length : 0
  list         = convert_json_file(
    path, COLORS[color_index % COLORS.length], known_urls, existing,
    allow_geocode: allow_geocode, google_api_key: google_api_key
  )

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
