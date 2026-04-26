#!/usr/bin/env ruby
# frozen_string_literal: true

# Opens each Google Maps URL from a Google Takeout CSV or JSON export in a real
# Chrome browser, scrapes the resolved name and coordinates, and writes results
# to the open-street-lists format.
#
# Coordinate/name resolution:
#   1. Fast-path: extract directly from the input URL (no browser needed)
#   2. Browser:   navigate to the URL, wait for Google Maps to redirect, then
#                 read the resolved URL + page title
#
# Resumable: if OUTPUT_FILE already exists, items whose google_maps_url is
# already present are skipped. The file is written after every new item so
# progress is not lost on interruption.
#
# Usage:
#   bundle exec ruby import_takeout_selenium.rb INPUT_FILE [OUTPUT_FILE] [LIST_NAME]
#
# Arguments:
#   INPUT_FILE   Google Takeout CSV (saved-places format) or JSON (GeoJSON FeatureCollection)
#   OUTPUT_FILE  Destination JSON file (default: ../lists.json)
#   LIST_NAME    Override list name (default: INPUT_FILE basename without extension)
#
# Options:
#   --headless     Run Chrome in headless mode (default: visible window)
#   --fast-only    Skip browser; only import entries resolvable from the URL alone
#   -h, --help     Show this message

require 'bundler/setup'
require 'selenium-webdriver'
require 'json'
require 'csv'
require 'securerandom'
require 'time'
require 'set'
require 'uri'
require 'cgi'

COLORS = %w[
  #3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6
  #ec4899 #06b6d4 #84cc16 #f97316 #6b7280
].freeze

GENERIC_TITLES = %w[dropped\ pin alfinete\ inserido pin\ solto].freeze

# ── URL helpers (shared with the CSV/JSON importers) ─────────────────────────

# Extracts [lat, lng] from a Google Maps search URL containing coordinates,
# e.g. https://www.google.com/maps/search/-22.87,-42.33
#
# @param url [String]
# @return [Array(Float, Float), nil]
def coords_from_search_url(url)
  m = url.match(%r{/maps/search/(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)})
  return nil unless m

  lat, lng = m[1].to_f, m[2].to_f
  (lat.zero? && lng.zero?) ? nil : [lat, lng]
end

# Extracts [lat, lng] from the @lat,lng anchor present in resolved Google Maps URLs,
# e.g. https://www.google.com/maps/place/Zoo+Berlin/@52.5083,13.369,17z/data=...
#
# @param url [String]
# @return [Array(Float, Float), nil]
def coords_from_place_url(url)
  m = url.match(/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/)
  return nil unless m

  lat, lng = m[1].to_f, m[2].to_f
  (lat.zero? && lng.zero?) ? nil : [lat, lng]
end

# Extracts a human-readable place name from a Google Maps place URL,
# e.g. https://www.google.com/maps/place/Zoo+Berlin/... → "Zoo Berlin"
#
# @param url [String]
# @return [String, nil]
def name_from_place_url(url)
  m = url.match(%r{/maps/place/([^/@]+)})
  return nil unless m && m[1].length > 0

  CGI.unescape(m[1].gsub('+', ' ')).strip.then { |n| n.empty? ? nil : n }
end

# ── Input parsers ─────────────────────────────────────────────────────────────

# Reads a Google Takeout CSV and returns an array of { name:, url: } hashes.
#
# @param path [String]
# @return [Array<Hash>]
def urls_from_csv(path)
  rows = CSV.read(path, headers: true, encoding: 'utf-8')
  rows.filter_map do |row|
    url = row['URL']&.strip
    next if url.nil? || url.empty?

    { name: row['Title']&.strip, url: url, note: row['Note']&.strip || '' }
  end
rescue CSV::MalformedCSVError => e
  warn "Failed to parse CSV #{path}: #{e.message}"
  []
end

