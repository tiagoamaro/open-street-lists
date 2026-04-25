#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts Google Takeout Maps exports into the open-street-lists format.
# Handles both JSON (GeoJSON FeatureCollections) and CSV (saved lists) files.
#
# CSV files with place-URL entries are geocoded via Nominatim (1 req/sec).
# Pass --no-geocode to skip geocoding and only import entries whose
# coordinates can be extracted directly from the URL.
#
# The script is resumable: if OUTPUT_FILE already exists, items whose
# google_maps_url is already present are skipped. New items are appended and
# the file is written after each list so progress is not lost on interruption.
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
require 'time'
require 'set'

COLORS = %w[
  #3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6
  #ec4899 #06b6d4 #84cc16 #f97316 #6b7280
].freeze

GENERIC_TITLES = %w[dropped\ pin alfinete\ inserido].freeze

# ── Geocoding ─────────────────────────────────────────────────────────────────

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

# ── URL helpers ───────────────────────────────────────────────────────────────

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
    'id'             => SecureRandom.uuid,
    'name'           => location['name'] || props['Title'] || 'Unknown',
    'lat'            => lat,
    'lng'            => lng,
    'notes'          => location['address'] || '',
    'google_maps_url' => url,
    'created_at'     => props['date'] || Time.now.utc.iso8601
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

# ── CSV ───────────────────────────────────────────────────────────────────────

# Converts a single CSV row to an item hash (string-keyed).
# Skips the row if its URL is already in +known_urls+.
# Tries to extract coordinates from the URL directly; falls back to geocoding.
#
# @param row          [CSV::Row]
# @param known_urls   [Set<String>]
# @param allow_geocode [Boolean]
# @return [Hash, nil]
def convert_csv_row(row, known_urls, allow_geocode:)
  title = row['Title']&.strip
  url   = row['URL']&.strip
  note  = row['Note']&.strip || ''

  return nil if url.nil? || url.empty?
  return nil if known_urls.include?(url)

  if (coords = coords_from_search_url(url))
    lat, lng = coords
    name = (title.nil? || title.empty? || GENERIC_TITLES.include?(title.downcase)) ? 'Dropped pin' : title
    return {
      'id'             => SecureRandom.uuid,
      'name'           => name,
      'lat'            => lat,
      'lng'            => lng,
      'notes'          => note,
      'google_maps_url' => url,
      'created_at'     => Time.now.utc.iso8601
    }
  end

  name = (title.nil? || title.empty?) ? name_from_place_url(url) : title
  return nil if name.nil? || name.empty?

  if allow_geocode
    print "    geocoding #{name.inspect}… "
    coords = geocode(name)
    if coords
      lat, lng = coords
      puts "#{lat}, #{lng}"
      return {
        'id'             => SecureRandom.uuid,
        'name'           => name,
        'lat'            => lat,
        'lng'            => lng,
        'notes'          => note,
        'google_maps_url' => url,
        'created_at'     => Time.now.utc.iso8601
      }
    else
      puts 'not found, skipped'
      return nil
    end
  end

  nil
end


# ── Main ──────────────────────────────────────────────────────────────────────

args          = ARGV.dup
no_geocode    = args.delete('--no-geocode')
takeout_dir   = args[0] || './Takeout'
output_path   = args[1] || './lists.json'
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

# Load existing output so the run is resumable
output = begin
  File.exist?(output_path) ? JSON.parse(File.read(output_path, encoding: 'utf-8')) : { 'version' => 1, 'lists' => [] }
rescue JSON::ParserError
  { 'version' => 1, 'lists' => [] }
end

lists_by_name = output['lists'].each_with_object({}) { |l, h| h[l['name']] = l }

# Build set of already-imported URLs so we can skip them
known_urls = Set.new
output['lists'].each { |l| (l['items'] || []).each { |i| known_urls << i['google_maps_url'] } }

if allow_geocode && csv_files.any?
  puts "Note: CSV place entries will be geocoded via Nominatim (1 req/sec)."
  puts "      Pass --no-geocode to skip geocoding (only inline-coord entries imported)."
  puts "      Already-imported URLs are skipped automatically.\n\n"
end

color_index = output['lists'].length # continue colour rotation after existing lists

puts "Processing #{json_files.length} JSON + #{csv_files.length} CSV file(s):\n\n"

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

csv_files.each do |path|
  list_name = File.basename(path, '.csv')
  puts "  [CSV]  #{File.basename(path)}"

  rows = begin
    CSV.read(path, headers: true, encoding: 'utf-8')
  rescue CSV::MalformedCSVError => e
    warn "  Skipping #{path}: #{e.message}"
    next
  end

  list  = lists_by_name[list_name]
  added = 0

  rows.each do |row|
    item = convert_csv_row(row, known_urls, allow_geocode: allow_geocode)
    next unless item

    known_urls << item['google_maps_url']

    unless list
      list = {
        'id'      => SecureRandom.uuid,
        'name'    => list_name,
        'icon'    => '📍',
        'color'   => COLORS[color_index % COLORS.length],
        'visible' => true,
        'items'   => []
      }
      output['lists'] << list
      lists_by_name[list_name] = list
      color_index += 1
    end

    list['items'] << item
    added += 1
    File.write(output_path, JSON.pretty_generate(output))
  end

  if added > 0
    puts "         → #{added} new place(s) added (#{list['items'].length} total in list)"
  else
    puts '         → skipped (no new importable rows)'
  end
end

total = output['lists'].sum { |l| (l['items'] || []).length }
puts "\nDone. #{output['lists'].length} list(s), #{total} place(s) total → #{output_path}"
