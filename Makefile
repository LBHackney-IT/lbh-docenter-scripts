.PHONY: init
init:
	./initialiseRepository.sh

.PHONY: db
db:
	./scrapers/databases.sh -d ./social-care-case-viewer-api
