#!/usr/bin/env ruby
# frozen_string_literal: true

# Converts Google Takeout Maps CSV exports (saved lists) into the
# open-street-lists format.
#
# Place-URL entries are geocoded via Nominatim (1 req/sec).
# Pass --no-geocode to skip geocoding and only import entries whose
# coordinates can be extracted directly from the URL.
#
# The script is resumable: if OUTPUT_FILE already exists, items whose
# google_maps_url is already present are skipped. New items are appended and
# the file is written after each row so progress is not lost on interruption.
#
# Usage:
#   ruby bin/import_takeout_csv.rb [TAKEOUT_DIR] [OUTPUT_FILE] [--no-geocode]
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

# ── CSV ───────────────────────────────────────────────────────────────────────

# Converts a single CSV row to an item hash (string-keyed).
# Skips the row if its URL is already in +known_urls+.
# Tries to extract coordinates from the URL directly; falls back to geocoding.
#
# @param row           [CSV::Row]
# @param known_urls    [Set<String>]
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
      'id'              => SecureRandom.uuid,
      'name'            => name,
      'lat'             => lat,
      'lng'             => lng,
      'notes'           => note,
      'google_maps_url' => url,
      'created_at'      => Time.now.utc.iso8601
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
        'id'              => SecureRandom.uuid,
        'name'            => name,
        'lat'             => lat,
        'lng'             => lng,
        'notes'           => note,
        'google_maps_url' => url,
        'created_at'      => Time.now.utc.iso8601
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

csv_files = Dir.glob(File.join(takeout_dir, '**', '*.csv')).sort

if csv_files.empty?
  warn "No CSV files found in '#{takeout_dir}'."
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
  puts "Note: CSV place entries will be geocoded via Nominatim (1 req/sec)."
  puts "      Pass --no-geocode to skip geocoding (only inline-coord entries imported)."
  puts "      Already-imported URLs are skipped automatically.\n\n"
end

color_index = output['lists'].length

puts "Processing #{csv_files.length} CSV file(s):\n\n"

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