# Reads a Google Takeout GeoJSON file and returns an array of { name:, url: } hashes.
#
# @param path [String]
# @return [Array<Hash>]
def urls_from_json(path)
  data = JSON.parse(File.read(path, encoding: 'utf-8'))
  return [] unless data['type'] == 'FeatureCollection'

  (data['features'] || []).filter_map do |f|
    props    = f['properties'] || {}
    location = props['location'] || {}
    name     = location['name'] || props['Title']
    url      = props['google_maps_url']

    # Build a fallback URL from inline geometry if no explicit URL
    if url.nil? || url.empty?
      coords = f.dig('geometry', 'coordinates') || []
      lng, lat = coords.map(&:to_f)
      url = "https://maps.google.com/?q=#{lat},#{lng}" if lat && lng && !(lat.zero? && lng.zero?)
    end

    next if url.nil? || url.empty?

    { name: name, url: url, note: location['address'] || '' }
  end
rescue JSON::ParserError => e
  warn "Failed to parse JSON #{path}: #{e.message}"
  []
end

# ── Browser scraping ──────────────────────────────────────────────────────────

# Builds a Selenium Chrome driver.
#
# @param headless [Boolean]
# @return [Selenium::WebDriver::Driver]
def build_driver(headless:)
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument('--headless=new') if headless
  options.add_argument('--disable-gpu')
  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.add_argument('--window-size=1280,900')
  # Suppress Chrome logging noise
  options.add_argument('--log-level=3')
  options.add_argument('--silent')

  Selenium::WebDriver.for(:chrome, options: options)
end

# Navigates to +url+ in the given driver, waits for Google Maps to settle, then
# returns [name, lat, lng] or nil if data could not be extracted.
#
# @param driver [Selenium::WebDriver::Driver]
# @param url    [String]
# @param name_hint [String, nil] name from the input file (used as fallback label)
# @return [Array(String, Float, Float), nil]
def scrape_google_maps(driver, url, name_hint: nil)
  driver.navigate.to(url)

  # Wait up to 15 s for the URL to contain coordinates (@lat,lng) or for a
  # consent/error page to appear.
  wait = Selenium::WebDriver::Wait.new(timeout: 15, interval: 0.5)

  resolved_url = nil
  begin
    wait.until do
      current = driver.current_url
      # Google Maps resolves to a URL containing @lat,lng once loaded
      if current.include?('@') || current.include?('/maps/search/')
        resolved_url = current
        true
      elsif current.include?('consent.google') || current.include?('accounts.google')
        # Consent / login wall — cannot proceed
        resolved_url = current
        true
      end
    end
  rescue Selenium::WebDriver::Error::TimeoutError
    resolved_url = driver.current_url
  end

  if resolved_url&.match?(/consent\.google|accounts\.google/)
    warn '    blocked by consent/login page — try running without --headless'
    return nil
  end

  coords = coords_from_place_url(resolved_url.to_s) ||
           coords_from_search_url(resolved_url.to_s)

  return nil unless coords

  lat, lng = coords

  # Prefer name from resolved URL, then page title, then input hint
  name = name_from_place_url(resolved_url.to_s)

  if name.nil? || GENERIC_TITLES.include?(name.downcase)
    title = driver.title.to_s.sub(/ [-–|] Google Maps$/i, '').strip
    name = title unless title.empty?
  end

  name ||= name_hint || 'Unknown'

  [name, lat, lng]
rescue Selenium::WebDriver::Error::WebDriverError => e
  warn "    browser error for #{url.inspect}: #{e.message}"
  nil
end

# ── Item builder ──────────────────────────────────────────────────────────────

# Builds a list item hash from scraped data.
#
# @param name [String]
# @param lat  [Float]
# @param lng  [Float]
# @param url  [String]
# @param note [String]
# @return [Hash]
def build_item(name, lat, lng, url, note)
  {
    'id'              => SecureRandom.uuid,
    'name'            => name,
    'lat'             => lat,
    'lng'             => lng,
    'notes'           => note,
    'google_maps_url' => url,
    'created_at'      => Time.now.utc.iso8601
  }
end

# ── Main ──────────────────────────────────────────────────────────────────────

args = ARGV.dup

