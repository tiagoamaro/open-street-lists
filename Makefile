# Google Takeout import scripts
#
# Usage:
#   make install
#   make selenium INPUT=path/to/file.csv
#   make selenium INPUT=path/to/file.json OUTPUT=lists.json
#   make selenium INPUT=... HEADLESS=1
#   make selenium INPUT=... FAST_ONLY=1

SCRIPTS_DIR  := google_takeout_scripts
BUNDLE       := bundle exec
OUTPUT       ?= lists.json
LIST_NAME    ?=
HEADLESS     ?=
FAST_ONLY    ?=

FLAGS :=
ifdef LIST_NAME
  FLAGS += $(LIST_NAME)
endif
ifdef HEADLESS
  FLAGS += --headless
endif
ifdef FAST_ONLY
  FLAGS += --fast-only
endif

.PHONY: install selenium csv json help

## Install gem dependencies
install:
	cd $(SCRIPTS_DIR) && bundle install

## Run the Selenium browser importer
## Required: INPUT=path/to/file.csv or INPUT=path/to/file.json
## Optional: OUTPUT=lists.json  LIST_NAME="My List"  HEADLESS=1  FAST_ONLY=1
selenium: install
ifndef INPUT
	$(error INPUT is required. Usage: make selenium INPUT=path/to/file.csv)
endif
	cd $(SCRIPTS_DIR) && bundle exec ruby import_takeout_selenium.rb \
	  "$$(realpath "$(INPUT)")" "$(CURDIR)/$(OUTPUT)" $(FLAGS)

## Run the plain CSV importer (no browser, no gems needed)
## Required: INPUT=path/to/file.csv
## Optional: OUTPUT=lists.json  GOOGLE_API_KEY=KEY  NO_GEOCODE=1
csv:
ifndef INPUT
	$(error INPUT is required. Usage: make csv INPUT=path/to/file.csv)
endif
	ruby $(SCRIPTS_DIR)/import_takeout_csv.rb "$(INPUT)" "$(OUTPUT)" \
	  $(if $(GOOGLE_API_KEY),--google-api-key=$(GOOGLE_API_KEY),) \
	  $(if $(NO_GEOCODE),--no-geocode,)

## Run the plain JSON importer (no browser, no gems needed)
## Required: INPUT=path/to/file.json
## Optional: OUTPUT=lists.json  GOOGLE_API_KEY=KEY  NO_GEOCODE=1
json:
ifndef INPUT
	$(error INPUT is required. Usage: make json INPUT=path/to/file.json)
endif
	ruby $(SCRIPTS_DIR)/import_takeout_json.rb "$(INPUT)" "$(OUTPUT)" \
	  $(if $(GOOGLE_API_KEY),--google-api-key=$(GOOGLE_API_KEY),) \
	  $(if $(NO_GEOCODE),--no-geocode,)

## Show this help
help:
	@grep -E '^##' $(MAKEFILE_LIST) | sed 's/^## //'