if args.include?('--help') || args.include?('-h')
  puts <<~HELP
    Usage:
      bundle exec ruby import_takeout_selenium.rb INPUT_FILE [OUTPUT_FILE] [LIST_NAME]

    Arguments:
      INPUT_FILE   Google Takeout CSV or GeoJSON file
      OUTPUT_FILE  Destination JSON (default: ../lists.json)
      LIST_NAME    Override list name (default: INPUT_FILE basename)

    Options:
      --headless    Run Chrome in headless mode
      --fast-only   Skip browser; import only entries with inline coordinates
      -h, --help    Show this message
  HELP
  exit 0
end

headless  = args.delete('--headless')
fast_only = args.delete('--fast-only')

input_path  = args[0]
output_path = args[1] || File.expand_path('../lists.json', __dir__)
list_name   = args[2]

if input_path.nil?
  warn 'Error: INPUT_FILE is required.'
  exit 1
end

unless File.exist?(input_path)
  warn "Error: file '#{input_path}' not found."
  exit 1
end

ext = File.extname(input_path).downcase
unless ['.csv', '.json'].include?(ext)
  warn "Error: INPUT_FILE must be a .csv or .json file."
  exit 1
end

list_name ||= File.basename(input_path, ext)

# Load input entries
entries = ext == '.csv' ? urls_from_csv(input_path) : urls_from_json(input_path)

if entries.empty?
  warn 'No importable entries found in input file.'
  exit 1
end

puts "Loaded #{entries.length} entr#{entries.length == 1 ? 'y' : 'ies'} from #{File.basename(input_path)}"

# Load or initialise output
output = begin
  File.exist?(output_path) ? JSON.parse(File.read(output_path, encoding: 'utf-8')) : { 'version' => 1, 'lists' => [] }
rescue JSON::ParserError
  { 'version' => 1, 'lists' => [] }
end

lists_by_name = output['lists'].each_with_object({}) { |l, h| h[l['name']] = l }

known_urls = Set.new
output['lists'].each { |l| (l['items'] || []).each { |i| known_urls << i['google_maps_url'] } }

pending = entries.reject { |e| known_urls.include?(e[:url]) }
puts "#{known_urls.size} URL(s) already imported. #{pending.length} remaining.\n\n"

if pending.empty?
  total = output['lists'].sum { |l| (l['items'] || []).length }
  puts "Nothing to do. #{output['lists'].length} list(s), #{total} place(s) total → #{output_path}"
  exit 0
end

# Ensure the target list exists
list = lists_by_name[list_name]
unless list
  color_index = output['lists'].length
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
end

driver    = nil
added     = 0
skipped   = 0

pending.each_with_index do |entry, idx|
  url  = entry[:url]
  note = entry[:note] || ''
  label = "  [#{idx + 1}/#{pending.length}]"

  # Fast-path: extract from URL without browser
  fast_coords = coords_from_search_url(url) || coords_from_place_url(url)

  if fast_coords
    lat, lng = fast_coords
    name = entry[:name]
    name = nil if name.nil? || name.empty? || GENERIC_TITLES.include?(name.downcase)
    name ||= name_from_place_url(url) || 'Dropped pin'
    puts "#{label} #{name} (#{lat}, #{lng}) [from URL]"

    item = build_item(name, lat, lng, url, note)
    list['items'] << item
    known_urls << url
    added += 1
    File.write(output_path, JSON.pretty_generate(output))
    next
  end

  if fast_only
    puts "#{label} skipped (no inline coords, --fast-only active)"
    skipped += 1
    next
  end

  # Browser path
  driver ||= build_driver(headless: headless)

  name_hint = entry[:name]&.then { |n| GENERIC_TITLES.include?(n.downcase) ? nil : n }
  print "#{label} opening browser for #{(name_hint || url).inspect}… "

  result = scrape_google_maps(driver, url, name_hint: name_hint)

  if result
    name, lat, lng = result
    puts "#{name} → #{lat}, #{lng}"

    item = build_item(name, lat, lng, url, note)
    list['items'] << item
    known_urls << url
    added += 1
    File.write(output_path, JSON.pretty_generate(output))
  else
    puts 'not found, skipped'
    skipped += 1
  end
end

driver&.quit

total = output['lists'].sum { |l| (l['items'] || []).length }
puts "\nDone. Added #{added}, skipped #{skipped}. #{output['lists'].length} list(s), #{total} place(s) total → #{output_path}"
